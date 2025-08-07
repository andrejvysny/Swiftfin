//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

struct DownloadIcon: View {

    @StateObject
    private var vm: DownloadIconViewModel

    // MARK: Init

    init(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo
    ) {
        _vm = StateObject(
            wrappedValue: DownloadIconViewModel(
                item: item,
                mediaSource: mediaSource
            )
        )
    }

    // MARK: Body

    var body: some View {
        Button {
            vm.handleTap()
        } label: {
            icon
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Sub-views

    @ViewBuilder
    private var icon: some View {
        switch vm.uiState {
        case .ready:
            Image(systemName: "arrow.down.circle")
        case let .downloading(progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .frame(width: 24, height: 24)
        case .complete:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(Color.accentColor)
        case .error:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }

    private var accessibilityLabel: String {
        switch vm.uiState {
        case .ready: return "Download"
        case .downloading: return "Downloading"
        case .complete: return "Downloaded"
        case .error: return "Download failed"
        }
    }
}
