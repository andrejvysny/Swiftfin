//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import IdentifiedCollections
import JellyfinAPI
import SwiftUI

extension SeriesEpisodeSelector {

    struct SeasonDownloadButton: View {

        @Injected(\.downloadManager)
        private var downloadManager: DownloadManager

        let seriesId: String
        let seasonViewModel: SeasonItemViewModel

        @State
        private var isDownloading = false

        private var seasonId: String? {
            seasonViewModel.season.id
        }

        private var episodes: IdentifiedArray<Int, BaseItemDto> {
            seasonViewModel.elements
        }

        private var downloadedCount: Int {
            episodes.count(where: { episode in
                downloadManager.isItemDownloaded(episode)
            })
        }

        private var activeCount: Int {
            episodes.count(where: { episode in
                guard let id = episode.id else { return false }
                return downloadManager.downloads.contains(where: { $0.item.id == id })
            })
        }

        private var totalCount: Int {
            episodes.count
        }

        private var completedCount: Int {
            downloadedCount + activeCompletedCount
        }

        private var activeCompletedCount: Int {
            episodes.count(where: { episode in
                guard let id = episode.id else { return false }
                if let task = downloadManager.downloads.first(where: { $0.item.id == id }),
                   case .complete = downloadManager.taskStates[task.taskID]
                {
                    return true
                }
                return false
            })
        }

        private var inProgressCount: Int {
            episodes.count(where: { episode in
                guard let id = episode.id else { return false }
                if let task = downloadManager.downloads.first(where: { $0.item.id == id }) {
                    let state = downloadManager.taskStates[task.taskID]
                    switch state {
                    case .downloading, .queued, .ready:
                        return true
                    default:
                        return false
                    }
                }
                return false
            })
        }

        private var aggregateProgress: Double {
            guard totalCount > 0 else { return 0 }
            var totalProgress = Double(downloadedCount)
            for episode in episodes {
                guard let id = episode.id else { continue }
                if let task = downloadManager.downloads.first(where: { $0.item.id == id }),
                   case let .downloading(p) = downloadManager.taskStates[task.taskID]
                {
                    totalProgress += p
                }
            }
            return totalProgress / Double(totalCount)
        }

        var body: some View {
            Button {
                downloadSeason()
            } label: {
                if totalCount == 0 {
                    EmptyView()
                } else if downloadedCount == totalCount {
                    // All downloaded
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if inProgressCount > 0 {
                    // Downloading
                    HStack(spacing: 4) {
                        Text("\(downloadedCount)/\(totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 2)

                            Circle()
                                .trim(from: 0, to: aggregateProgress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))

                            Image(systemName: "arrow.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 20, height: 20)
                    }
                } else if downloadedCount > 0 {
                    // Partially downloaded
                    HStack(spacing: 4) {
                        Text("\(downloadedCount)/\(totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.primary)
                    }
                } else {
                    // Not downloaded
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(downloadedCount == totalCount || isDownloading)
        }

        private func downloadSeason() {
            guard let seasonId, !isDownloading else { return }
            isDownloading = true

            Task {
                do {
                    _ = try await downloadManager.downloadSeason(
                        seriesId: seriesId,
                        seasonId: seasonId
                    )
                } catch {
                    // Silently handle — individual downloads will show errors
                }
                await MainActor.run {
                    isDownloading = false
                }
            }
        }
    }
}
