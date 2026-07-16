//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

struct DownloadActionButtonWithProgress: View {
    enum Styling {
        case inherited
        case plain
    }

    @StateObject
    var viewModel: DownloadActionButtonWithProgressViewModel

    var onErrorTap: (() -> Void)?
    var onStartTap: (() -> Void)?
    var onCompletedTap: (() -> Void)?

    private let shouldAutoStart: Bool
    private let styling: Styling

    // MARK: - Convenience Initializers

    /// Creates a download button for a single item
    init(
        item: BaseItemDto,
        mediaSourceId: String? = nil,
        shouldAutoStart: Bool = true,
        styling: Styling = .inherited,
        onStartTap: (() -> Void)? = nil,
        onCompletedTap: (() -> Void)? = nil,
        onErrorTap: (() -> Void)? = nil
    ) {
        self._viewModel = StateObject(wrappedValue: DownloadActionButtonWithProgressViewModel(
            item: item,
            mediaSourceId: mediaSourceId,
            shouldAutoStart: shouldAutoStart
        ))
        self.shouldAutoStart = shouldAutoStart
        self.styling = styling
        self.onStartTap = onStartTap
        self.onCompletedTap = onCompletedTap
        self.onErrorTap = onErrorTap
    }

    /// Creates a download button with an existing view model
    init(
        viewModel: DownloadActionButtonWithProgressViewModel,
        shouldAutoStart: Bool = true,
        styling: Styling = .inherited,
        onStartTap: (() -> Void)? = nil,
        onCompletedTap: (() -> Void)? = nil,
        onErrorTap: (() -> Void)? = nil
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.shouldAutoStart = shouldAutoStart
        self.styling = styling
        self.onStartTap = onStartTap
        self.onCompletedTap = onCompletedTap
        self.onErrorTap = onErrorTap
    }

    var body: some View {
        Button {
            switch viewModel.state {
            case .ready:
                onStartTap?()
                if shouldAutoStart {
                    viewModel.start()
                }
            case .downloading:
                onStartTap?()
                if shouldAutoStart {
                    viewModel.pause()
                }
            case .paused:
                onStartTap?()
                if shouldAutoStart {
                    viewModel.resume()
                }
            case .queued:
                viewModel.cancel()
            case .error:
                onStartTap?()
                if shouldAutoStart {
                    viewModel.retryDownload()
                    onErrorTap?()
                }
            case .partiallyCompleted:
                onStartTap?()
            case .completed:
                onCompletedTap?()
            }
        } label: {
            if viewModel.state == .downloading {
                progressIcon(progress: viewModel.progress)
            } else if viewModel.state == .paused {
                progressIcon(iconName: "chevron.right.2", iconColor: .orange, progress: viewModel.progress)
            } else {
                Image(systemName: iconName(for: viewModel.state))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundColor(iconColor(for: viewModel.state))
            }
        }
        .if(styling == .plain) { view in
            view.buttonStyle(.plain)
        }
        .onAppear {
            // Refresh the download state when the view appears to ensure it's up to date
            viewModel.refreshDownloadState()
        }
    }

    // MARK: - Progress Icon

    private func progressIcon(iconName: String = "arrow.down", iconColor: Color = .accentColor, progress: Double) -> some View {
        ZStack {
            // Background circle (full, gray)
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)

            // Foreground progress (primary color)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    iconColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // Center icon
            Image(systemName: iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .bold(true)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(iconColor)
        }
        .frame(width: 24, height: 24)
    }

    // MARK: - Icon logic

    private func iconName(for state: DownloadTaskState) -> String {
        switch state {
        case .completed:
            "checkmark.circle.fill"
        case .paused:
            "pause.circle"
        case .ready:
            "arrow.down.circle"
        case .downloading:
            "arrow.down"
        case .queued:
            "clock.badge.checkmark"
        case .error:
            "exclamationmark.circle"
        case .partiallyCompleted:
            "checkmark.circle"
        }
    }

    private func iconColor(for state: DownloadTaskState) -> Color {
        switch state {
        case .completed, .partiallyCompleted:
            .green
        case .ready:
            .primary
        case .queued:
            .orange
        case .error:
            .red
        default:
            .accentColor
        }
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 20) {
        DownloadActionButtonWithProgress(viewModel: .init(state: .ready, progress: 0.0))
        DownloadActionButtonWithProgress(viewModel: .init(state: .downloading, progress: 0.3))
        DownloadActionButtonWithProgress(viewModel: .init(state: .paused, progress: 0.3))
        DownloadActionButtonWithProgress(viewModel: .init(state: .queued, progress: 0.0))
        DownloadActionButtonWithProgress(viewModel: .init(state: .error, progress: 0.3))
        DownloadActionButtonWithProgress(viewModel: .init(state: .partiallyCompleted))
        DownloadActionButtonWithProgress(viewModel: .init(state: .completed))
    }
}
