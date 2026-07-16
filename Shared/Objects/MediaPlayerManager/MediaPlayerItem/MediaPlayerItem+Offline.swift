//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension MediaPlayerItem {

    /// Builds a `MediaPlayerItem` from offline download playback info.
    static func buildOffline(from playbackInfo: DownloadPlaybackInfo) -> MediaPlayerItem {
        .init(
            baseItem: playbackInfo.item,
            mediaSource: playbackInfo.mediaSource,
            playSessionID: "offline-\(UUID().uuidString)",
            url: playbackInfo.fileURL
        )
    }
}
