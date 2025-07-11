import Foundation

/// Protocol for network operations, enabling testing via dependency injection
public protocol NetworkServiceProtocol: AnyObject {
    func createDownloadTask(with url: URL, identifier: DownloadID) -> URLSessionDownloadTask
    func createDownloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask
    func invalidateAndCancel()
}

/// Delegate protocol for network layer events
public protocol NetworkLayerDelegate: AnyObject, Sendable {
    func networkLayer(_ layer: NetworkLayer, didUpdateProgress progress: Double, for id: DownloadID) async
    func networkLayer(_ layer: NetworkLayer, didCompleteDownload id: DownloadID, at location: URL) async
    func networkLayer(_ layer: NetworkLayer, didFailDownload id: DownloadID, with error: Error) async
} 