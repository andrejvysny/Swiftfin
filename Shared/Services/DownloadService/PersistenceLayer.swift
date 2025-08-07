import Foundation
import CoreData
import os.log

/// Protocol for download persistence operations
public protocol PersistenceLayerProtocol: Sendable {
    func save(_ record: DownloadRecord) async throws
    func update(_ record: DownloadRecord) async throws
    func delete(id: DownloadID) async throws
    func fetchAll() async throws -> [DownloadRecord]
    func fetch(id: DownloadID) async throws -> DownloadRecord?
    func deleteAll() async throws
}

/// Core Data implementation of persistence layer
public actor PersistenceLayer: PersistenceLayerProtocol {
    private let logger = Logger(subsystem: "org.jellyfin.swiftfin", category: "PersistenceLayer")
    private let container: NSPersistentContainer
    
    public init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "DownloadModel")
        
        // Configure for in-memory store (testing)
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        
        // Load persistent stores
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Failed to load Core Data stack: \(error)")
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
    
    // MARK: - Public API
    
    public func save(_ record: DownloadRecord) async throws {
        let context = container.newBackgroundContext()
        
        try await context.perform {
            let entity = DownloadEntity(context: context)
            entity.id = record.id
            entity.url = record.url.absoluteString
            entity.state = record.state.rawValue
            entity.priority = Int16(record.priority.rawValue)
            entity.resumeData = record.resumeData
            entity.retryCount = Int16(record.retryCount)
            entity.createdAt = record.createdAt
            entity.expectedBytes = record.expectedBytes
            entity.downloadedBytes = record.downloadedBytes
            
            if let metadata = record.metadata {
                entity.metadataJSON = try? JSONEncoder().encode(metadata)
            }
            
            try context.save()
        }
        
        logger.debug("Saved download record: \(record.id)")
    }
    
    public func update(_ record: DownloadRecord) async throws {
        let context = container.newBackgroundContext()
        
        try await context.perform {
            let request = DownloadEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
            
            guard let entity = try context.fetch(request).first else {
                throw PersistenceError.notFound
            }
            
            entity.state = record.state.rawValue
            entity.resumeData = record.resumeData
            entity.retryCount = Int16(record.retryCount)
            entity.downloadedBytes = record.downloadedBytes
            
            try context.save()
        }
        
        logger.debug("Updated download record: \(record.id)")
    }
    
    public func delete(id: DownloadID) async throws {
        let context = container.newBackgroundContext()
        
        try await context.perform {
            let request = DownloadEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                try context.save()
            }
        }
        
        logger.debug("Deleted download record: \(id)")
    }
    
    public func fetchAll() async throws -> [DownloadRecord] {
        let context = container.newBackgroundContext()
        
        return try await context.perform {
            let request = DownloadEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            
            let entities = try context.fetch(request)
            return entities.compactMap { self.makeRecord(from: $0) }
        }
    }
    
    public func fetch(id: DownloadID) async throws -> DownloadRecord? {
        let context = container.newBackgroundContext()
        
        return try await context.perform {
            let request = DownloadEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            
            guard let entity = try context.fetch(request).first else { return nil }
            return self.makeRecord(from: entity)
        }
    }
    
    public func deleteAll() async throws {
        let context = container.newBackgroundContext()
        
        try await context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "DownloadEntity")
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            
            try context.execute(deleteRequest)
            try context.save()
        }
        
        logger.info("Deleted all download records")
    }
    
    // MARK: - Private Helpers
    
    private func makeRecord(from entity: DownloadEntity) -> DownloadRecord? {
        guard let id = entity.id,
              let urlString = entity.url,
              let url = URL(string: urlString),
              let stateString = entity.state,
              let state = DownloadState(rawValue: stateString) else {
            logger.warning("Invalid entity data, skipping")
            return nil
        }
        
        let priority = TaskPriority(rawValue: Int(entity.priority)) ?? .medium
        
        let record = DownloadRecord(
            id: id,
            url: url,
            state: state,
            priority: priority,
            resumeData: entity.resumeData,
            retryCount: Int(entity.retryCount),
            createdAt: entity.createdAt ?? Date(),
            expectedBytes: entity.expectedBytes,
            downloadedBytes: entity.downloadedBytes
        )
        
        if let metadataJSON = entity.metadataJSON {
            record.metadata = try? JSONDecoder().decode(DownloadMetadata.self, from: metadataJSON)
        }
        
        return record
    }
}

// MARK: - Core Data Model

@objc(DownloadEntity)
public class DownloadEntity: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var url: String?
    @NSManaged public var state: String?
    @NSManaged public var priority: Int16
    @NSManaged public var resumeData: Data?
    @NSManaged public var retryCount: Int16
    @NSManaged public var createdAt: Date?
    @NSManaged public var expectedBytes: Int64
    @NSManaged public var downloadedBytes: Int64
    @NSManaged public var metadataJSON: Data?
}

// MARK: - Errors

public enum PersistenceError: LocalizedError {
    case notFound
    case saveFailed
    
    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Download record not found"
        case .saveFailed:
            return "Failed to save download record"
        }
    }
} 