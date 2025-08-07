//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import Logging
import SwiftUI

struct DownloadsView: View {

    @StateObject
    private var downloadManager = Container.shared.downloadManager()

    @Injected(\.networkMonitor)
    private var networkMonitor

    @Injected(\.currentUserSession)
    private var userSession

    @Router
    private var router

    @State
    private var downloadedItems: [DownloadTask] = []

    @State
    private var hierarchicalGroups: [DownloadGroup] = []

    @State
    private var isLoading: Bool = true

    @State
    private var showingDeleteAlert = false

    @State
    private var showingDeleteAllAlert = false

    @State
    private var taskToDelete: DownloadTask?

    @State
    private var isServerUnreachable: Bool = false

    private let logger = Logger.swiftfin()

    // MARK: - Computed Properties

    private var activeDownloads: [DownloadTask] {
        downloadManager.downloads.filter { task in
            switch task.state {
            case .ready, .downloading:
                return true
            default:
                return false
            }
        }
    }

    private var hasActiveDownloads: Bool {
        !activeDownloads.isEmpty
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 72))
                .foregroundColor(.secondary)

            Text("No Downloads")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Download content to watch offline")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !networkMonitor.isConnected {
                OfflineBanner(type: .offline, showDescription: true)
            } else if isServerUnreachable {
                OfflineBanner(type: .serverUnreachable, showDescription: true)
            }
        }
        .padding()
    }

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {

                    Spacer()

                    if isServerUnreachable {
                        OfflineBanner(type: .serverUnreachable, compact: true)
                    } else if !networkMonitor.isConnected {
                        OfflineBanner(type: .offline, compact: true)
                    }
                }
                .padding(.horizontal)

                HStack {
                    Text(isServerUnreachable ?
                        "Your Jellyfin server is unreachable. Downloaded content is available for offline viewing." :
                        networkMonitor.isConnected ?
                        "Downloaded content available for offline viewing" :
                        "Offline content"
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                    Spacer()

                    if !hierarchicalGroups.isEmpty {
                        Text("\(totalItemCount) items • \(totalStorageUsed)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal)

                // In-Progress Downloads Section
                if hasActiveDownloads {
                    InProgressDownloadsSection(
                        activeDownloads: activeDownloads,
                        onCancelDownload: cancelDownload
                    )
                }

                // Completed Downloads Section
                if !hierarchicalGroups.isEmpty {
                    DownloadsHierarchicalView(
                        downloadGroups: hierarchicalGroups,
                        onPlayItem: playDownloadedItem,
                        onDeleteItem: deleteDownloadedItem
                    )
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            logger.info("Pull-to-refresh triggered")
            await Task {
                loadDownloadedItems()
            }.value
        }
    }

    private var totalStorageUsed: String {
        let totalBytes = hierarchicalGroups.reduce(0) { $0 + $1.totalStorageSize }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private var totalItemCount: Int {
        hierarchicalGroups.reduce(0) { $0 + $1.itemCount }
    }

    var body: some View {
        NavigationView {
            ZStack {
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Loading downloads...")
                            .foregroundColor(.secondary)
                    }
                } else if hierarchicalGroups.isEmpty && !hasActiveDownloads {
                    emptyView
                } else {
                    contentView
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .alert("Delete Download", isPresented: $showingDeleteAlert) {
                Button(L10n.cancel, role: .cancel) {
                    taskToDelete = nil
                }
                Button(L10n.delete, role: .destructive) {
                    confirmDelete()
                }
            } message: {
                if let taskToDelete = taskToDelete {
                    Text("Are you sure you want to delete '\(taskToDelete.item.displayTitle)'?")
                } else {
                    Text("Are you sure you want to delete this downloaded item?")
                }
            }
            .alert("Delete All Downloads", isPresented: $showingDeleteAllAlert) {
                Button(L10n.cancel, role: .cancel) {}
                Button("Delete All", role: .destructive) {
                    confirmDeleteAll()
                }
            } message: {
                Text("Are you sure you want to delete all \(totalItemCount) downloaded items? This action cannot be undone.")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        // Delete All button (only show if there are completed downloads)
                        if !hierarchicalGroups.isEmpty {
                            Button {
                                logger.info("User requested to delete all downloads")
                                showingDeleteAllAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }

                        // Refresh button
                        Button {
                            logger.info("Manual refresh triggered")
                            isLoading = true
                            Task {
                                loadDownloadedItems()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .rotationEffect(.degrees(isLoading ? 360 : 0))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            logger.info("DownloadsView appeared")
            Task {
                loadDownloadedItems()
            }
        }
        .onNotification(.didDetectServerUnreachable) {
            logger.info("Server unreachable notification received in DownloadsView")
            isServerUnreachable = true
        }
        .onReceive(networkMonitor.$isConnected) { isConnected in
            // Reset server unreachable status when network status changes
            if isConnected {
                isServerUnreachable = false
            }
        }
    }

    // MARK: - Private Methods

    /// Custom media URL resolution that handles the new version-specific file structure
    private func getMediaURLForDownloadTask(_ downloadTask: DownloadTask) -> URL? {
        guard let baseDownloadFolder = downloadTask.item.downloadFolder else {
            logger.error("No download folder available for item: \(downloadTask.item.displayTitle)")
            return nil
        }

        // Check if this is a version-specific download (has a target media source)
        if let mediaSourceId = downloadTask.targetMediaSource?.id {
            // New structure: check version-specific folder
            let versionFolder = baseDownloadFolder.appendingPathComponent(mediaSourceId)
            logger.debug("Checking version-specific folder: \(versionFolder.path)")

            // Check if version-specific folder exists
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: versionFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue else {
                logger.debug("Version-specific folder does not exist: \(versionFolder.path)")
                // Fall back to base folder
                return getMediaURLFromBaseFolder(downloadTask, baseFolder: baseDownloadFolder)
            }

            // Look for media files in version-specific folder
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: versionFolder.path)
                logger.debug("Version-specific folder contents: \(contents)")

                // Try to find media file in version-specific folder
                if let mediaURL = findMediaFile(in: contents, baseFolder: versionFolder) {
                    logger.debug("Found media file in version-specific folder: \(mediaURL.path)")
                    return mediaURL
                }
            } catch {
                logger.error("Error reading version-specific folder: \(error)")
            }
        }

        // Fall back to base folder (legacy structure)
        return getMediaURLFromBaseFolder(downloadTask, baseFolder: baseDownloadFolder)
    }

    /// Helper method to find media files in a given folder
    private func findMediaFile(in contents: [String], baseFolder: URL) -> URL? {
        let videoExtensions = ["mp4", "mkv", "mov", "avi", "m4v", "webm", "ogv", "wmv", "flv", "ts", "m2ts"]

        // First priority: Look for legacy Media.* files (most common in existing downloads)
        if let legacyFile = contents.first(where: { $0.starts(with: "Media.") }) {
            let mediaURL = baseFolder.appendingPathComponent(legacyFile)
            if FileManager.default.fileExists(atPath: mediaURL.path) {
                logger.debug("Found legacy media file: \(legacyFile)")
                return mediaURL
            }
        }

        // Second priority: Look for MediaSourceInfo.id-based files (new structure)
        // These files start with a long string (MediaSourceInfo.id) followed by extension
        for filename in contents {
            let lowercased = filename.lowercased()
            // Check if this looks like a MediaSourceInfo.id-based file (long string with video extension)
            if lowercased.count > 20 && videoExtensions.contains(where: { lowercased.hasSuffix(".\($0)") }) {
                let mediaURL = baseFolder.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: mediaURL.path) {
                    logger.debug("Found MediaSourceInfo.id-based file: \(filename)")
                    return mediaURL
                }
            }
        }

        // Third priority: Look for version files (version1.mp4, version2.avi, etc.)
        if let versionFile = contents.first(where: { $0.starts(with: "version") }) {
            let mediaURL = baseFolder.appendingPathComponent(versionFile)
            if FileManager.default.fileExists(atPath: mediaURL.path) {
                logger.debug("Found version file: \(versionFile)")
                return mediaURL
            }
        }

        // Last priority: Look for any video files with common extensions
        for filename in contents {
            let lowercased = filename.lowercased()
            if videoExtensions.contains(where: { lowercased.hasSuffix(".\($0)") }) {
                let mediaURL = baseFolder.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: mediaURL.path) {
                    logger.debug("Found video file: \(filename)")
                    return mediaURL
                }
            }
        }

        return nil
    }

    /// Helper method to get media URL from base folder (legacy structure)
    private func getMediaURLFromBaseFolder(_ downloadTask: DownloadTask, baseFolder: URL) -> URL? {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: baseFolder.path)
            logger.debug("Base folder contents: \(contents)")
            return findMediaFile(in: contents, baseFolder: baseFolder)
        } catch {
            logger.error("Error reading base folder: \(error)")
            return nil
        }
    }

    private func loadDownloadedItems() {
        logger.info("Loading downloaded items")
        logger.debug("Network status: \(networkMonitor.isConnected)")
        logger.debug("User session available: \(userSession != nil)")
        logger.debug("Downloads directory path: \(URL.downloads.path)")

        // Check if downloads directory exists
        var isDirectory: ObjCBool = false
        let downloadsExists = FileManager.default.fileExists(atPath: URL.downloads.path, isDirectory: &isDirectory)
        logger.debug("Downloads directory exists: \(downloadsExists), isDirectory: \(isDirectory.boolValue)")

        if downloadsExists {
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: URL.downloads.path)
                logger.debug("Downloads directory contents: \(contents)")

                if contents.isEmpty {
                    logger.info("Downloads directory is empty")
                } else {
                    logger.info("Downloads directory contains \(contents.count) items: \(contents)")
                }
            } catch {
                logger.error("Failed to read downloads directory contents: \(error)")
            }
        } else {
            logger.warning("Downloads directory does not exist or is not a directory")
        }

        let items = downloadManager.downloadedItems()
        logger.info("DownloadManager returned \(items.count) downloaded items")

        // Enhanced logging for multiple version detection
        var movieGroups: [String: [DownloadTask]] = [:]

        for (index, item) in items.enumerated() {
            logger
                .debug(
                    "Item \(index): \(item.item.displayTitle) (ID: \(item.item.id ?? "nil")) - Type: \(item.item.type?.rawValue ?? "nil")"
                )

            // Track movie items for version analysis
            if item.item.type == .movie {
                let baseId = item.item.id ?? "unknown"
                if movieGroups[baseId] == nil {
                    movieGroups[baseId] = []
                }
                movieGroups[baseId]?.append(item)

                // Log media source information using new targetMediaSource
                if let targetMediaSource = item.targetMediaSource {
                    let videoCodec = targetMediaSource.videoStreams?.first?.codec ?? "nil"
                    logger
                        .debug(
                            "  Target media source: ID=\(targetMediaSource.id ?? "nil"), Container=\(targetMediaSource.container ?? "nil"), Codec=\(videoCodec)"
                        )
                } else {
                    logger.debug("  No target media source found")
                }
            }

            // Check if media file exists for this item using custom resolution
            if let mediaURL = getMediaURLForDownloadTask(item) {
                let mediaExists = FileManager.default.fileExists(atPath: mediaURL.path)
                logger.debug("  Media file exists: \(mediaExists) at \(mediaURL.path)")

                // Log file size for debugging
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
                    if let fileSize = attributes[.size] as? Int64 {
                        logger.debug("  Media file size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
                    }
                } catch {
                    logger.warning("  Could not get media file attributes: \(error)")
                }
            } else {
                logger.warning("  No media URL found for item using custom resolution")

                // Try the original method as fallback for debugging
                if let originalMediaURL = item.getMediaURL() {
                    logger.debug("  Original method found media URL: \(originalMediaURL.path)")
                } else {
                    logger.error("  Both custom and original methods failed to find media URL")
                }
            }

            // Check if images exist
            if let primaryImageURL = item.getImageURL(name: "Primary") {
                let imageExists = FileManager.default.fileExists(atPath: primaryImageURL.path)
                logger.debug("  Primary image exists: \(imageExists)")
            }

            if let backdropImageURL = item.getImageURL(name: "Backdrop") {
                let imageExists = FileManager.default.fileExists(atPath: backdropImageURL.path)
                logger.debug("  Backdrop image exists: \(imageExists)")
            }
        }

        // Log movie version analysis
        for (movieId, movieTasks) in movieGroups {
            if movieTasks.count > 1 {
                logger.info("Found \(movieTasks.count) versions for movie ID: \(movieId)")
                for (versionIndex, task) in movieTasks.enumerated() {
                    logger.info("  Version \(versionIndex + 1): \(task.item.displayTitle)")
                    if let targetMediaSource = task.targetMediaSource {
                        logger.info("    Media source ID: \(targetMediaSource.id ?? "nil")")
                        logger.info("    Container: \(targetMediaSource.container ?? "nil")")
                        let videoCodec = targetMediaSource.videoStreams?.first?.codec ?? "nil"
                        logger.info("    Video codec: \(videoCodec)")
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.downloadedItems = items
            self.hierarchicalGroups = transformDownloadsToHierarchy(items)
            self.isLoading = false
            self.logger.info("Updated UI with \(items.count) downloaded items in \(self.hierarchicalGroups.count) groups")

            // Log the final hierarchy for debugging
            for (groupIndex, group) in self.hierarchicalGroups.enumerated() {
                self.logger.debug("Group \(groupIndex): \(group.displayTitle) (ID: \(group.id))")
            }
        }
    }

    private func playDownloadedItem(_ downloadTask: DownloadTask) {
        // Verify media file exists using custom resolution before playing
        if let mediaURL = getMediaURLForDownloadTask(downloadTask) {
            logger.info("Playing downloaded item: \(downloadTask.item.displayTitle) from \(mediaURL.path)")
            let manager = CustomDownloadVideoPlayerManager(downloadTask: downloadTask, mediaURL: mediaURL)
            router.route(to: .videoPlayer(manager: manager))
        } else {
            logger.error("Cannot play item - no media file found: \(downloadTask.item.displayTitle)")
            // TODO: Show user-friendly error message
        }
    }

    private func deleteDownloadedItem(_ downloadTask: DownloadTask) {
        logger.info("User requested to delete download: \(downloadTask.item.displayTitle)")
        taskToDelete = downloadTask
        showingDeleteAlert = true
    }

    private func cancelDownload(_ downloadTask: DownloadTask) {
        logger.info("User requested to cancel download: \(downloadTask.item.displayTitle)")
        downloadManager.cancel(task: downloadTask)
    }

    private func confirmDelete() {
        guard let taskToDelete = taskToDelete else { return }

        logger.info("Confirming deletion of download: \(taskToDelete.item.displayTitle)")

        // Delete the download
        downloadManager.deleteDownload(task: taskToDelete)

        // Remove from UI list
        downloadedItems.removeAll { $0.item.id == taskToDelete.item.id }

        // Refresh hierarchical groups
        hierarchicalGroups = transformDownloadsToHierarchy(downloadedItems)

        // Clear the task reference
        self.taskToDelete = nil

        logger.info("Successfully deleted download from UI")
    }

    private func confirmDeleteAll() {
        logger.info("Confirming deletion of all downloads")
        downloadManager.deleteAllDownloads()
        downloadedItems.removeAll()
        hierarchicalGroups.removeAll()
        logger.info("Successfully deleted all downloads from UI")
    }
}

// MARK: - In-Progress Downloads Section

struct InProgressDownloadsSection: View {
    let activeDownloads: [DownloadTask]
    let onCancelDownload: (DownloadTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack {
                Text("In Progress")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(activeDownloads.count) download\(activeDownloads.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(8)
            }
            .padding(.horizontal)

            // In-Progress Downloads List
            LazyVStack(spacing: 8) {
                ForEach(activeDownloads) { downloadTask in
                    InProgressDownloadRow(
                        downloadTask: downloadTask,
                        onCancel: { onCancelDownload(downloadTask) }
                    )
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - In-Progress Download Row

struct InProgressDownloadRow: View {
    @ObservedObject
    var downloadTask: DownloadTask
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ImageView(downloadTask.getImageURL(name: "Primary") ?? downloadTask.getImageURL(name: "Backdrop"))
                .failure {
                    Rectangle()
                        .foregroundColor(.secondary.opacity(0.3))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        }
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 48)
                .cornerRadius(8)
                .clipped()

            // Info and Progress
            VStack(alignment: .leading, spacing: 4) {
                Text(downloadTask.item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Progress Bar and Percentage
                HStack(spacing: 8) {
                    // Progress Bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 4)
                                .cornerRadius(2)

                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * progressValue, height: 4)
                                .cornerRadius(2)
                                .animation(.linear(duration: 0.2), value: progressValue)
                        }
                    }
                    .frame(height: 4)

                    // Percentage
                    Text("\(Int(progressValue * 100))%")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }

                // Status Text
                Text(statusText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Cancel Button
            Button {
                onCancel()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }

    private var progressValue: Double {
        switch downloadTask.state {
        case let .downloading(progress):
            return progress
        case .ready:
            return 0.0
        default:
            return 0.0
        }
    }

    private var statusText: String {
        switch downloadTask.state {
        case .ready:
            return "Preparing download..."
        case let .downloading(progress):
            return "Downloading... \(Int(progress * 100))%"
        default:
            return "Unknown status"
        }
    }
}

// MARK: - Custom Download Video Player Manager

/// Custom DownloadVideoPlayerManager that uses the custom media URL resolution
/// to handle the new version-specific file structure
final class CustomDownloadVideoPlayerManager: VideoPlayerManager {

    init(downloadTask: DownloadTask, mediaURL: URL) {
        super.init()

        logger.info("Initializing CustomDownloadVideoPlayerManager for item: \(downloadTask.item.displayTitle)")
        logger.info("Using custom media URL: \(mediaURL.path)")
        logger.info("Download task state: \(downloadTask.state)")

        logger.info("Found playback URL: \(mediaURL)")
        logger.info("File exists: \(FileManager.default.fileExists(atPath: mediaURL.path))")

        // Validate media file
        if !validateMediaFile(at: mediaURL) {
            logger.error("Media file validation failed for: \(mediaURL)")
            self.createFallbackViewModel(for: downloadTask)
            return
        }

        // Get streams from the downloaded item
        let videoStreams = downloadTask.item.videoStreams
        let audioStreams = downloadTask.item.audioStreams
        let subtitleStreams = downloadTask.item.subtitleStreams

        logger.info("Video streams: \(videoStreams.count)")
        logger.info("Audio streams: \(audioStreams.count)")
        logger.info("Subtitle streams: \(subtitleStreams.count)")

        // Use the first media source from the item if available, otherwise create empty one
        var mediaSource = downloadTask.item.mediaSources?.first ?? MediaSourceInfo()

        // Update the media source for local playback
        mediaSource.path = mediaURL.path
        mediaSource.isRemote = false
        mediaSource.isSupportsDirectPlay = true
        mediaSource.isSupportsDirectStream = true
        mediaSource.isSupportsTranscoding = false // Disable transcoding for offline content

        // Ensure media streams are populated
        if mediaSource.mediaStreams == nil || mediaSource.mediaStreams?.isEmpty == true {
            mediaSource.mediaStreams = videoStreams + audioStreams + subtitleStreams
        }

        // Validate stream configurations for offline playback
        if audioStreams.isEmpty {
            logger.warning("No audio streams found - this may cause playback issues")
        }
        if videoStreams.isEmpty {
            logger.warning("No video streams found - this may cause playback issues")
        }

        // Log stream details for debugging
        for stream in audioStreams {
            logger
                .debug(
                    "Audio stream: codec=\(stream.codec ?? "unknown"), channels=\(stream.channels ?? 0), sampleRate=\(stream.sampleRate ?? 0)"
                )
        }
        for stream in videoStreams {
            logger.debug("Video stream: codec=\(stream.codec ?? "unknown"), width=\(stream.width ?? 0), height=\(stream.height ?? 0)")
        }

        logger.info("Creating VideoPlayerViewModel with URL: \(mediaURL)")

        self.currentViewModel = .init(
            playbackURL: mediaURL,
            item: downloadTask.item,
            mediaSource: mediaSource,
            playSessionID: "",
            videoStreams: videoStreams,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams,
            selectedAudioStreamIndex: -1,
            selectedSubtitleStreamIndex: -1,
            chapters: [],
            playMethod: .directPlay
        )
    }

    private func validateMediaFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Media file does not exist: \(url.path)")
            return false
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64 {
                logger.debug("Media file size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")

                // Check for minimum file size (1MB threshold to catch corrupted downloads)
                if fileSize < 1024 * 1024 {
                    logger.warning("Media file seems very small (\(fileSize) bytes) - may be corrupted")
                    return false
                }
            }

            // Check if file is readable
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                logger.error("Media file is not readable: \(url.path)")
                return false
            }

            return true
        } catch {
            logger.error("Error checking media file attributes: \(error)")
            return false
        }
    }

    private func createFallbackViewModel(for downloadTask: DownloadTask) {
        logger.warning("Creating fallback VideoPlayerViewModel for item: \(downloadTask.item.displayTitle)")

        // Create a minimal view model to prevent crashes
        let fallbackURL = URL(fileURLWithPath: "/tmp/fallback.mp4")
        var fallbackMediaSource = MediaSourceInfo()
        fallbackMediaSource.path = fallbackURL.path
        fallbackMediaSource.isRemote = false

        self.currentViewModel = .init(
            playbackURL: fallbackURL,
            item: downloadTask.item,
            mediaSource: fallbackMediaSource,
            playSessionID: "",
            videoStreams: [],
            audioStreams: [],
            subtitleStreams: [],
            selectedAudioStreamIndex: -1,
            selectedSubtitleStreamIndex: -1,
            chapters: [],
            playMethod: .directPlay
        )
    }
}
