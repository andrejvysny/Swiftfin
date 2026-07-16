//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

// MARK: - Shared Data Structures

struct DownloadMetadata: Codable {
    let itemId: String
    let itemType: String?
    let displayTitle: String
    var item: BaseItemDto?
    var episodes: [String: BaseItemDto]?
    var versions: [VersionInfo]

    init(
        itemId: String,
        itemType: String?,
        displayTitle: String,
        item: BaseItemDto? = nil,
        episodes: [String: BaseItemDto]? = nil,
        versions: [VersionInfo] = []
    ) {
        self.itemId = itemId
        self.itemType = itemType
        self.displayTitle = displayTitle
        self.item = item
        self.episodes = episodes
        self.versions = versions
    }
}

struct VersionInfo: Codable {
    let versionId: String
    let container: String
    let isStatic: Bool
    let mediaSourceId: String?
    let episodeId: String?
    let downloadDate: String
    let taskId: String

    init(
        versionId: String,
        container: String,
        isStatic: Bool,
        mediaSourceId: String?,
        episodeId: String? = nil,
        downloadDate: String,
        taskId: String
    ) {
        self.versionId = versionId
        self.container = container
        self.isStatic = isStatic
        self.mediaSourceId = mediaSourceId
        self.episodeId = episodeId
        self.downloadDate = downloadDate
        self.taskId = taskId
    }
}

struct DownloadPlaybackInfo {
    let item: BaseItemDto
    let mediaSource: MediaSourceInfo
    let version: VersionInfo
    let fileURL: URL

    var defaultAudioStreamIndex: Int {
        mediaSource.defaultAudioStreamIndex
            ?? mediaSource.audioStreams?.first?.index
            ?? -1
    }

    var defaultSubtitleStreamIndex: Int {
        mediaSource.defaultSubtitleStreamIndex
            ?? mediaSource.subtitleStreams?.first?.index
            ?? -1
    }
}

// MARK: - Download Job Types

enum DownloadJobType: Hashable, Equatable {
    case media
    case backdropImage
    case primaryImage
    case metadata
    case subtitle(index: Int)
}

enum ImageDownloadContext: Hashable, Equatable {
    case episode(id: String)
    case season(id: String)
    case series(id: String)
    case movie(id: String)
}

/// Download quality selection reusing the existing `PlaybackBitrate` for transcoding.
enum DownloadQuality: Hashable, Equatable {
    case original
    case transcoded(PlaybackBitrate)
}

// MARK: - Codable Wrapper for DownloadQuality

enum CodableDownloadQuality: Codable, Equatable {
    case original
    case transcoded(Int)

    init(from quality: DownloadQuality) {
        switch quality {
        case .original:
            self = .original
        case let .transcoded(bitrate):
            self = .transcoded(bitrate.rawValue)
        }
    }

    func toDownloadQuality() -> DownloadQuality {
        switch self {
        case .original:
            return .original
        case let .transcoded(rawValue):
            if let bitrate = PlaybackBitrate(rawValue: rawValue) {
                return .transcoded(bitrate)
            }
            return .original
        }
    }
}

// MARK: - Active Download Record

struct ActiveDownloadRecord: Codable, Identifiable {
    let id: UUID
    let itemId: String
    let storageItemId: String?
    let episodeId: String?
    let mediaSourceId: String?
    let versionId: String?
    let container: String
    let quality: CodableDownloadQuality
    let isStatic: Bool
    let allowVideoStreamCopy: Bool
    let allowAudioStreamCopy: Bool
    let deviceId: String?
    let deviceProfileId: String?
    let downloadURL: URL
    let startedAt: Date
    var urlSessionTaskIdentifier: Int?
    var lastKnownProgress: Double
    var status: ActiveDownloadStatus
    var queuePosition: Int?

    enum ActiveDownloadStatus: String, Codable {
        case active
        case paused
        case queued
        case waitingForReconnect
        case forceQuitCancelled
    }
}

// MARK: - Recovery Result

struct RecoveryResult {
    let reconnected: [(record: ActiveDownloadRecord, urlSessionTaskIdentifier: Int)]
    let orphaned: [ActiveDownloadRecord]
}

// MARK: - Download Recovery Error

