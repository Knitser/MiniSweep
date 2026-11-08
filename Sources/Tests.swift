import Foundation
import Darwin

func scanSynchronously(_ root: String, cancelled: Bool = false) -> (ScanCollector, Int32) {
    let collector = ScanCollector { _, _, _, _, _ in }
    guard let handle = ms_scan_create() else { return (collector, ENOMEM) }
    if cancelled { ms_scan_cancel(handle) }
    let result = ms_scan_run(handle, root, 3, scanCallback, Unmanaged.passUnretained(collector).toOpaque())
    ms_scan_destroy(handle); return (collector, result)
}
func runScanCLI(_ path: String) -> Int32 {
    let (collector, code) = scanSynchronously(path)
    let report: [String: Any] = ["path": path, "result": code, "skipped": collector.skipped,
        "nodes": collector.nodes.map { ["path": $0.path, "allocated": $0.bytes, "logical": $0.logical, "files": $0.files, "directory": $0.directory] as [String: Any] }, "errors": collector.errors,
        "fileTypes": collector.fileTypes.values.sorted { $0.bytes > $1.bytes }.map { ["extension": $0.extensionName, "allocated": $0.bytes, "logical": $0.logical, "count": $0.count] as [String: Any] }]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
    return code == 0 ? 0 : 1
}
func runMemoryCLI() -> Int32 {
    var ptr: UnsafeMutablePointer<MSProcess>?
    let n = Int(ms_processes(&ptr)); let stats = ms_memory(); var rows: [[String: Any]] = []
    if let ptr {
        for i in 0..<n { let p = ptr[i]; rows.append(["pid": p.pid, "parent": p.parent, "name": cString(p.name), "bytes": p.footprint, "owner": cString(p.owner), "executable": cString(p.executable), "storage": cString(p.storage)]) }
        ms_processes_free(ptr)
    }
    let report: [String: Any] = ["physical": stats.physical, "compressed": stats.compressed, "swap": stats.swap_used, "processes": rows.sorted { ($0["bytes"] as? UInt64 ?? 0) > ($1["bytes"] as? UInt64 ?? 0) }]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
    return n > 0 ? 0 : 1
}

func runTrashSelfTest() -> Int32 {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("MiniSweep-trash-test-" + UUID().uuidString)
    let file = folder.appendingPathComponent("MiniSweep disposable test.txt")
    var trashed: NSURL?
    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("MiniSweep disposable round-trip test".utf8).write(to: file)
        try fm.trashItem(at: file, resultingItemURL: &trashed)
        guard !fm.fileExists(atPath: file.path), let destination = trashed as URL?, fm.fileExists(atPath: destination.path) else {
            print("FAIL: Trash did not produce a recoverable item"); return 1
        }
        try fm.moveItem(at: destination, to: file)
        guard try String(contentsOf: file, encoding: .utf8) == "MiniSweep disposable round-trip test" else { return 1 }
        try fm.removeItem(at: folder)
        print("PASS: disposable file moved to Trash, restored intact, and test fixture removed")
        return 0
    } catch {
        // Leave any recoverable test file in Trash on failure; never remove a failed restore permanently.
        print("FAIL: \(error.localizedDescription)"); return 1
    }
}

