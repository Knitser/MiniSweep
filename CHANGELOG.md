# Changelog

## 1.2.0 — 2026-11-09

- Storage Growth Lens compares complete scans against saved local baselines and identifies added, removed, grown and shrunken paths.
- Baselines are bounded to 10 folders, use owner-only metadata files, and can be replaced or cleared from the app.
- Partial or inaccessible scans are excluded from comparisons to avoid false removal reports.
- App memory inspectors can open app storage and recognized VM disk workspaces directly in Storage Explorer.
- VM workspace links preserve the cleanup protections around workload and session data.
- Expanded verification to 50 checks, including persistence, in-place edits, partial scans, VM paths and tiny treemap layouts.

## 1.1.0 — 2026-11-09

- Developer ID signing and Apple notarization, with attached tickets for offline verification.
- Dark appearance by default, native Liquid Glass on supported macOS versions, and material fallbacks.
- Aurora, Ocean and Copper storage palettes; Light and System appearance options.
- Single-click folder-block navigation, Back/Forward history, and a complete folder-contents browser.
- Sort folder items by size, name or file count; filter files separately from folders.
- Full-scan file-type totals, allocated versus logical size, and file metadata inspectors.
- Per-process memory details with PIDs, executable paths, resident memory, footprint, peaks and observation duration.
- Better cleanup candidate filtering, explicit partial-scan status, and detection of files edited after review.
- More reliable bounds for tiny treemap blocks, bounded type aggregation, and 36 verification checks.

## 1.0.0 — 2026-11-08

Initial storage explorer, app memory monitor and reviewed Trash cleanup. This older release was ad-hoc signed and not notarized.
