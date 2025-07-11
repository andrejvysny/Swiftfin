import Foundation

/// Unique identifier for download tasks.
public typealias DownloadID = UUID

/// Priority levels for download tasks
public enum TaskPriority: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    
    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Download task state
public enum DownloadState: String {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

/// Possible events emitted by `DownloadManager`.
public enum DownloadEvent: Sendable {
    case queued(DownloadID)
    case started(DownloadID)
    case progress(DownloadID, Double)
    case completed(DownloadID, URL)
    case failed(DownloadID, DownloadError)
    case paused(DownloadID)
    case resumed(DownloadID)
    case cancelled(DownloadID)
}

/// Errors that may occur during downloads.
public enum DownloadError: Error, LocalizedError {
    case network(underlying: Error?)
    case server(statusCode: Int)
    case diskFull
    case cancelled
    case timeout
    case offline
    case integrityCheckFailed
    case quotaExceeded
    case unknown
    
    public var errorDescription: String? {
        switch self {
        case .network(let error):
            return "Network error: \(error?.localizedDescription ?? "Unknown")"
        case .server(let code):
            return "Server error: HTTP \(code)"
        case .diskFull:
            return "Insufficient storage space"
        case .cancelled:
            return "Download cancelled"
        case .timeout:
            return "Request timed out"
        case .offline:
            return "No internet connection"
        case .integrityCheckFailed:
            return "Downloaded file is corrupted"
        case .quotaExceeded:
            return "Download quota exceeded"
        case .unknown:
            return "Unknown error occurred"
        }
    }
    
    init(from error: Error) {
        let nsError = error as NSError
        
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            self = .offline
        case NSURLErrorTimedOut:
            self = .timeout
        case NSURLErrorCancelled:
            self = .cancelled
        case NSURLErrorCannotWriteToFile, NSURLErrorFileDoesNotExist:
            self = .diskFull
        default:
            if nsError.domain == NSURLErrorDomain {
                self = .network(underlying: error)
            } else {
                self = .unknown
            }
        }
    }
}

/// Metadata for download validation
public struct DownloadMetadata: Codable {
    public let expectedSize: Int64?
    public let checksum: String?
    public let mimeType: String?
    public let filename: String?
    
    public init(expectedSize: Int64? = nil, checksum: String? = nil, 
                mimeType: String? = nil, filename: String? = nil) {
        self.expectedSize = expectedSize
        self.checksum = checksum
        self.mimeType = mimeType
        self.filename = filename
    }
}
