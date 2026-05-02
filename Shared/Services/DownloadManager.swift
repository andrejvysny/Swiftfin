//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation
import JellyfinAPI
import Logging

@MainActor
final class DownloadManager: NSObject, ObservableObject {

    private let logger = Logger.swiftfin()

    // Published state for UI
    @Published
    private(set) var downloads: [DownloadTask] = []

    // Published state tracking for each task
    @Published
    private(set) var taskStates: [UUID: DownloadTask.State] = [:]
    @Published
    private(set) var storageMutationVersion: Int = 0

    // Injected services
    private var sessionManager: DownloadSessionManaging
    private let urlBuilder: DownloadURLBuilding
    private let metadataManager: DownloadMetadataManaging
    private let imageManager: DownloadImageManaging
    private let fileService: DownloadFileServicing
    private let queuePersistence: DownloadQueuePersistence

    // Track completion status for each DownloadTask
    private var completedJobsByTask: [UUID: Set<DownloadJobType>] = [:]

    // Concurrent download queue
    private let maxConcurrentDownloads = 3
    private var pendingQueue: [DownloadTask] = []

    // Progress persistence throttling
    private var lastPersistedProgress: [UUID: Double] = [:]

    init(
        sessionManager: DownloadSessionManaging = DownloadSessionManager(),
        urlBuilder: DownloadURLBuilding = DownloadURLBuilder(),
        metadataManager: DownloadMetadataManaging? = nil,
        imageManager: DownloadImageManaging? = nil,
        fileService: DownloadFileServicing = DownloadFileService(),
        queuePersistence: DownloadQueuePersistence = Container.shared.downloadQueuePersistence()
    ) {
        self.sessionManager = sessionManager
        self.urlBuilder = urlBuilder
        self.fileService = fileService
        self.queuePersistence = queuePersistence

        self.metadataManager = metadataManager ?? DownloadMetadataManager(fileService: fileService)
        self.imageManager = imageManager ?? DownloadImageManager(urlBuilder: urlBuilder, fileService: fileService)

        super.init()

        self.sessionManager.delegate = self

        // Wire up background session completion handler from AppDelegate
        #if os(iOS)
        if let handler = AppDelegate.backgroundSessionCompletionHandler {
            self.sessionManager.backgroundCompletionHandler = handler
            AppDelegate.backgroundSessionCompletionHandler = nil
        }
        #endif

        do {
            try fileService.ensureDownloadDirectory()
        } catch {
            logger.error("Failed to create downloads directory: \(error.localizedDescription)")
        }

        recoverDownloadsOnLaunch()
    }

    // MARK: - Public Interface

    func clearTmp() {
        fileService.clearTmp()
    }

    // MARK: - State Management

    func getTaskState(taskID: UUID) -> DownloadTask.State {
        taskStates[taskID] ?? .ready
    }

    private func updateTaskState(taskID: UUID, state: DownloadTask.State) {
        taskStates[taskID] = state
    }

    private func incrementStorageMutationVersion() {
        storageMutationVersion = storageMutationVersion &+ 1
    }

    func deleteRootFolder(for task: DownloadTask) {
        guard let downloadFolder = task.item.downloadFolder else { return }
        try? FileManager.default.removeItem(at: downloadFolder)
    }

    func createFolder(for task: DownloadTask) throws {
        guard let downloadFolder = task.item.downloadFolder else { return }
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
    }

    func download(task: DownloadTask) {
        guard !downloads.contains(where: { $0.taskID == task.taskID }) else { return }

        downloads.append(task)

        if activeDownloadCount() >= maxConcurrentDownloads {
            updateTaskState(taskID: task.taskID, state: .queued)
            pendingQueue.append(task)
            persistQueue()
        } else {
            updateTaskState(taskID: task.taskID, state: .ready)
            persistQueue()
            Task {
                await startDownloadForTask(task)
            }
        }
    }

    // MARK: - Queue Helpers

    private func activeDownloadCount() -> Int {
        let queuedIDs = Set(pendingQueue.map(\.taskID))
        return taskStates.count(where: { key, value in
            guard !queuedIDs.contains(key) else { return false }
            switch value {
            case .downloading, .ready:
                return true
            default:
                return false
            }
        })
    }

