import Foundation

/// High level interface for the download manager.
public protocol DownloadManagerProtocol {
    @discardableResult
    func enqueue(_ item: URL, priority: TaskPriority) async -> DownloadID
    func pause(_ id: DownloadID) async
    func resume(_ id: DownloadID) async
    func cancel(_ id: DownloadID) async
    var events: AsyncStream<DownloadEvent> { get }
}
