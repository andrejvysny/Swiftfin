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

@MainActor
final class ItemDownloadListViewModel: ViewModel {

    // MARK: - Input

    let seriesItem: BaseItemDto

    // MARK: - Dependencies

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    // MARK: - Published State

    @Published
    private(set) var downloadedEpisodes: [DownloadedEpisode] = []
    @Published
    private(set) var episodesBySeason: [Int: [DownloadedEpisode]] = [:]
    @Published
    private(set) var isLoading: Bool = false

    // MARK: - Computed Presentation

    var sortedSeasons: [Int] {
        Array(episodesBySeason.keys).sorted()
    }

    var totalEpisodeCount: Int {
        downloadedEpisodes.count
    }

    // MARK: - Init

    init(item: BaseItemDto) {
        self.seriesItem = item
    }

    // MARK: - Intents

    func load() {
        guard !isLoading else { return }
        isLoading = true
        Task { await loadDownloadedEpisodes() }
    }

    func refresh() async {
        await loadDownloadedEpisodes()
    }

    func deleteEpisode(_ episode: DownloadedEpisode) {
        logger.info("Deleting downloaded episode: \(episode.displayTitle)")

        guard downloadManager.deleteDownloadedMedia(item: episode.episodeItem) else {
            logger.error("Failed to delete episode: \(episode.displayTitle)")
            return
        }

        downloadedEpisodes.removeAll { $0.id == episode.id }
        regroupEpisodes()
    }

    // MARK: - Loading

    private func loadDownloadedEpisodes() async {
        defer { isLoading = false }

        guard let seriesId = seriesItem.id else {
            logger.error("No series ID provided")
            return
        }

        let seriesPath = URL.downloads.appendingPathComponent(seriesId)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: seriesPath.path)
        let seasonFolders = contents?.filter { $0.hasPrefix("Season-") }.sorted() ?? []

        var episodes: [DownloadedEpisode] = []

        for seasonFolder in seasonFolders {
            let seasonPath = seriesPath.appendingPathComponent(seasonFolder)
            let metadataURL = seasonPath.appendingPathComponent("metadata.json")

            guard let metadata = loadMetadata(at: metadataURL) else { continue }
            episodes.append(contentsOf: downloadedEpisodes(from: metadata, in: seasonPath, seriesId: seriesId))
        }

