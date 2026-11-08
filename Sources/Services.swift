import SwiftUI
import AppKit
import Darwin

let sweepHome = FileManager.default.homeDirectoryForCurrentUser.path
let gib = Double(1 << 30)
func byteText(_ value: Int64) -> String {
    let n = Double(max(value, 0))
    if n >= gib { return String(format: "%.1f GiB", n / gib) }
    if n >= 1_048_576 { return String(format: "%.0f MiB", n / 1_048_576) }
    if n >= 1024 { return String(format: "%.0f KiB", n / 1024) }
    return "\(Int(n)) B"
}
func shortPath(_ path: String) -> String { path == sweepHome ? "~" : path.replacingOccurrences(of: sweepHome + "/", with: "~/") }
func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
func cString<T>(_ tuple: T) -> String {
    withUnsafePointer(to: tuple) { p in p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
}

struct FileNode: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let logical: Int64
    let files: UInt64
    let directory: Bool
    var category: String = ""
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var parent: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
}

struct FileTypeTotal: Identifiable {
    let extensionName: String
    var bytes: Int64 = 0
    var logical: Int64 = 0
    var count: UInt64 = 0
    var id: String { extensionName }
    var label: String { extensionName == "#other" ? "Other file types" : extensionName.isEmpty ? "No extension" : "." + extensionName }
}
enum StorageSort: String, CaseIterable {
    case largest = "Largest first", smallest = "Smallest first", name = "Name", files = "Most files"
}

struct DiskStatus {
    var total: Int64 = 0
    var free: Int64 = 0
    var fraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
    static func read() -> DiskStatus {
        var fs = statfs()
        guard statfs(sweepHome, &fs) == 0 else { return DiskStatus() }
        return DiskStatus(total: Int64(fs.f_blocks) * Int64(fs.f_bsize), free: Int64(fs.f_bavail) * Int64(fs.f_bsize))
    }
}

// Written only by its scan worker; final values are handed to the main queue after the worker returns.
final class ScanCollector: @unchecked Sendable {
    var nodes: [FileNode] = []
    var largest: [FileNode] = []
    var errors: [String] = []
    var skipped = 0
    var fileTypes: [String: FileTypeTotal] = [:]
    let rootPath: String?
    let progress: ([FileNode], Int64, UInt64, String, Int) -> Void
    init(rootPath: String? = nil, progress: @escaping ([FileNode], Int64, UInt64, String, Int) -> Void) { self.rootPath = rootPath; self.progress = progress }
    func event(path: String, kind: Int32, allocated: Int64, logical: Int64, files: UInt64, error: Int32) {
        if kind == 5 {
            var ext = path.lowercased()
            if fileTypes[ext] == nil && fileTypes.count >= 512 { ext = "#other" }
            var value = fileTypes[ext] ?? FileTypeTotal(extensionName: ext)
            value.bytes += allocated; value.logical += logical; value.count += files
            fileTypes[ext] = value
            return
        }
        if kind == 1 || kind == 2 {
            let n = FileNode(path: path, bytes: allocated, logical: logical, files: files, directory: kind == 1)
            // Keep every direct child, even when large nested files are discovered first.
            if kind == 1 || rootPath == nil || n.parent == rootPath { nodes.append(n) }
            if kind == 2 && allocated >= 8 * 1024 * 1024 {
                largest.append(n)
                if largest.count > 250 { largest.sort { $0.bytes > $1.bytes }; largest = Array(largest.prefix(150)) }
            }
        } else if kind == 3 {
            progress(nodes, allocated, files, path, skipped)
        } else if kind == 4 {
            skipped += 1
            if errors.count < 100 { errors.append("\(shortPath(path)): \(String(cString: strerror(error)))") }
        }
    }
}

// Cancellation is atomic in C. Keeping the handle alive in its worker prevents cancel/free races.
final class ScanHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init?() { guard let p = ms_scan_create() else { return nil }; pointer = p }
    func cancel() { ms_scan_cancel(pointer) }
    deinit { ms_scan_destroy(pointer) }
}

let scanCallback: MSScanCallback = { context, path, kind, allocated, logical, files, error in
    guard let context, let path else { return }
    Unmanaged<ScanCollector>.fromOpaque(context).takeUnretainedValue().event(path: String(cString: path), kind: kind, allocated: allocated, logical: logical, files: files, error: error)
}

