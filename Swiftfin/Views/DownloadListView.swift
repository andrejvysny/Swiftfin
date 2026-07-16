//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import JellyfinAPI
import Logging
import SwiftUI

struct DownloadListView: View {

    // MARK: - Properties

    var error: Error?
    var onRetry: (() -> Void)?

    // MARK: - State Properties

    @Router
    private var router

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    @StateObject
    private var viewModel = DownloadListViewModel()

    @State
    private var showingDeleteAlert = false

    @State
    private var showingDeleteAllAlert = false

    @State
    private var showingVersionSelectionAlert = false

    @State
    private var showToDelete: DownloadedShow?

    @State
    private var movieToDelete: DownloadedMovie?

    @State
    private var selectedMovie: DownloadedMovie?

    @State
    private var isEditMode = false

    @State
    private var selectedForDeletion: Set<String> = []

    // MARK: - Dependencies

    private let logger = Logger.swiftfin()

    // MARK: - Computed Properties

    private var totalStorageUsed: String {
        viewModel.totalStorageUsedText
    }

    private var totalItemCount: Int {
        viewModel.totalItemCount
    }

    // MARK: - Active Downloads

    private var activeDownloads: [DownloadTask] {
        downloadManager.downloads.filter {
            if case .downloading = downloadManager.taskStates[$0.taskID] { return true }
            return false
        }
    }

    private var queuedDownloads: [DownloadTask] {
        downloadManager.downloads.filter {
            if case .queued = downloadManager.taskStates[$0.taskID] { return true }
            return false
        }
    }

    // MARK: - Empty State View

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text("No Downloads")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Download content to watch offline")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.orange)

