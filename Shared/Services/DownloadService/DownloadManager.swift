import Foundation
import Factory
import BackgroundTasks
import os.log

/// Concrete implementation of `DownloadManagerProtocol` used across the app
public final class DownloadManager: DownloadManagerProtocol {
    private let logger = Logger(subsystem: "org.jellyfin.swiftfin", category: "DownloadManager")
    
    // Event stream
    private let eventsStream: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    
    // Dependencies
    private let networkLayer: NetworkLayer
    private let coordinator: TaskCoordinator
    private let storage: StorageManager
    private let persistence: PersistenceLayerProtocol
    
    // Configuration
    private let backgroundTaskIdentifier = "org.jellyfin.swiftfin.download.process"
    
    public init(maxConcurrent: Int = 3,
                storage: StorageManager? = nil,
                persistence: PersistenceLayerProtocol? = nil,
                networkService: NetworkServiceProtocol? = nil) {
        
        // Initialize dependencies
        self.storage = storage ?? StorageManager()
        self.persistence = persistence ?? PersistenceLayer()
        self.networkLayer = networkService as? NetworkLayer ?? NetworkLayer()
        
        // Create event stream
        var cont: AsyncStream<DownloadEvent>.Continuation!
        self.eventsStream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
        
        // Create coordinator
        self.coordinator = TaskCoordinator(
            networkService: self.networkLayer,
            storage: self.storage,
            persistence: self.persistence,
            maxConcurrent: maxConcurrent,
            continuation: cont
        )
        
        // Set up network layer delegate
        self.networkLayer.delegate = coordinator
        
        // Initialize on first access
        Task {
            await self.initialize()
        }
    }
    
    // MARK: - DownloadManagerProtocol
    
    public var events: AsyncStream<DownloadEvent> { 
        eventsStream 
    }
    
    @discardableResult
    public func enqueue(_ url: URL, 
                       priority: TaskPriority = .medium,
                       metadata: DownloadMetadata? = nil) async -> DownloadID {
        let id = DownloadID()
        
        // Estimate size if not provided
        let expectedBytes = metadata?.expectedSize ?? estimateDownloadSize(for: url)
        
        let record = DownloadRecord(
            id: id,
            url: url,
            priority: priority,
            expectedBytes: expectedBytes
        )
        record.metadata = metadata
        
        await coordinator.enqueue(record)
        
        // Schedule background task
        scheduleBackgroundProcessing()
        
        logger.info("Enqueued download: \(id) for \(url)")
        
        return id
    }
    
    public func pause(_ id: DownloadID) async {
        await coordinator.pause(id: id)
    }
    
    public func resume(_ id: DownloadID) async {
        await coordinator.resume(id: id)
    }
    
    public func cancel(_ id: DownloadID) async {
        await coordinator.cancel(id: id)
    }
    
    // MARK: - Additional API
    
    /// Get current status of all downloads
    public func getAllDownloads() async -> [DownloadRecord] {
        do {
            return try await persistence.fetchAll()
        } catch {
            logger.error("Failed to fetch downloads: \(error)")
            return []
        }
    }
    
    /// Get status of a specific download
    public func getDownload(_ id: DownloadID) async -> DownloadRecord? {
        do {
            return try await persistence.fetch(id: id)
        } catch {
            logger.error("Failed to fetch download \(id): \(error)")
            return nil
        }
    }
    
    /// Clean up orphaned files
    public func cleanupOrphans() async {
        do {
            let records = try await persistence.fetchAll()
            let validFiles = Set(records.compactMap { record in
                storage.destination(for: record.url, filename: record.metadata?.filename)
            })
            
            try await storage.cleanupOrphans(validFiles: validFiles)
        } catch {
            logger.error("Cleanup failed: \(error)")
        }
    }
    
    /// Get storage usage statistics
    public func getStorageStats() -> (used: Int64, quota: Int64) {
        let used = storage.calculateUsedSpace()
        return (used, 5_000_000_000) // 5GB default quota
    }
    
    // MARK: - Background Processing
    
    /// Handle background URLSession events
    public func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        networkLayer.backgroundCompletionHandler = completionHandler
    }
    
    /// Process downloads in background
    public func processBackgroundDownloads() async {
        logger.info("Processing background downloads")
        
        // Coordinator will automatically process queue
        await coordinator.initialize()
        
        // Clean up old downloads
        await cleanupOrphans()
        
        // Schedule next task if needed
        let downloads = await getAllDownloads()
        if downloads.contains(where: { $0.state == .queued }) {
            scheduleBackgroundProcessing()
        }
    }
    
    // MARK: - Private Methods
    
    private func initialize() async {
        // Register background task
        registerBackgroundTask()
        
        // Initialize coordinator with persisted downloads
        await coordinator.initialize()
        
        logger.info("DownloadManager initialized")
    }
    
    private func estimateDownloadSize(for url: URL) -> Int64 {
        // Default estimate - could be improved with HEAD request
        return 100_000_000 // 100MB default
    }
    
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            
            Task {
                await self.processBackgroundDownloads()
                task.setTaskCompleted(success: true)
            }
            
            // Schedule next execution
            self.scheduleBackgroundProcessing()
        }
    }
    
    private func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // 1 minute
        
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background processing task")
        } catch {
            logger.error("Failed to schedule background task: \(error)")
        }
    }
}

// MARK: - Factory Integration

extension Container {
    public var downloadManager: Factory<DownloadManager> {
        self { DownloadManager() }.shared
    }
}
