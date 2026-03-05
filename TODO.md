# PR #1674 Review Fixes

## Files to Remove

- [x] Remove `development.md`
- [x] Remove `test.md`
- [x] Remove `DEVELOPER_GUIDE.md`

## File Naming / Organization

- [x] Rename `Documentation/downloads-file-structure-guide.md` to camelCase
- [x] Add `.github/copilot-instructions.md` to `.gitignore`

## Use Existing Patterns Instead of Custom

- [x] Replace `Int64.toReadableFileSize()` with `FormatStyle` in `FormatStyle.swift`, remove `Int64+Extensions.swift`
- [x] Replace `DownloadQuality`/`TranscodingParameters` with `PlaybackBitrate` reference
- [x] Remove `seasonImageURL` from `BaseItemDto+Images.swift`

## Download Path Structure

- [x] Nest episode downloads into season folder: `series/season/episodeId` not `series/episodeId`

## Code Cleanup

- [x] Remove AI-generated comments throughout
- [x] Clean up unnecessary commented-out code
- [x] Remove debug methods from DownloadMetadataManager