        downloadedEpisodes = deduplicateEpisodes(sortEpisodes(episodes))
        regroupEpisodes()
    }

    private func loadMetadata(at url: URL) -> DownloadMetadata? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(DownloadMetadata.self, from: data)
    }

    private func downloadedEpisodes(from metadata: DownloadMetadata, in seasonPath: URL, seriesId: String) -> [DownloadedEpisode] {
        if let episodesDict = metadata.episodes, !episodesDict.isEmpty {
            return episodesDict.values
                .sorted { lhs, rhs in
                    episodeSortComparator(
                        DownloadedEpisode.placeholder(for: lhs),
                        DownloadedEpisode.placeholder(for: rhs)
                    )
                }
                .compactMap { episodeItem in
                    let preferredVersion = metadata.versions.first { versionBelongs($0, to: episodeItem) }
                    return buildDownloadedEpisode(
                        episodeItem: episodeItem,
                        preferredVersion: preferredVersion,
                        seriesId: seriesId
                    )
                }
        }

        return metadata.versions.compactMap { versionInfo in
            guard let episodeItem = resolveEpisodeItem(for: versionInfo, from: metadata, in: seasonPath) else {
                logger.warning("Unable to resolve downloaded episode for version \(versionInfo.versionId)")
                return nil
            }

            return buildDownloadedEpisode(
                episodeItem: episodeItem,
                preferredVersion: versionInfo,
                seriesId: seriesId
            )
        }
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

        if let mediaSourceId = versionInfo.mediaSourceId, let episodeItem = metadata.episodes?[mediaSourceId] {
            return episodeItem
        }

        if let episodeItem = metadata.episodes?[versionInfo.versionId] {
            return episodeItem
        }

        if metadata.item?.type == .episode {
            return metadata.item
        }

        return nil
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
            logger.warning("Missing media file for downloaded episode: \(episodeItem.displayTitle)")
            return nil
        }

        return DownloadedEpisode(
            id: episodeItem.id ?? UUID().uuidString,
            episodeItem: episodeItem,
            versionInfo: resolvedVersion,
            mediaURL: mediaURL,
            primaryImageURL: getPrimaryImageURL(for: seriesId, episodeItem: episodeItem),
            backdropImageURL: getBackdropImageURL(for: seriesId, episodeItem: episodeItem),
            fileSize: downloadManager.mediaFileSize(for: episodeItem, version: resolvedVersion)
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

    private func placeholderVersion(for item: BaseItemDto) -> VersionInfo {
        VersionInfo(
            versionId: item.id ?? UUID().uuidString,
            container: item.mediaSources?.first?.container ?? "mp4",
            isStatic: true,
            mediaSourceId: item.mediaSources?.first?.id,
            episodeId: item.id,
            downloadDate: "",
            taskId: ""
        )
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

    // MARK: - Grouping

    private func deduplicateEpisodes(_ episodes: [DownloadedEpisode]) -> [DownloadedEpisode] {
        var uniqueEpisodes: [DownloadedEpisode] = []
        var seenEpisodeIds: Set<String> = []

        for episode in episodes {
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

    private func regroupEpisodes() {
        var grouped: [Int: [DownloadedEpisode]] = [:]

        for episode in downloadedEpisodes {
            let seasonNumber = episode.seasonNumber ?? 1
            grouped[seasonNumber, default: []].append(episode)
        }

        for key in grouped.keys {
            grouped[key]?.sort(by: episodeSortComparator)
        }

        episodesBySeason = grouped
    }

    private func sortEpisodes(_ episodes: [DownloadedEpisode]) -> [DownloadedEpisode] {
        episodes.sorted(by: episodeSortComparator)
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

    // MARK: - Resolution Helpers

    private func inferEpisodeId(in seasonFolder: URL, versionInfo: VersionInfo) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: seasonFolder.path) else {
            return nil
        }

        let candidates = contents.filter { filename in
            guard !filename.contains("metadata"), !filename.hasPrefix(".") else { return false }

            if let mediaSourceId = versionInfo.mediaSourceId, filename.contains(mediaSourceId) {
                return true
            }

            if filename.contains(versionInfo.versionId) {
                return true
            }

            return filename.contains("-")
        }

        for candidate in candidates {
            guard let dash = candidate.firstIndex(of: "-") else { continue }
            let prefix = String(candidate[..<dash])
            if prefix.count > 10 {
                return prefix
            }
        }

        return nil
    }

    private func getPrimaryImageURL(for seriesId: String, episodeItem: BaseItemDto) -> URL? {
        getImageURL(for: seriesId, episodeItem: episodeItem, imageName: "Primary")
    }

    private func getBackdropImageURL(for seriesId: String, episodeItem: BaseItemDto) -> URL? {
        getImageURL(for: seriesId, episodeItem: episodeItem, imageName: "Backdrop")
    }

    private func getImageURL(for seriesId: String, episodeItem: BaseItemDto, imageName: String) -> URL? {
        let seriesPath = URL.downloads.appendingPathComponent(seriesId)

        if let seasonNumber = episodeItem.parentIndexNumber, let episodeId = episodeItem.id {
            let seasonFolder = seriesPath.appendingPathComponent("Season-\(String(format: "%02d", seasonNumber))")
            let seasonImagesFolder = seasonFolder.appendingPathComponent("Images")

            if let contents = try? FileManager.default.contentsOfDirectory(atPath: seasonImagesFolder.path) {
                if let episodeImage = contents.first(where: { $0.hasPrefix("Episode-\(episodeId)-\(imageName)") }) {
                    return seasonImagesFolder.appendingPathComponent(episodeImage)
                }

                if let seasonId = episodeItem.seasonID,
                   let seasonImage = contents.first(where: { $0.hasPrefix("Season-\(seasonId)-\(imageName)") })
                {
                    return seasonImagesFolder.appendingPathComponent(seasonImage)
                }
            }
        }

        let seriesImagesFolder = seriesPath.appendingPathComponent("Images")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: seriesImagesFolder.path),
           let seriesImage = contents.first(where: { $0.hasPrefix("Series-\(seriesId)-\(imageName)") })
        {
            return seriesImagesFolder.appendingPathComponent(seriesImage)
        }

        return nil
    }
}

private extension DownloadedEpisode {
    static func placeholder(for episodeItem: BaseItemDto) -> DownloadedEpisode {
        DownloadedEpisode(
            id: episodeItem.id ?? UUID().uuidString,
            episodeItem: episodeItem,
            versionInfo: VersionInfo(
                versionId: episodeItem.id ?? UUID().uuidString,
                container: "mp4",
                isStatic: true,
                mediaSourceId: episodeItem.mediaSources?.first?.id,
                episodeId: episodeItem.id,
                downloadDate: "",
                taskId: ""
            ),
            mediaURL: nil,
            primaryImageURL: nil,
            backdropImageURL: nil,
            fileSize: nil
        )
    }
}
