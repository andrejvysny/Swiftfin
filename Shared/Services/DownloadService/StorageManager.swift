import Foundation
import os.log

/// Token representing a storage reservation that releases space when deallocated
public final class StorageReservation {
    private let bytes: Int64
    private let onRelease: () -> Void
    
    fileprivate init(bytes: Int64, onRelease: @escaping () -> Void) {
        self.bytes = bytes
        self.onRelease = onRelease
    }
    
    deinit {
        onRelease()
    }
}

/// Manages storage locations, disk quota, and cleanup operations
public final class StorageManager {
    private let logger = Logger(subsystem: "org.jellyfin.swiftfin", category: "StorageManager")
    
    private let root: URL
    private let quotaBytes: Int64
    private let minFreeSpace: Int64
    
    /// Thread-safe reserved bytes tracking
    private let reservationQueue = DispatchQueue(label: "org.jellyfin.storage.reservation")
    private var _reservedBytes: Int64 = 0
    
    public init(root: URL = .downloads, 
                quotaBytes: Int64 = 5_000_000_000, // 5GB default quota
                minFreeSpace: Int64 = 100_000_000) { // 100MB buffer
        self.root = root
        self.quotaBytes = quotaBytes
        self.minFreeSpace = minFreeSpace
        
        // Create root directory if needed
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try markAsExcludedFromBackup(url: root)
        } catch {
            logger.error("Failed to create download directory: \(error)")
        }
    }
    
    // MARK: - Public API
    
    /// Generate destination URL for a download
    public func destination(for url: URL, filename: String? = nil) -> URL {
        let name = filename ?? url.lastPathComponent
        return root.appendingPathComponent(sanitizeFilename(name))
    }
    
    /// Reserve storage space for a download
    public func reserveSpace(bytes: Int64) -> StorageReservation? {
        return reservationQueue.sync {
            guard hasSpaceAvailable(for: bytes + _reservedBytes) else {
                logger.warning("Insufficient space to reserve \(bytes) bytes")
                return nil
            }
            
            _reservedBytes += bytes
            logger.debug("Reserved \(bytes) bytes, total reserved: \(_reservedBytes)")
            
            return StorageReservation(bytes: bytes) { [weak self] in
                self?.releaseReservation(bytes: bytes)
            }
        }
    }
    
    /// Move downloaded file to final destination
    public func moveToDestination(from tempURL: URL, to destination: URL) throws {
        // Create parent directory if needed
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        
        // Move file
        try FileManager.default.moveItem(at: tempURL, to: destination)
        
        // Mark as excluded from backup
        try markAsExcludedFromBackup(url: destination)
        
        logger.debug("Moved download to: \(destination.path)")
    }
    
    /// Check if file exists at destination
    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
    
    /// Get file size
    public func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
    
    /// Clean up orphaned files (files without corresponding records)
    public func cleanupOrphans(validFiles: Set<URL>) async throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        
        var deletedCount = 0
        var reclaimedBytes: Int64 = 0
        
        for fileURL in contents {
            guard !validFiles.contains(fileURL) else { continue }
            
            if let size = fileSize(at: fileURL) {
                reclaimedBytes += size
            }
            
            do {
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
                logger.debug("Deleted orphan: \(fileURL.lastPathComponent)")
            } catch {
                logger.error("Failed to delete orphan: \(error)")
            }
        }
        
        if deletedCount > 0 {
            logger.info("Cleaned up \(deletedCount) orphans, reclaimed \(reclaimedBytes) bytes")
        }
    }
    
    /// Calculate total used space
    public func calculateUsedSpace() -> Int64 {
        do {
            return try root.directoryTotalAllocatedSize(includingSubfolders: true)
        } catch {
            logger.error("Failed to calculate used space: \(error)")
            return 0
        }
    }
    
    // MARK: - Private Methods
    
    private func releaseReservation(bytes: Int64) {
        reservationQueue.sync {
            _reservedBytes -= bytes
            logger.debug("Released \(bytes) bytes, total reserved: \(_reservedBytes)")
        }
    }
    
    private func hasSpaceAvailable(for bytes: Int64) -> Bool {
        // Check system free space
        guard let freeSpace = getAvailableSpace() else { return false }
        guard freeSpace > bytes + minFreeSpace else { return false }
        
        // Check quota
        let currentUsage = calculateUsedSpace()
        guard currentUsage + bytes <= quotaBytes else { return false }
        
        return true
    }
    
    private func getAvailableSpace() -> Int64? {
        do {
            let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage.map(Int64.init)
        } catch {
            logger.error("Failed to get available space: \(error)")
            return nil
        }
    }
    
    private func markAsExcludedFromBackup(url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try url.setResourceValues(resourceValues)
    }
    
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove invalid characters for filesystem
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return filename.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
}

// MARK: - URL Extension

extension URL {
    /// Calculate total size of directory including subfolders
    func directoryTotalAllocatedSize(includingSubfolders: Bool = true) throws -> Int64 {
        guard hasDirectoryPath else { return 0 }
        
        let allocatedSizeKey: URLResourceKey = .totalFileAllocatedSizeKey
        let directoryEnumerator = FileManager.default.enumerator(
            at: self,
            includingPropertiesForKeys: [allocatedSizeKey],
            options: includingSubfolders ? [] : [.skipsSubdirectoryDescendants]
        )
        
        guard let enumerator = directoryEnumerator else { return 0 }
        
        var totalSize: Int64 = 0
        
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [allocatedSizeKey])
            if let size = values.totalFileAllocatedSize {
                totalSize += Int64(size)
            }
        }
        
        return totalSize
    }
}
