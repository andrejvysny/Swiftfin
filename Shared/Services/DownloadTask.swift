//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import Files
import Foundation
import Get
import JellyfinAPI
import Logging

// TODO: Only move items if entire download successful
// TODO: Better state for which stage of downloading

class DownloadTask: NSObject, ObservableObject {

    // MARK: - Types

    enum State {

        case cancelled
        case complete
        case downloading(Double)
        case error(Error)
        case ready
    }

    // MARK: - Properties

    private let logger = Logger.swiftfin()
    @Injected(\.currentUserSession)
    private var userSession: UserSession!

    @Published
    var state: State = .ready {
        didSet {
            // Notify DownloadManager when state changes for UI updates
            notifyDownloadManager()
        }
    }

    private var downloadTask: Task<Void, Never>?

    let item: BaseItemDto

    // Store the specific media source being downloaded
    let targetMediaSource: MediaSourceInfo?

    // Track version number for file naming
    private let versionNumber: Int

    var imagesFolder: URL? {
        getVersionSpecificFolder()?.appendingPathComponent("metadata")
    }

    var metadataFolder: URL? {
        getVersionSpecificFolder()?.appendingPathComponent("metadata")
    }

    // MARK: - Initialization

    init(item: BaseItemDto, versionNumber: Int = 1) {
        let logger = Logger.swiftfin()
        logger.debug("Creating DownloadTask for item: \(item.displayTitle)")
        logger.debug("Item ID: \(item.id ?? "nil")")
        logger.debug("Item type: \(item.type?.rawValue ?? "nil")")
        logger.debug("Item download folder: \(item.downloadFolder?.path ?? "nil")")

        self.item = item
        self.targetMediaSource = item.mediaSources?.first
        self.versionNumber = versionNumber
        logger.debug("Target media source: \(targetMediaSource?.id ?? "nil")")
        logger.debug("Version number: \(versionNumber)")
    }

    init(item: BaseItemDto, mediaSource: MediaSourceInfo, versionNumber: Int = 1) {
        let logger = Logger.swiftfin()
        logger.debug("Creating DownloadTask for item: \(item.displayTitle) with specific media source: \(mediaSource.id ?? "nil")")
        logger.debug("Item ID: \(item.id ?? "nil")")
        logger.debug("Item type: \(item.type?.rawValue ?? "nil")")

        self.item = item
        self.targetMediaSource = mediaSource
        self.versionNumber = versionNumber
        logger.debug("Target media source: \(targetMediaSource?.id ?? "nil")")
        logger.debug("Version number: \(versionNumber)")
    }

    // MARK: - Public API

    func createFolder() throws {
        guard let downloadFolder = getVersionSpecificFolder() else { return }
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
    }

    func download() {
        logger.info("Starting download process for item: \(item.displayTitle) (ID: \(item.id ?? "unknown"))")
        logger.debug("Initial state: \(state)")
        logger.debug("Download folder: \(item.downloadFolder?.path ?? "nil")")

        let task = Task {
            logger.debug("Download task started on background thread")

            // Check available storage before starting download
            #if os(iOS)
            if let fileSize = targetMediaSource?.size,
               fileSize > 0
            {
                let availableStorage = FileManager.default.availableStorage
                let requiredSpace = Int(Double(fileSize) * 1.2) // Add 20% buffer for temporary files

                logger.debug("File size: \(fileSize), Available storage: \(availableStorage), Required space: \(requiredSpace)")

                if availableStorage < requiredSpace {
                    logger.error("Insufficient storage for download. Available: \(availableStorage), Required: \(requiredSpace)")
                    await MainActor.run {
                        self.state = .error(DownloadError.notEnoughStorage)
                        Container.shared.downloadManager().remove(task: self)
                    }
                    return
                } else {
                    logger.debug("Storage check passed")
                }
            } else {
                logger.debug("No file size information available, skipping storage check")
            }
            #endif

            // Don't delete the folder before download - we handle directory creation in downloadMedia()
            // deleteRootFolder()

            // TODO: Look at TaskGroup for parallel calls
            do {
                logger.debug("Starting media download")

                // Special handling for Series - they don't have media to download, just create folder structure
                if item.type == .series {
                    logger.info("Processing series download - creating folder structure for '\(item.displayTitle)'")

                    if let mediaSources = item.mediaSources, !mediaSources.isEmpty {
                        logger.info("Series has media sources, proceeding with download")
                        try await downloadMedia()
                    } else {
                        logger.info("Series has no media sources, creating folder structure only")
                        try createFolder()

                        // Save series metadata
                        saveMetadata()

                        // Download series images
                        await downloadPrimaryImage()
                        await downloadBackdropImage()

                        logger.info("Series folder structure created successfully")
                        await MainActor.run {
                            self.state = .complete
                        }
                        return
                    }
                } else {
                    try await downloadMedia()
                }

                logger.debug("Media download completed successfully")
            } catch {
                logger.error("Media download failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.state = .error(error)
                    Container.shared.downloadManager().remove(task: self)
                }
                return
            }

            logger.debug("Starting backdrop image download")
            await downloadBackdropImage()
            logger.debug("Backdrop image download completed")

            logger.debug("Starting primary image download")
            await downloadPrimaryImage()
            logger.debug("Primary image download completed")

            logger.debug("Saving metadata")
            saveMetadata()
            logger.debug("Metadata saved successfully")

            await MainActor.run {
                logger.info("Download completed successfully for item: \(self.item.displayTitle)")
                self.state = .complete
            }
        }

        self.downloadTask = task
        logger.debug("Download task assigned to instance variable")
    }