    private func startNextQueuedDownload() {
        while activeDownloadCount() < maxConcurrentDownloads, !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            updateTaskState(taskID: next.taskID, state: .ready)
            Task {
                await startDownloadForTask(next)
            }
        }
        persistQueue()
    }

    private func startDownloadForTask(_ downloadTask: DownloadTask) async {
        do {
            try fileService.checkAvailableDiskSpace()

            guard let downloadURL = urlBuilder.mediaURL(
                itemId: downloadTask.item.id!,
                quality: downloadTask.quality,
                mediaSourceId: downloadTask.mediaSourceId,
                container: downloadTask.container,
                isStatic: downloadTask.isStatic,
                allowVideoStreamCopy: downloadTask.allowVideoStreamCopy,
                allowAudioStreamCopy: downloadTask.allowAudioStreamCopy,
                deviceId: downloadTask.deviceId,
                deviceProfileId: downloadTask.deviceProfileId
            ) else {
                logger.error("Failed to construct download URL for item: \(downloadTask.item.id!)")
                updateTaskState(taskID: downloadTask.taskID, state: .error(URLError(.badURL)))
                return
            }

            completedJobsByTask[downloadTask.taskID] = Set<DownloadJobType>()
            try await startAllDownloads(for: downloadTask, with: downloadURL)
        } catch {
            logger.error("Failed to start download for item: \(downloadTask.item.id!) - \(error.localizedDescription)")
            updateTaskState(taskID: downloadTask.taskID, state: .error(error))
        }
    }

    func startDownload(
        itemId: String,
        quality: DownloadQuality = .original,
        mediaSourceId: String? = nil,
        container: String = "mp4",
        isStatic: Bool = true,
        allowVideoStreamCopy: Bool = true,
        allowAudioStreamCopy: Bool = true,
        deviceId: String? = nil,
        deviceProfileId: String? = nil
    ) -> UUID {
        if let existing = downloads.first(where: { task in
            guard task.item.id == itemId && task.mediaSourceId == mediaSourceId else { return false }
            let currentState = taskStates[task.taskID] ?? .ready
            switch currentState {
            case .ready, .downloading, .paused, .queued:
                return true
            default:
                return false
            }
        }) {
            logger
                .info(
                    "Download already in progress for item: \(itemId), mediaSourceId: \(mediaSourceId ?? "nil"). Returning existing task ID."
                )
            return existing.taskID
        }

        let taskID = UUID()
        logger.trace("Starting download for item: \(itemId) with task ID: \(taskID)")

        Task {
            do {
                try fileService.checkAvailableDiskSpace()

                guard let userSession = Container.shared.currentUserSession() else {
                    logger.error("No user session available for download")
                    return
                }

                let request = Paths.getItem(itemID: itemId, userID: userSession.user.id)
                let response = try await userSession.client.send(request)
                let item = response.value

                let downloadTask = DownloadTask(
                    item: item,
                    taskID: taskID,
                    mediaSourceId: mediaSourceId,
                    versionId: mediaSourceId,
                    container: container,
                    quality: quality,
                    isStatic: isStatic,
                    allowVideoStreamCopy: allowVideoStreamCopy,
                    allowAudioStreamCopy: allowAudioStreamCopy,
                    deviceId: deviceId,
                    deviceProfileId: deviceProfileId
                )

                await MainActor.run {
                    self.downloads.append(downloadTask)

                    if self.activeDownloadCount() >= self.maxConcurrentDownloads {
                        self.taskStates[taskID] = .queued
                        self.pendingQueue.append(downloadTask)
                        self.persistQueue()
                    } else {
                        self.taskStates[taskID] = .ready
                        self.persistQueue()
                    }
                }

                // Only start if not queued
                let isQueued = await MainActor.run { self.pendingQueue.contains(where: { $0.taskID == taskID }) }
                guard !isQueued else { return }

                guard let downloadURL = urlBuilder.mediaURL(
                    itemId: itemId,
                    quality: quality,
                    mediaSourceId: mediaSourceId,
                    container: container,
                    isStatic: isStatic,
                    allowVideoStreamCopy: allowVideoStreamCopy,
                    allowAudioStreamCopy: allowAudioStreamCopy,
                    deviceId: deviceId,
                    deviceProfileId: deviceProfileId
                ) else {
                    logger.error("Failed to construct download URL for item: \(itemId)")
                    return
                }

                completedJobsByTask[taskID] = Set<DownloadJobType>()
                try await startAllDownloads(for: downloadTask, with: downloadURL)
            } catch {
                logger.error("Failed to start download for item: \(itemId) - \(error.localizedDescription)")

                await MainActor.run {
                    if self.downloads.firstIndex(where: { $0.taskID == taskID }) != nil {
                        self.taskStates[taskID] = .error(error)
                    }
                }
            }
        }

        return taskID
    }

    func pauseDownload(taskID: UUID) {
        guard downloads.first(where: { $0.taskID == taskID }) != nil else { return }

        sessionManager.pause(taskID: taskID)

        updateTaskState(taskID: taskID, state: .paused)
        queuePersistence.update(id: taskID) { $0.status = .paused }
    }

    func resumeDownload(taskID: UUID) {
        guard let task = downloads.first(where: { $0.taskID == taskID }) else { return }

        let resumeData = queuePersistence.loadResumeData(for: taskID)

        Task {
            do {
                let urlTaskId = try await sessionManager.resume(taskID: taskID, with: resumeData)

                updateTaskState(taskID: taskID, state: .downloading(0.0))
                queuePersistence.update(id: taskID) { record in
                    record.urlSessionTaskIdentifier = urlTaskId
                    record.status = .active
                }
                queuePersistence.deleteResumeData(for: taskID)
            } catch {
                logger.info("Resume failed, restarting download: \(error.localizedDescription)")
                await restartDownload(for: task)
            }
        }
    }

    func cancelDownload(taskID: UUID, removeFile: Bool = false) {
        guard let task = downloads.first(where: { $0.taskID == taskID }) else {
            logger.warning("Attempted to cancel non-existent download task: \(taskID)")
            return
        }

        logger.info("Cancelling download for task: \(taskID)")

        // Remove from pending queue if queued
        pendingQueue.removeAll(where: { $0.taskID == taskID })

        sessionManager.cancel(taskID: taskID)

        completedJobsByTask.removeValue(forKey: taskID)
        queuePersistence.remove(id: taskID)
        queuePersistence.deleteResumeData(for: taskID)

        if removeFile {
            let didMutateStorage = removeDownloadedStorage(for: task)
            if didMutateStorage {
                incrementStorageMutationVersion()
            }
        }

        cancel(task: task)
        startNextQueuedDownload()
    }

    func downloadStatus(taskID: UUID) -> DownloadTask.State? {
        taskStates[taskID]
    }

    func allDownloads() -> [DownloadTask] {
        downloads
    }

    // MARK: - Bulk Downloads

    /// Fetch all episodes for a season and enqueue them
    func downloadSeason(
        seriesId: String,
        seasonId: String,
        quality: DownloadQuality = .original
    ) async throws -> [UUID] {
        guard let userSession = Container.shared.currentUserSession() else { return [] }

        var params = Paths.GetEpisodesParameters()
        params.enableUserData = true
        params.fields = .MinimumFields
        params.seasonID = seasonId
        params.userID = userSession.user.id

        let request = Paths.getEpisodes(seriesID: seriesId, parameters: params)
        let response = try await userSession.client.send(request)

        return await MainActor.run {
            downloadItems(items: response.value.items ?? [], quality: quality)
        }
    }

    /// Enqueue multiple items, skipping already downloaded/active
    @MainActor
    func downloadItems(
        items: [BaseItemDto],
        quality: DownloadQuality = .original
    ) -> [UUID] {
        var taskIDs: [UUID] = []
        for item in items {
            guard let itemId = item.id else { continue }
            guard !isItemDownloaded(item) else { continue }
            guard !downloads.contains(where: { $0.item.id == itemId }) else { continue }

            let mediaSourceId = item.mediaSources?.first?.id
            let task = DownloadTask(
                item: item,
                mediaSourceId: mediaSourceId,
                versionId: mediaSourceId,
                quality: quality
            )
            download(task: task)
            taskIDs.append(task.taskID)
        }
        return taskIDs
    }

    /// Download all episodes for all seasons of a series
    func downloadAllSeries(seriesId: String, quality: DownloadQuality = .original) async throws -> [UUID] {
        guard let userSession = Container.shared.currentUserSession() else { return [] }

        var params = Paths.GetSeasonsParameters()
        params.userID = userSession.user.id

        let request = Paths.getSeasons(seriesID: seriesId, parameters: params)
        let response = try await userSession.client.send(request)

        var allTaskIDs: [UUID] = []
        for season in response.value.items ?? [] {
            guard let seasonId = season.id else { continue }
            let ids = try await downloadSeason(seriesId: seriesId, seasonId: seasonId, quality: quality)
            allTaskIDs.append(contentsOf: ids)
        }
        return allTaskIDs
    }

    // MARK: - File Operations (Delegated to FileService)

    func deleteAllDownloadedMedia() {
        logger.info("Deleting all downloaded media")

        let activeTasks = downloads.map(\.taskID)
        for taskID in activeTasks {
            cancelDownload(taskID: taskID, removeFile: true)
        }

        var didMutateStorage = !activeTasks.isEmpty

        do {
            try fileService.deleteAllDownloads()
            logger.info("Successfully deleted all downloaded media")
            didMutateStorage = true
        } catch {
            logger.error("Failed to delete all downloads: \(error.localizedDescription)")
        }

        reset()

        if didMutateStorage {
            incrementStorageMutationVersion()
        }
    }

    @discardableResult
    func deleteDownloadedMedia(itemId: String) -> Bool {
        let matchingTasks = downloads.filter { taskMatchesStorageItem($0, storageItemId: itemId) }
        if matchingTasks.isNotEmpty {
            for task in matchingTasks {
                cancelDownload(taskID: task.taskID, removeFile: true)
            }
            removeStaleTasks(forStorageItemId: itemId)
            return true
        }

        do {
            let didDelete = try fileService.deleteDownloads(for: itemId)

            if didDelete {
                removeStaleTasks(forStorageItemId: itemId)
                incrementStorageMutationVersion()
            }

            return didDelete
        } catch {
            logger.error("Failed to delete downloaded media for item \(itemId): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteDownloadedMedia(item: BaseItemDto) -> Bool {
        guard let itemType = item.type else { return false }

        switch itemType {
        case .episode:
            let didDelete = deleteDownloadedEpisode(item)
            if didDelete {
                if let episodeId = item.id {
                    removeStaleTasks { $0.item.id == episodeId }
                }
                incrementStorageMutationVersion()
            }
            return didDelete
        case .movie:
            guard let itemId = item.id else { return false }
            return deleteDownloadedMedia(itemId: itemId)
        default:
            guard let itemId = storageRootItemId(for: item) else { return false }
            return deleteDownloadedMedia(itemId: itemId)
        }
    }

    func deleteDownloadedMedia(itemIds: [String]) -> [String] {
        logger.info("Deleting downloaded media for \(itemIds.count) items")

        var successfulDeletions: [String] = []

        for itemId in itemIds {
            if deleteDownloadedMedia(itemId: itemId) {
                successfulDeletions.append(itemId)
            }
        }

        logger.info("Successfully deleted \(successfulDeletions.count) out of \(itemIds.count) items")
        return successfulDeletions
    }

    // MARK: - Status and Size Methods (Delegated)

    func getTotalDownloadSize() -> Int64? {
        fileService.getTotalDownloadSize()
    }

    func getDownloadSize(itemId: String) -> Int64? {
        fileService.getDownloadSize(itemId: itemId)
    }

    func isItemDownloaded(itemId: String) -> Bool {
        fileService.isItemDownloaded(itemId: itemId)
    }

    func isItemDownloaded(_ item: BaseItemDto) -> Bool {
        !downloadedVersions(for: item).isEmpty
    }

    func isItemVersionDownloaded(itemId: String, mediaSourceId: String?) -> Bool {
        logger.debug("Checking if item version is downloaded - itemId: \(itemId), mediaSourceId: \(mediaSourceId ?? "nil")")

        guard fileService.isItemDownloaded(itemId: itemId) else {
            logger.debug("Item directory not found for itemId: \(itemId)")
            return false
        }

        let downloadedVersions = metadataManager.getDownloadedVersions(for: itemId)
        logger.debug("Found \(downloadedVersions.count) downloaded versions for itemId: \(itemId)")

        let targetMediaSourceId = mediaSourceId ?? itemId
        logger.debug("Target mediaSourceId (normalized): \(targetMediaSourceId)")

        let hasMetadataVersion = downloadedVersions.contains { version in
            let versionMediaSourceId = version.mediaSourceId ?? itemId
            logger.debug("Comparing target '\(targetMediaSourceId)' with version '\(versionMediaSourceId)'")
            return versionMediaSourceId == targetMediaSourceId
        }

        let hasMedia = fileService.hasMediaFile(for: itemId, mediaSourceId: mediaSourceId)

        let isDownloaded = hasMetadataVersion && hasMedia
        logger.debug("Item version downloaded result: \(isDownloaded)")
        return isDownloaded
    }

    func isItemVersionDownloaded(for item: BaseItemDto, mediaSourceId: String?) -> Bool {
        if let mediaSourceId {
            return downloadedVersions(for: item)
                .contains { versionMatchesRequestedIdentifier($0, requestedIdentifier: mediaSourceId, item: item) }
        }

        return isItemDownloaded(item)
    }

    func getDownloadedItemIds() -> [String] {
        fileService.getDownloadedItemIds()
    }

    // MARK: - Metadata Methods (Delegated)

    func getDownloadMetadata(for itemId: String) -> DownloadMetadata? {
        metadataManager.readMetadata(itemId: itemId)
    }

    func getDownloadedVersions(for itemId: String) -> [VersionInfo] {
        metadataManager.getDownloadedVersions(for: itemId)
    }

    func downloadedVersions(for item: BaseItemDto) -> [VersionInfo] {
        metadataVersions(for: item).filter { mediaFileURL(for: item, version: $0) != nil }
    }

    func playbackInfo(for item: BaseItemDto, mediaSourceId: String?) -> DownloadPlaybackInfo? {
        guard let itemType = item.type else { return nil }

        switch itemType {
        case .movie:
            return resolveMoviePlaybackInfo(for: item, mediaSourceId: mediaSourceId)
        case .episode:
            return resolveEpisodePlaybackInfo(for: item, mediaSourceId: mediaSourceId)
        default:
            return nil
        }
    }

    func mediaFileURL(for item: BaseItemDto, version: VersionInfo?) -> URL? {
        fileService.mediaFileURL(for: item, version: version)
    }

    func mediaFileSize(for item: BaseItemDto, version: VersionInfo?) -> Int64? {
        guard let fileURL = mediaFileURL(for: item, version: version) else { return nil }
        return try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64
    }

    // MARK: - File Operations for Tasks

    func getImageURL(for task: DownloadTask, name: String) -> URL? {
        do {
            guard let imagesFolder = task.imagesFolder else { return nil }
            let images = try FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)

            guard let imageFilename = images.first(where: { $0.starts(with: name) }) else { return nil }

            return imagesFolder.appendingPathComponent(imageFilename)
        } catch {
            return nil
        }
    }

    func getMediaURL(for task: DownloadTask) -> URL? {
        if let info = playbackInfo(for: task.item, mediaSourceId: task.mediaSourceId) {
            return info.fileURL
        }

        return mediaFileURL(for: task.item, version: nil)
    }

    // MARK: - Legacy/Compatibility Methods

    func task(for item: BaseItemDto) -> DownloadTask? {
        if let currentlyDownloading = downloads.first(where: { $0.item.id == item.id }) {
            return currentlyDownloading
        }

        guard let version = downloadedVersions(for: item).first else { return nil }

        return DownloadTask(
            item: item,
            mediaSourceId: version.mediaSourceId,
            versionId: version.versionId,
            container: version.container,
            isStatic: version.isStatic
        )
    }

    func cancel(task: DownloadTask) {
        guard downloads.contains(where: { $0.taskID == task.taskID }) else { return }

        updateTaskState(taskID: task.taskID, state: .cancelled)
        remove(task: task)
    }

    func remove(task: DownloadTask) {
        pendingQueue.removeAll(where: { $0.taskID == task.taskID })
        downloads.removeAll(where: { $0.taskID == task.taskID })
        taskStates.removeValue(forKey: task.taskID)
        completedJobsByTask.removeValue(forKey: task.taskID)
        lastPersistedProgress.removeValue(forKey: task.taskID)
    }

    func reset() {
        downloads.removeAll()
        taskStates.removeAll()
        pendingQueue.removeAll()
        completedJobsByTask.removeAll()
        lastPersistedProgress.removeAll()
    }

    func downloadedItems() -> [DownloadTask] {
        do {
            let downloadContents = try FileManager.default.contentsOfDirectory(
                at: URL.downloads,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return downloadContents.compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return metadataManager.parseDownloadItem(with: url.lastPathComponent)
            }
        } catch {
            logger.error("Error retrieving all downloads: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private Helpers

    private func resolveMoviePlaybackInfo(for item: BaseItemDto, mediaSourceId: String?) -> DownloadPlaybackInfo? {
        guard let itemId = item.id else { return nil }

        guard isItemDownloaded(item) else {
            logger.debug("Movie not downloaded for itemId: \(itemId)")
            return nil
        }

        guard let mediaSource = resolveMediaSource(for: item, requestedMediaSourceId: mediaSourceId) else {
            logger.warning("Unable to resolve media source for movie: \(itemId)")
            return nil
        }

        let version: VersionInfo? = if let mediaSourceId {
            selectVersion(for: item, mediaSourceId: mediaSourceId)
        } else {
            selectVersion(for: item, mediaSourceId: nil)
                ?? fallbackVersion(for: item, mediaSource: mediaSource, requestedMediaSourceId: nil)
        }

        guard let version else {
            logger.warning("Unable to resolve version for movie: \(itemId)")
            return nil
        }

        guard let fileURL = mediaFileURL(for: item, version: version) else {
            logger.warning("Unable to locate media file for movie: \(itemId)")
            return nil
        }

        return DownloadPlaybackInfo(item: item, mediaSource: mediaSource, version: version, fileURL: fileURL)
    }

    private func resolveEpisodePlaybackInfo(for item: BaseItemDto, mediaSourceId: String?) -> DownloadPlaybackInfo? {
        guard let episodeId = item.id else { return nil }

        guard isItemDownloaded(item) else {
            logger.debug("Series not downloaded for episode: \(episodeId)")
            return nil
        }

        guard let mediaSource = resolveMediaSource(for: item, requestedMediaSourceId: mediaSourceId) else {
            logger.warning("Unable to resolve media source for episode: \(episodeId)")
            return nil
        }

        let version: VersionInfo? = if let mediaSourceId {
            selectVersion(for: item, mediaSourceId: mediaSourceId)
        } else {
            selectVersion(for: item, mediaSourceId: nil)
                ?? fallbackVersion(for: item, mediaSource: mediaSource, requestedMediaSourceId: nil)
        }

        guard let version else {
            logger.warning("Unable to resolve version for episode: \(episodeId)")
            return nil
        }

        guard let fileURL = mediaFileURL(for: item, version: version) else {
            logger.warning("Unable to locate media file for episode: \(episodeId)")
            return nil
        }

        return DownloadPlaybackInfo(item: item, mediaSource: mediaSource, version: version, fileURL: fileURL)
    }

    private func selectVersion(for item: BaseItemDto, mediaSourceId: String?) -> VersionInfo? {
        selectVersion(from: metadataVersions(for: item), for: item, mediaSourceId: mediaSourceId)
    }

    private func selectVersion(from versions: [VersionInfo], for item: BaseItemDto, mediaSourceId: String?) -> VersionInfo? {
        let matchingVersions = versions.filter { versionBelongs($0, to: item) }
        guard !matchingVersions.isEmpty else { return nil }

        if let mediaSourceId {
            return matchingVersions.first(where: {
                versionMatchesRequestedIdentifier($0, requestedIdentifier: mediaSourceId, item: item)
            })
        }

        if item.type == .episode,
           let itemId = item.id,
           let sameEpisodeVersion = matchingVersions.first(where: { $0.episodeId == itemId })
        {
            return sameEpisodeVersion
        }

        if let itemId = item.id,
           let itemVersion = matchingVersions
               .first(where: { versionMatchesRequestedIdentifier($0, requestedIdentifier: itemId, item: item) })
        {
            return itemVersion
        }

        return matchingVersions.first
    }

    private func resolveMediaSource(for item: BaseItemDto, requestedMediaSourceId: String?) -> MediaSourceInfo? {
        if let mediaSources = item.mediaSources, !mediaSources.isEmpty {
            if let requestedMediaSourceId,
               let match = mediaSources.first(where: { $0.id == requestedMediaSourceId })
            {
                return match
            }

            if let itemId = item.id,
               let match = mediaSources.first(where: { $0.id == itemId })
            {
                return match
            }

            return mediaSources.first
        }

        // Fallback: construct MediaSourceInfo from version metadata for offline playback.
        // The stored BaseItemDto may lack mediaSources (Paths.getItem doesn't populate it).
        let versions = metadataVersions(for: item)

        let matchingVersion: VersionInfo? = if let requestedMediaSourceId {
            versions.first(where: { $0.mediaSourceId == requestedMediaSourceId || $0.versionId == requestedMediaSourceId })
        } else {
            versions.first
        }

        if let version = matchingVersion {
            var source = MediaSourceInfo()
            source.id = version.mediaSourceId ?? version.versionId
            source.container = version.container
            return source
        }

        if let sourceId = requestedMediaSourceId ?? item.id {
            var source = MediaSourceInfo()
            source.id = sourceId
            return source
        }

        return nil
    }

    private func fallbackVersion(for item: BaseItemDto, mediaSource: MediaSourceInfo, requestedMediaSourceId: String?) -> VersionInfo {
        let fallbackId = requestedMediaSourceId
            ?? mediaSource.id
            ?? item.id
            ?? UUID().uuidString

        let container = mediaSource.container
            ?? item.mediaSources?.first?.container
            ?? "mp4"

        return VersionInfo(
            versionId: fallbackId,
            container: container,
            isStatic: true,
            mediaSourceId: requestedMediaSourceId ?? mediaSource.id ?? item.id,
            episodeId: item.type == .episode ? item.id : nil,
            downloadDate: "",
            taskId: UUID().uuidString
        )
    }

    private func metadataVersions(for item: BaseItemDto) -> [VersionInfo] {
        guard let storageItemId = storageRootItemId(for: item) else { return [] }
        return metadataManager
            .getDownloadedVersions(for: storageItemId)
            .filter { versionBelongs($0, to: item) }
    }

    private func storageRootItemId(for item: BaseItemDto) -> String? {
        switch item.type {
        case .episode:
            item.seriesID
        case .movie:
            item.id
        default:
            item.id
        }
    }

    private func versionBelongs(_ version: VersionInfo, to item: BaseItemDto) -> Bool {
        switch item.type {
        case .episode:
            guard let episodeId = item.id else { return false }

            if version.episodeId == episodeId {
                return true
            }

            if version.episodeId == nil {
                if let versionMediaSourceId = version.mediaSourceId,
                   item.mediaSources?.contains(where: { $0.id == versionMediaSourceId }) == true
                {
                    return true
                }

                if version.versionId == episodeId || version.mediaSourceId == episodeId {
                    return true
                }
            }

            return false
        case .movie:
            return true
        default:
            return false
        }
    }

    private func versionMatchesRequestedIdentifier(_ version: VersionInfo, requestedIdentifier: String, item: BaseItemDto) -> Bool {
        guard versionBelongs(version, to: item) else { return false }
        return version.mediaSourceId == requestedIdentifier || version.versionId == requestedIdentifier
    }

    private func taskMatchesStorageItem(_ task: DownloadTask, storageItemId: String) -> Bool {
        task.item.id == storageItemId || storageRootItemId(for: task.item) == storageItemId
    }

    private func removeStaleTasks(forStorageItemId storageItemId: String) {
        removeStaleTasks { taskMatchesStorageItem($0, storageItemId: storageItemId) }
    }

    private func removeStaleTasks(where predicate: (DownloadTask) -> Bool) {
        let staleTasks = downloads.filter(predicate)

        guard staleTasks.isNotEmpty else { return }

        for task in staleTasks {
            sessionManager.cancel(taskID: task.taskID)
            queuePersistence.remove(id: task.taskID)
            queuePersistence.deleteResumeData(for: task.taskID)
            remove(task: task)
        }

        persistQueue()
    }

    private func removeDownloadedStorage(for task: DownloadTask) -> Bool {
        if task.item.type == .episode {
            return deleteDownloadedEpisode(task.item)
        }

        guard let downloadFolder = task.item.downloadFolder,
              FileManager.default.fileExists(atPath: downloadFolder.path)
        else {
            return false
        }

        do {
            try FileManager.default.removeItem(at: downloadFolder)
            return true
        } catch {
            logger.warning("Failed to remove downloaded folder at \(downloadFolder.path): \(error.localizedDescription)")
            return false
        }
    }

    private func deleteDownloadedEpisode(_ item: BaseItemDto) -> Bool {
        guard let episodeId = item.id,
              let seriesId = item.seriesID,
              let seasonNumber = item.parentIndexNumber
        else {
            return false
        }

        let seriesFolder = URL.downloads.appendingPathComponent(seriesId)
        let seasonFolder = seriesFolder.appendingPathComponent("Season-\(String(format: "%02d", seasonNumber))")
        let seasonMetadataURL = seasonFolder.appendingPathComponent("metadata.json")
        let seriesMetadataURL = seriesFolder.appendingPathComponent("metadata.json")

        let candidateVersions = metadataVersions(for: item)

        let removedFiles = deleteEpisodeFiles(
            episodeId: episodeId,
            from: seasonFolder,
            item: item,
            candidateVersions: candidateVersions
        )
        let updatedSeasonMetadata = updateEpisodeMetadata(at: seasonMetadataURL, for: item)
        let updatedSeriesMetadata = updateEpisodeMetadata(at: seriesMetadataURL, for: item)

        if !FileManager.default.fileExists(atPath: seasonMetadataURL.path) {
            try? FileManager.default.removeItem(at: seasonFolder)
        }

        if !FileManager.default.fileExists(atPath: seriesMetadataURL.path) {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: seriesFolder.path)
            let remainingSeasonFolders = contents?.filter { $0.hasPrefix("Season-") } ?? []
            if remainingSeasonFolders.isEmpty {
                try? FileManager.default.removeItem(at: seriesFolder)
            }
        }

        return removedFiles || updatedSeasonMetadata || updatedSeriesMetadata
    }

    private func deleteEpisodeFiles(
        episodeId: String,
        from seasonFolder: URL,
        item: BaseItemDto,
        candidateVersions: [VersionInfo]
    ) -> Bool {
        var removed = false

        let explicitURLs = Set(candidateVersions.compactMap { mediaFileURL(for: item, version: $0) })
        for fileURL in explicitURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                removed = true
            } catch {
                logger.warning("Failed to remove downloaded episode file at \(fileURL.path): \(error.localizedDescription)")
            }
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: seasonFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return removed
        }

        for fileURL in contents {
            let name = fileURL.lastPathComponent
            let isEpisodeMedia = !name.lowercased().contains("metadata")
                && (name.hasPrefix("\(episodeId).") || name.hasPrefix("\(episodeId)-"))
            let isEpisodeImage = name.hasPrefix("Episode-\(episodeId)-")

            guard isEpisodeMedia || isEpisodeImage else { continue }

            do {
                try FileManager.default.removeItem(at: fileURL)
                removed = true
            } catch {
                logger.warning("Failed to remove episode asset at \(fileURL.path): \(error.localizedDescription)")
            }
        }

        let imagesFolder = seasonFolder.appendingPathComponent("Images")
        if let images = try? FileManager.default.contentsOfDirectory(
            at: imagesFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for imageURL in images where imageURL.lastPathComponent.hasPrefix("Episode-\(episodeId)-") {
                do {
                    try FileManager.default.removeItem(at: imageURL)
                    removed = true
                } catch {
                    logger.warning("Failed to remove episode image at \(imageURL.path): \(error.localizedDescription)")
                }
            }

            if (try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: imagesFolder)
            }
        }

        return removed
    }

    private func updateEpisodeMetadata(at metadataURL: URL, for item: BaseItemDto) -> Bool {
        guard let episodeId = item.id,
              FileManager.default.fileExists(atPath: metadataURL.path),
              let data = FileManager.default.contents(atPath: metadataURL.path),
              var metadata = try? JSONDecoder().decode(DownloadMetadata.self, from: data)
        else {
            return false
        }

        let originalVersions = metadata.versions.count
        metadata.versions.removeAll { versionBelongs($0, to: item) }

        if var episodes = metadata.episodes {
            episodes.removeValue(forKey: episodeId)
            metadata.episodes = episodes.isEmpty ? nil : episodes
        }

        if metadata.item?.type == .episode, metadata.item?.id == episodeId {
            metadata.item = metadata.episodes?.values.sorted { $0.displayTitle < $1.displayTitle }.first
        }

        if metadata.versions.isEmpty && metadata.episodes == nil {
            do {
                try FileManager.default.removeItem(at: metadataURL)
                return true
            } catch {
                logger.warning("Failed to remove empty metadata file at \(metadataURL.path): \(error.localizedDescription)")
                return originalVersions > metadata.versions.count
            }
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let updatedData = try encoder.encode(metadata)
            try updatedData.write(to: metadataURL, options: .atomic)
            return originalVersions != metadata.versions.count
        } catch {
            logger.warning("Failed to update metadata file at \(metadataURL.path): \(error.localizedDescription)")
            return false
        }
    }

    private func recoveredItem(for record: ActiveDownloadRecord) -> BaseItemDto? {
        let storageItemId = record.storageItemId ?? record.itemId

        if let episodeId = record.episodeId,
           let metadata = metadataManager.readMetadata(itemId: storageItemId)
        {
            if let episode = metadata.episodes?[episodeId] {
                return episode
            }

            if metadata.item?.id == episodeId {
                return metadata.item
            }
        }

        return metadataManager.parseDownloadItem(with: storageItemId)?.item
    }

    // MARK: - Queue Persistence

    private func persistQueue() {
        let records: [ActiveDownloadRecord] = downloads.compactMap { task in
            guard let itemId = task.item.id else { return nil }
            let state = taskStates[task.taskID] ?? .ready

            let status: ActiveDownloadRecord.ActiveDownloadStatus = switch state {
            case .downloading:
                .active
            case .paused:
                .paused
            case .queued:
                .queued
            case .error:
                .forceQuitCancelled
            default:
                .active
            }

            let progress: Double = if case let .downloading(p) = state {
                p
            } else {
                0
            }

            let queuePos = pendingQueue.firstIndex(where: { $0.taskID == task.taskID })

            let downloadURL = urlBuilder.mediaURL(
                itemId: itemId,
                quality: task.quality,
                mediaSourceId: task.mediaSourceId,
                container: task.container,
                isStatic: task.isStatic,
                allowVideoStreamCopy: task.allowVideoStreamCopy,
                allowAudioStreamCopy: task.allowAudioStreamCopy,
                deviceId: task.deviceId,
                deviceProfileId: task.deviceProfileId
            )

            guard let downloadURL else { return nil }

            return ActiveDownloadRecord(
                id: task.taskID,
                itemId: itemId,
                storageItemId: storageRootItemId(for: task.item),
                episodeId: task.item.type == .episode ? itemId : nil,
                mediaSourceId: task.mediaSourceId,
                versionId: task.versionId,
                container: task.container,
                quality: CodableDownloadQuality(from: task.quality),
                isStatic: task.isStatic,
                allowVideoStreamCopy: task.allowVideoStreamCopy,
                allowAudioStreamCopy: task.allowAudioStreamCopy,
                deviceId: task.deviceId,
                deviceProfileId: task.deviceProfileId,
                downloadURL: downloadURL,
                startedAt: Date(),
                urlSessionTaskIdentifier: nil,
                lastKnownProgress: progress,
                status: status,
                queuePosition: queuePos
            )
        }

        queuePersistence.save(records)
    }

    private func recoverDownloadsOnLaunch() {
        let records = queuePersistence.load()
        guard !records.isEmpty else { return }

        logger.info("Recovering \(records.count) downloads from persistence")

        Task {
            let result = await sessionManager.recoverActiveDownloads(records: records)

            await MainActor.run {
                // Reconnected downloads
                for (record, _) in result.reconnected {
                    if let item = recoveredItem(for: record) {
                        let reconTask = DownloadTask(
                            item: item,
                            taskID: record.id,
                            mediaSourceId: record.mediaSourceId,
                            versionId: record.versionId,
                            container: record.container,
                            quality: record.quality.toDownloadQuality(),
                            isStatic: record.isStatic,
                            allowVideoStreamCopy: record.allowVideoStreamCopy,
                            allowAudioStreamCopy: record.allowAudioStreamCopy,
                            deviceId: record.deviceId,
                            deviceProfileId: record.deviceProfileId
                        )

                        downloads.append(reconTask)
                        completedJobsByTask[record.id] = Set<DownloadJobType>()
                        updateTaskState(taskID: record.id, state: .downloading(record.lastKnownProgress))
                    }
                }

                // Orphaned downloads (force-quit or session expired)
                for record in result.orphaned {
                    if let item = recoveredItem(for: record) {
                        let resumeDataExists = queuePersistence.loadResumeData(for: record.id) != nil

                        let reconTask = DownloadTask(
                            item: item,
                            taskID: record.id,
                            mediaSourceId: record.mediaSourceId,
                            versionId: record.versionId,
                            container: record.container,
                            quality: record.quality.toDownloadQuality(),
                            isStatic: record.isStatic,
                            allowVideoStreamCopy: record.allowVideoStreamCopy,
                            allowAudioStreamCopy: record.allowAudioStreamCopy,
                            deviceId: record.deviceId,
                            deviceProfileId: record.deviceProfileId
                        )

                        downloads.append(reconTask)

                        if record.status == .queued {
                            // Re-queue items that were waiting
                            self.pendingQueue.append(reconTask)
                            updateTaskState(taskID: record.id, state: .queued)
                        } else if resumeDataExists && record.status == .paused {
                            updateTaskState(taskID: record.id, state: .paused)
                        } else {
                            updateTaskState(
                                taskID: record.id,
                                state: .error(DownloadRecoveryError.forceQuitCancelled)
                            )
                        }
                    } else {
                        // Metadata no longer exists, clean up
                        queuePersistence.remove(id: record.id)
                        queuePersistence.deleteResumeData(for: record.id)
                    }
                }

                // Sort pending queue by persisted queue position
                self.pendingQueue.sort { a, b in
                    let posA = records.first(where: { $0.id == a.taskID })?.queuePosition ?? Int.max
                    let posB = records.first(where: { $0.id == b.taskID })?.queuePosition ?? Int.max
                    return posA < posB
                }

                persistQueue()
                self.startNextQueuedDownload()
            }
        }
    }

    private func startAllDownloads(for downloadTask: DownloadTask, with mediaURL: URL) async throws {
        if let downloadFolder = downloadTask.item.downloadFolder {
            try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        }

        try metadataManager.writeMetadata(for: downloadTask)
        markJobCompleted(taskID: downloadTask.taskID, jobType: .metadata)

        let urlTaskId = try await sessionManager.start(url: mediaURL, taskID: downloadTask.taskID, jobType: .media)
        updateTaskState(taskID: downloadTask.taskID, state: .downloading(0.0))

        queuePersistence.update(id: downloadTask.taskID) { record in
            record.urlSessionTaskIdentifier = urlTaskId
        }
        persistQueue()

        imageManager.downloadImages(for: downloadTask) { result in
            switch result {
            case .success:
                self.logger.trace("Image downloads completed for: \(downloadTask.item.displayTitle)")
            case let .failure(error):
                self.logger.warning("Some image downloads failed: \(error.localizedDescription)")
            }
        }

        // Safety timeout in case image downloads hang
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds

            if let currentState = taskStates[downloadTask.taskID],
               case .downloading = currentState,
               isTaskFullyCompleted(taskID: downloadTask.taskID)
            {
                finalizeCompletedTask(taskID: downloadTask.taskID, itemTitle: downloadTask.item.displayTitle)
                logger.info("Download completed via timeout safety mechanism: \(downloadTask.item.displayTitle)")
            }
        }
    }

    private func restartDownload(for task: DownloadTask) async {
        guard let downloadURL = urlBuilder.mediaURL(
            itemId: task.item.id!,
            quality: task.quality,
            mediaSourceId: task.mediaSourceId,
            container: task.container,
            isStatic: task.isStatic,
            allowVideoStreamCopy: task.allowVideoStreamCopy,
            allowAudioStreamCopy: task.allowAudioStreamCopy,
            deviceId: task.deviceId,
            deviceProfileId: task.deviceProfileId
        ) else {
            logger.error("Failed to construct download URL for restart")
            return
        }

        do {
            try await startAllDownloads(for: task, with: downloadURL)
        } catch {
            logger.error("Failed to restart download: \(error.localizedDescription)")
        }
    }

    // MARK: - Completion Tracking

    private func markJobCompleted(taskID: UUID, jobType: DownloadJobType) {
        var completed = completedJobsByTask[taskID] ?? Set<DownloadJobType>()
        completed.insert(jobType)
        completedJobsByTask[taskID] = completed
    }

    private func finalizeCompletedTask(taskID: UUID, itemTitle: String) {
        updateTaskState(taskID: taskID, state: .complete)
        queuePersistence.remove(id: taskID)
        queuePersistence.deleteResumeData(for: taskID)
        incrementStorageMutationVersion()

        if let task = downloads.first(where: { $0.taskID == taskID }) {
            remove(task: task)
        } else {
            taskStates.removeValue(forKey: taskID)
            completedJobsByTask.removeValue(forKey: taskID)
            lastPersistedProgress.removeValue(forKey: taskID)
        }

        logger.trace("Essential downloads completed for: \(itemTitle)")
        startNextQueuedDownload()
    }

    private func isTaskFullyCompleted(taskID: UUID) -> Bool {
        guard let completed = completedJobsByTask[taskID] else { return false }

        // Only require essential downloads - media and metadata
        // Images are optional and shouldn't block completion
        let requiredJobs: Set<DownloadJobType> = [.media, .metadata]

        return requiredJobs.isSubset(of: completed)
    }
}

