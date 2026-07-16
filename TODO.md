# Bulk Downloads Implementation

## Phase 1: Concurrent Download Queue

- [x] Add `.queued` to `DownloadTask.State`
- [x] Add `.queued` to `ActiveDownloadRecord.ActiveDownloadStatus`
- [x] Add `queuePosition` to `ActiveDownloadRecord`
- [x] Add queue logic to `DownloadManager` (maxConcurrent=3, pendingQueue, startNextQueued)
- [x] Update `persistQueue()` for queued state
- [x] Update `recoverDownloadsOnLaunch()` for queued items
- [x] Add `.queued` to `DownloadTaskState` enum in VM
- [x] Add queued icon in `DownloadActionButtonWithProgress`

## Phase 2: Bulk Download Methods

- [x] Add `downloadSeason()` to `DownloadManager`
- [x] Add `downloadItems()` to `DownloadManager`
- [x] Add `downloadAllSeries()` to `DownloadManager`

## Phase 6: Queue Section in Downloads List

- [x] Add active/queued download sections to `DownloadListView`
- [x] ActiveDownloadRow + QueuedDownloadRow components

## Phase 3: Season Download Button

- [x] Create `SeasonDownloadButton.swift`
- [x] Add to `EpisodeSelector` header

## Phase 4: Multi-Select Episodes

- [x] Selection mode in `EpisodeSelector`
- [x] Checkbox overlay on `EpisodeCard`
- [x] Download selected action

## Phase 5: Multi-Select in Library Views

- [x] Selection mode in `PagingLibraryView`
- [x] Batch download action
- [x] Edit mode in `DownloadListView` for batch delete
