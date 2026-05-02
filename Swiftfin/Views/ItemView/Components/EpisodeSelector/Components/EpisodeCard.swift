//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

extension SeriesEpisodeSelector {

    struct EpisodeCard: View {

        @Default(.accentColor)
        private var accentColor
        @Default(.Customization.Indicators.showPlayed)
        private var showPlayed

        @Namespace
        private var namespace

        @Router
        private var router

        let episode: BaseItemDto
        var isSelectionMode: Bool = false
        var isSelected: Bool = false
        var onToggleSelection: (() -> Void)?
        var onEnterSelectionMode: (() -> Void)?

        @ViewBuilder
        private var overlayView: some View {
            if let progressLabel = episode.progressLabel {
                LandscapePosterProgressBar(
                    title: progressLabel,
                    progress: (episode.userData?.playedPercentage ?? 0) / 100
                )
            } else if episode.userData?.isPlayed ?? false, showPlayed {
                WatchedIndicator(size: 25)
            }
        }

        private var episodeContent: String {
            if episode.isUnaired {
                episode.airDateLabel ?? L10n.noOverviewAvailable
            } else {
                episode.overview ?? L10n.noOverviewAvailable
            }
        }

        @ViewBuilder
        private var selectionOverlay: some View {
            if isSelectionMode {
                ZStack(alignment: .topTrailing) {
                    Color.clear

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(8)
                }
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Button {
                    if isSelectionMode {
                        onToggleSelection?()
                    } else {
                        router.route(
                            to: .videoPlayer(
                                item: episode,
                                queue: EpisodeMediaPlayerQueue(episode: episode)
                            )
                        )
                    }
                } label: {
                    ImageView(episode.imageSource(.primary, maxWidth: 250))
                        .failure {
                            SystemImageContentView(systemName: episode.systemImage)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            overlayView
                        }
                        .overlay {
                            selectionOverlay
                        }
                        .contentShape(.contextMenuPreview, Rectangle())
                        .backport
                        .matchedTransitionSource(id: "item", in: namespace)
                        .posterStyle(.landscape)
                        .posterShadow()
                        .opacity(isSelectionMode && !isSelected ? 0.6 : 1.0)
                }
                .onLongPressGesture {
                    if !isSelectionMode {
                        onEnterSelectionMode?()
                    }
                }

                SeriesEpisodeSelector.EpisodeContent(
                    header: episode.displayTitle,
                    subHeader: episode.episodeLocator ?? .emptyDash,
                    content: episodeContent
                ) {
                    if isSelectionMode {
                        onToggleSelection?()
                    } else {
                        router.route(to: .item(item: episode), in: namespace)
                    }
                }
            }
        }
    }
}
