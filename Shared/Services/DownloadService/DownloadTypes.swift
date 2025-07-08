import Foundation

/// Unique identifier for download tasks.
public typealias DownloadID = UUID

/// Possible events emitted by `DownloadManager`.
public enum DownloadEvent {
    case started(DownloadID)
    case progress(DownloadID, Double)
    case completed(DownloadID, URL)
    case failed(DownloadID, DownloadError)
}

/// Errors that may occur during downloads.
public enum DownloadError: Error {
    case network
    case server
    case diskFull
    case cancelled
    case unknown
}
