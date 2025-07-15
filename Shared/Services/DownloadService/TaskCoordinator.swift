import Foundation

/// Actor responsible for coordinating download tasks and applying policies.
actor TaskCoordinator {
    static var shared: TaskCoordinator?

    private var active: [DownloadID: DownloadRecord] = [:]
    private var queue: [DownloadRecord] = []
    private let maxConcurrent: Int
    private let storage: StorageManager
    private let eventContinuation: AsyncStream<DownloadEvent>.Continuation

    init(maxConcurrent: Int, storage: StorageManager, continuation: AsyncStream<DownloadEvent>.Continuation) {
        self.maxConcurrent = maxConcurrent
        self.storage = storage
        self.eventContinuation = continuation
        TaskCoordinator.shared = self
    }

    func enqueue(_ record: DownloadRecord) {
        queue.append(record)
        queue.sort { $0.priority.rawValue > $1.priority.rawValue }
        tick()
    }

    func pause(id: DownloadID) {
        guard let record = active[id] else { return }
        record.task?.cancel(byProducingResumeData: { data in
            record.resumeData = data
            record.state = .paused
            self.active.removeValue(forKey: id)
            self.queue.insert(record, at: 0)
        })
    }

    func resume(id: DownloadID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue[index].state = .queued
        }
        tick()
    }

    func cancel(id: DownloadID) {
        if let record = active[id] {
            record.task?.cancel()
            active.removeValue(forKey: id)
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
        }
        eventContinuation.yield(.failed(id, .cancelled))
        tick()
    }

    func updateProgress(for id: DownloadID, progress: Double) {
        eventContinuation.yield(.progress(id, progress))
    }

    func completed(id: DownloadID, location: URL) async {
        guard let record = active[id] else { return }
        do {
            let dest = storage.destination(for: record.url)
            try storage.move(temp: location, to: dest)
            eventContinuation.yield(.completed(id, dest))
            active.removeValue(forKey: id)
            tick()
        } catch {
            eventContinuation.yield(.failed(id, .diskFull))
        }
    }

    func failed(id: DownloadID, error: Error) {
        active.removeValue(forKey: id)
        eventContinuation.yield(.failed(id, .network))
        tick()
    }

    private func tick() {
        guard active.count < maxConcurrent else { return }
        guard !queue.isEmpty else { return }
        let record = queue.removeFirst()
        start(record)
    }

    private func start(_ record: DownloadRecord) {
        guard storage.hasSpace(for: record.expectedBytes) else {
            eventContinuation.yield(.failed(record.id, .diskFull))
            return
        }
        let task: URLSessionDownloadTask
        if let resume = record.resumeData {
            task = NetworkLayer.shared.session.downloadTask(withResumeData: resume)
        } else {
            task = NetworkLayer.shared.createTask(for: record.url, identifier: record.id)
        }
        record.task = task
        record.state = .downloading
        active[record.id] = record
        task.resume()
        eventContinuation.yield(.started(record.id))
    }
}

/// Simple record describing a task managed by the coordinator.
final class DownloadRecord {
    let id: DownloadID
    let url: URL
    var state: State = .queued
    var resumeData: Data?
    weak var task: URLSessionDownloadTask?
    let expectedBytes: Int64
    let priority: TaskPriority

    enum State { case queued, downloading, paused }

    init(id: DownloadID = .init(), url: URL, expectedBytes: Int64 = 0, priority: TaskPriority) {
        self.id = id
        self.url = url
        self.expectedBytes = expectedBytes
        self.priority = priority
    }
}
