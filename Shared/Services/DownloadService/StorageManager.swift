import Foundation

/// Manages storage locations and disk quota.
final class StorageManager {
    private let root: URL
    private let quotaBytes: Int64

    init(root: URL = .downloads, quotaBytes: Int64 = Int64(1_000_000_000)) {
        self.root = root
        self.quotaBytes = quotaBytes
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func destination(for url: URL) -> URL {
        root.appendingPathComponent(url.lastPathComponent)
    }

    func hasSpace(for bytes: Int64) -> Bool {
        let free = FileManager.default.availableStorage
        return free > bytes && free > 5_000_000 && usedSpace() + bytes < quotaBytes
    }

    func move(temp: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
    }

    func usedSpace() -> Int64 {
        return Int64((try? root.directoryTotalAllocatedSize(includingSubfolders: true)) ?? 0)
    }
}
