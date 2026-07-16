//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging

final class DownloadSessionManager: NSObject, DownloadSessionManaging {

    private let logger = Logger.swiftfin()

    // Background URLSession infrastructure
    private var backgroundSession: URLSession!
    private let sessionQueue = DispatchQueue(label: "downloadManager.session", qos: .utility)
    private static let backgroundSessionIdentifier = "com.jellyfin.swiftfin.background-downloads"

    // Mapping between URLSessionDownloadTask identifier and DownloadJob
    private var activeJobs: [Int: DownloadJob] = [:]

    // Background session completion handler (set by AppDelegate)
    var backgroundCompletionHandler: (() -> Void)?

    // Delegate for session events
    weak var delegate: DownloadSessionDelegate?

    override init() {
        super.init()
        setupBackgroundSession()
    }

    // MARK: - Public Interface

    @discardableResult
    func start(url: URL, taskID: UUID, jobType: DownloadJobType) async throws -> Int {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpShouldHandleCookies = true
        urlRequest.httpShouldUsePipelining = true
        let urlDownloadTask = backgroundSession.downloadTask(with: urlRequest)

        let downloadJob = DownloadJob(
            type: jobType,
            taskID: taskID,
            url: url,
            destinationPath: ""
        )

        activeJobs[urlDownloadTask.taskIdentifier] = downloadJob

        urlDownloadTask.resume()

        func redacted(_ url: URL) -> String {
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            if let idx = comps.queryItems?.firstIndex(where: { $0.name.lowercased() == "api_key" }) {
                comps.queryItems?[idx].value = "REDACTED"
            }
            return comps.string ?? url.absoluteString
        }

        logger.trace("Started \(jobType) download: taskId=\(urlDownloadTask.taskIdentifier), url=\(redacted(url))")
        return urlDownloadTask.taskIdentifier
    }

    func pause(taskID: UUID) {
        sessionQueue.async {
            let relatedTasks = self.activeJobs.filter { $0.value.taskID == taskID }

            for (urlTaskIdentifier, _) in relatedTasks {
                self.backgroundSession.getAllTasks { tasks in
                    if let urlTask = tasks.first(where: { $0.taskIdentifier == urlTaskIdentifier }) as? URLSessionDownloadTask {
                        urlTask.cancel { resumeData in
                            if let resumeData {
                                Task { @MainActor in
                                    self.delegate?.sessionDidSaveResumeData(resumeData, for: urlTaskIdentifier)
                                }
                            }
                            self.logger.trace("Paused URLSession task: \(urlTaskIdentifier)")
                        }
                    }
                }

                self.activeJobs.removeValue(forKey: urlTaskIdentifier)
            }
        }
    }

    @discardableResult
    func resume(taskID: UUID, with resumeData: Data?) async throws -> Int {
        guard let resumeData else {
            throw NSError(domain: "DownloadSessionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No resume data available"])
        }

        let urlDownloadTask = backgroundSession.downloadTask(withResumeData: resumeData)

        let downloadJob = DownloadJob(
            type: .media,
            taskID: taskID,
            url: URL(string: "")!,
            destinationPath: ""
        )

        activeJobs[urlDownloadTask.taskIdentifier] = downloadJob
        urlDownloadTask.resume()

