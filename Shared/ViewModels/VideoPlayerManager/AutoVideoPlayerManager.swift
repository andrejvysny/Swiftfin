//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation
import JellyfinAPI
import Logging

final class AutoVideoPlayerManager: VideoPlayerManager {

    private let log = Logger.swiftfin()
    private let downloadManager: DownloadManager

    private var isOfflinePlayback = false

    init(item: BaseItemDto, mediaSource: MediaSourceInfo) {
        self.downloadManager = Container.shared.downloadManager()

        super.init()

        Task {
            await loadPlayback(item: item, mediaSource: mediaSource)
        }
    }

    private func loadPlayback(item: BaseItemDto, mediaSource: MediaSourceInfo) async {
        if let playbackInfo = downloadManager.playbackInfo(for: item, mediaSourceId: mediaSource.id) {
            log.debug("Resolved offline playback for item: \(item.displayTitle)")

            let viewModel = makeViewModel(from: playbackInfo)

            await MainActor.run {
                self.currentViewModel = viewModel
                self.isOfflinePlayback = true
            }

            return
        }

        log.debug("Falling back to online playback for item: \(item.displayTitle)")

        do {
            let viewModel = try await item.videoPlayerViewModel(with: mediaSource)
            await MainActor.run {
                self.currentViewModel = viewModel
                self.isOfflinePlayback = false
            }
        } catch {
            log.error("Failed to create online video player view model: \(error.localizedDescription)")
        }
    }

    private func makeViewModel(from playbackInfo: DownloadPlaybackInfo) -> VideoPlayerViewModel {
        let mediaSource = playbackInfo.mediaSource
        let mediaStreams = mediaSource.mediaStreams ?? []

        return VideoPlayerViewModel(
            playbackURL: playbackInfo.fileURL,
            item: playbackInfo.item,
            mediaSource: mediaSource,
            playSessionID: "offline-\(UUID().uuidString)",
            videoStreams: mediaStreams.filter { $0.type == .video },
            audioStreams: mediaStreams.filter { $0.type == .audio },
            subtitleStreams: mediaStreams.filter { $0.type == .subtitle },
            selectedAudioStreamIndex: playbackInfo.defaultAudioStreamIndex,
            selectedSubtitleStreamIndex: playbackInfo.defaultSubtitleStreamIndex,
            chapters: playbackInfo.item.fullChapterInfo,
            playMethod: .directPlay
        )
    }

    override func sendStartReport() {
        guard !isOfflinePlayback else { return }
        super.sendStartReport()
    }

    override func sendPauseReport() {
        guard !isOfflinePlayback else { return }
        super.sendPauseReport()
    }

    override func sendStopReport() {
        guard !isOfflinePlayback else { return }
        super.sendStopReport()
    }

    override func sendProgressReport() {
        guard !isOfflinePlayback else { return }
        super.sendProgressReport()
    }
}
