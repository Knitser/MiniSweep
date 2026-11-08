<img src="assets/icon.png" width="96" alt="MiniSweep icon">

# MiniSweep

A native macOS utility for seeing where your storage and memory go. Explore large files, watch app memory usage, and review cleanup before moving anything to Trash.

Built by [knitser](https://github.com/Knitser).

**[Download the latest release](https://github.com/Knitser/MiniSweep/releases/latest)** · Apple silicon · macOS 14 or later

## Features

- **Storage map:** a treemap and sorted list of the largest files and folders, with allocated sizes and a list of large files anywhere in the scan.
- **Live memory monitor:** app footprints grouped with helper processes, five-second samples, trend charts, compressed memory and swap usage.
- **Growth watch:** flags sustained memory growth after enough samples have been collected.
- **Reviewed cleanup:** find caches and old downloads, inspect them in Finder, and choose individual items for a final review.
- **Trash first:** cleanup uses the native macOS Trash API. Protected folders, running app bundles and changed file identities are checked before each move.
- **Local operation:** no account, API key, analytics, network service, login agent or scheduled cleanup.

## Install

1. Download `MiniSweep-1.0.0-macos-arm64.dmg` or the app ZIP from [Releases](https://github.com/Knitser/MiniSweep/releases/latest).
2. Open the disk image or extract the ZIP, then drag `MiniSweep.app` into Applications.
3. Open MiniSweep. The first scan maps Applications.

The release is ad-hoc signed and is not Apple-notarized. macOS may require an explicit approval to open a downloaded build. You can also build the app locally using the instructions below.

For a complete storage scan, use **Disk access & permissions** to open Full Disk Access in System Settings, add MiniSweep, then quit and reopen it. Folders macOS will not let the app read are skipped and reported, so totals may be partial.

## Storage explorer

Choose Home, Applications, Downloads, Caches, All data, or a custom folder or mounted volume. Bigger blocks mean larger items. Click to select; double-click a folder to scan inside it. **Reveal** opens the selected item in Finder. **Add to review** queues a permitted item without moving it.

Scanning runs in the background, reports progress and can be stopped. Directory symlinks are not followed, and scans stay on the starting filesystem. Sparse files are measured by allocated blocks rather than apparent length. APFS clones and hard links can share blocks, so per-path totals are estimates and may exceed the space a cleanup would reclaim.

## Memory monitor

Memory is sampled every five seconds using macOS physical-footprint counters, including compressed memory. Helpers are grouped with their parent app where ownership can be determined. Some virtual machines can also be attributed to their owning app. Protected processes may be unavailable.

The Change column and trend charts cover up to 15 minutes in the current session. Growth watch requires at least 30 seconds, 128 MiB and 20% growth, with at least four increases across the last six intervals. A change in an app's helper-process set resets its baseline.

Sustained growth is a signal to investigate, not proof of a memory leak. Use Activity Monitor or Instruments for deeper diagnosis. **Quit** requests a normal app quit after confirmation; save your work first. Swap can remain allocated after apps close.

## Cleanup

**Find cleanup** checks recognized app caches, temporary package downloads and Downloads. Nothing is selected automatically. Inspect each item before adding it to review, then confirm the final queue.

Downloads can contain your only copy of a file. Apps may need to download data again after cache cleanup. Close related apps before proceeding.

Cleanup accepts personal files under your home directory, individual apps directly inside Applications, and recognized cache locations. It protects system locations, hidden personal folders, general Library data, running app bundles and MiniSweep itself. External volumes can be mapped but cannot be cleaned by this version.

Parent/child selections are deduplicated, paths and file identities are revalidated, and failed moves are reported individually. Items go to Trash, where Finder can restore them. **Space is reclaimed only when you empty Trash yourself.**

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

```sh
dist/MiniSweep.app/Contents/MacOS/MiniSweep --self-test
dist/MiniSweep.app/Contents/MacOS/MiniSweep --trash-self-test
```

The first command runs 28 checks covering size aggregation, sparse files, symlinks, cancellation, cleanup boundaries, file identity changes, growth thresholds and treemap bounds. The second creates a disposable file, moves it to Trash, restores it intact and removes only its own fixture.

Read-only diagnostics are also available:

```sh
dist/MiniSweep.app/Contents/MacOS/MiniSweep --scan-json /path/to/folder
dist/MiniSweep.app/Contents/MacOS/MiniSweep --memory-json
```

These commands use the terminal's permissions, which can differ from the app's. Their JSON output contains local paths or process names and is not uploaded by the app.

Copyright © 2026 knitser.