struct FileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let length: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let mode: UInt16
    static func read(_ path: String) -> FileIdentity? {
        var s = stat()
        guard lstat(path, &s) == 0 else { return nil }
        return FileIdentity(device: s.st_dev, inode: s.st_ino, length: s.st_size,
                            modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(s.st_mtimespec.tv_nsec), mode: s.st_mode)
    }
}
struct QueueEntry: Identifiable {
    var id: String { node.path }
    let node: FileNode
    let identity: FileIdentity
}

struct CleanupPolicy {
    let home: String
    var cacheRoots: [String] {
        [home + "/Library/Caches", home + "/.npm/_cacache", home + "/.npm/_npx"] +
        ["Claude", "Codex", "ChatGPT", "Google/Chrome"].flatMap { app in
            ["Cache", "Code Cache", "GPUCache"].map { home + "/Library/Application Support/" + app + "/" + $0 }
        }
    }
    func refusal(_ path: String, runningBundles: [String]) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard p == path, p != "/", p != home, p != home + "/Library", p != "/Applications" else { return "This is a protected root folder." }
        let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        if runningBundles.contains(where: { inside(p, $0) || inside($0, p) || inside(resolved, $0) }) {
            return "Quit this app before moving it or its parent folder to Trash."
        }
        let ordinaryHome = inside(p, home) && !inside(p, home + "/Library") && !p.dropFirst(home.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") })
        let cache = cacheRoots.contains { root in inside(p, root) && p != home + "/Library/Caches" }
        let application = URL(fileURLWithPath: p).deletingLastPathComponent().path == "/Applications" && p.hasSuffix(".app")
        guard ordinaryHome || cache || application else { return "Protected location. Only personal files, app bundles, and recognized caches can enter cleanup." }
        if ordinaryHome && (!inside(resolved, home) || inside(resolved, home + "/Library") || resolved.dropFirst(home.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") })) {
            return "This path resolves to a protected location."
        }
        if cache && !cacheRoots.contains(where: { inside(resolved, $0) }) { return "This cache points outside its permitted location." }
        if application && resolved != p { return "This app is a link to another location." }
        if p == Bundle.main.bundleURL.path || inside(Bundle.main.bundleURL.path, p) { return "MiniSweep cannot move itself or its parent folder." }
        return nil
    }
}

@MainActor final class SweepModel: ObservableObject {
    @Published var page = "Storage"
    @Published var disk = DiskStatus.read()
    @Published var root = "/Applications"
    @Published var nodes: [FileNode] = []
    @Published var largest: [FileNode] = []
    @Published var isScanning = false
    @Published var scanBytes: Int64 = 0
    @Published var scannedFiles: UInt64 = 0
    @Published var scanPath = ""
    @Published var skipped = 0
    @Published var scanErrors: [String] = []
    @Published var elapsed: TimeInterval = 0
    @Published var selected: FileNode?
    @Published var showContents = false
    @Published var inspected: FileNode?
    @Published var fileTypes: [FileTypeTotal] = []
    @Published var storageSort = StorageSort.largest
    @Published var storageKind = "All items"
    @Published var navigation: [String] = []
    @Published var navigationIndex = -1
    @Published var largestFilter = ""
    @Published var queue: [QueueEntry] = []
    @Published var showReview = false
    @Published var showAccess = false
    @Published var alert: String?
    @Published var cleanupItems: [FileNode] = []
    @Published var findingCleanup = false
    @Published var cleanupNote = ""
    @Published var trashBusy = false
    @Published var freedThisSession: Int64 = 0
    @Published var storageFilter = ""
    @Published var scanComplete = false
    let policy = CleanupPolicy(home: sweepHome)
    var scanHandle: ScanHandle?
    var scanID = UUID()
    var start = Date()
    var cleanupHandle: ScanHandle?
    var childNodes: [FileNode] {
        let items = nodes.filter { $0.parent == root && (storageFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(storageFilter)) &&
            (storageKind == "All items" || (storageKind == "Folders" ? $0.directory : !$0.directory)) }
        return items.sorted {
            switch storageSort {
            case .largest: return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
            case .smallest: return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes < $1.bytes
            case .name: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .files: return $0.files == $1.files ? $0.bytes > $1.bytes : $0.files > $1.files
            }
        }
    }
    var filteredLargest: [FileNode] { largest.filter { largestFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(largestFilter) } }
    var folderBytes: Int64 { nodes.first(where: { $0.path == root })?.bytes ?? scanBytes }
    var queueBytes: Int64 { queue.reduce(0) { $0 + $1.node.bytes } }
    var runningBundles: [String] { NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path } }
    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose a folder or volume to map. MiniSweep reads sizes without opening file contents."
        if p.runModal() == .OK, let url = p.url { scan(url.path) }
    }
    func scan(_ path: String? = nil, recordHistory: Bool = true) {
        scanHandle?.cancel()
        let newRoot = URL(fileURLWithPath: path ?? root).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: newRoot) else { alert = "This folder is no longer available."; return }
        if recordHistory && (navigationIndex < 0 || navigation[navigationIndex] != newRoot) {
            navigation = Array(navigation.prefix(navigationIndex + 1)); navigation.append(newRoot)
            if navigation.count > 50 { navigation.removeFirst() }
            navigationIndex = navigation.count - 1
        }
        root = newRoot; scanID = UUID(); let id = scanID
        nodes = []; largest = []; selected = nil; fileTypes = []; largestFilter = ""; scanErrors = []; skipped = 0; scannedFiles = 0; scanBytes = 0
        storageFilter = ""; isScanning = true; scanComplete = false; start = Date(); elapsed = 0
        guard let handle = ScanHandle() else { isScanning = false; alert = "Could not start the scanner."; return }
        scanHandle = handle
        let collector = ScanCollector(rootPath: newRoot) { [weak self] partial, bytes, files, active, skipped in
            let children = partial.filter { $0.parent == newRoot || $0.path == newRoot }
            DispatchQueue.main.async {
                guard let self, self.scanID == id else { return }
                self.nodes = children; self.scanBytes = bytes; self.scannedFiles = files; self.scanPath = active
                self.skipped = skipped; self.elapsed = Date().timeIntervalSince(self.start)
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let code = ms_scan_run(handle.pointer, newRoot, 1, scanCallback, Unmanaged.passUnretained(collector).toOpaque())
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanID == id else { return }
                self.scanHandle = nil; self.isScanning = false
                self.nodes = collector.nodes; self.largest = Array(collector.largest.sorted { $0.bytes > $1.bytes }.prefix(100))
                self.fileTypes = collector.fileTypes.values.sorted { $0.bytes > $1.bytes }
                self.skipped = collector.skipped; self.scanErrors = collector.errors
                self.elapsed = Date().timeIntervalSince(self.start); self.disk = DiskStatus.read()
                self.scanComplete = code == 0
                if code != 0 && code != ECANCELED { self.alert = "Scan stopped: \(String(cString: strerror(code)))." }
            }
        }
    }
    func stopScan() { scanHandle?.cancel() }
    func navigate(_ offset: Int) {
        let next = navigationIndex + offset
        guard navigation.indices.contains(next) else { return }
        navigationIndex = next; scan(navigation[next], recordHistory: false)
    }
    func reveal(_ n: FileNode) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)]) }
    func refusal(_ n: FileNode) -> String? { policy.refusal(n.path, runningBundles: runningBundles) }
    func addToQueue(_ n: FileNode) {
        if let reason = refusal(n) { alert = reason; return }
        if queue.contains(where: { inside(n.path, $0.node.path) }) { return }
        guard let identity = FileIdentity.read(n.path) else { alert = "This item has moved or cannot be read."; return }
        queue.removeAll { inside($0.node.path, n.path) }
        queue.append(QueueEntry(node: n, identity: identity))
    }
    func findCleanup() {
        guard !findingCleanup else { return }
        findingCleanup = true; cleanupItems = []; cleanupNote = "Checking app caches and Downloads…"
        let cacheRoot = sweepHome + "/Library/Caches"
        let downloads = sweepHome + "/Downloads"
        let roots = [cacheRoot, downloads, sweepHome + "/.npm/_cacache", sweepHome + "/.npm/_npx"] +
            ["Claude", "Codex", "ChatGPT"].flatMap { a in ["Cache", "Code Cache", "GPUCache"].map { sweepHome + "/Library/Application Support/" + a + "/" + $0 } }
        let handle = ScanHandle(); cleanupHandle = handle
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [FileNode] = []; var skippedCount = 0; var cancelled = false
            if let handle {
                for path in roots where FileManager.default.fileExists(atPath: path) {
                    let collector = ScanCollector(rootPath: path) { _, _, _, _, _ in }
                    let code = ms_scan_run(handle.pointer, path, 1, scanCallback, Unmanaged.passUnretained(collector).toOpaque())
                    skippedCount += collector.skipped
                    if code == ECANCELED { cancelled = true; break }
                    let candidates = collector.nodes.filter { n in
                        n.bytes > 1024 * 1024 && ((path == cacheRoot || path == downloads) ? n.parent == path : n.path == path)
                    }.map { n -> FileNode in var item = n; item.category = path == downloads ? "Review download" : "App cache"; return item }
                    found.append(contentsOf: candidates)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.cleanupHandle = nil
                self.cleanupItems = found.sorted { $0.bytes > $1.bytes }; self.findingCleanup = false
                self.cleanupNote = (cancelled ? "Stopped · partial results. " : "") + "\(found.count) items to review · \(skippedCount) inaccessible locations · Nothing is selected automatically."
            }
        }
    }
    func moveQueueToTrash() {
        guard !trashBusy, !queue.isEmpty else { return }
        // Revalidate the whole plan before the first filesystem mutation.
        let bundles = runningBundles
        for e in queue {
            if let reason = policy.refusal(e.node.path, runningBundles: bundles) { alert = "\(e.node.name): \(reason)"; return }
            guard FileIdentity.read(e.node.path) == e.identity else { alert = "\(e.node.name) changed since review. Remove it from the queue and scan it again."; return }
        }
        trashBusy = true
        var succeeded: [String] = []; var failures: [String] = []; var bytes: Int64 = 0
        for e in queue {
            do {
                guard policy.refusal(e.node.path, runningBundles: runningBundles) == nil,
                      FileIdentity.read(e.node.path) == e.identity else { throw NSError(domain: "MiniSweep", code: 1, userInfo: [NSLocalizedDescriptionKey: "The item changed or became protected."]) }
                var result: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: e.node.path), resultingItemURL: &result)
                succeeded.append(e.id); bytes += e.node.bytes
            } catch { failures.append("\(e.node.name): \(error.localizedDescription)") }
        }
        queue.removeAll { succeeded.contains($0.id) }; cleanupItems.removeAll { succeeded.contains($0.id) }
        freedThisSession += bytes; disk = DiskStatus.read(); showReview = false; trashBusy = false
        let note = "Moved \(succeeded.count) items (\(byteText(bytes))) to Trash. Space is reclaimed after you empty Trash in Finder."
        alert = note + (failures.isEmpty ? "" : "\n\nCould not move:\n" + failures.joined(separator: "\n"))
        if !succeeded.isEmpty { scanComplete = false }
    }
    func openPermissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
}

