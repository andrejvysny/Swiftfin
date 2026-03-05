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

final class DownloadVideoPlayerManager: VideoPlayerManager {

    init(downloadTask: DownloadTask) {
        super.init()

        let downloadManager = Container.shared.downloadManager()
        guard let playbackInfo = downloadManager.playbackInfo(
            for: downloadTask.item,
            mediaSourceId: downloadTask.mediaSourceId
        ) else {
            logger.error("Download task does not have playback info for item: \(downloadTask.item.displayTitle)")

            return
        }

        let mediaSource = playbackInfo.mediaSource
        let mediaStreams = mediaSource.mediaStreams ?? []

        let selectedAudioIndex = playbackInfo.defaultAudioStreamIndex
        let selectedSubtitleIndex = playbackInfo.defaultSubtitleStreamIndex

        self.currentViewModel = .init(
            playbackURL: playbackInfo.fileURL,
            item: playbackInfo.item,
            mediaSource: mediaSource,
            playSessionID: "offline-\(downloadTask.taskID.uuidString)",
            videoStreams: mediaStreams.filter { $0.type == .video },
            audioStreams: mediaStreams.filter { $0.type == .audio },
            subtitleStreams: mediaStreams.filter { $0.type == .subtitle },
            selectedAudioStreamIndex: selectedAudioIndex,
            selectedSubtitleStreamIndex: selectedSubtitleIndex,
            chapters: playbackInfo.item.fullChapterInfo,
            playMethod: .directPlay
        )
    }

    override func getAdjacentEpisodes(for item: BaseItemDto) {}

    override func sendStartReport() {}

    override func sendPauseReport() {}

    override func sendStopReport() {}

    override func sendProgressReport() {}
}
