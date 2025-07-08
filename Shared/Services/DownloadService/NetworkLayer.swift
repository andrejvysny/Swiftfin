import Foundation
import os.log

/// Network layer that manages the background URLSession.
final class NetworkLayer: NSObject {
    static let shared = NetworkLayer()

    /// Completion handler provided by the app delegate when the background session finishes.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "org.jellyfin.swiftfin.download")
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func createTask(for url: URL, identifier: DownloadID) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: url)
        task.taskDescription = identifier.uuidString
        return task
    }
}

extension NetworkLayer: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString) else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { await TaskCoordinator.shared?.updateProgress(for: id, progress: progress) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString) else { return }
        Task { await TaskCoordinator.shared?.completed(id: id, location: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let idString = task.taskDescription, let id = UUID(uuidString: idString) else { return }
        Task { await TaskCoordinator.shared?.failed(id: id, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}
