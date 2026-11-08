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
        "nodes": collector.nodes.map { ["path": $0.path, "allocated": $0.bytes, "logical": $0.logical, "files": $0.files, "directory": $0.directory] as [String: Any] }, "errors": collector.errors]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
    return code == 0 ? 0 : 1
}
func runMemoryCLI() -> Int32 {
    var ptr: UnsafeMutablePointer<MSProcess>?
    let n = Int(ms_processes(&ptr)); let stats = ms_memory(); var rows: [[String: Any]] = []
    if let ptr {
        for i in 0..<n { let p = ptr[i]; rows.append(["pid": p.pid, "parent": p.parent, "name": cString(p.name), "bytes": p.footprint, "owner": cString(p.owner), "executable": cString(p.executable)]) }
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

func runSelfTests() -> Int32 {
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
        let now = Date(); let baseline: Int64 = 500 * 1024 * 1024
        let rising = (0..<8).map { MemorySample(time: now.addingTimeInterval(Double($0 * 5)), bytes: baseline + Int64($0) * 32 * 1024 * 1024) }
        let growth = MemoryRow(id: "test", name: "Test", path: "", bytes: rising.last!.bytes, processes: [1], samples: rising)
        check(growth.growing, "sustained memory growth flagged")
        let warmup = MemoryRow(id: "test", name: "Test", path: "", bytes: rising[2].bytes, processes: [1], samples: Array(rising.prefix(3)))
        check(!warmup.growing, "short memory spikes do not trigger growth watch")
        let flat = (0..<8).map { MemorySample(time: now.addingTimeInterval(Double($0 * 5)), bytes: baseline) }
        check(!MemoryRow(id: "test", name: "Test", path: "", bytes: baseline, processes: [1], samples: flat).growing, "stable memory is not flagged")
        let tiles = mapLayout(scan.nodes.filter { $0.parent == downloads.path }, size: CGSize(width: 640, height: 320))
        check(!tiles.isEmpty && tiles.allSatisfy { $0.rect.width >= 0 && $0.rect.height >= 0 && $0.rect.maxX <= 640 && $0.rect.maxY <= 320 }, "treemap stays in bounds")
    } catch { failures.append(error.localizedDescription) }
    print("MiniSweep: \(checks - failures.count)/\(checks) checks passed")
    for failure in failures { print("FAIL: " + failure) }
    return failures.isEmpty ? 0 : 1
}