@MainActor func runSelfTests() -> Int32 {
    var failures: [String] = []; var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) { checks += 1; if !condition() { failures.append(name) } }
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("MiniSweep-tests-" + UUID().uuidString)
    defer { try? fm.removeItem(at: temp) }
    do {
        let home = temp.appendingPathComponent("home")
        let downloads = home.appendingPathComponent("Downloads")
        let deep = downloads.appendingPathComponent("nested/deeper")
        let outside = temp.appendingPathComponent("outside")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/demo"), withIntermediateDirectories: true)
        try Data(repeating: 0x37, count: 3 * 1024 * 1024).write(to: deep.appendingPathComponent("three.bin"))
        try Data(repeating: 0x51, count: 9 * 1024 * 1024).write(to: outside.appendingPathComponent("outside.bin"))
        let sparse = downloads.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: Data())
        let handle = try FileHandle(forWritingTo: sparse); try handle.truncate(atOffset: 100 * 1024 * 1024); try handle.close()
        try fm.createSymbolicLink(atPath: downloads.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
        let (scan, result) = scanSynchronously(downloads.path)
        check(result == 0, "scanner completes")
        let root = scan.nodes.first { $0.path == downloads.path }
        check(root != nil && root!.files == 3, "nested counts include symlink once")
        check(!scan.nodes.contains { $0.path.hasSuffix("outside.bin") }, "scanner never follows directory symlinks")
        let sparseNode = scan.nodes.first { $0.path == sparse.path }
        check(sparseNode?.logical == 100 * 1024 * 1024, "logical sparse-file size retained")
        check((sparseNode?.bytes ?? Int64.max) < 1024 * 1024, "sparse file not counted at logical size")
        check((root?.bytes ?? 0) >= 3 * 1024 * 1024 && (root?.bytes ?? Int64.max) < 5 * 1024 * 1024, "ancestor allocated totals exclude linked external files")
        check(scan.fileTypes["bin"]?.count == 2, "file type totals include nested small and sparse files")
        check(scan.fileTypes["bin"]?.logical == 103 * 1024 * 1024, "file type logical totals preserve sparse-file lengths")
        check(scan.fileTypes.values.reduce(UInt64(0)) { $0 + $1.count } == 2, "file type totals exclude symbolic links and their targets")
        let manyTypes = ScanCollector { _, _, _, _, _ in }
        for i in 0..<1000 { manyTypes.event(path: "type\(i)", kind: 5, allocated: 10, logical: 10, files: 1, error: 0) }
        check(manyTypes.fileTypes.count <= 513 && manyTypes.fileTypes.values.reduce(UInt64(0)) { $0 + $1.count } == 1000, "rare file types are bounded without losing total counts")
        let (_, cancelled) = scanSynchronously(downloads.path, cancelled: true)
        check(cancelled == ECANCELED, "cancellation stops before traversal")
        let (_, missing) = scanSynchronously(temp.appendingPathComponent("missing").path)
        // fts reports a missing root as a readable error event, not a fabricated total.
        let (notFound, _) = scanSynchronously(temp.appendingPathComponent("missing").path)
        check(missing != 0 || notFound.skipped > 0, "missing paths are reported")
        let policy = CleanupPolicy(home: home.path)
        check(policy.refusal("/", runningBundles: []) != nil, "filesystem root protected")
        check(policy.refusal(home.path, runningBundles: []) != nil, "home root protected")
        check(policy.refusal(home.path + "/Library", runningBundles: []) != nil, "Library protected")
        check(policy.refusal(home.path + "/Library/Caches", runningBundles: []) != nil, "entire cache root protected")
        check(policy.refusal(home.path + "/Library/Mail", runningBundles: []) != nil, "private app data protected")
        check(policy.refusal(home.path + "/.ssh/key", runningBundles: []) != nil, "hidden credentials protected")
        check(policy.refusal(home.path + "/Downloads/../Library", runningBundles: []) != nil, "noncanonical paths rejected")
        check(policy.refusal(home.path + "/Library/Caches/demo", runningBundles: []) == nil, "specific recognized cache allowed")
        check(policy.refusal(sparse.path, runningBundles: []) == nil, "personal file allowed")
        check(policy.refusal(downloads.appendingPathComponent("outside-link").path, runningBundles: []) != nil, "escaped symlink blocked")
        try fm.createSymbolicLink(atPath: home.appendingPathComponent("Library/Caches/escape").path, withDestinationPath: downloads.path)
        check(policy.refusal(home.path + "/Library/Caches/escape", runningBundles: []) != nil, "cache symlink escape blocked")
        check(policy.refusal("/Applications/Demo.app", runningBundles: ["/Applications/Demo.app"]) != nil, "running app protected")
        check(policy.refusal("/Applications", runningBundles: []) != nil, "Applications root protected")
        check(policy.refusal("/System/Applications/Demo.app", runningBundles: []) != nil, "system application protected")
        check(policy.refusal("/Applications/Demo.app/Contents/data", runningBundles: []) != nil, "app internals cannot be removed piecemeal")
        let identity = FileIdentity.read(sparse.path)
        try fm.moveItem(at: sparse, to: downloads.appendingPathComponent("old.bin"))
        try Data("replacement".utf8).write(to: sparse)
        check(FileIdentity.read(sparse.path) != identity, "replaced files detected before trashing")
        let editedIdentity = FileIdentity.read(sparse.path)
        let editor = try FileHandle(forWritingTo: sparse)
        try editor.truncate(atOffset: 0); try editor.write(contentsOf: Data("changed after review with the same inode".utf8)); try editor.close()
        check(FileIdentity.read(sparse.path)?.inode == editedIdentity?.inode, "in-place edit keeps the test inode")
        check(FileIdentity.read(sparse.path) != editedIdentity, "in-place edits invalidate a cleanup review")
        let now = Date(); let baseline: Int64 = 500 * 1024 * 1024
        let rising = (0..<8).map { MemorySample(time: now.addingTimeInterval(Double($0 * 5)), bytes: baseline + Int64($0) * 32 * 1024 * 1024) }
        let growth = MemoryRow(id: "test", name: "Test", path: "", bytes: rising.last!.bytes, processes: [1], samples: rising)
        check(growth.growing, "sustained memory growth flagged")
        check(growth.peak == rising.last!.bytes && growth.observationSeconds == 35, "memory inspector peak and observation duration match samples")
        let warmup = MemoryRow(id: "test", name: "Test", path: "", bytes: rising[2].bytes, processes: [1], samples: Array(rising.prefix(3)))
        check(!warmup.growing, "short memory spikes do not trigger growth watch")
        let flat = (0..<8).map { MemorySample(time: now.addingTimeInterval(Double($0 * 5)), bytes: baseline) }
        check(!MemoryRow(id: "test", name: "Test", path: "", bytes: baseline, processes: [1], samples: flat).growing, "stable memory is not flagged")
        let tiles = mapLayout(scan.nodes.filter { $0.parent == downloads.path }, size: CGSize(width: 640, height: 320))
        check(!tiles.isEmpty && tiles.allSatisfy { $0.rect.width >= 0 && $0.rect.height >= 0 && $0.rect.maxX <= 640 && $0.rect.maxY <= 320 }, "treemap stays in bounds")
        let uneven = (0..<300).map { FileNode(path: "/fixture/\($0)", bytes: $0 == 0 ? 1_000_000_000 : 1, logical: 0, files: 1, directory: true) }
        let compact = mapLayout(uneven, size: CGSize(width: 320, height: 200))
        check(compact.count == 65 && compact.allSatisfy { $0.rect.width >= 0 && $0.rect.height >= 0 && $0.rect.maxX <= 320 && $0.rect.maxY <= 200 }, "tiny treemap blocks remain in bounds and preserve the all-items group")
        let diskBaseline = StorageBaseline(root: downloads.path, date: now.addingTimeInterval(-3600), bytes: 100, device: 1, inode: 2, entries: [
            StorageEntry(path: downloads.path + "/growing", bytes: 60, files: 2, directory: true),
            StorageEntry(path: downloads.path + "/removed", bytes: 40, files: 1, directory: false)])
        let current = StorageBaseline(root: downloads.path, date: now, bytes: 120, device: 1, inode: 2, entries: [
            StorageEntry(path: downloads.path + "/growing", bytes: 80, files: 3, directory: true),
            StorageEntry(path: downloads.path + "/new", bytes: 40, files: 1, directory: false)])
        let comparison = StorageComparison(baseline: diskBaseline, current: current)
        check(comparison.delta == 20 && comparison.changes.count == 3, "growth lens reconciles added, removed and resized paths")
        check(comparison.changes.first(where: { $0.name == "removed" })?.kind == "Removed", "removed paths stay distinct from files that shrank")
        check(comparison.changes.first(where: { $0.name == "new" })?.kind == "Added", "new paths are identified")
        let zero = StorageBaseline(root: downloads.path, date: now, bytes: 100, device: 1, inode: 2, entries: diskBaseline.entries + [StorageEntry(path: downloads.path + "/empty", bytes: 0, files: 0, directory: false)])
        check(StorageComparison(baseline: diskBaseline, current: zero).changes.first?.kind == "Added", "zero-byte additions remain visible")
        let baselineFile = temp.appendingPathComponent("private-baselines.json")
        let store = GrowthLensStore(file: baselineFile)
        try store.save(diskBaseline)
        let loaded = GrowthLensStore(file: baselineFile)
        check(loaded.baseline(for: downloads.path)?.date == diskBaseline.date, "growth baselines persist between sessions")
        let storedAttributes = try fm.attributesOfItem(atPath: baselineFile.path)
        check((storedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "baseline files use owner-only permissions")
        let lensModel = SweepModel(growthStore: loaded)
        lensModel.root = downloads.path; lensModel.nodes = scan.nodes; lensModel.scanComplete = true; lensModel.skipped = 1
        lensModel.updateGrowthLens()
        check(lensModel.growthComparison == nil && loaded.baseline(for: downloads.path)?.date == diskBaseline.date, "inaccessible folders cannot create false removal comparisons or overwrite baselines")
        try loaded.remove(downloads.path)
        check(GrowthLensStore(file: baselineFile).baseline(for: downloads.path) == nil, "saved baselines can be cleared")
        try Data("corrupt baseline".utf8).write(to: baselineFile)
        check(GrowthLensStore(file: baselineFile).loadError != nil, "corrupt baseline data is reported rather than silently trusted")
        check(StorageBaseline.capture(root: downloads.path, nodes: scan.nodes) != nil, "complete folder snapshots retain filesystem identity")
        func vmContext(_ path: String) -> (String, String) {
            var owner = [CChar](repeating: 0, count: 64), storage = [CChar](repeating: 0, count: 4096)
            path.withCString { p in owner.withUnsafeMutableBufferPointer { o in storage.withUnsafeMutableBufferPointer { d in
                ms_vm_path_context(p, o.baseAddress, o.count, d.baseAddress, d.count)
            } } }
            return (String(cString: owner), String(cString: storage))
        }
        let vmBundle = "/fixture/Library/Application Support/Claude/vm_bundles/example.bundle"
        check(vmContext(vmBundle + "/rootfs.img").1 == vmBundle, "VM disk attribution maps a bundle rather than an individual backing file")
        check(vmContext("/fixture/Library/Application Support/Claude/claude-code/runtime").1.isEmpty, "ordinary helper executables are not misidentified as VM storage")
        let dockerDisk = "/fixture/Library/Containers/com.docker.docker/Data/vms/0/data"
        check(vmContext(dockerDisk + "/Docker.raw").1 == dockerDisk, "Docker disk attribution identifies the VM data directory")
        check(vmContext(dockerDisk + "/Docker.raw.log").1.isEmpty, "logs named after a disk image are not classified as backing disks")
    } catch { failures.append(error.localizedDescription) }
    print("MiniSweep: \(checks - failures.count)/\(checks) checks passed")
    for failure in failures { print("FAIL: " + failure) }
    return failures.isEmpty ? 0 : 1
}
