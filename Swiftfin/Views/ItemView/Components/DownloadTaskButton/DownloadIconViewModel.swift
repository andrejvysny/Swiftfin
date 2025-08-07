//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import JellyfinAPI

@MainActor
final class DownloadIconViewModel: ObservableObject {

    enum UIState: Equatable {
        case ready
        case downloading(Double) // 0‥1
        case complete
        case error
    }

    // MARK: Inputs

    let item: BaseItemDto
    let mediaSource: MediaSourceInfo

    // MARK: Outputs

    @Published
    var uiState: UIState = .ready

    // MARK: Dependencies

    @Injected(\.downloadManager)
    private var downloadManager

    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo
    ) {
        self.item = item
        self.mediaSource = mediaSource
        updateDownloadState()
        bindTask()
    }

    // MARK: Public API

    func handleTap() {
        switch uiState {
        case .ready, .error:
            beginDownload()
        case .downloading:
            // Could add cancel functionality here if needed
            break
        case .complete:
            // Already downloaded - do nothing
            break
        }
    }

    func beginDownload() {
        guard uiState != .complete else {
            return
        }

        // Immediately update state to show we're starting the download
        uiState = .downloading(0.0)

        // Create a new item with only the selected media source
        var selected = item
        selected.mediaSources = [mediaSource]

        // Use the new download method that handles version numbering
        downloadManager.download(item: selected, mediaSource: mediaSource)
    }

    // MARK: Private

    private func updateDownloadState() {
        guard let sourceId = mediaSource.id else {
            uiState = .ready
            return
        }

        // Check if this specific media source is downloaded
        if downloadManager.isMediaSourceDownloaded(item: item, mediaSourceId: sourceId) {
            uiState = .complete
            return
        }

        // Check if there's an active download for this specific media source
        if let task = downloadManager.task(for: item, mediaSourceId: sourceId) {
            switch task.state {
            case .ready: uiState = .ready
            case let .downloading(progress): uiState = .downloading(progress)
            case .complete: uiState = .complete
            case .error: uiState = .error
            case .cancelled: uiState = .ready
            }
            return
        }

        // No active download found
        uiState = .ready
    }

    private func bindTask() {
        // Listen for download state changes
        downloadManager.$downloads
            .compactMap { [weak self] (_: [DownloadTask]) -> DownloadTask? in
                guard let self else { return nil }
                guard let sourceId = mediaSource.id else { return nil }
                return downloadManager.task(for: item, mediaSourceId: sourceId)
            }
            .sink { [weak self] (task: DownloadTask) in
                guard let self else { return }
                switch task.state {
                case .ready, .cancelled: uiState = .ready
                case let .downloading(p): uiState = .downloading(p)
                case .complete:
                    uiState = .complete
                    // Update downloaded state when download completes
                    updateDownloadState()
                case .error: uiState = .error
                }
            }
            .store(in: &cancellables)

        // Also listen for general changes to update downloaded status
        downloadManager.$downloads
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateDownloadState()
            }
            .store(in: &cancellables)
    }
}