struct RawProcess {
    let pid: Int32, parent: Int32
    let bytes: UInt64, started: UInt64
    let resident: UInt64
    let name: String, executable: String, owner: String
}
struct ProcessDetail: Identifiable {
    let pid: Int32
    let name: String
    let path: String
    let bytes: Int64
    let resident: Int64
    let started: UInt64
    var id: Int32 { pid }
}
struct MemorySample { let time: Date; let bytes: Int64 }
struct MemoryRow: Identifiable {
    let id: String
    let name: String
    let path: String
    let bytes: Int64
    let processes: [Int32]
    var samples: [MemorySample] = []
    var details: [ProcessDetail] = []
    var peak: Int64 { max(bytes, samples.map(\.bytes).max() ?? bytes) }
    var resident: Int64 { details.reduce(0) { $0 + $1.resident } }
    var observationSeconds: TimeInterval { max(0, (samples.last?.time ?? Date()).timeIntervalSince(samples.first?.time ?? Date())) }
    var delta: Int64 { bytes - (samples.first?.bytes ?? bytes) }
    var growing: Bool {
        guard samples.count >= 7, let first = samples.first, let last = samples.last,
              last.time.timeIntervalSince(first.time) >= 29,
              delta >= 128 * 1024 * 1024, Double(delta) >= Double(max(first.bytes, 1)) * 0.2 else { return false }
        let tail = Array(samples.suffix(7))
        return zip(tail.dropFirst(), tail).filter { $0.bytes > $1.bytes }.count >= 4
    }
}
@MainActor final class MemoryMonitor: ObservableObject {
    @Published var rows: [MemoryRow] = []
    @Published var stats = MSMemory()
    @Published var paused = false
    @Published var sampling = false
    @Published var updated: Date?
    @Published var search = ""
    @Published var onlyGrowing = false
    @Published var byGrowth = false
    @Published var selected: MemoryRow?
    var history: [String: [MemorySample]] = [:]
    var timer: Timer?
    var visibleRows: [MemoryRow] {
        rows.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (!onlyGrowing || $0.growing) }
            .sorted { byGrowth ? $0.delta > $1.delta : $0.bytes > $1.bytes }
    }
    func start() {
        refresh()
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, !self.paused { self.refresh() } }
        } }
    }
    func refresh() {
        guard !sampling else { return }; sampling = true
        let apps = NSWorkspace.shared.runningApplications.compactMap { a -> (String, String)? in
            guard let path = a.bundleURL?.path else { return nil }; return (a.localizedName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = ms_memory(); var pointer: UnsafeMutablePointer<MSProcess>?
            let count = Int(ms_processes(&pointer)); var raw: [RawProcess] = []
            if let p = pointer {
                for i in 0..<count {
                    let r = p[i]
                    raw.append(RawProcess(pid: r.pid, parent: r.parent, bytes: r.footprint, started: r.started, resident: r.resident, name: cString(r.name), executable: cString(r.executable), owner: cString(r.owner)))
                }
                ms_processes_free(p)
            }
            let lookup = Dictionary(uniqueKeysWithValues: raw.map { ($0.pid, $0) })
            func appPath(_ p: String) -> String? { guard let range = p.range(of: ".app/") else { return nil }; return String(p[..<range.lowerBound]) + ".app" }
            var groups: [String: (String, String, Int64, [Int32])] = [:]
            for r in raw {
                var bundle = appPath(r.executable)
                if !r.owner.isEmpty, let app = apps.first(where: { $0.0.localizedCaseInsensitiveContains(r.owner) }) { bundle = app.1 }
                var parent = r.parent; var visited = Set<Int32>()
                while bundle == nil, parent > 1, let p = lookup[parent], visited.insert(parent).inserted, visited.count < 24 {
                    bundle = appPath(p.executable); parent = p.parent
                }
                let key = bundle ?? "process:\(r.pid):\(r.started)"
                let name = bundle.map { b in apps.first(where: { $0.1 == b })?.0 ?? URL(fileURLWithPath: b).deletingPathExtension().lastPathComponent } ?? (r.name.isEmpty ? "Process \(r.pid)" : r.name)
                let old = groups[key]
                groups[key] = (name, bundle ?? r.executable, (old?.2 ?? 0) + Int64(r.bytes), (old?.3 ?? []) + [r.pid])
            }
            let values = groups
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; let now = Date()
                var next: [MemoryRow] = []
                for (key, value) in values {
                    var samples = self.history[key] ?? []
                    // A changed set of helper processes starts a new baseline, avoiding false leak alerts.
                    let details = value.3.compactMap { lookup[$0] }.map {
                        ProcessDetail(pid: $0.pid, name: $0.name, path: $0.executable, bytes: Int64($0.bytes), resident: Int64($0.resident), started: $0.started)
                    }.sorted { $0.bytes > $1.bytes }
                    if let old = self.rows.first(where: { $0.id == key }),
                       Set(old.details.map { "\($0.pid):\($0.started)" }) != Set(details.map { "\($0.pid):\($0.started)" }) { samples = [] }
                    samples.append(MemorySample(time: now, bytes: value.2)); samples = Array(samples.suffix(180))
                    self.history[key] = samples
                    next.append(MemoryRow(id: key, name: value.0, path: value.1, bytes: value.2, processes: value.3, samples: samples, details: details))
                }
                self.history = self.history.filter { values[$0.key] != nil }; self.rows = next.sorted { $0.bytes > $1.bytes }
                self.stats = info; self.updated = now; self.sampling = false
            }
        }
    }
    func reset() { history = [:]; rows = []; refresh() }
    func quit(_ row: MemoryRow) {
        guard row.path.hasSuffix(".app"), row.path != Bundle.main.bundleURL.path else { return }
        let alert = NSAlert(); alert.messageText = "Quit \(row.name)?"
        alert.informativeText = "MiniSweep will request a normal quit. Save work in this app first."
        alert.addButton(withTitle: "Quit app"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == row.path { app.terminate() }
        }
    }
}