    func cancel() {
        logger.info("Cancelling download for item: \(item.displayTitle) (ID: \(item.id ?? "unknown"))")
        logger.debug("Current state before cancellation: \(state)")

        // Cancel the underlying download task
        if let downloadTask = self.downloadTask {
            logger.debug("Cancelling underlying download task")
            downloadTask.cancel()
        } else {
            logger.debug("No underlying download task to cancel")
        }

        // Clean up any partial downloads
        logger.debug("Cleaning up partial downloads")
        deleteRootFolder()

        logger.info("Internal download task for '\(item.displayTitle)' cancelled.")
    }

    // MARK: - File Management

    func deleteRootFolder() {
        guard let downloadFolder = getVersionSpecificFolder() else {
            logger.debug("No download folder to delete")
            return
        }

        logger.debug("Deleting version-specific folder: \(downloadFolder)")

        do {
            try FileManager.default.removeItem(at: downloadFolder)
            logger.debug("Successfully deleted version-specific folder")
        } catch {
            logger.error("Failed to delete version-specific folder: \(error.localizedDescription)")
        }
    }

    func encodeMetadata() -> Data {
        try! JSONEncoder().encode(item)
    }

    // MARK: - Version-Specific Folder Management

    /// Gets the version-specific folder for this download task
    private func getVersionSpecificFolder() -> URL? {
        guard let baseDownloadFolder = item.downloadFolder else { return nil }

        // If we have a target media source with ID, create a version-specific folder
        if let mediaSourceId = targetMediaSource?.id {
            let versionFolder = baseDownloadFolder.appendingPathComponent(mediaSourceId)
            logger.debug("Using version-specific folder: \(versionFolder.path)")
            return versionFolder
        }

        // Fallback to base folder for legacy downloads
        logger.debug("Using base folder (legacy): \(baseDownloadFolder.path)")
        return baseDownloadFolder
    }

    // MARK: - Download Implementation

    private func downloadMedia() async throws {

        let logger = Logger.swiftfin()
        logger.info("Starting media download for item: \(item.id ?? "unknown")")
        logger.debug("Target media source: \(targetMediaSource?.id ?? "nil")")

        let client = APIClient(
            baseURL: Container.shared.currentUserSession()!.client.configuration.url,
            apiKey: Container.shared.currentUserSession()!.client.accessToken ?? "",
            userId: Container.shared.currentUserSession()!.user.id
        )

        // Ensure download directory exists - use version-specific folder
        guard let downloadFolder = getVersionSpecificFolder() else {
            logger.error("No download folder available for item")
            throw JellyfinAPIError("No download folder available")
        }

        // Create base Downloads directory if it doesn't exist
        let downloadsRoot = URL.downloads
        do {
            try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true, attributes: nil)
            logger.debug("Created base downloads directory at: \(downloadsRoot)")
        } catch {
            logger.error("Failed to create base downloads directory: \(error)")
            throw error
        }

