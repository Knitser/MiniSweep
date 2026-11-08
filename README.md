<img src="assets/icon.png" width="96" alt="MiniSweep icon">

# MiniSweep

A native macOS utility for seeing where your storage and memory go. Explore large files, watch app memory usage, and review cleanup before moving anything to Trash.

Built by [knitser](https://github.com/Knitser).

**[Download the latest release](https://github.com/Knitser/MiniSweep/releases/latest)** · Apple silicon · macOS 14 or later

## Features

- **Fast navigation:** reuse indexed folder totals after a scan. When file metadata exceeds the memory budget, drill-down reads only immediate children instead of walking the nested tree again. Saved overviews appear immediately while a fresh scan runs.
- **Find space:** a clear route from Storage to caches and downloads, category filters, existing Trash space and batch staging into the final cleanup review.
- **App identity:** real macOS app icons and icon-derived map colors and memory accents.
- **Storage map:** single-click folder drill-down, Back/Forward navigation, a full folder-contents browser, configurable sorting, and large-file filtering. Every subfolder remains accessible, including items grouped into smaller blocks.
- **File details:** allocated versus logical size, nested file counts, timestamps, ownership, permissions, path copying, and file-type totals from the full scan.
- **Native appearance:** dark mode by default, native Liquid Glass on macOS 26 or later, material effects on earlier versions, and Aurora, Ocean and Copper map palettes. Light and system appearance remain available.
- **Live memory monitor:** app footprints grouped with helper processes, five-second samples, trend charts, compressed memory and swap usage. Open an inspector for each process's PID, executable path, footprint, resident size, observed peak and sample window.
- **Growth watch:** flags sustained memory growth after enough samples have been collected.
- **Storage Growth Lens:** save a local size baseline, then see which immediate child paths grew, shrank, appeared or disappeared in later complete scans.
- **Memory → storage links:** jump from an app’s memory inspector to its app bundle or a recognized VM’s on-disk workspace. Protected workload data stays outside cleanup.
- **Reviewed cleanup:** find caches and old downloads, inspect them in Finder, and choose individual items for a final review.
- **Trash first:** cleanup uses the native macOS Trash API. Protected folders, running app bundles and changed file identities are checked before each move.
- **Local operation:** no account, API key, analytics, network service, login agent or scheduled cleanup.

## Install

1. Download the macOS DMG or the app ZIP from [Releases](https://github.com/Knitser/MiniSweep/releases/latest).
2. Open the disk image or extract the ZIP, then drag `MiniSweep.app` into Applications.
3. Open MiniSweep. The first scan maps Applications.

The current release is signed with Developer ID and notarized by Apple. Notarization tickets are attached for offline verification. macOS may still show its normal first-open confirmation for an app downloaded from the internet. You can also build the app locally using the instructions below.

Use **Disk access & permissions** to inspect the actual reasons items were skipped. Enable the signed MiniSweep app in Full Disk Access in System Settings, then quit and reopen it. Full Disk Access does not override every filesystem permission, ACL or system protection. Online-only cloud items remain online, changed files are distinguished from permission errors, and totals may be partial.

## Storage explorer

Choose Home, Applications, Downloads, Caches, All data, or a custom folder or mounted volume. Bigger blocks mean larger items. Single-click a folder block to scan inside it. Back and Forward return through folder history. Use All items or click the Other items block to browse every item in the current folder. Click a file block to select it, then open Details for metadata. **Reveal** opens the selected item in Finder. **Add to review** queues a permitted item without moving it.

The first scan still enumerates readable metadata; it is not an instant or raw APFS volume index. Scanning runs in the background, shows provisional top-level totals before large branches finish, reports progress and can be stopped. File-type totals are batched before being passed to the interface. Cloud materialization is disabled for scanner metadata operations so scans do not request downloads of online-only files or directories. The default traversal was retained after bulk enumeration benchmarks did not show a consistent improvement.

Completed scans retain a bounded navigation index (up to 200,000 entries and a 64 MiB estimated metadata budget), reserving directory capacity separately from file listings. Once the file budget fills, folder navigation can still combine indexed recursive folder totals with a shallow read of immediate files. Uncached or structurally changed folders require a new scan. Dated cached views cannot create fresh Growth Lens baselines or stage storage cleanup; refresh first or use fresh cleanup candidates.

Up to three root overviews, containing names, metadata, top file summaries and error samples, are saved locally within 4 MiB. Their files use owner-only permissions. On reopening, the last overview appears with its timestamp while refreshing. Use **Forget saved overviews** to clear them. These snapshots contain local paths and are never uploaded.

Directory symlinks are not followed, and scans stay on the starting filesystem. The All data target covers the writable Data volume; other mounted filesystems, snapshots and other APFS volumes are outside that path total, even though the disk meter shows container space. Sparse files are measured by allocated blocks rather than apparent length. APFS clones and hard links can share blocks, so per-path totals are estimates and may exceed the space a cleanup would reclaim.

## Memory monitor

Memory is sampled every five seconds using macOS physical-footprint counters, including compressed memory. Helpers are grouped with their parent app where ownership can be determined. Some virtual machines can also be attributed to their owning app. Protected processes may be unavailable.

The Change column and trend charts cover up to 15 minutes in the current session. Growth watch requires at least 30 seconds, 128 MiB and 20% growth, with at least four increases across the last six intervals. A change in an app's helper-process set resets its baseline.

Sustained growth is a signal to investigate, not proof of a memory leak. Use Activity Monitor or Instruments for deeper diagnosis. **Quit** requests a normal app quit after confirmation; save your work first. Swap can remain allocated after apps close.

## Storage Growth Lens

A complete readable scan creates a local baseline for the selected folder. Later complete scans compare immediate child paths and their recursive allocated sizes against that baseline. The panel separates added, removed, grown and shrunken items and links existing paths to their metadata inspector.

Use **Set baseline** to replace the comparison point, or the clear button to forget it. Inaccessible or incomplete scans do not overwrite a baseline or produce misleading removal reports. A folder or volume whose identity changed requires a new baseline.

At most 10 folders are remembered, with up to 10,000 direct children per folder. Baselines contain paths, sizes, counts and filesystem identity; no file contents. They remain on this Mac in the app’s Application Support folder, use owner-only file permissions, and are never uploaded. Memory history and cleanup selections remain session-only. Growth does not imply that a file is junk or safe to delete, and shared APFS blocks remain an estimate.

## Memory → storage

Open an app’s memory inspector and choose **Map app storage** to investigate its disk footprint. For recognizable virtual machines, the inspector can also link to the VM workspace identified from open backing files. Attribution depends on what macOS permits the app to inspect and currently recognizes supported Claude and Docker layouts. A VM must be running to expose this context.

VM images and session state are workload data. These links are for storage inspection, and protected Library paths cannot enter the cleanup queue.

## Cleanup

**Find cleanup** checks recognized app caches, temporary package downloads and Downloads. Nothing is selected automatically. Inspect each item before adding it to review, then confirm the final queue. **Add shown items to review** stages the currently filtered candidates as a batch; it does not move or delete them.

Downloads can contain your only copy of a file. Apps may need to download data again after cache cleanup. Close related apps before proceeding.

Cleanup accepts personal files under your home directory, individual apps directly inside Applications, and recognized cache locations. It protects system locations, hidden personal folders, general Library data, running app bundles and MiniSweep itself. External volumes can be mapped but cannot be cleaned by this version.

Parent/child selections are deduplicated, paths, file identities, modification times and sizes are revalidated, and failed moves are reported individually. Items go to Trash, where Finder can restore them. **Space is reclaimed only when you empty Trash yourself.**

## Build

Requires Apple's Swift toolchain and macOS SDK. No third-party packages or downloads are needed.

```sh
git clone https://github.com/Knitser/MiniSweep.git
cd MiniSweep
zsh build.sh
open dist/MiniSweep.app
```

The build targets Apple silicon and macOS 14. Pass an output directory to `build.sh` to change the destination. `Icon.swift` draws the app icon; the ready-to-use `AppIcon.icns` is included.

## Verify

Local builds use an ad-hoc signature unless a Developer ID identity is supplied. Release signing reads the private key from Keychain; it never exports it.

```sh
MINISWEEP_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh build.sh
```

Developer ID signing alone is not notarization. A distribution build must also be submitted to Apple and have its accepted ticket stapled before packaging. Credentials and signing keys must stay outside the repository.

```sh
dist/MiniSweep.app/Contents/MacOS/MiniSweep --self-test
dist/MiniSweep.app/Contents/MacOS/MiniSweep --trash-self-test
```

The first command runs 55 checks covering size aggregation, sparse files, symlinks, cancellation, cleanup boundaries, file replacement and in-place edits, bounded file-type aggregation, growth thresholds, extreme treemap layouts, persisted size comparisons, partial-scan safeguards, scanner parity, bounded index coverage, shallow navigation, saved overview privacy and VM backing-file classification. The second creates a disposable file, moves it to Trash, restores it intact and removes only its own fixture.

Read-only diagnostics are also available:

```sh
dist/MiniSweep.app/Contents/MacOS/MiniSweep --scan-json /path/to/folder
dist/MiniSweep.app/Contents/MacOS/MiniSweep --memory-json
dist/MiniSweep.app/Contents/MacOS/MiniSweep --benchmark-scan /path/to/folder
```

These commands use the terminal's permissions, which can differ from the app's. Their JSON output contains local paths or process names and is not uploaded by the app.

Copyright © 2026 knitser.
