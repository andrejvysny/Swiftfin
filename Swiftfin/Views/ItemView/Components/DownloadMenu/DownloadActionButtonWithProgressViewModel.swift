//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import Foundation
import JellyfinAPI

// MARK: - DownloadTaskState Enum for UI

enum DownloadTaskState {
    case ready
    case downloading
    case paused
    case queued
    case error
    case partiallyCompleted
    case completed
}

// MARK: - ViewModel

@MainActor
final class DownloadActionButtonWithProgressViewModel: ObservableObject {

    // MARK: - Published State

    @Published
    var state: DownloadTaskState = .ready
    @Published
    var progress: Double = 0.0

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var taskStateObserver: AnyCancellable?
    private var allTaskStateObservers: [UUID: AnyCancellable] = [:]
    private var downloadTask: DownloadTask?
    private var taskID: UUID?
    private var allItemTasks: [DownloadTask] = []

    private let shouldAutoStart: Bool
    private let item: BaseItemDto?
    private let mediaSourceId: String?

    // MARK: - Dependencies

    @Injected(\.downloadManager)
    private var downloadManager: DownloadManager

    // MARK: - Initializers

    init(downloadTask: DownloadTask) {
        self.downloadTask = downloadTask
        self.item = downloadTask.item
        self.mediaSourceId = downloadTask.mediaSourceId
        self.taskID = downloadTask.taskID
        self.shouldAutoStart = true

        setupStateObservation()
    }

    init(item: BaseItemDto, mediaSourceId: String? = nil, shouldAutoStart: Bool = true) {
        self.item = item
        self.mediaSourceId = mediaSourceId
        self.shouldAutoStart = shouldAutoStart
        self.downloadTask = nil
        self.taskID = nil

        setupStateObservation()
    }

    init(state: DownloadTaskState = .ready, progress: Double = 0.0) {
        self.item = nil
        self.mediaSourceId = nil
        self.shouldAutoStart = true
        self.state = state
        self.progress = progress
    }

    deinit {
        taskStateObserver?.cancel()
        allTaskStateObservers.values.forEach { $0.cancel() }
        allTaskStateObservers.removeAll()
    }

    // MARK: - Download Actions

    func start() {
        guard let item, let itemId = item.id else { return }
        guard !downloadManager.isItemVersionDownloaded(for: item, mediaSourceId: mediaSourceId) else { return }

        taskID = downloadManager.startDownload(
            itemId: itemId,
            mediaSourceId: mediaSourceId
        )
    }

    func pause() {
        guard let taskID else { return }
        downloadManager.pauseDownload(taskID: taskID)
    }

    func resume() {
        guard let taskID else { return }
        downloadManager.resumeDownload(taskID: taskID)
    }

    func cancel() {
        guard let taskID else { return }
        downloadManager.cancelDownload(taskID: taskID, removeFile: true)
    }

    func retryDownload() {
        guard let taskID else { return }

        downloadManager.cancelDownload(taskID: taskID, removeFile: true)
        self.taskID = nil
        self.downloadTask = nil
        start()
    }

    func refreshDownloadState() {
        recomputeState()
    }

    // MARK: - State Management

    private var usesSpecificVersionState: Bool {
        shouldAutoStart || mediaSourceId != nil
    }

