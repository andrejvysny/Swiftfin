import Foundation

/// High level interface for the download manager
public protocol DownloadManagerProtocol: Sendable {
    /// Enqueue a new download
    @discardableResult
    func enqueue(_ url: URL, priority: TaskPriority, metadata: DownloadMetadata?) async -> DownloadID
    
    /// Pause an active download
    func pause(_ id: DownloadID) async
    
    /// Resume a paused download
    func resume(_ id: DownloadID) async
    
    /// Cancel a download
    func cancel(_ id: DownloadID) async
    
    /// Stream of download events
    var events: AsyncStream<DownloadEvent> { get }
}
