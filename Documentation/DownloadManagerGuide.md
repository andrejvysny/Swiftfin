# Download Manager Guide

This document explains the background download service located under `Shared/Services/DownloadService`. It describes how it is structured, how to integrate it and how to use its API.

## Overview

The download service provides a lightweight API for downloading files in the background on iOS. It wraps a background `URLSession` and publishes progress and state updates through an async stream. Tasks are coordinated by an actor to limit concurrency and to handle pause/resume operations. Files are stored under the app's `Downloads` directory with basic disk quota checks.

## Setup

1. Ensure the `Shared/Services/DownloadService` folder is included in your target.
2. In your `UIApplicationDelegate` implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` and forward the completion handler to `NetworkLayer.shared`:
   ```swift
   func application(_ application: UIApplication,
                    handleEventsForBackgroundURLSession identifier: String,
                    completionHandler: @escaping () -> Void) {
       NetworkLayer.shared.backgroundCompletionHandler = completionHandler
   }
   ```
3. Obtain the manager via the dependency container or instantiate it directly:
   ```swift
   let downloadManager = Container.shared.backgroundDownloadManager()
   ```
   or
   ```swift
   let downloadManager = DownloadManager()
   ```

## Components

### `DownloadManager`
Facade conforming to `DownloadManagerProtocol`. Creates a `TaskCoordinator` and exposes an async stream of `DownloadEvent` values.

### `TaskCoordinator`
An `actor` maintaining an active set of downloads and a queue. It limits the number of concurrent tasks, forwards progress, and moves completed files via `StorageManager`.

### `NetworkLayer`
Owns the background `URLSession`. Delegate callbacks notify the `TaskCoordinator` about progress or completion.

### `StorageManager`
Handles the local filesystem: determines destination paths, checks available space and moves files while excluding them from iCloud backups.

## API

### `DownloadManagerProtocol`
```swift
public protocol DownloadManagerProtocol {
    @discardableResult
    func enqueue(_ item: URL, priority: TaskPriority) async -> DownloadID
    func pause(_ id: DownloadID) async
    func resume(_ id: DownloadID) async
    func cancel(_ id: DownloadID) async
    var events: AsyncStream<DownloadEvent> { get }
}
```

#### Methods
* `enqueue(_ item: URL, priority: TaskPriority)` – starts downloading `item` with the given priority and returns a `DownloadID` used to control the task.
* `pause(_ id: DownloadID)` – pauses an active download if possible. Resume data is preserved to allow resuming later.
* `resume(_ id: DownloadID)` – resumes a paused or queued download.
* `cancel(_ id: DownloadID)` – cancels the download and emits a `.failed` event with the `.cancelled` error.
* `events` – asynchronous sequence of `DownloadEvent` values to observe task status.

### `DownloadEvent`
```swift
public enum DownloadEvent {
    case started(DownloadID)
    case progress(DownloadID, Double)   // progress in the range 0–1
    case completed(DownloadID, URL)     // file moved to final location
    case failed(DownloadID, DownloadError)
}
```

### `DownloadError`
```swift
public enum DownloadError: Error {
    case network
    case server
    case diskFull
    case cancelled
    case unknown
}
```

### `DownloadManager` Initializer
```swift
init(maxConcurrent: Int = 3, storage: StorageManager = StorageManager())
```
* `maxConcurrent` – Maximum number of simultaneous downloads.
* `storage` – Instance handling file storage. Defaults to a manager rooted in `URL.downloads`.

## Usage Example

```swift
let manager = DownloadManager()  // or via Container.shared
let taskID = await manager.enqueue(mediaURL, priority: .utility)

Task.detached {
    for await event in manager.events {
        switch event {
        case .progress(let id, let value) where id == taskID:
            print("progress", value)
        case .completed(let id, let url) where id == taskID:
            print("saved to", url)
        case .failed(let id, let error) where id == taskID:
            print("failed", error)
        default:
            break
        }
    }
}
```

You may call `pause(_:)`, `resume(_:)` or `cancel(_:)` with the `DownloadID` to control the task.

## Limitations

* Tasks are not persisted across app launches.
* No retry mechanism is implemented beyond the resume data when pausing.
* Disk quota checks are minimal; adjust `StorageManager` as needed.

This service can serve as a starting point for integrating background downloads in your app. Extend the `TaskCoordinator` or `StorageManager` to support additional features such as retry policies, persistence or background task scheduling.
