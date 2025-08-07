# Download Manager Test Plan - Multiple Versions

## Overview
This test plan verifies that the refactored download manager correctly handles downloading multiple versions of the same movie with the new file naming scheme (version1.mp4, version2.avi, etc.).

## Prerequisites
- Jellyfin server with at least one movie that has multiple versions (different quality/format)
- iOS device or simulator with Swiftfin installed
- Sufficient storage space for downloads

## Test Cases

### 1. Download First Version
**Steps:**
1. Navigate to a movie with multiple versions
2. Tap the download button
3. Select the first version from the media source selection sheet
4. Tap the download icon for that version

**Expected Results:**
- Download starts with progress indicator
- File is saved as `MediaID/version1.[ext]` where [ext] is the original format (mp4, mkv, etc.)
- Download icon shows as completed (filled circle) for that specific version
- Other versions still show as available to download

### 2. Download Second Version
**Steps:**
1. While first version is downloaded, tap the download button again
2. Select a different version from the media source selection sheet
3. Tap the download icon for the second version

**Expected Results:**
- Second download starts
- File is saved as `MediaID/version2.[ext]`
- Both versions show as completed in the selection sheet
- Downloads view shows the movie with multiple versions

### 3. Playback of Downloaded Versions
**Steps:**
1. Go to Downloads view
2. Find the movie with multiple versions
3. Tap to play

**Expected Results:**
- The most recent version plays correctly
- Video loads from local storage (no network activity)
- All metadata (title, duration, etc.) displays correctly

### 4. Delete Single Version
**Steps:**
1. In Downloads view, swipe on the movie
2. Tap delete
3. Confirm deletion

**Expected Results:**
- All versions are deleted
- Download folder is removed
- Movie shows as available to download again in item view

### 5. Series Metadata Download
**Steps:**
1. Navigate to a TV series
2. Tap the download button

**Expected Results:**
- Download starts (metadata and images only)
- Series folder is created with metadata/images
- Series appears in Downloads view
- No media files are downloaded (series itself has no playable content)

### 6. Episode Download with Hierarchy
**Steps:**
1. Navigate to a TV episode
2. Download the episode

**Expected Results:**
- File is saved as `SeriesID/SeasonID/EpisodeID/version1.[ext]`
- Episode appears under the series in Downloads view
- Proper folder hierarchy is maintained

### 7. UI State Consistency
**Steps:**
1. Start downloading a large file
2. Navigate away from the item view
3. Return to the item view

**Expected Results:**
- Download progress is maintained
- Download icon shows current progress
- State is consistent across app restarts

### 8. Storage Check
**Steps:**
1. Fill device storage to near capacity
2. Attempt to download a large file

**Expected Results:**
- Download fails with "Not enough storage" error
- Error is displayed to user
- No partial files remain

## Edge Cases

### Multiple Concurrent Downloads
- Download 3+ different movies simultaneously
- Verify all progress independently
- Check that version numbering remains consistent

### App Termination
- Start a download
- Force quit the app
- Reopen and verify download state

### Network Interruption
- Start a download
- Turn off network
- Verify error handling and ability to retry

## Validation Checklist
- [ ] Version files are named correctly (version1.mp4, version2.avi)
- [ ] Each media source has independent download state
- [ ] Downloads view correctly shows all downloaded items
- [ ] Playback works for all downloaded versions
- [ ] Series metadata downloads work without media files
- [ ] Folder structure matches requirements
- [ ] UI updates reflect download state changes
- [ ] Error handling works correctly

## Notes
- Check console logs for any warnings or errors during downloads
- Verify UserDefaults cleanup when downloads are deleted
- Ensure no orphaned files remain after deletion