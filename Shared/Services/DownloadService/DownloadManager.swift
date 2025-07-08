import Foundation
import os.log

/// Concrete implementation of `DownloadManagerProtocol` used across the app.
final class DownloadManager: DownloadManagerProtocol {
    static let shared = DownloadManager()

    private let eventsStream: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    private let coordinator: TaskCoordinator

    init(maxConcurrent: Int = 3, storage: StorageManager = StorageManager()) {
        var cont: AsyncStream<DownloadEvent>.Continuation!
        self.eventsStream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
        self.coordinator = TaskCoordinator(maxConcurrent: maxConcurrent, storage: storage, continuation: cont)
    }

    var events: AsyncStream<DownloadEvent> { eventsStream }

    func enqueue(_ item: URL, priority: TaskPriority) async -> DownloadID {
        let id = DownloadID()
        let record = DownloadRecord(id: id, url: item, priority: priority)
        await coordinator.enqueue(record)
        return id
    }

    func pause(_ id: DownloadID) async {
        await coordinator.pause(id: id)
    }

    func resume(_ id: DownloadID) async {
        await coordinator.resume(id: id)
    }

    func cancel(_ id: DownloadID) async {
        await coordinator.cancel(id: id)
    }
}

import Factory

extension Container {
    var backgroundDownloadManager: Factory<DownloadManager> {
        self { DownloadManager() }.shared
    }
}