        // Create version-specific directory
        do {
            try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true, attributes: nil)
            logger.debug("Created version-specific download directory at: \(downloadFolder)")
        } catch {
            logger.error("Failed to create version-specific download directory: \(error)")
            throw error
        }

        // Determine the destination filename using MediaSourceInfo.id
        let destinationFilename: String
        if let mediaSourceId = targetMediaSource?.id,
           let container = targetMediaSource?.container
        {
            // Use MediaSourceInfo.id as the filename with container extension
            destinationFilename = "\(mediaSourceId).\(container.lowercased())"
            logger.debug("Using MediaSourceInfo.id-based filename: \(destinationFilename)")
        } else if let mediaSourceId = targetMediaSource?.id {
            // Fallback to MediaSourceInfo.id with mp4 extension
            destinationFilename = "\(mediaSourceId).mp4"
            logger.debug("Using MediaSourceInfo.id-based filename with fallback extension: \(destinationFilename)")
        } else if let container = targetMediaSource?.container {
            // Fallback to version pattern if no MediaSourceInfo.id
            destinationFilename = "version\(versionNumber).\(container.lowercased())"
            logger.debug("Using version pattern filename: \(destinationFilename)")
        } else {
            // Final fallback
            destinationFilename = "version\(versionNumber).mp4"
            logger.debug("Using final fallback filename: \(destinationFilename)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            client.downloadItem(
                itemId: item.id ?? "",
                destinationURL: downloadFolder.appendingPathComponent(destinationFilename),
                mediaSourceId: targetMediaSource?.id,
                onProgress: { progress in
                    Task { @MainActor in
                        self.state = .downloading(progress)
                    }
                },
                completion: { result in
                    switch result {
                    case let .success(finalURL):
                        logger.info("Media download completed successfully for item: \(self.item.id ?? "unknown") at: \(finalURL)")
                        logger.debug("Downloaded to version-specific folder: \(downloadFolder.path)")

                        // Save the actual filename for later retrieval
                        let actualFilename = finalURL.lastPathComponent
                        if actualFilename != destinationFilename {
                            // Store the actual filename in metadata for later use
                            if let mediaSourceId = self.targetMediaSource?.id {
                                let key = "download_\(self.item.id ?? "")_\(mediaSourceId)_filename"
                                UserDefaults.standard.set(actualFilename, forKey: key)
                                logger.debug("Stored actual filename '\(actualFilename)' with key: \(key)")
                            }
                        }

                        continuation.resume()
                    case let .failure(error):
                        logger.error("Media download failed for item: \(self.item.id ?? "unknown") - \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            )
        }
    }

    private func downloadBackdropImage() async {

        guard let type = item.type else { return }

        let imageURL: URL

        // TODO: move to BaseItemDto
        switch type {
        case .movie, .series:
            guard let url = item.imageSource(.backdrop, maxWidth: 600).url else { return }
            imageURL = url
        case .episode:
            guard let url = item.imageSource(.primary, maxWidth: 600).url else { return }
            imageURL = url
        default:
            return
        }

        guard let response = try? await userSession.client.download(
            for: .init(url: imageURL).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Backdrop")
        saveImage(from: response, filename: filename)
    }

    // MARK: - Image Downloads

    private func downloadPrimaryImage() async {

        guard let type = item.type else { return }

        let imageURL: URL

        switch type {
        case .movie, .series:
            guard let url = item.imageSource(.primary, maxWidth: 300).url else { return }
            imageURL = url
        default:
            return
        }

        guard let response = try? await userSession.client.download(
            for: .init(url: imageURL).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Primary")
        saveImage(from: response, filename: filename)
    }

    private func saveImage(from response: Response<URL>?, filename: String) {

        guard let response, let imagesFolder else { return }

        do {
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

            try FileManager.default.moveItem(
                at: response.value,
                to: imagesFolder.appendingPathComponent(filename)
            )
        } catch {
            logger.error("Error saving image: \(error.localizedDescription)")
        }
    }

    private func getImageFilename(from response: Response<URL>, secondary: String) -> String {

        if let suggestedFilename = response.response.suggestedFilename {
            return suggestedFilename
        } else {
            let imageExtension = response.response.mimeSubtype ?? "png"
            return "\(secondary).\(imageExtension)"
        }
    }

    private func saveMetadata() {
        guard let metadataFolder else { return }

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        // Create a version-specific item with only the target media source
        var versionSpecificItem = item
        if let targetMediaSource = targetMediaSource {
            // Only include the specific media source being downloaded
            versionSpecificItem.mediaSources = [targetMediaSource]
        }

        let itemJsonData = try! jsonEncoder.encode(versionSpecificItem)
        let itemJson = String(data: itemJsonData, encoding: .utf8)
        let itemFileURL = metadataFolder.appendingPathComponent("Item.json")

        do {
            try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)

            try itemJson?.write(to: itemFileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Error saving item metadata: \(error.localizedDescription)")
        }
    }

    // MARK: - File Access

    func getImageURL(name: String) -> URL? {
        do {
            guard let imagesFolder else { return nil }
            let images = try FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)

            guard let imageFilename = images.first(where: { $0.starts(with: name) }) else { return nil }

            return imagesFolder.appendingPathComponent(imageFilename)
        } catch {
            return nil
        }
    }

    func getMediaURL() -> URL? {
        do {
            // Use version-specific folder
            guard let downloadFolder = getVersionSpecificFolder() else {
                logger.error("No download folder available for item: \(item.id ?? "unknown")")
                return nil
            }

            let contents = try FileManager.default.contentsOfDirectory(atPath: downloadFolder.path)
            logger.debug("Download folder contents: \(contents)")

            // First check if we have a stored filename from the download
            var mediaFilename: String?

            // Try version-specific key first
            if let mediaSourceId = targetMediaSource?.id {
                let versionKey = "download_\(item.id ?? "")_\(mediaSourceId)_filename"
                if let storedFilename = UserDefaults.standard.string(forKey: versionKey) {
                    // Verify the stored filename still exists
                    if contents.contains(storedFilename) {
                        mediaFilename = storedFilename
                        logger.debug("Using stored media filename for version \(mediaSourceId): \(storedFilename)")
                    }
                }
            }

            // Fallback to legacy key if no version-specific key found
            if mediaFilename == nil {
                if let storedFilename = UserDefaults.standard.string(forKey: "download_\(item.id ?? "")_filename") {
                    // Verify the stored filename still exists
                    if contents.contains(storedFilename) {
                        mediaFilename = storedFilename
                        logger.debug("Using legacy stored media filename: \(storedFilename)")
                    }
                }
            }

            // If no stored filename or it doesn't exist, look for MediaSourceInfo.id-based files first
            if mediaFilename == nil {
                if let mediaSourceId = targetMediaSource?.id {
                    // Look for files that start with the MediaSourceInfo.id
                    mediaFilename = contents.first(where: { $0.starts(with: mediaSourceId) })

                    if mediaFilename != nil {
                        logger.debug("Found MediaSourceInfo.id-based file: \(mediaFilename!)")
                    }
                }
            }

            // If still no media file found, look for version files
            if mediaFilename == nil {
                // Look for version files (version1.mp4, version2.avi, etc.)
                mediaFilename = contents.first(where: { $0.starts(with: "version\(versionNumber).") })

                // If specific version not found, look for any version file
                if mediaFilename == nil {
                    mediaFilename = contents.first(where: { $0.starts(with: "version") })
                }
            }

            // If still no media file found, look for common video extensions
            if mediaFilename == nil {
                let videoExtensions = ["mp4", "mkv", "mov", "avi", "m4v", "webm", "ogv", "wmv", "flv", "ts", "m2ts"]
                mediaFilename = contents.first { filename in
                    let lowercased = filename.lowercased()
                    return videoExtensions.contains { lowercased.hasSuffix(".\($0)") }
                }

                if let foundFilename = mediaFilename {
                    logger.debug("Found video file by extension: \(foundFilename)")
                    let fileExtension = URL(fileURLWithPath: foundFilename).pathExtension.lowercased()
                    logger.debug("Media file format: \(fileExtension)")

                    // Log warnings for formats that may have compatibility issues
                    switch fileExtension {
                    case "avi":
                        logger.warning("AVI format detected - may require VLC player for optimal compatibility")
                    case "mkv":
                        logger.info("MKV format detected - VLC player recommended for full feature support")
                    case "wmv", "flv":
                        logger.warning("Legacy format detected (\(fileExtension)) - compatibility may vary")
                    default:
                        logger.debug("Standard format detected (\(fileExtension))")
                    }
                }
            }

            guard let foundFilename = mediaFilename else {
                logger.error("No media file found in download folder for item: \(item.id ?? "unknown")")
                logger.error("Searched for: stored filename, MediaSourceInfo.id-based files, version files, and common video extensions")
                return nil
            }

            let mediaURL = downloadFolder.appendingPathComponent(foundFilename)

            // Verify the file actually exists
            guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                logger.error("Media file path exists in directory listing but file doesn't exist: \(mediaURL)")
                return nil
            }

            // Validate media file properties
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
                if let fileSize = attributes[.size] as? Int64 {
                    logger.debug("Media file size: \(fileSize) bytes")

                    // Check for minimum file size (1MB threshold to catch corrupted downloads)
                    if fileSize < 1024 * 1024 {
                        logger.warning("Media file seems very small (\(fileSize) bytes) - may be corrupted")
                    }
                } else {
                    logger.warning("Could not determine media file size")
                }

                // Check if file is readable
                guard FileManager.default.isReadableFile(atPath: mediaURL.path) else {
                    logger.error("Media file is not readable: \(mediaURL.path)")
                    return nil
                }
            } catch {
                logger.error("Error checking media file attributes: \(error)")
                return nil
            }

            logger.debug("Found and validated media file: \(mediaURL)")
            return mediaURL
        } catch {
            logger.error("Error reading download folder for item: \(item.id ?? "unknown") - \(error)")
            return nil
        }
    }

    // MARK: - DownloadManager Notification

    private func notifyDownloadManager() {
        // Notify on main thread to trigger UI updates
        DispatchQueue.main.async {
            Container.shared.downloadManager().objectWillChange.send()
        }
    }
}

extension DownloadTask: Identifiable {

    var id: String {
        item.id!
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadTask: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async {
            self.state = .downloading(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard let error else { return }

        DispatchQueue.main.async {
            self.state = .error(error)

            Container.shared.downloadManager().remove(task: self)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        DispatchQueue.main.async {
            self.state = .error(error)

            Container.shared.downloadManager().remove(task: self)
        }
    }
}