                if let onRetry {
                    Button("Retry Connection") { onRetry() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        ScrollView {

            VStack(alignment: .leading, spacing: 20) {
                // Storage summary header
                HStack {

                    if let error {
                        Spacer()
                        HStack(spacing: 6) {
                            Text(error.localizedDescription)
                                .font(.caption)
                                .lineLimit(1)

                            if let onRetry {
                                Button {
                                    onRetry()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption.bold())
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("Content avaliable for offline viewing")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    if !viewModel.downloadedShows.isEmpty || !viewModel.downloadedMovies.isEmpty {
                        Text("\(totalItemCount) items • \(totalStorageUsed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)

                // Active downloads
                if !activeDownloads.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloading")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(activeDownloads) { task in
                            ActiveDownloadRow(
                                task: task,
                                progress: progressFor(task),
                                onCancel: { downloadManager.cancelDownload(taskID: task.taskID, removeFile: true) }
                            )
                            .padding(.horizontal)
                        }
                    }
                }

                // Queued downloads
                if !queuedDownloads.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Queued (\(queuedDownloads.count))")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(queuedDownloads) { task in
                            QueuedDownloadRow(
                                task: task,
                                onCancel: { downloadManager.cancelDownload(taskID: task.taskID, removeFile: true) }
                            )
                            .padding(.horizontal)
                        }
                    }
                }

                // Downloads list
                LazyVStack(spacing: 12) {
                    // Downloaded Shows
                    ForEach(viewModel.downloadedShows) { show in
                        if isEditMode {
                            editModeRow(id: show.id, title: show.displayTitle) {
                                DownloadedShowRow(
                                    show: show,
                                    onTap: { toggleDeletion(show.id) },
                                    onDelete: { deleteDownloadedShow(show) }
                                )
                            }
                        } else {
                            DownloadedShowRow(
                                show: show,
                                onTap: { handleShowTap(show) },
                                onDelete: { deleteDownloadedShow(show) }
                            )
                        }
                    }

                    // Downloaded Movies
                    ForEach(viewModel.downloadedMovies) { movie in
                        if isEditMode {
                            editModeRow(id: movie.id, title: movie.displayTitle) {
                                DownloadedMovieRow(
                                    movie: movie,
                                    onTap: { toggleDeletion(movie.id) },
                                    onDelete: { deleteDownloadedMovie(movie) }
                                )
                            }
                        } else {
                            DownloadedMovieRow(
                                movie: movie,
                                onTap: { handleMovieTap(movie) },
                                onDelete: { deleteDownloadedMovie(movie) }
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .refreshable { await viewModel.refresh() }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Loading downloads...")
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.downloadedShows.isEmpty && viewModel.downloadedMovies.isEmpty
                && activeDownloads.isEmpty && queuedDownloads.isEmpty
            {
                emptyView
            } else {
                contentView
            }
        }
        .navigationTitle(L10n.downloads)
        .navigationBarTitleDisplayMode(.large)
        .alert("Delete Download", isPresented: $showingDeleteAlert) {
            Button(L10n.cancel, role: .cancel) {
                showToDelete = nil
                movieToDelete = nil
            }
            Button(L10n.delete, role: .destructive) {
                confirmDelete()
            }
        } message: {
            if let showToDelete {
                Text("Are you sure you want to delete '\(showToDelete.displayTitle)' and all its episodes?")
            } else if let movieToDelete {
                Text("Are you sure you want to delete '\(movieToDelete.displayTitle)'?")
            } else {
                Text("Are you sure you want to delete this downloaded item?")
            }
        }
        .alert("Delete All Downloads", isPresented: $showingDeleteAllAlert) {
            Button(L10n.cancel, role: .cancel) {}
            Button("Delete All", role: .destructive) {
                confirmDeleteAll()
            }
        } message: {
            Text("Are you sure you want to delete all \(totalItemCount) downloaded items? This action cannot be undone.")
        }
        .alert("Select Version", isPresented: $showingVersionSelectionAlert) {
            if let selectedMovie {
                ForEach(selectedMovie.versions, id: \.id) { version in
                    Button(version.displayName) {
                        playMovieVersion(version)
                    }
                }
                Button(L10n.cancel, role: .cancel) {
                    self.selectedMovie = nil
                }
            }
        } message: {
            if let selectedMovie {
                Text("Select which version of '\(selectedMovie.displayTitle)' to play:")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !viewModel.downloadedShows.isEmpty || !viewModel.downloadedMovies.isEmpty {
                    Button(isEditMode ? "Done" : "Edit") {
                        isEditMode.toggle()
                        if !isEditMode { selectedForDeletion.removeAll() }
                    }
                    .font(.subheadline)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.downloadedShows.isEmpty || !viewModel.downloadedMovies.isEmpty {
                    Button {
                        logger.info("User requested to delete all downloads")
                        showingDeleteAllAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                if isEditMode && !selectedForDeletion.isEmpty {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete (\(selectedForDeletion.count))", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            viewModel.load()
        }
    }

    // MARK: - Private Methods

    private func deleteDownloadedShow(_ show: DownloadedShow) {
        logger.info("User requested to delete show: \(show.displayTitle)")
        showToDelete = show
        showingDeleteAlert = true
    }

    private func deleteDownloadedMovie(_ movie: DownloadedMovie) {
        logger.info("User requested to delete movie: \(movie.displayTitle)")
        movieToDelete = movie
        showingDeleteAlert = true
    }

    private func confirmDelete() {
        if let showToDelete {
            logger.info("Confirming deletion of show: \(showToDelete.displayTitle)")

            viewModel.deleteShow(id: showToDelete.id)

            self.showToDelete = nil

        } else if let movieToDelete {
            logger.info("Confirming deletion of movie: \(movieToDelete.displayTitle)")

            viewModel.deleteMovie(id: movieToDelete.id)

            self.movieToDelete = nil
        }
    }

    private func deleteSelected() {
        logger.info("Deleting \(selectedForDeletion.count) selected items")
        _ = downloadManager.deleteDownloadedMedia(itemIds: Array(selectedForDeletion))
        selectedForDeletion.removeAll()
        isEditMode = false
        viewModel.load()
    }

    private func confirmDeleteAll() {
        logger.info("Confirming deletion of all downloads")
        viewModel.deleteAll()
    }

    private func handleShowTap(_ show: DownloadedShow) {
        logger.info("User tapped on show: \(show.displayTitle)")
        router.route(to: .itemDownloadList(item: show.seriesItem))
    }

    private func handleMovieTap(_ movie: DownloadedMovie) {
        if movie.hasMultipleVersions {
            selectedMovie = movie
            showingVersionSelectionAlert = true
        } else {
            // Single version - play directly
            if let version = movie.versions.first {
                playMovieVersion(version)
            }
        }
    }

    private func playMovieVersion(_ downloadedVersion: DownloadedVersion) {
        logger.info("Playing downloaded movie version: \(downloadedVersion.displayName)")

        let mediaSource = resolveMediaSource(for: downloadedVersion.item, using: downloadedVersion.versionInfo)
            ?? fallbackMediaSource(from: downloadedVersion.versionInfo, item: downloadedVersion.item)

        router.route(
            to: .videoPlayer(
                item: downloadedVersion.item,
                mediaSource: mediaSource
            )
        )
    }

    private func fallbackMediaSource(from versionInfo: VersionInfo?, item: BaseItemDto) -> MediaSourceInfo? {
        let sourceId = versionInfo?.mediaSourceId ?? versionInfo?.versionId ?? item.id
        guard let sourceId else { return nil }
        var source = MediaSourceInfo()
        source.id = sourceId
        source.container = versionInfo?.container
        return source
    }

    private func toggleDeletion(_ id: String) {
        if selectedForDeletion.contains(id) {
            selectedForDeletion.remove(id)
        } else {
            selectedForDeletion.insert(id)
        }
    }

    @ViewBuilder
    private func editModeRow(id: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleDeletion(id)
            } label: {
                Image(systemName: selectedForDeletion.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedForDeletion.contains(id) ? .red : .secondary)
            }
            .buttonStyle(.plain)

            content()
        }
    }

    private func progressFor(_ task: DownloadTask) -> Double {
        if case let .downloading(p) = downloadManager.taskStates[task.taskID] {
            return p
        }
        return 0
    }

    private func resolveMediaSource(for item: BaseItemDto, using versionInfo: VersionInfo?) -> MediaSourceInfo? {
        guard let mediaSources = item.mediaSources, !mediaSources.isEmpty else { return nil }

        if let versionId = versionInfo?.versionId,
           let match = mediaSources.first(where: { $0.id == versionId })
        {
            return match
        }

        if let mediaSourceId = versionInfo?.mediaSourceId,
           let match = mediaSources.first(where: { $0.id == mediaSourceId })
        {
            return match
        }

        if let itemId = item.id,
           let match = mediaSources.first(where: { $0.id == itemId })
        {
            return match
        }

        return mediaSources.first
    }
}

// MARK: - Downloaded Show Row

struct DownloadedShowRow: View {

    // MARK: - Properties

    let show: DownloadedShow
    let onTap: () -> Void
    let onDelete: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                ImageView(show.primaryImageURL ?? show.backdropImageURL)
                    .pipeline(.Swiftfin.local)
                    .failure {
                        Rectangle()
                            .foregroundStyle(.secondary.opacity(0.3))
                            .overlay {
                                Image(systemName: "tv")
                            }
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Content info
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(show.displayTitle)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .lineLimit(2)

                        Spacer()

                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }

                    if let overview = show.seriesItem.overview {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    // Metadata badges
                    HStack {
                        if let year = show.seriesItem.productionYear {
                            Text(String(year))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Text("\(show.episodeCount) episodes")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        if show.seasons.count > 1 {
                            Text("\(show.seasons.count) seasons")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Spacer()
                    }
                }
            }
            .padding()
            .background(.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Download Row

struct ActiveDownloadRow: View {

    let task: DownloadTask
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ImageView(task.item.imageSource(.primary, maxWidth: 80))
                .failure {
                    Rectangle()
                        .foregroundStyle(.secondary.opacity(0.3))
                        .overlay {
                            Image(systemName: "arrow.down.circle")
                        }
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                ProgressView(value: progress)
                    .tint(.accentColor)

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Queued Download Row

struct QueuedDownloadRow: View {

    let task: DownloadTask
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ImageView(task.item.imageSource(.primary, maxWidth: 80))
                .failure {
                    Rectangle()
                        .foregroundStyle(.secondary.opacity(0.3))
                        .overlay {
                            Image(systemName: "clock")
                        }
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text("Waiting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Downloaded Movie Row

struct DownloadedMovieRow: View {

    // MARK: - Properties

    let movie: DownloadedMovie
    let onTap: () -> Void
    let onDelete: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                ImageView(movie.primaryImageURL ?? movie.backdropImageURL)
                    .pipeline(.Swiftfin.local)
                    .failure {
                        Rectangle()
                            .foregroundStyle(.secondary.opacity(0.3))
                            .overlay {
                                Image(systemName: "film")
                            }
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Content info
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(movie.displayTitle)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .lineLimit(2)

                        Spacer()

                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }

                    if let overview = movie.movieItem.overview {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    // Metadata badges
                    HStack {
                        if let year = movie.movieItem.productionYear {
                            Text(String(year))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        if let runtime = movie.movieItem.runTimeTicks {
                            let minutes = runtime / 600_000_000 // Convert ticks to minutes
                            Text("\(minutes)m")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                        }

                        if movie.hasMultipleVersions {
                            Text("\(movie.versions.count) versions")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Spacer()
                    }
                }
            }
            .padding()
            .background(.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