        logger.trace("Resumed download task with identifier: \(urlDownloadTask.taskIdentifier)")
        return urlDownloadTask.taskIdentifier
    }

    func cancel(taskID: UUID) {
        sessionQueue.async {
            let relatedTasks = self.activeJobs.filter { $0.value.taskID == taskID }

            for (urlTaskIdentifier, _) in relatedTasks {
                self.backgroundSession.getAllTasks { tasks in
                    if let urlTask = tasks.first(where: { $0.taskIdentifier == urlTaskIdentifier }) {
                        urlTask.cancel()
                        self.logger.trace("Cancelled URLSession task: \(urlTaskIdentifier)")
                    }
                }

                // Remove from task mapping
                self.activeJobs.removeValue(forKey: urlTaskIdentifier)
            }
        }
    }

    func getAllTasks() -> [URLSessionDownloadTask] {
        var tasks: [URLSessionDownloadTask] = []
        let semaphore = DispatchSemaphore(value: 0)

        backgroundSession.getAllTasks { allTasks in
            tasks = allTasks.compactMap { $0 as? URLSessionDownloadTask }
            semaphore.signal()
        }

        semaphore.wait()
        return tasks
    }

    // MARK: - Private Setup

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true

        backgroundSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    func recoverActiveDownloads(records: [ActiveDownloadRecord]) async -> RecoveryResult {
        let liveTasks = await withCheckedContinuation { continuation in
            backgroundSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }

        let liveTaskIds = Set(liveTasks.map(\.taskIdentifier))

        var reconnected: [(record: ActiveDownloadRecord, urlSessionTaskIdentifier: Int)] = []
        var orphaned: [ActiveDownloadRecord] = []

        for record in records {
            if let urlTaskId = record.urlSessionTaskIdentifier, liveTaskIds.contains(urlTaskId) {
                // Rebuild the activeJobs mapping
                let downloadJob = DownloadJob(
                    type: .media,
                    taskID: record.id,
                    url: record.downloadURL,
                    destinationPath: ""
                )
                activeJobs[urlTaskId] = downloadJob
                reconnected.append((record: record, urlSessionTaskIdentifier: urlTaskId))
                logger.trace("Reconnected download: taskID=\(record.id), urlSessionTask=\(urlTaskId)")
            } else {
                orphaned.append(record)
                logger.trace("Orphaned download: taskID=\(record.id)")
            }
        }

        logger.info("Recovery: \(reconnected.count) reconnected, \(orphaned.count) orphaned")
        return RecoveryResult(reconnected: reconnected, orphaned: orphaned)
    }

    // MARK: - Helper Methods

    func getDownloadJob(for taskIdentifier: Int) -> DownloadJob? {
        activeJobs[taskIdentifier]
    }

    func removeDownloadJob(for taskIdentifier: Int) {
        activeJobs.removeValue(forKey: taskIdentifier)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadSessionManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Log original and final URL (post-redirect) if available
        let original = downloadTask.originalRequest?.url
        let current = downloadTask.currentRequest?.url
        func redact(_ url: URL?) -> String {
            guard let url else { return "nil" }
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            if let idx = comps.queryItems?.firstIndex(where: { $0.name.lowercased() == "api_key" }) {
                comps.queryItems?[idx].value = "REDACTED"
            }
            return comps.string ?? url.absoluteString
        }
        var status: String = "unknown"
        var locationHeader: String = ""
        if let http = downloadTask.response as? HTTPURLResponse {
            status = "\(http.statusCode)"
            if let loc = http.allHeaderFields["Location"] as? String, !loc.isEmpty {
                locationHeader = ", Location=\(loc)"
            }
        }
        logger
            .trace(
                "Download completed: task=\(downloadTask.taskIdentifier), status=\(status)\(locationHeader), original=\(redact(original)), final=\(redact(current)))"
            )

        // The URLSession-provided `location` is ephemeral and may be removed
        // before the delegate hop to MainActor executes. Stage it immediately.
        let stagedLocation = stageDownloadFile(
            from: location,
            taskIdentifier: downloadTask.taskIdentifier
        ) ?? location

        // Notify delegate about completion
        Task { @MainActor in
            self.delegate?.sessionDidCompleteDownload(
                taskIdentifier: downloadTask.taskIdentifier,
                location: stagedLocation,
                response: downloadTask.response
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Guard against unknown content length which can be -1
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        // Throttle progress updates to reduce UI churn - only notify delegate if progress changed by 5% or more
        enum ProgressTracker {
            static var lastReported: [Int: Double] = [:]
            static var lastLogged: [Int: Double] = [:]
        }
        let taskId = downloadTask.taskIdentifier
        let lastReported = ProgressTracker.lastReported[taskId] ?? 0.0

        // Only notify delegate if progress changed by more than 5% or completed
        if abs(progress - lastReported) >= 0.05 || progress == 1.0 {
            Task { @MainActor in
                self.delegate?.sessionDidUpdateProgress(
                    taskIdentifier: downloadTask.taskIdentifier,
                    progress: progress
                )
            }
            ProgressTracker.lastReported[taskId] = progress
        }

        // Log only if progress changed by more than 10%
        let lastLogged = ProgressTracker.lastLogged[taskId] ?? 0.0
        if abs(progress - lastLogged) >= 0.10 || progress == 1.0 {
            logger.trace("Download progress: \(progress) for task: \(taskId)")
            ProgressTracker.lastLogged[taskId] = progress
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        let original = task.originalRequest?.url
        let current = task.currentRequest?.url
        func redact(_ url: URL?) -> String {
            guard let url else { return "nil" }
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            if let idx = comps.queryItems?.firstIndex(where: { $0.name.lowercased() == "api_key" }) {
                comps.queryItems?[idx].value = "REDACTED"
            }
            return comps.string ?? url.absoluteString
        }
        logger.error("Download task error: \(error.localizedDescription), original=\(redact(original)), final=\(redact(current)))")

        // Extract resume data from error if available
        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Task { @MainActor in
                self.delegate?.sessionDidSaveResumeData(resumeData, for: task.taskIdentifier)
            }
        }

        // Detect force-quit cancellation
        if let downloadTask = task as? URLSessionDownloadTask {
            let cancelReason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
            if cancelReason == NSURLErrorCancelledReasonUserForceQuitApplication {
                Task { @MainActor in
                    self.delegate?.sessionDidCompleteWithError(
                        taskIdentifier: downloadTask.taskIdentifier,
                        error: DownloadRecoveryError.forceQuitCancelled
                    )
                }
            } else {
                Task { @MainActor in
                    self.delegate?.sessionDidCompleteWithError(
                        taskIdentifier: downloadTask.taskIdentifier,
                        error: error
                    )
                }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        logger.trace("Background URLSession did finish events")

        // Notify delegate about background events completion
        Task { @MainActor in
            self.delegate?.sessionDidFinishBackgroundEvents()
        }

        // Call the background session completion handler on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    private func stageDownloadFile(from sourceURL: URL, taskIdentifier: Int) -> URL? {
        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory.appendingPathComponent("SwiftfinDownloadStaging", isDirectory: true)
        let stagedURL = stagingDirectory.appendingPathComponent("task-\(taskIdentifier)-\(UUID().uuidString).tmp", isDirectory: false)

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: stagedURL.path) {
                try fileManager.removeItem(at: stagedURL)
            }

            try fileManager.moveItem(at: sourceURL, to: stagedURL)
            return stagedURL
        } catch {
            logger.warning("Failed to stage completed download for task \(taskIdentifier): \(error.localizedDescription)")
            return nil
        }
    }
}