// MARK: - DownloadSessionDelegate

extension DownloadManager: DownloadSessionDelegate {

    func sessionDidCompleteDownload(taskIdentifier: Int, location: URL, response: URLResponse?) {
        guard let downloadJob = sessionManager.getDownloadJob(for: taskIdentifier) else {
            logger.error("Could not find corresponding DownloadJob for URLSessionDownloadTask: \(taskIdentifier)")
            return
        }
        defer { sessionManager.removeDownloadJob(for: taskIdentifier) }

        guard let downloadTaskIndex = downloads.firstIndex(where: { $0.taskID == downloadJob.taskID }) else {
            logger.trace("Ignoring completion for finalized task: \(downloadJob.taskID)")
            return
        }

        let swiftfinDownloadTask = downloads[downloadTaskIndex]

        do {
            switch downloadJob.type {
            case .media:
                try fileService.moveMediaFile(
                    from: location,
                    to: swiftfinDownloadTask.item.downloadFolder!,
                    for: swiftfinDownloadTask,
                    response: response
                )
            case .backdropImage, .primaryImage:
                let context: ImageDownloadContext = switch swiftfinDownloadTask.item.type {
                case .movie:
                    .movie(id: swiftfinDownloadTask.item.id ?? "")
                case .episode:
                    .episode(id: swiftfinDownloadTask.item.id ?? "")
                default:
                    .episode(id: swiftfinDownloadTask.item.id ?? "")
                }

                try fileService.moveImageFile(
                    from: location,
                    to: swiftfinDownloadTask.item.downloadFolder!,
                    for: swiftfinDownloadTask,
                    response: response,
                    jobType: downloadJob.type,
                    context: context
                )
            case .metadata:
                break
            case .subtitle:
                break
            }

            markJobCompleted(taskID: downloadJob.taskID, jobType: downloadJob.type)
            if isTaskFullyCompleted(taskID: downloadJob.taskID) {
                finalizeCompletedTask(taskID: downloadJob.taskID, itemTitle: swiftfinDownloadTask.item.displayTitle)
            }

        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")

            updateTaskState(taskID: downloadJob.taskID, state: .error(error))
            persistQueue()
            try? FileManager.default.removeItem(at: location)
        }
    }

