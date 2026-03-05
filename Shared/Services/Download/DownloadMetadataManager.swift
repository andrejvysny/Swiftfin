//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import Logging

final class DownloadMetadataManager: DownloadMetadataManaging {

    private let logger = Logger.swiftfin()
    private let fileService: DownloadFileServicing

    init(fileService: DownloadFileServicing) {
        self.fileService = fileService
    }

    // MARK: - Public Interface

    func readMetadata(itemId: String) -> DownloadMetadata? {
        let downloadPath = URL.downloads.appendingPathComponent(itemId)
        let metadataFile = downloadPath.appendingPathComponent("metadata.json")

        if FileManager.default.fileExists(atPath: metadataFile.path),
           let data = FileManager.default.contents(atPath: metadataFile.path)
        {
            do {
                let metadata = try JSONDecoder().decode(DownloadMetadata.self, from: data)

                if metadata.itemType?.lowercased() == "series",
                   let aggregated = aggregateSeriesMetadata(for: itemId, baseMetadata: metadata)
                {
                    return aggregated
                }

                return metadata
            } catch {
                logger.warning("Failed to decode metadata for item \(itemId): \(error)")
            }
        }

        if let aggregated = aggregateSeriesMetadata(for: itemId, baseMetadata: nil) {
            return aggregated
        }

        return nil
    }

    func readSeasonMetadata(seriesId: String, seasonNumber: Int) -> DownloadMetadata? {
        let seasonFolderName = "Season-\(String(format: "%02d", seasonNumber))"
        let seasonMetadataPath = URL
            .downloads
            .appendingPathComponent(seriesId)
            .appendingPathComponent(seasonFolderName)
            .appendingPathComponent("metadata.json")

        guard FileManager.default.fileExists(atPath: seasonMetadataPath.path),
              let data = FileManager.default.contents(atPath: seasonMetadataPath.path)
        else {
            return nil
        }

        do {
            let metadata = try JSONDecoder().decode(DownloadMetadata.self, from: data)
            return metadata
        } catch {
            logger.warning("Failed to decode season metadata for seriesId: \(seriesId) season: \(seasonNumber) - \(error)")
            return nil
        }
    }

    func writeMetadata(for task: DownloadTask) throws {
        guard let downloadFolder = task.item.downloadFolder else { return }

        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)

        if task.item.type == .episode {
            try writeSeriesMetadata(for: task, at: downloadFolder)
            try writeSeasonMetadata(for: task, at: downloadFolder)
        } else {
            try saveMetadata(for: task, at: downloadFolder)
        }