enum DownloadRecoveryError: Error, LocalizedError {
    case forceQuitCancelled
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .forceQuitCancelled:
            "Download was cancelled because the app was force-quit"
        case .sessionExpired:
            "Download session expired"
        }
    }
}

struct DownloadJob {
    let type: DownloadJobType
    let taskID: UUID
    let url: URL
    let destinationPath: String
}

// MARK: - Error Types

enum MediaValidationError: Error, LocalizedError {
    case invalidHTTPStatus(Int)
    case unacceptableContentType(String?)
    case suspiciouslySmallFile(Int64)

    var errorDescription: String? {
        switch self {
        case let .invalidHTTPStatus(code):
            "Invalid HTTP status: \(code)"
        case let .unacceptableContentType(type):
            "Unacceptable content type: \(type ?? "unknown")"
        case let .suspiciouslySmallFile(size):
            "Downloaded media file is too small (\(size) bytes)"
        }
    }
}

// MARK: - Service Protocols

protocol DownloadFileServicing {
    func ensureDownloadDirectory() throws
    func moveMediaFile(from temp: URL, to destination: URL, for task: DownloadTask, response: URLResponse?) throws
    func moveImageFile(
        from temp: URL,
        to destination: URL,
        for task: DownloadTask,
        response: URLResponse?,
        jobType: DownloadJobType,
        context: ImageDownloadContext
    ) throws
    func validateMediaFile(at url: URL, response: URLResponse?) throws
    func calculateSize(of folder: URL) throws -> Int64
    func deleteDownloads(for itemId: String) throws -> Bool
    func deleteAllDownloads() throws
    func clearTmp()
    func checkAvailableDiskSpace() throws
    func hasMediaFile(for itemId: String, mediaSourceId: String?) -> Bool
    func getDownloadedItemIds() -> [String]
    func getTotalDownloadSize() -> Int64?
    func getDownloadSize(itemId: String) -> Int64?
    func isItemDownloaded(itemId: String) -> Bool
    func mediaFileURL(for item: BaseItemDto, version: VersionInfo?) -> URL?
}

protocol DownloadURLBuilding {
    func mediaURL(
        itemId: String,
        quality: DownloadQuality,
        mediaSourceId: String?,
        container: String,
        isStatic: Bool,
        allowVideoStreamCopy: Bool,
        allowAudioStreamCopy: Bool,
        deviceId: String?,
        deviceProfileId: String?
    ) -> URL?

    func imageURL(for item: BaseItemDto, type: DownloadJobType) -> URL?
}

protocol DownloadMetadataManaging {
    func readMetadata(itemId: String) -> DownloadMetadata?
    func readSeasonMetadata(seriesId: String, seasonNumber: Int) -> DownloadMetadata?
    func writeMetadata(for task: DownloadTask) throws
    func getDownloadedVersions(for itemId: String) -> [VersionInfo]
    func parseDownloadItem(with id: String) -> DownloadTask?
}

protocol DownloadImageManaging {
    func downloadImages(for task: DownloadTask, completion: @escaping (Result<Void, Error>) -> Void)
}

protocol DownloadSessionManaging {
    var delegate: DownloadSessionDelegate? { get set }
    var backgroundCompletionHandler: (() -> Void)? { get set }
    func start(url: URL, taskID: UUID, jobType: DownloadJobType) async throws -> Int
    func pause(taskID: UUID)
    func resume(taskID: UUID, with resumeData: Data?) async throws -> Int
    func cancel(taskID: UUID)
    func getAllTasks() -> [URLSessionDownloadTask]

    // Job management methods
    func getDownloadJob(for taskIdentifier: Int) -> DownloadJob?
    func removeDownloadJob(for taskIdentifier: Int)

    // Recovery
    func recoverActiveDownloads(records: [ActiveDownloadRecord]) async -> RecoveryResult
}

// MARK: - Delegate Protocol

@MainActor
protocol DownloadSessionDelegate: AnyObject {
    func sessionDidCompleteDownload(taskIdentifier: Int, location: URL, response: URLResponse?)
    func sessionDidUpdateProgress(taskIdentifier: Int, progress: Double)
    func sessionDidCompleteWithError(taskIdentifier: Int, error: Error?)
    func sessionDidSaveResumeData(_ data: Data, for taskIdentifier: Int)
    func sessionDidFinishBackgroundEvents()
}
