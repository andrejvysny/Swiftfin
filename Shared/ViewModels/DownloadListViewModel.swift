//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import SwiftUI

// MARK: - Presentation Models

struct DownloadedShow: Identifiable {
    let id: String
    let seriesItem: BaseItemDto
    let episodes: [DownloadedEpisode]
    let primaryImageURL: URL?
    let backdropImageURL: URL?

    var displayTitle: String {
        seriesItem.displayTitle
    }

    var episodeCount: Int {
        episodes.count
    }

    var seasons: Set<Int> {
        Set(episodes.compactMap(\.seasonNumber))
    }
}

struct DownloadedEpisode: Identifiable {
    let id: String
    let episodeItem: BaseItemDto
    let versionInfo: VersionInfo
    let mediaURL: URL?
    let primaryImageURL: URL?
    let backdropImageURL: URL?
    let fileSize: Int64?

    var seasonNumber: Int? {
        episodeItem.parentIndexNumber
    }

    var episodeNumber: Int? {
        episodeItem.indexNumber
    }

    var displayTitle: String {
        episodeItem.displayTitle
    }
}

struct DownloadedMovie: Identifiable {
    let id: String
    let movieItem: BaseItemDto
    let versions: [DownloadedVersion]
    let primaryImageURL: URL?
    let backdropImageURL: URL?

    var displayTitle: String {
        movieItem.displayTitle
    }

    var hasMultipleVersions: Bool {
        versions.count > 1
    }
}

struct DownloadedVersion: Identifiable {
    let id: String
    let item: BaseItemDto
    let versionInfo: VersionInfo
    let mediaURL: URL?
    let primaryImageURL: URL?
    let backdropImageURL: URL?

    var displayName: String {
        if let mediaSourceId = versionInfo.mediaSourceId,
           let mediaSource = item.mediaSources?.first(where: { $0.id == mediaSourceId })
        {
            return mediaSource.displayTitle
        }

        if let mediaSourceId = versionInfo.mediaSourceId {
            return "Version \(mediaSourceId.prefix(8))"
        }

        return "Original Version"
    }
}

@MainActor
final class DownloadListViewModel: ViewModel {

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    @Published
    var items: [DownloadTask] = []

    @Published
    private(set) var downloadedShows: [DownloadedShow] = []
    @Published
    private(set) var downloadedMovies: [DownloadedMovie] = []
    @Published
    private(set) var isLoading: Bool = false

    // MARK: - Computed Presentation

    var totalStorageUsedText: String {
        guard let totalBytes = downloadManager.getTotalDownloadSize() else { return L10n.unknown }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var totalItemCount: Int {
        let episodeCount = downloadedShows.reduce(0) { $0 + $1.episodeCount }
        let movieVersionCount = downloadedMovies.reduce(0) { $0 + $1.versions.count }
        return episodeCount + movieVersionCount
    }

    override nonisolated init() {
        super.init()
    }

    // MARK: - Intents

    func load() {
        guard !isLoading else { return }
        isLoading = true
        Task { await loadDownloadedItems() }
    }

    func refresh() async {
        await loadDownloadedItems()
    }

    func deleteShow(id: String) {
        logger.info("Deleting downloaded show: \(id)")
        guard downloadManager.deleteDownloadedMedia(itemId: id) else {
            logger.error("Failed to delete show: \(id)")
            return
        }

        downloadedShows.removeAll { $0.id == id }
    }

    func deleteMovie(id: String) {
        logger.info("Deleting downloaded movie: \(id)")
        guard downloadManager.deleteDownloadedMedia(itemId: id) else {
            logger.error("Failed to delete movie: \(id)")
            return
        }

        downloadedMovies.removeAll { $0.id == id }
    }

    func deleteAll() {
        logger.info("Deleting all downloads")
        downloadManager.deleteAllDownloadedMedia()
        downloadedShows.removeAll()
        downloadedMovies.removeAll()
    }

    // MARK: - Private

    private func createSeriesItemFromEpisode(_ episode: BaseItemDto) -> BaseItemDto {
        var seriesItem = BaseItemDto()
        seriesItem.id = episode.seriesID
        seriesItem.name = episode.seriesName
        seriesItem.type = .series
        seriesItem.overview = episode.overview
        seriesItem.productionYear = episode.productionYear
        return seriesItem
    }

    private func getSeriesPrimaryImageURL(for seriesId: String) -> URL? {
        let imagesFolder = URL.downloads.appendingPathComponent(seriesId).appendingPathComponent("Images")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path),
           let imageFile = contents.first(where: { $0.hasPrefix("Series-\(seriesId)-Primary") })
        {
            return imagesFolder.appendingPathComponent(imageFile)
        }
        return nil
    }