        // Remove legacy Metadata folder if present
        let legacyMetadataFolder = downloadFolder.appendingPathComponent("Metadata")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacyMetadataFolder.path, isDirectory: &isDir), isDir.boolValue {
            do {
                try FileManager.default.removeItem(at: legacyMetadataFolder)
            } catch {
                logger.warning("Failed to remove legacy Metadata folder: \(error.localizedDescription)")
            }
        }

        logger.trace("Saved metadata for: \(task.item.displayTitle)")
    }

    func getDownloadedVersions(for itemId: String) -> [VersionInfo] {
        readMetadata(itemId: itemId)?.versions ?? []
    }

    func parseDownloadItem(with id: String) -> DownloadTask? {
        let root = URL.downloads.appendingPathComponent(id)
        let mergedMetadataFile = root.appendingPathComponent("metadata.json")

        let jsonDecoder = JSONDecoder()

        if let data = FileManager.default.contents(atPath: mergedMetadataFile.path),
           let meta = try? jsonDecoder.decode(DownloadMetadata.self, from: data),
           let offlineItem = meta.item
        {
            let task = DownloadTask(item: offlineItem)
            return task
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let seasonFolders = contents.filter { $0.hasPrefix("Season-") }

            if !seasonFolders.isEmpty {
                for seasonFolder in seasonFolders {
                    let seasonPath = root.appendingPathComponent(seasonFolder)
                    let seasonMetadataFile = seasonPath.appendingPathComponent("metadata.json")

                    if let seasonData = FileManager.default.contents(atPath: seasonMetadataFile.path),
                       let seasonMeta = try? jsonDecoder.decode(DownloadMetadata.self, from: seasonData),
                       let episodeItem = seasonMeta.item,
                       episodeItem.type == .episode
                    {
                        let task = DownloadTask(item: episodeItem)
                        return task
                    }
                }
            }
        } catch {
            logger.debug("Could not read contents of download folder: \(error)")
        }

        let legacyItemFile = root.appendingPathComponent("Metadata").appendingPathComponent("Item.json")
        if let itemData = FileManager.default.contents(atPath: legacyItemFile.path),
           let offlineItem = try? jsonDecoder.decode(BaseItemDto.self, from: itemData)
        {
            let task = DownloadTask(item: offlineItem)
            return task
        }

        return nil
    }

    // MARK: - Private Helpers

    private func writeSeriesMetadata(for task: DownloadTask, at seriesFolder: URL) throws {
        guard task.item.type == .episode else { return }

        let metadataFile = seriesFolder.appendingPathComponent("metadata.json")
        var seriesMetadata: DownloadMetadata

        if FileManager.default.fileExists(atPath: metadataFile.path),
           let existingData = FileManager.default.contents(atPath: metadataFile.path),
           let existing = try? JSONDecoder().decode(DownloadMetadata.self, from: existingData)
        {
            seriesMetadata = existing
        } else {
            let seriesId = task.item.seriesID ?? ""
            let seriesName = task.item.seriesName ?? task.item.displayTitle
            seriesMetadata = DownloadMetadata(
                itemId: seriesId,
                itemType: "Series",
                displayTitle: seriesName
            )
        }

        if seriesMetadata.item == nil {
            var seriesItem = BaseItemDto()
            seriesItem.id = task.item.seriesID
            seriesItem.name = task.item.seriesName ?? seriesMetadata.displayTitle
            seriesItem.type = .series
            seriesMetadata.item = seriesItem
        }

        let uniqueVersionId = task.mediaSourceId ?? task.item.id ?? "default"
        let episodeId = task.item.id
        let versionInfo = VersionInfo(
            versionId: uniqueVersionId,
            container: task.container,
            isStatic: task.isStatic,
            mediaSourceId: task.mediaSourceId,
            episodeId: episodeId,
            downloadDate: ISO8601DateFormatter().string(from: Date()),
            taskId: task.taskID.uuidString
        )

        let normalizedCurrent = task.mediaSourceId ?? episodeId ?? task.item.id

        seriesMetadata.versions.removeAll { version in
            let sameEpisode = version.episodeId == episodeId
            let normalizedExisting = version.mediaSourceId ?? version.episodeId ?? task.item.id
            return sameEpisode && normalizedExisting == normalizedCurrent
        }

        seriesMetadata.versions.append(versionInfo)
        seriesMetadata.versions = deduplicatedVersions(seriesMetadata.versions)

        var episodesMap = seriesMetadata.episodes ?? [:]
        if let episodeKey = episodeId {
            episodesMap[episodeKey] = task.item
        }
        seriesMetadata.episodes = episodesMap.isEmpty ? nil : episodesMap

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(seriesMetadata)
        try jsonData.write(to: metadataFile)

        logger.trace("Updated series metadata for: \(seriesMetadata.displayTitle)")
    }

    private func writeSeasonMetadata(for task: DownloadTask, at seriesFolder: URL) throws {
        guard task.item.type == .episode,
              let season = task.season else { return }

        let seasonFolder = seriesFolder.appendingPathComponent("Season-\(String(format: "%02d", season))")
        try FileManager.default.createDirectory(at: seasonFolder, withIntermediateDirectories: true)

        let metadataFile = seasonFolder.appendingPathComponent("metadata.json")
        var seasonMetadata: DownloadMetadata

        if FileManager.default.fileExists(atPath: metadataFile.path),
           let existingData = FileManager.default.contents(atPath: metadataFile.path),
           let existing = try? JSONDecoder().decode(DownloadMetadata.self, from: existingData)
        {
            seasonMetadata = existing
        } else {
            let seasonId = task.item.seasonID ?? ""
            let seasonName = "Season \(season)"
            seasonMetadata = DownloadMetadata(
                itemId: seasonId,
                itemType: "Season",
                displayTitle: seasonName
            )
        }

        let uniqueVersionId = task.mediaSourceId ?? task.item.id ?? "default"
        let episodeId = task.item.id
        let versionInfo = VersionInfo(
            versionId: uniqueVersionId,
            container: task.container,
            isStatic: task.isStatic,
            mediaSourceId: task.mediaSourceId,
            episodeId: episodeId,
            downloadDate: ISO8601DateFormatter().string(from: Date()),
            taskId: task.taskID.uuidString
        )

        seasonMetadata.versions.removeAll { version in
            let normalizedExisting = version.mediaSourceId ?? task.item.id
            let normalizedCurrent = task.mediaSourceId ?? task.item.id
            return normalizedExisting == normalizedCurrent
        }

        seasonMetadata.versions.append(versionInfo)

        seasonMetadata.item = task.item

        var episodesMap = seasonMetadata.episodes ?? [:]
        if let episodeKey = episodeId {
            episodesMap[episodeKey] = task.item
        }
        seasonMetadata.episodes = episodesMap

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(seasonMetadata)
        try jsonData.write(to: metadataFile)
    }

    private func aggregateSeriesMetadata(for seriesId: String, baseMetadata: DownloadMetadata?) -> DownloadMetadata? {
        let downloadPath = URL.downloads.appendingPathComponent(seriesId)

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: downloadPath.path) else {
            return baseMetadata
        }

        let seasonFolders = contents.filter { $0.hasPrefix("Season-") }
        if seasonFolders.isEmpty {
            return baseMetadata
        }

        var aggregatedVersions = baseMetadata?.versions ?? []
        var aggregatedEpisodes = baseMetadata?.episodes ?? [:]
        var displayTitle = baseMetadata?.displayTitle ?? "Unknown Series"
        var seriesItem = baseMetadata?.item

        for seasonFolder in seasonFolders.sorted() {
            let seasonPath = downloadPath.appendingPathComponent(seasonFolder)
            let seasonMetadataFile = seasonPath.appendingPathComponent("metadata.json")

            guard let seasonData = FileManager.default.contents(atPath: seasonMetadataFile.path),
                  let seasonMeta = try? JSONDecoder().decode(DownloadMetadata.self, from: seasonData)
            else {
                continue
            }

            aggregatedVersions.append(contentsOf: seasonMeta.versions)

            if let episodes = seasonMeta.episodes {
                aggregatedEpisodes.merge(episodes) { _, new in new }
            } else if let episodeItem = seasonMeta.item, let episodeId = episodeItem.id {
                aggregatedEpisodes[episodeId] = episodeItem
            }

            if seriesItem == nil {
                if let existingSeriesItem = baseMetadata?.item {
                    seriesItem = existingSeriesItem
                } else if let episode = seasonMeta.item {
                    var inferredSeries = BaseItemDto()
                    inferredSeries.id = episode.seriesID
                    inferredSeries.name = episode.seriesName ?? displayTitle
                    inferredSeries.type = .series
                    seriesItem = inferredSeries
                    if let name = episode.seriesName {
                        displayTitle = name
                    }
                }
            }
        }

        if aggregatedVersions.isEmpty {
            return baseMetadata
        }

        let versions = deduplicatedVersions(aggregatedVersions)
        let episodes = aggregatedEpisodes.isEmpty ? baseMetadata?.episodes : aggregatedEpisodes

        return DownloadMetadata(
            itemId: baseMetadata?.itemId ?? seriesId,
            itemType: "Series",
            displayTitle: displayTitle,
            item: seriesItem ?? baseMetadata?.item,
            episodes: episodes,
            versions: versions
        )
    }

    private func deduplicatedVersions(_ versions: [VersionInfo]) -> [VersionInfo] {
        var seenKeys = Set<String>()
        var unique: [VersionInfo] = []

        for version in versions {
            let key = [
                version.episodeId ?? "",
                version.mediaSourceId ?? "",
                version.versionId,
            ].joined(separator: "|")

            if seenKeys.insert(key).inserted {
                unique.append(version)
            }
        }

        return unique
    }

    private func saveMetadata(for task: DownloadTask, at folder: URL) throws {
        let metadataFile = folder.appendingPathComponent("metadata.json")
        var downloadMetadata: DownloadMetadata

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: metadataFile.path),
           let existingData = FileManager.default.contents(atPath: metadataFile.path),
           let existing = try? JSONDecoder().decode(DownloadMetadata.self, from: existingData)
        {
            downloadMetadata = existing
        } else {
            downloadMetadata = DownloadMetadata(
                itemId: task.item.id ?? "",
                itemType: task.item.type?.rawValue,
                displayTitle: task.item.displayTitle
            )
        }

        downloadMetadata.item = task.item

        let uniqueVersionId = task.mediaSourceId ?? task.item.id ?? "default"
        let versionInfo = VersionInfo(
            versionId: uniqueVersionId,
            container: task.container,
            isStatic: task.isStatic,
            mediaSourceId: task.mediaSourceId,
            downloadDate: ISO8601DateFormatter().string(from: Date()),
            taskId: task.taskID.uuidString
        )

        downloadMetadata.versions.removeAll { version in
            let normalizedExisting = version.mediaSourceId ?? task.item.id
            let normalizedCurrent = task.mediaSourceId ?? task.item.id
            return normalizedExisting == normalizedCurrent
        }

        downloadMetadata.versions.append(versionInfo)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(downloadMetadata)
        try jsonData.write(to: metadataFile)

        logger.trace("Updated metadata.json for: \(task.item.displayTitle) with \(downloadMetadata.versions.count) versions")
    }
}
