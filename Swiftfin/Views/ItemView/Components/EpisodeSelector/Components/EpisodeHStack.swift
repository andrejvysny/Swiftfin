//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CollectionHStack
import JellyfinAPI
import SwiftUI

// TODO: The content/loading/error states are implemented as different CollectionHStacks because it was just easy.
//       A theoretically better implementation would be a single CollectionHStack with cards that represent the state instead.
extension SeriesEpisodeSelector {

    struct EpisodeHStack: View {

        @ObservedObject
        var viewModel: SeasonItemViewModel

        @State
        private var didScrollToPlayButtonItem = false

        @StateObject
        private var proxy = CollectionHStackProxy()

        let playButtonItem: BaseItemDto?
        var isSelectionMode: Bool = false
        @Binding
        var selectedEpisodeIDs: Set<String>
        var onEnterSelectionMode: ((String) -> Void)?

        init(
            viewModel: SeasonItemViewModel,
            playButtonItem: BaseItemDto?,
            isSelectionMode: Bool = false,
            selectedEpisodeIDs: Binding<Set<String>> = .constant([]),
            onEnterSelectionMode: ((String) -> Void)? = nil
        ) {
            self._viewModel = ObservedObject(wrappedValue: viewModel)
            self.playButtonItem = playButtonItem
            self.isSelectionMode = isSelectionMode
            self._selectedEpisodeIDs = selectedEpisodeIDs
            self.onEnterSelectionMode = onEnterSelectionMode
        }

        private func contentView(viewModel: SeasonItemViewModel) -> some View {
            CollectionHStack(
                uniqueElements: viewModel.elements,
                id: \.unwrappedIDHashOrZero,
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { episode in
                SeriesEpisodeSelector.EpisodeCard(
                    episode: episode,
                    isSelectionMode: isSelectionMode,
                    isSelected: selectedEpisodeIDs.contains(episode.id ?? ""),
                    onToggleSelection: {
                        guard let id = episode.id else { return }
                        if selectedEpisodeIDs.contains(id) {
                            selectedEpisodeIDs.remove(id)
                        } else {
                            selectedEpisodeIDs.insert(id)
                        }
                    },
                    onEnterSelectionMode: {
                        guard let id = episode.id else { return }
                        onEnterSelectionMode?(id)
                    }
                )
            }
            .clipsToBounds(false)
            .scrollBehavior(.continuousLeadingEdge)
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .proxy(proxy)
            .onFirstAppear {
                guard !didScrollToPlayButtonItem else { return }
                didScrollToPlayButtonItem = true

                // good enough?
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let playButtonItem else { return }
                    proxy.scrollTo(id: playButtonItem.unwrappedIDHashOrZero, animated: false)
                }
            }
        }

        var body: some View {
            switch viewModel.state {
            case .content:
                if viewModel.elements.isEmpty {
                    EmptyHStack()
                } else {
                    contentView(viewModel: viewModel)
                }
            case let .error(error):
                ErrorHStack(viewModel: viewModel, error: error)
            case .initial, .refreshing:
                LoadingHStack()
            }
        }
    }

    struct EmptyHStack: View {

        var body: some View {
            CollectionHStack(
                count: 1,
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { _ in
                SeriesEpisodeSelector.EmptyCard()
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }

    // TODO: better refresh design
    struct ErrorHStack: View {

        @ObservedObject
        var viewModel: SeasonItemViewModel

        let error: ErrorMessage

        var body: some View {
            CollectionHStack(
                count: 1,
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { _ in
                SeriesEpisodeSelector.ErrorCard(error: error) {
                    viewModel.send(.refresh)
                }
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }

    struct LoadingHStack: View {

        var body: some View {
            CollectionHStack(
                count: Int.random(in: 2 ..< 5),
                columns: UIDevice.isPhone ? 1.5 : 3.5
            ) { _ in
                SeriesEpisodeSelector.LoadingCard()
            }
            .insets(horizontal: EdgeInsets.edgePadding)
            .itemSpacing(EdgeInsets.edgePadding / 2)
            .scrollDisabled(true)
        }
    }
}