    private func getSeriesBackdropImageURL(for seriesId: String) -> URL? {
        let imagesFolder = URL.downloads.appendingPathComponent(seriesId).appendingPathComponent("Images")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path),
           let imageFile = contents.first(where: { $0.hasPrefix("Series-\(seriesId)-Backdrop") })
        {
            return imagesFolder.appendingPathComponent(imageFile)
        }
        return nil
    }

    private func getPrimaryImageURL(for itemId: String, item: BaseItemDto) -> URL? {
        getImageURL(for: itemId, item: item, imageName: "Primary")
    }

    private func getBackdropImageURL(for itemId: String, item: BaseItemDto) -> URL? {
        getImageURL(for: itemId, item: item, imageName: "Backdrop")
    }

    private func getImageURL(for itemId: String, item: BaseItemDto, imageName: String) -> URL? {
        if item.type == .episode, let seriesId = item.seriesID {
            let seriesPath = URL.downloads.appendingPathComponent(seriesId)

            if let seasonNumber = item.parentIndexNumber, let episodeId = item.id {
                let seasonFolder = seriesPath.appendingPathComponent("Season-\(String(format: "%02d", seasonNumber))")
                let seasonImagesFolder = seasonFolder.appendingPathComponent("Images")
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: seasonImagesFolder.path) {
                    if let imageFile = contents.first(where: { $0.hasPrefix("Episode-\(episodeId)-\(imageName)") }) {
                        return seasonImagesFolder.appendingPathComponent(imageFile)
                    }

                    if let seasonId = item.seasonID,
                       let imageFile = contents.first(where: { $0.hasPrefix("Season-\(seasonId)-\(imageName)") })
                    {
                        return seasonImagesFolder.appendingPathComponent(imageFile)
                    }
                }
            }

            let seriesImagesFolder = seriesPath.appendingPathComponent("Images")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: seriesImagesFolder.path),
               let imageFile = contents.first(where: { $0.hasPrefix("Series-\(seriesId)-\(imageName)") })
            {
                return seriesImagesFolder.appendingPathComponent(imageFile)
            }

            return nil
        }

        let imagesFolder = URL.downloads.appendingPathComponent(itemId).appendingPathComponent("Images")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path),
           let imageFile = contents.first(where: { $0.hasPrefix(imageName) })
        {
            return imagesFolder.appendingPathComponent(imageFile)
        }

        return nil
    }

    private func loadMetadata(at url: URL) -> DownloadMetadata? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(DownloadMetadata.self, from: data)
    }

    private func inferEpisodeId(in seasonFolder: URL, versionInfo: VersionInfo) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: seasonFolder.path) else {
            return nil
        }

        let candidates = contents.filter { filename in
            guard !filename.contains("metadata") else { return false }

            if let mediaSourceId = versionInfo.mediaSourceId, filename.contains(mediaSourceId) {
                return true
            }

            return filename.contains("-")
        }

        if let match = candidates.first, let dash = match.firstIndex(of: "-") {
            return String(match[..<dash])
        }

        return nil
    }

    private func resolveEpisodeItem(for versionInfo: VersionInfo, from metadata: DownloadMetadata, in seasonPath: URL) -> BaseItemDto? {
        if let episodeId = versionInfo.episodeId, let episodeItem = metadata.episodes?[episodeId] {
            return episodeItem
        }

        if let inferredEpisodeId = inferEpisodeId(in: seasonPath, versionInfo: versionInfo),
           let episodeItem = metadata.episodes?[inferredEpisodeId]
        {
            return episodeItem
        }

        if let episodeItem = metadata.item, episodeItem.type == .episode {
            return episodeItem
        }

        return nil
    }

    private func versionBelongs(_ version: VersionInfo, to item: BaseItemDto) -> Bool {
        guard let episodeId = item.id else { return false }

        if version.episodeId == episodeId {
            return true
        }

        if version.episodeId == nil {
            if let mediaSourceId = version.mediaSourceId,
               item.mediaSources?.contains(where: { $0.id == mediaSourceId }) == true
            {
                return true
            }

            return version.versionId == episodeId || version.mediaSourceId == episodeId
        }

        return false
    }

    private func placeholderVersion(for item: BaseItemDto) -> VersionInfo {
        VersionInfo(
            versionId: item.id ?? UUID().uuidString,
            container: item.mediaSources?.first?.container ?? "mp4",
            isStatic: true,
            mediaSourceId: item.mediaSources?.first?.id,
            episodeId: item.type == .episode ? item.id : nil,
            downloadDate: "",
            taskId: ""
        )
    }

    private func resolvedVersion(for item: BaseItemDto, preferredVersion: VersionInfo?) -> VersionInfo? {
        if let preferredVersion,
           downloadManager.mediaFileURL(for: item, version: preferredVersion) != nil
        {
            return preferredVersion
        }

        if let preferredIdentifier = preferredVersion?.mediaSourceId ?? preferredVersion?.versionId,
           let playbackVersion = downloadManager.playbackInfo(for: item, mediaSourceId: preferredIdentifier)?.version
        {
            return playbackVersion
        }

        if let playbackVersion = downloadManager.playbackInfo(for: item, mediaSourceId: nil)?.version {
            return playbackVersion
        }

        return downloadManager.downloadedVersions(for: item).first
    }

    private func buildDownloadedEpisode(
        episodeItem: BaseItemDto,
        preferredVersion: VersionInfo?,
        seriesId: String
    ) -> DownloadedEpisode? {
        let resolvedVersion = resolvedVersion(for: episodeItem, preferredVersion: preferredVersion)
            ?? preferredVersion
            ?? placeholderVersion(for: episodeItem)

        guard let mediaURL = downloadManager.mediaFileURL(for: episodeItem, version: resolvedVersion),
              FileManager.default.fileExists(atPath: mediaURL.path)
        else {
            return nil
        }

        return DownloadedEpisode(
            id: episodeItem.id ?? UUID().uuidString,
            episodeItem: episodeItem,
            versionInfo: resolvedVersion,
            mediaURL: mediaURL,
            primaryImageURL: getPrimaryImageURL(for: seriesId, item: episodeItem),
            backdropImageURL: getBackdropImageURL(for: seriesId, item: episodeItem),
            fileSize: downloadManager.mediaFileSize(for: episodeItem, version: resolvedVersion)
        )
    }

    private func buildDownloadedVersion(item: BaseItemDto, versionInfo: VersionInfo) -> DownloadedVersion? {
        guard let mediaURL = downloadManager.mediaFileURL(for: item, version: versionInfo),
              FileManager.default.fileExists(atPath: mediaURL.path),
              let itemId = item.id
        else {
            return nil
        }

        return DownloadedVersion(
            id: versionInfo.versionId,
            item: item,
            versionInfo: versionInfo,
            mediaURL: mediaURL,
            primaryImageURL: getPrimaryImageURL(for: itemId, item: item),
            backdropImageURL: getBackdropImageURL(for: itemId, item: item)
        )
    }

    private func deduplicateEpisodes(_ episodes: [DownloadedEpisode]) -> [DownloadedEpisode] {
        var uniqueEpisodes: [DownloadedEpisode] = []
        var seenEpisodeIds: Set<String> = []

        for episode in episodes.sorted(by: episodeSortComparator) {
            if let episodeId = episode.episodeItem.id {
                guard !seenEpisodeIds.contains(episodeId) else { continue }
                seenEpisodeIds.insert(episodeId)
                uniqueEpisodes.append(episode)
                continue
            }

            let fallbackKey = "\(episode.seasonNumber ?? 0)_\(episode.episodeNumber ?? 0)"
            guard !seenEpisodeIds.contains(fallbackKey) else { continue }
            seenEpisodeIds.insert(fallbackKey)
            uniqueEpisodes.append(episode)
        }

        return uniqueEpisodes
    }

    private func episodeSortComparator(_ lhs: DownloadedEpisode, _ rhs: DownloadedEpisode) -> Bool {
        if let lhsSeason = lhs.seasonNumber, let rhsSeason = rhs.seasonNumber, lhsSeason != rhsSeason {
            return lhsSeason < rhsSeason
        }

        if let lhsEpisode = lhs.episodeNumber, let rhsEpisode = rhs.episodeNumber, lhsEpisode != rhsEpisode {
            return lhsEpisode < rhsEpisode
        }

        return lhs.displayTitle < rhs.displayTitle
    }

    private func loadShowEpisodes(
        seriesId: String,
        itemPath: URL,
        seasonFolders: [String]
    ) -> (seriesItem: BaseItemDto, episodes: [DownloadedEpisode])? {
        var seriesItem: BaseItemDto?
        var allEpisodes: [DownloadedEpisode] = []

        for seasonFolder in seasonFolders.sorted() {
            let seasonPath = itemPath.appendingPathComponent(seasonFolder)
            let metadataURL = seasonPath.appendingPathComponent("metadata.json")

            guard let metadata = loadMetadata(at: metadataURL) else { continue }

            if let episodesDict = metadata.episodes, !episodesDict.isEmpty {
                for episodeItem in episodesDict.values.sorted(by: { $0.displayTitle < $1.displayTitle }) {
                    if seriesItem == nil {
                        seriesItem = createSeriesItemFromEpisode(episodeItem)
                    }

                    let preferredVersion = metadata.versions.first { versionBelongs($0, to: episodeItem) }
                    if let downloadedEpisode = buildDownloadedEpisode(
                        episodeItem: episodeItem,
                        preferredVersion: preferredVersion,
                        seriesId: seriesId
                    ) {
                        allEpisodes.append(downloadedEpisode)
                    }
                }
            } else {
                for versionInfo in metadata.versions {
                    guard let episodeItem = resolveEpisodeItem(for: versionInfo, from: metadata, in: seasonPath) else { continue }

                    if seriesItem == nil {
                        seriesItem = createSeriesItemFromEpisode(episodeItem)
                    }

                    if let downloadedEpisode = buildDownloadedEpisode(
                        episodeItem: episodeItem,
                        preferredVersion: versionInfo,
                        seriesId: seriesId
                    ) {
                        allEpisodes.append(downloadedEpisode)
                    }
                }
            }
        }

        guard let seriesItem else { return nil }
        return (seriesItem: seriesItem, episodes: deduplicateEpisodes(allEpisodes))
    }

    private func appendLegacyEpisode(
        item: BaseItemDto,
        into showsDict: inout [String: (seriesItem: BaseItemDto, episodes: [DownloadedEpisode])]
    ) {
        guard let seriesId = item.seriesID else { return }

        if showsDict[seriesId] == nil {
            showsDict[seriesId] = (seriesItem: createSeriesItemFromEpisode(item), episodes: [])
        }

        let preferredVersions = downloadManager.downloadedVersions(for: item)
        if preferredVersions.isEmpty {
            if let downloadedEpisode = buildDownloadedEpisode(episodeItem: item, preferredVersion: nil, seriesId: seriesId) {
                showsDict[seriesId]?.episodes.append(downloadedEpisode)
            }
            return
        }

        for versionInfo in preferredVersions {
            if let downloadedEpisode = buildDownloadedEpisode(episodeItem: item, preferredVersion: versionInfo, seriesId: seriesId) {
                showsDict[seriesId]?.episodes.append(downloadedEpisode)
            }
        }
    }

    private func appendMovie(metadata: DownloadMetadata, item: BaseItemDto, itemId: String, into movies: inout [DownloadedMovie]) {
        let versions = metadata.versions.compactMap { buildDownloadedVersion(item: item, versionInfo: $0) }
        guard !versions.isEmpty else { return }

        movies.append(
            DownloadedMovie(
                id: item.id ?? UUID().uuidString,
                movieItem: item,
                versions: versions,
                primaryImageURL: getPrimaryImageURL(for: itemId, item: item),
                backdropImageURL: getBackdropImageURL(for: itemId, item: item)
            )
        )
    }

    private func loadDownloadedItems() async {
        logger.info("Loading downloaded items from filesystem")
        defer { isLoading = false }

        let downloadedItemIds = downloadManager.getDownloadedItemIds()
        var showsDict: [String: (seriesItem: BaseItemDto, episodes: [DownloadedEpisode])] = [:]
        var moviesArray: [DownloadedMovie] = []

        for itemId in downloadedItemIds {
            let itemPath = URL.downloads.appendingPathComponent(itemId)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: itemPath.path)) ?? []
            let seasonFolders = contents.filter { $0.hasPrefix("Season-") }

            if !seasonFolders.isEmpty {
                if let showData = loadShowEpisodes(seriesId: itemId, itemPath: itemPath, seasonFolders: seasonFolders),
                   !showData.episodes.isEmpty
                {
                    showsDict[itemId] = showData
                }
                continue
            }

            guard let metadata = downloadManager.getDownloadMetadata(for: itemId), let item = metadata.item else { continue }

            switch item.type {
            case .episode:
                appendLegacyEpisode(item: item, into: &showsDict)
            case .movie:
                appendMovie(metadata: metadata, item: item, itemId: itemId, into: &moviesArray)
            default:
                continue
            }
        }

        downloadedShows = showsDict.values
            .map { entry in
                let seriesId = entry.seriesItem.id ?? UUID().uuidString
                return DownloadedShow(
                    id: seriesId,
                    seriesItem: entry.seriesItem,
                    episodes: deduplicateEpisodes(entry.episodes).sorted(by: episodeSortComparator),
                    primaryImageURL: getSeriesPrimaryImageURL(for: seriesId),
                    backdropImageURL: getSeriesBackdropImageURL(for: seriesId)
                )
            }
            .sorted { $0.displayTitle < $1.displayTitle }

        downloadedMovies = moviesArray.sorted { $0.displayTitle < $1.displayTitle }
        items = downloadManager.downloadedItems()
    }
}