    private func setupStateObservation() {
        seedInitialObservers()
        recomputeState()

        downloadManager.$downloads
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] downloads in
                self?.handleDownloadsUpdate(downloads)
            }
            .store(in: &cancellables)

        downloadManager.$storageMutationVersion
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.recomputeState()
            }
            .store(in: &cancellables)
    }

    private func seedInitialObservers() {
        guard let item else { return }

        if usesSpecificVersionState {
            let existingTask = currentTask(for: item)
            downloadTask = existingTask
            taskID = existingTask?.taskID

            if let taskID = existingTask?.taskID {
                observeTaskState(taskID: taskID)
            }
        } else {
            replaceAllItemTasks(with: currentTasks(for: item))
        }
    }

    private func observeTaskState(taskID: UUID) {
        taskStateObserver?.cancel()
        taskStateObserver = downloadManager.$taskStates
            .compactMap { $0[taskID] }
            .removeDuplicates(by: statesAreEquivalent(_:_:))
            .sink { [weak self] _ in
                self?.recomputeState()
            }
    }

    private func observeAllVersionsTaskState(taskID: UUID) {
        let observer = downloadManager.$taskStates
            .compactMap { $0[taskID] }
            .removeDuplicates(by: statesAreEquivalent(_:_:))
            .sink { [weak self] _ in
                self?.recomputeState()
            }

        allTaskStateObservers[taskID] = observer
    }

    private func handleDownloadsUpdate(_ downloads: [DownloadTask]) {
        guard let item else { return }

        if usesSpecificVersionState {
            let currentTask = currentTask(for: item, in: downloads)

            if downloadTask?.taskID != currentTask?.taskID {
                downloadTask = currentTask
                taskID = currentTask?.taskID
                taskStateObserver?.cancel()
                taskStateObserver = nil

                if let taskID = currentTask?.taskID {
                    observeTaskState(taskID: taskID)
                }
            }
        } else {
            replaceAllItemTasks(with: currentTasks(for: item, in: downloads))
        }

        recomputeState()
    }

    private func replaceAllItemTasks(with tasks: [DownloadTask]) {
        let nextTaskIDs = Set(tasks.map(\.taskID))
        let currentTaskIDs = Set(allItemTasks.map(\.taskID))
        guard nextTaskIDs != currentTaskIDs else { return }

        allItemTasks = tasks
        allTaskStateObservers.values.forEach { $0.cancel() }
        allTaskStateObservers.removeAll()

        for task in tasks {
            observeAllVersionsTaskState(taskID: task.taskID)
        }
    }

    private func recomputeState() {
        guard let item else { return }

        if usesSpecificVersionState {
            recomputeSpecificVersionState(for: item)
        } else {
            recomputeAggregateState(for: item)
        }
    }

    private func recomputeSpecificVersionState(for item: BaseItemDto) {
        let currentTask = currentTask(for: item)
        downloadTask = currentTask
        taskID = currentTask?.taskID

        if let currentTask {
            apply(taskState: downloadManager.getTaskState(taskID: currentTask.taskID))
            return
        }

        if downloadManager.isItemVersionDownloaded(for: item, mediaSourceId: mediaSourceId) {
            state = .completed
            progress = 1.0
        } else {
            state = .ready
            progress = 0.0
        }
    }

    private func recomputeAggregateState(for item: BaseItemDto) {
        replaceAllItemTasks(with: currentTasks(for: item))

        let totalAvailableVersions = max(item.mediaSources?.count ?? 1, 1)
        let completedVersionCount = min(downloadManager.downloadedVersions(for: item).count, totalAvailableVersions)
        let taskStates = allItemTasks.map { downloadManager.getTaskState(taskID: $0.taskID) }

        if taskStates.isEmpty {
            applyCompletedState(completedVersionCount: completedVersionCount, totalAvailableVersions: totalAvailableVersions)
            return
        }

        let downloadingProgress = taskStates.compactMap { taskState -> Double? in
            if case let .downloading(progress) = taskState {
                return progress
            }
            return nil
        }

        let hasError = taskStates.contains { if case .error = $0 { true } else { false } }
        let hasPaused = taskStates.contains { if case .paused = $0 { true } else { false } }
        let hasQueued = taskStates.contains { if case .queued = $0 { true } else { false } }
        let hasReady = taskStates.contains { if case .ready = $0 { true } else { false } }

        let aggregateProgress = min(
            1.0,
            (Double(completedVersionCount) + downloadingProgress.reduce(0, +)) / Double(totalAvailableVersions)
        )

        if !downloadingProgress.isEmpty {
            state = .downloading
            progress = aggregateProgress
        } else if hasError {
            state = .error
            progress = aggregateProgress
        } else if hasPaused {
            state = .paused
            progress = aggregateProgress
        } else if hasQueued || hasReady {
            state = .queued
            progress = aggregateProgress
        } else {
            applyCompletedState(completedVersionCount: completedVersionCount, totalAvailableVersions: totalAvailableVersions)
        }
    }

    private func apply(taskState: DownloadTask.State) {
        switch taskState {
        case .ready:
            state = .ready
            progress = 0.0
        case let .downloading(progressValue):
            state = .downloading
            progress = progressValue
        case .paused:
            state = .paused
        case .queued:
            state = .queued
            progress = 0.0
        case .complete:
            state = .completed
            progress = 1.0
        case .cancelled:
            state = .ready
            progress = 0.0
        case .error:
            state = .error
        }
    }

    private func applyCompletedState(completedVersionCount: Int, totalAvailableVersions: Int) {
        if completedVersionCount == totalAvailableVersions {
            state = .completed
            progress = 1.0
        } else if completedVersionCount > 0 {
            state = .partiallyCompleted
            progress = Double(completedVersionCount) / Double(totalAvailableVersions)
        } else {
            state = .ready
            progress = 0.0
        }
    }

    private func statesAreEquivalent(_ lhs: DownloadTask.State, _ rhs: DownloadTask.State) -> Bool {
        switch (lhs, rhs) {
        case let (.downloading(lhsProgress), .downloading(rhsProgress)):
            abs(lhsProgress - rhsProgress) < 0.05
        case (.ready, .ready), (.paused, .paused), (.complete, .complete), (.cancelled, .cancelled), (.queued, .queued):
            true
        case (.error, .error):
            true
        default:
            false
        }
    }

    private func currentTask(for item: BaseItemDto, in downloads: [DownloadTask]? = nil) -> DownloadTask? {
        let downloads = downloads ?? downloadManager.downloads
        return downloads.first { task in
            task.item.id == item.id
                && task.mediaSourceId == mediaSourceId
                && !isTerminalTask(task)
        }
    }

    private func currentTasks(for item: BaseItemDto, in downloads: [DownloadTask]? = nil) -> [DownloadTask] {
        let downloads = downloads ?? downloadManager.downloads
        return downloads.filter {
            $0.item.id == item.id && !isTerminalTask($0)
        }
    }

    private func isTerminalTask(_ task: DownloadTask) -> Bool {
        switch downloadManager.getTaskState(taskID: task.taskID) {
        case .complete, .cancelled:
            true
        default:
            false
        }
    }
}
