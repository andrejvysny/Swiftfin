import Foundation
import os.log
import Collections

/// Download record managed by the coordinator
public final class DownloadRecord: @unchecked Sendable {
    public let id: DownloadID
    public let url: URL
    public var state: DownloadState
    public let priority: TaskPriority
    public var resumeData: Data?
    public var retryCount: Int
    public let createdAt: Date
    public let expectedBytes: Int64
    public var downloadedBytes: Int64
    public var metadata: DownloadMetadata?
    
    // Runtime properties
    weak var task: URLSessionDownloadTask?
    var reservation: StorageReservation?
    var lastRetryDate: Date?
    
    public init(id: DownloadID = .init(),
                url: URL,
                state: DownloadState = .queued,
                priority: TaskPriority = .medium,
                resumeData: Data? = nil,
                retryCount: Int = 0,
                createdAt: Date = Date(),
                expectedBytes: Int64 = 0,
                downloadedBytes: Int64 = 0) {
        self.id = id
        self.url = url
        self.state = state
        self.priority = priority
        self.resumeData = resumeData
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.expectedBytes = expectedBytes
        self.downloadedBytes = downloadedBytes
    }
}

/// Actor responsible for coordinating download tasks
public actor TaskCoordinator {
    private let logger = Logger(subsystem: "org.jellyfin.swiftfin", category: "TaskCoordinator")
    
    // Dependencies
    private let networkService: NetworkServiceProtocol
    private let storage: StorageManager
    private let persistence: PersistenceLayerProtocol
    private let eventContinuation: AsyncStream<DownloadEvent>.Continuation
    
    // Configuration
    private let maxConcurrent: Int
    private let maxRetries: Int
    
    // State management
    private var active: [DownloadID: DownloadRecord] = [:]
    private var queue: Heap<DownloadRecord>
    
    // Progress throttling
    private var lastProgressUpdate: [DownloadID: (progress: Double, date: Date)] = [:]
    private let progressThrottleInterval: TimeInterval = 0.5
    private let progressThrottleDelta: Double = 0.01
    
    public init(networkService: NetworkServiceProtocol,
                storage: StorageManager,
                persistence: PersistenceLayerProtocol,
                maxConcurrent: Int = 3,
                maxRetries: Int = 3,
                continuation: AsyncStream<DownloadEvent>.Continuation) {
        self.networkService = networkService
        self.storage = storage
        self.persistence = persistence
        self.maxConcurrent = maxConcurrent
        self.maxRetries = maxRetries
        self.eventContinuation = continuation
        
        // Initialize priority queue
        self.queue = Heap { lhs, rhs in
            // Higher priority first, then older tasks
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
    
    // MARK: - Public API
    
    public func initialize() async {
        // Restore persisted downloads
        do {
            let persisted = try await persistence.fetchAll()
            for record in persisted {
                switch record.state {
                case .downloading:
                    // Convert active downloads back to queued
                    record.state = .queued
                    queue.insert(record)
                case .queued, .paused:
                    queue.insert(record)
                case .completed, .failed:
                    // Skip completed/failed
                    break
                }
            }
            
            logger.info("Restored \(queue.count) downloads from persistence")
            
            // Start processing
            await tick()
        } catch {
            logger.error("Failed to restore downloads: \(error)")
        }
    }
    
    public func enqueue(_ record: DownloadRecord) async {
        // Check if already exists
        if active[record.id] != nil || queue.contains(where: { $0.id == record.id }) {
            logger.warning("Download already exists: \(record.id)")
            return
        }
        
        // Add to queue
        queue.insert(record)
        
        // Persist
        do {
            try await persistence.save(record)
        } catch {
            logger.error("Failed to persist download: \(error)")
        }
        
        // Notify
        eventContinuation.yield(.queued(record.id))
        
        // Schedule background task if needed
        await scheduleBackgroundTaskIfNeeded()
        
        // Process queue
        await tick()
    }
    
    public func pause(id: DownloadID) async {
        guard let record = active[id] else {
            logger.warning("Cannot pause - download not active: \(id)")
            return
        }
        
        // Cancel with resume data
        record.task?.cancel { [weak record] resumeData in
            Task { [weak self, weak record] in
                guard let self, let record else { return }
                
                record.resumeData = resumeData
                record.state = .paused
                
                // Update persistence
                try? await self.persistence.update(record)
                
                // Move back to queue
                await self.moveToQueue(record)
                
                // Notify
                self.eventContinuation.yield(.paused(id))
            }
        }
    }
    
    public func resume(id: DownloadID) async {
        // Find in queue
        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            logger.warning("Cannot resume - download not found: \(id)")
            return
        }
        
        let record = queue.remove(at: index)
        record.state = .queued
        queue.insert(record)
        
        // Update persistence
        try? await persistence.update(record)
        
        // Notify
        eventContinuation.yield(.resumed(id))
        
        // Process queue
        await tick()
    }
    
    public func cancel(id: DownloadID) async {
        // Check active downloads
        if let record = active[id] {
            record.task?.cancel()
            active.removeValue(forKey: id)
            record.reservation = nil
        }
        
        // Check queue
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
        }
        
        // Remove from persistence
        try? await persistence.delete(id: id)
        
        // Notify
        eventContinuation.yield(.cancelled(id))
        
        // Process queue
        await tick()
    }
    
    // MARK: - NetworkLayerDelegate
    
    public func updateProgress(for id: DownloadID, progress: Double) {
        // Throttle progress updates
        let now = Date()
        if let last = lastProgressUpdate[id] {
            guard abs(progress - last.progress) > progressThrottleDelta ||
                  now.timeIntervalSince(last.date) > progressThrottleInterval else { return }
        }
        
        lastProgressUpdate[id] = (progress, now)
        
        // Update record
        if let record = active[id] {
            record.downloadedBytes = Int64(Double(record.expectedBytes) * progress)
        }
        
        // Notify
        eventContinuation.yield(.progress(id, progress))
    }
    
    public func completed(id: DownloadID, location: URL) async {
        guard let record = active[id] else {
            logger.warning("Completed download not found: \(id)")
            return
        }
        
        // Validate download if metadata available
        if let expectedSize = record.metadata?.expectedSize,
           let actualSize = storage.fileSize(at: location),
           actualSize != expectedSize {
            logger.error("Size mismatch for \(id): expected \(expectedSize), got \(actualSize)")
            await handleFailure(record: record, error: DownloadError.integrityCheckFailed)
            return
        }
        
        // Move to final destination
        do {
            let destination = storage.destination(for: record.url, filename: record.metadata?.filename)
            try storage.moveToDestination(from: location, to: destination)
            
            // Update state
            record.state = .completed
            active.removeValue(forKey: id)
            record.reservation = nil
            
            // Update persistence
            try? await persistence.update(record)
            
            // Clean progress tracking
            lastProgressUpdate.removeValue(forKey: id)
            
            // Notify
            eventContinuation.yield(.completed(id, destination))
            
            logger.info("Download completed: \(id)")
        } catch {
            logger.error("Failed to move download: \(error)")
            await handleFailure(record: record, error: DownloadError.diskFull)
        }
        
        // Process next
        await tick()
    }
    
    public func failed(id: DownloadID, error: Error) async {
        guard let record = active[id] else {
            logger.warning("Failed download not found: \(id)")
            return
        }
        
        // Extract resume data if available
        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            record.resumeData = resumeData
        }
        
        await handleFailure(record: record, error: DownloadError(from: error))
    }
    
    // MARK: - Private Methods
    
    private func tick() async {
        // Process queue while we have capacity
        while active.count < maxConcurrent, let record = queue.popMax() {
            await start(record)
        }
    }
    
    private func start(_ record: DownloadRecord) async {
        // Reserve storage space
        guard let reservation = storage.reserveSpace(bytes: record.expectedBytes) else {
            logger.warning("Insufficient space for download: \(record.id)")
            eventContinuation.yield(.failed(record.id, .diskFull))
            return
        }
        
        record.reservation = reservation
        
        // Create task
        let task: URLSessionDownloadTask
        if let resumeData = record.resumeData {
            task = networkService.createDownloadTask(withResumeData: resumeData)
            task.taskDescription = record.id.uuidString
        } else {
            task = networkService.createDownloadTask(with: record.url, identifier: record.id)
        }
        
        // Update state
        record.task = task
        record.state = .downloading
        active[record.id] = record
        
        // Update persistence
        try? await persistence.update(record)
        
        // Start download
        task.resume()
        
        // Notify
        eventContinuation.yield(.started(record.id))
        
        logger.debug("Started download: \(record.id)")
    }
    
    private func handleFailure(record: DownloadRecord, error: DownloadError) async {
        active.removeValue(forKey: record.id)
        record.reservation = nil
        record.task = nil
        
        // Check if we should retry
        let shouldRetry = record.retryCount < maxRetries && 
                         error != .cancelled && 
                         error != .quotaExceeded
        
        if shouldRetry {
            record.retryCount += 1
            record.state = .queued
            
            // Calculate exponential backoff
            let delay = pow(2.0, Double(record.retryCount))
            record.lastRetryDate = Date().addingTimeInterval(delay)
            
            logger.info("Retrying download \(record.id) (attempt \(record.retryCount)) after \(delay)s")
            
            // Update persistence
            try? await persistence.update(record)
            
            // Schedule retry
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self.retryDownload(record)
            }
        } else {
            // Final failure
            record.state = .failed
            
            // Update persistence
            try? await persistence.update(record)
            
            // Notify
            eventContinuation.yield(.failed(record.id, error))
            
            logger.error("Download failed permanently: \(record.id) - \(error)")
        }
        
        // Process next
        await tick()
    }
    
    private func retryDownload(_ record: DownloadRecord) async {
        // Re-add to queue if not cancelled
        if record.state == .queued {
            queue.insert(record)
            await tick()
        }
    }
    
    private func moveToQueue(_ record: DownloadRecord) async {
        active.removeValue(forKey: record.id)
        record.reservation = nil
        record.task = nil
        queue.insert(record)
        
        // Process next
        await tick()
    }
    
    private func scheduleBackgroundTaskIfNeeded() async {
        // This would integrate with BGTaskScheduler
        // Implementation depends on app delegate setup
    }
}

// MARK: - NetworkLayerDelegate Conformance

extension TaskCoordinator: NetworkLayerDelegate {
    public func networkLayer(_ layer: NetworkLayer, didUpdateProgress progress: Double, for id: DownloadID) async {
        await updateProgress(for: id, progress: progress)
    }
    
    public func networkLayer(_ layer: NetworkLayer, didCompleteDownload id: DownloadID, at location: URL) async {
        await completed(id: id, location: location)
    }
    
    public func networkLayer(_ layer: NetworkLayer, didFailDownload id: DownloadID, with error: Error) async {
        await failed(id: id, error: error)
    }
}