    func sessionDidUpdateProgress(taskIdentifier: Int, progress: Double) {
        guard let downloadJob = sessionManager.getDownloadJob(for: taskIdentifier),
              downloads.firstIndex(where: { $0.taskID == downloadJob.taskID }) != nil
        else {
            return
        }

        if case .media = downloadJob.type {
            updateTaskState(taskID: downloadJob.taskID, state: .downloading(progress))

            // Persist progress every 10%
            let lastPersisted = lastPersistedProgress[downloadJob.taskID] ?? 0.0
            if abs(progress - lastPersisted) >= 0.10 || progress >= 1.0 {
                lastPersistedProgress[downloadJob.taskID] = progress
                queuePersistence.update(id: downloadJob.taskID) { record in
                    record.lastKnownProgress = progress
                }
            }
        }
    }

    func sessionDidCompleteWithError(taskIdentifier: Int, error: Error?) {
        guard let downloadJob = sessionManager.getDownloadJob(for: taskIdentifier) else {
            logger.warning("Could not find corresponding DownloadJob for URLSessionDownloadTask error: \(taskIdentifier)")
            return
        }
        defer { sessionManager.removeDownloadJob(for: taskIdentifier) }

        guard let error else {
            logger.trace("Ignoring empty error completion for task: \(downloadJob.taskID)")
            return
        }

        guard downloads.firstIndex(where: { $0.taskID == downloadJob.taskID }) != nil else {
            logger.trace("Ignoring error callback for finalized task: \(downloadJob.taskID)")
            return
        }

        let swiftfinDownloadTask = downloads.first(where: { $0.taskID == downloadJob.taskID })!

        if swiftfinDownloadTask.shouldRetry(for: error) {
            logger.info("Retrying download for: \(swiftfinDownloadTask.item.displayTitle) (attempt \(swiftfinDownloadTask.retryCount + 1))")

            if var updatedTask = downloads.first(where: { $0.taskID == swiftfinDownloadTask.taskID }) {
                updatedTask.incrementRetryCount()
                if let index = downloads.firstIndex(where: { $0.taskID == swiftfinDownloadTask.taskID }) {
                    downloads[index] = updatedTask
                }
            }

            let delay = pow(2.0, Double(swiftfinDownloadTask.retryCount + 1))

            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                Task {
                    await self.retrySpecificDownload(for: swiftfinDownloadTask, jobType: downloadJob.type)
                }
            }

        } else {
            switch downloadJob.type {
            case .media, .metadata:
                updateTaskState(taskID: downloadJob.taskID, state: .error(error))
                persistQueue()
                startNextQueuedDownload()
            case .backdropImage, .primaryImage, .subtitle:
                logger
                    .warning("\(downloadJob.type) download failed, checking if task can complete without it: \(error.localizedDescription)")

                if isTaskFullyCompleted(taskID: downloadJob.taskID) {
                    finalizeCompletedTask(taskID: downloadJob.taskID, itemTitle: swiftfinDownloadTask.item.displayTitle)
                    logger.trace("Task completed despite \(downloadJob.type) download failure: \(swiftfinDownloadTask.item.displayTitle)")
                }
            }
        }
    }

    func sessionDidSaveResumeData(_ data: Data, for taskIdentifier: Int) {
        guard let downloadJob = sessionManager.getDownloadJob(for: taskIdentifier) else { return }
        queuePersistence.saveResumeData(data, for: downloadJob.taskID)
        logger.trace("Saved resume data for task: \(downloadJob.taskID)")
    }

    func sessionDidFinishBackgroundEvents() {
        logger.trace("Background session events finished")
    }

    private func retrySpecificDownload(for downloadTask: DownloadTask, jobType: DownloadJobType) async {
        switch jobType {
        case .media:
            await retryMediaDownload(for: downloadTask)
        case .backdropImage, .primaryImage:
            await retryImageDownload(for: downloadTask, imageType: jobType)
        case .metadata:
            do {
                try metadataManager.writeMetadata(for: downloadTask)
                markJobCompleted(taskID: downloadTask.taskID, jobType: .metadata)
            } catch {
                logger.error("Failed to save metadata on retry: \(error.localizedDescription)")
            }
        case .subtitle:
            break
        }
    }

    private func retryMediaDownload(for downloadTask: DownloadTask) async {
        guard let downloadURL = urlBuilder.mediaURL(
            itemId: downloadTask.item.id!,
            quality: downloadTask.quality,
            mediaSourceId: downloadTask.mediaSourceId,
            container: downloadTask.container,
            isStatic: downloadTask.isStatic,
            allowVideoStreamCopy: downloadTask.allowVideoStreamCopy,
            allowAudioStreamCopy: downloadTask.allowAudioStreamCopy,
            deviceId: downloadTask.deviceId,
            deviceProfileId: downloadTask.deviceProfileId
        ) else {
            logger.error("Failed to construct download URL for retry of item: \(downloadTask.item.id!)")
            return
        }

        do {
            try await sessionManager.start(url: downloadURL, taskID: downloadTask.taskID, jobType: .media)
        } catch {
            logger.error("Failed to retry media download: \(error.localizedDescription)")
        }
    }

    private func retryImageDownload(for downloadTask: DownloadTask, imageType: DownloadJobType) async {
        guard let imageURL = urlBuilder.imageURL(for: downloadTask.item, type: imageType) else {
            logger.error("Failed to create image URL for retry")
            return
        }

        do {
            try await sessionManager.start(url: imageURL, taskID: downloadTask.taskID, jobType: imageType)
        } catch {
            logger.error("Failed to retry image download: \(error.localizedDescription)")
        }
    }
}
