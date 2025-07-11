import Foundation
import os.log

/// Network layer that manages the background URLSession.
public final class NetworkLayer: NSObject {
    private let logger = Logger(subsystem: "org.jellyfin.swiftfin", category: "NetworkLayer")
    
    /// Thread-safe access to completion handler
    private let completionHandlerQueue = DispatchQueue(label: "org.jellyfin.download.completion")
    private var _backgroundCompletionHandler: (() -> Void)?
    
    /// Delegate for network events
    public weak var delegate: NetworkLayerDelegate?
    
    /// Session identifier for background downloads
    private let sessionIdentifier: String
    
    /// Lazy-loaded background session
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.shouldUseExtendedBackgroundIdleMode = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    public init(identifier: String = "org.jellyfin.swiftfin.download") {
        self.sessionIdentifier = identifier
        super.init()
    }
    
    /// Thread-safe completion handler property
    public var backgroundCompletionHandler: (() -> Void)? {
        get { completionHandlerQueue.sync { _backgroundCompletionHandler } }
        set { completionHandlerQueue.sync { _backgroundCompletionHandler = newValue } }
    }
}

// MARK: - NetworkServiceProtocol

extension NetworkLayer: NetworkServiceProtocol {
    public func createDownloadTask(with url: URL, identifier: DownloadID) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: url)
        task.taskDescription = identifier.uuidString
        task.priority = URLSessionTask.defaultPriority
        return task
    }
    
    public func createDownloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        return session.downloadTask(withResumeData: resumeData)
    }
    
    public func invalidateAndCancel() {
        session.invalidateAndCancel()
    }
}

// MARK: - URLSessionDownloadDelegate

extension NetworkLayer: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, 
                          downloadTask: URLSessionDownloadTask,
                          didWriteData bytesWritten: Int64, 
                          totalBytesWritten: Int64,
                          totalBytesExpectedToWrite: Int64) {
        guard let idString = downloadTask.taskDescription, 
              let id = UUID(uuidString: idString) else { 
            logger.warning("Download task missing identifier")
            return 
        }
        
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        Task { [weak delegate] in
            await delegate?.networkLayer(self, didUpdateProgress: progress, for: id)
        }
    }
    
    public func urlSession(_ session: URLSession, 
                          downloadTask: URLSessionDownloadTask,
                          didFinishDownloadingTo location: URL) {
        guard let idString = downloadTask.taskDescription, 
              let id = UUID(uuidString: idString) else { 
            logger.warning("Download task missing identifier")
            return 
        }
        
        logger.debug("Download completed for \(id) at \(location.path)")
        
        Task { [weak delegate] in
            await delegate?.networkLayer(self, didCompleteDownload: id, at: location)
        }
    }
    
    public func urlSession(_ session: URLSession, 
                          task: URLSessionTask, 
                          didCompleteWithError error: Error?) {
        guard let error, 
              let idString = task.taskDescription, 
              let id = UUID(uuidString: idString) else { return }
        
        // Check if we got resume data
        let userInfo = (error as NSError).userInfo
        if let resumeData = userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            logger.debug("Download failed with resume data for \(id)")
            // Store resume data in the error for coordinator to handle
            let errorWithResumeData = NSError(
                domain: (error as NSError).domain,
                code: (error as NSError).code,
                userInfo: userInfo
            )
            Task { [weak delegate] in
                await delegate?.networkLayer(self, didFailDownload: id, with: errorWithResumeData)
            }
        } else {
            logger.error("Download failed for \(id): \(error.localizedDescription)")
            Task { [weak delegate] in
                await delegate?.networkLayer(self, didFailDownload: id, with: error)
            }
        }
    }
    
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        logger.info("Background session finished events")
        
        completionHandlerQueue.async { [weak self] in
            self?._backgroundCompletionHandler?()
            self?._backgroundCompletionHandler = nil
        }
    }
    
    public func urlSession(_ session: URLSession, 
                          didBecomeInvalidWithError error: Error?) {
        if let error {
            logger.error("Session became invalid: \(error.localizedDescription)")
        }
    }
}
