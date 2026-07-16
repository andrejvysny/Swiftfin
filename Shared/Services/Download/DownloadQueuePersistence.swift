//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging

final class DownloadQueuePersistence {

    private let logger = Logger.swiftfin()
    private let queue = DispatchQueue(label: "downloadQueuePersistence", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var queueFileURL: URL {
        URL.downloads.appendingPathComponent(".active-queue.json")
    }

    private var resumeDataDirectory: URL {
        URL.downloads.appendingPathComponent(".resume-data")
    }

    // MARK: - Queue Persistence

    func save(_ records: [ActiveDownloadRecord]) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: URL.downloads,
                    withIntermediateDirectories: true
                )
                let data = try encoder.encode(records)
                try data.write(to: queueFileURL, options: .atomic)
            } catch {
                logger.error("Failed to save active queue: \(error.localizedDescription)")
            }
        }
    }

    func load() -> [ActiveDownloadRecord] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return [] }
            do {
                let data = try Data(contentsOf: queueFileURL)
                return try decoder.decode([ActiveDownloadRecord].self, from: data)
            } catch {
                logger.error("Failed to load active queue: \(error.localizedDescription)")
                return []
            }
        }
    }

    func update(id: UUID, block: (inout ActiveDownloadRecord) -> Void) {
        var records = load()
        if let index = records.firstIndex(where: { $0.id == id }) {
            block(&records[index])
            save(records)
        }
    }

    func remove(id: UUID) {
        var records = load()
        records.removeAll { $0.id == id }
        save(records)
    }

    func removeAll() {
        save([])
    }

    // MARK: - Resume Data Persistence

    func saveResumeData(_ data: Data, for taskID: UUID) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: resumeDataDirectory,
                    withIntermediateDirectories: true
                )
                let fileURL = resumeDataDirectory.appendingPathComponent("\(taskID.uuidString).bin")
                try data.write(to: fileURL, options: .atomic)
            } catch {
                logger.error("Failed to save resume data for \(taskID): \(error.localizedDescription)")
            }
        }
    }

    func loadResumeData(for taskID: UUID) -> Data? {
        queue.sync {
            let fileURL = resumeDataDirectory.appendingPathComponent("\(taskID.uuidString).bin")
            return try? Data(contentsOf: fileURL)
        }
    }

    func deleteResumeData(for taskID: UUID) {
        queue.sync {
            let fileURL = resumeDataDirectory.appendingPathComponent("\(taskID.uuidString).bin")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
