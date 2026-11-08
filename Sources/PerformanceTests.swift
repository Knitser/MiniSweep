import Foundation
import Darwin

private struct StorageCheckTypeTotal: Equatable {
    var bytes: Int64 = 0
    var logical: Int64 = 0
    var count: UInt64 = 0
}

private final class StorageCheckCollector {
    let collector: ScanCollector
    var types: [String: StorageCheckTypeTotal] = [:]
    var errorCodes: [Int32: Int] = [:]
    init(index: StorageScanIndex? = nil) { collector = ScanCollector(index: index) { _ in } }
    func event(path: String, kind: Int32, allocated: Int64, logical: Int64, files: UInt64, error: Int32) {
        collector.event(path: path, kind: kind, allocated: allocated, logical: logical, files: files, error: error)
        if kind == 5 {
            var total = types[path] ?? StorageCheckTypeTotal()
            total.bytes += allocated; total.logical += logical; total.count += files
            types[path] = total
        } else if kind == 4 { errorCodes[error, default: 0] += 1 }
    }
}

private let storageCheckCallback: MSScanCallback = { context, path, kind, allocated, logical, files, error in
    guard let context, let path else { return }
    Unmanaged<StorageCheckCollector>.fromOpaque(context).takeUnretainedValue().event(
        path: String(cString: path), kind: kind, allocated: allocated, logical: logical, files: files, error: error)
}

@MainActor func runStoragePerformanceChecks(_ check: (Bool, String) -> Void, directory: URL) throws {
    let manager = FileManager.default
    let fixture = directory.appendingPathComponent("scan-performance")
    let nested = fixture.appendingPathComponent("nested/deeper")
    let empty = fixture.appendingPathComponent("empty")
    let outside = directory.appendingPathComponent("scan-performance-outside")
    try manager.createDirectory(at: nested, withIntermediateDirectories: true)
    try manager.createDirectory(at: empty, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    for i in 0..<540 {
        let folder = i % 3 == 0 ? fixture : i % 3 == 1 ? nested : nested.deletingLastPathComponent()
        try Data(repeating: UInt8(i % 251), count: [0, 63, 4097][i % 3]).write(to: folder.appendingPathComponent("item\(i).ext\(i)"))
    }
    try Data("Unicode metadata".utf8).write(to: nested.appendingPathComponent("空 🧹.small"))
    try Data(repeating: 0x43, count: 8 * 1024 * 1024).write(to: nested.appendingPathComponent("large.payload"))
    try Data("Do not traverse this symlink target".utf8).write(to: outside.appendingPathComponent("outside.txt"))
    let sparse = nested.appendingPathComponent("sparse.payload")
    manager.createFile(atPath: sparse.path, contents: Data())
    let sparseHandle = try FileHandle(forWritingTo: sparse)
    try sparseHandle.truncate(atOffset: 64 * 1024 * 1024); try sparseHandle.close()
    try manager.createSymbolicLink(at: fixture.appendingPathComponent("outside-link"), withDestinationURL: outside)
    try manager.createSymbolicLink(at: nested.appendingPathComponent("cycle-link"), withDestinationURL: fixture)
    guard let identity = FileIdentity.read(fixture.path) else { throw NSError(domain: "MiniSweep", code: 4) }

    typealias Scanner = (OpaquePointer?, UnsafePointer<CChar>?, Int32, MSScanCallback?, UnsafeMutableRawPointer?) -> Int32
    func run(_ scanner: Scanner, root: String, index: StorageScanIndex? = nil) -> (StorageCheckCollector, Int32, TimeInterval) {
        let result = StorageCheckCollector(index: index)
        guard let handle = ms_scan_create() else { return (result, ENOMEM, 0) }
        defer { ms_scan_destroy(handle) }
        let start = Date()
        let code = root.withCString { scanner(handle, $0, Int32.max, storageCheckCallback, Unmanaged.passUnretained(result).toOpaque()) }
        return (result, code, Date().timeIntervalSince(start))
    }
    let index = StorageScanIndex(root: fixture.path)
    let current = run(ms_scan_run, root: fixture.path, index: index)
    let reference = run(ms_scan_run_reference, root: fixture.path)
    let bulk = run(ms_scan_run_bulk, root: fixture.path)
    index.finish(completed: current.1 == 0, skipped: current.0.collector.skipped, rootIdentity: identity)
    func sortedNodes(_ value: StorageCheckCollector) -> [FileNode] { value.collector.nodes.sorted { $0.path < $1.path } }
    func boundedTotals(_ value: StorageCheckCollector) -> StorageCheckTypeTotal {
        value.collector.fileTypes.values.reduce(StorageCheckTypeTotal()) {
            StorageCheckTypeTotal(bytes: $0.bytes + $1.bytes, logical: $0.logical + $1.logical, count: $0.count + $1.count)
        }
    }
    let missingPath = directory.appendingPathComponent("performance-missing-root").path
    let missing = [run(ms_scan_run, root: missingPath), run(ms_scan_run_reference, root: missingPath), run(ms_scan_run_bulk, root: missingPath)]
    let parity = current.1 == 0 && reference.1 == 0 && bulk.1 == 0 &&
        sortedNodes(current.0) == sortedNodes(reference.0) && sortedNodes(current.0) == sortedNodes(bulk.0) &&
        current.0.types == reference.0.types && current.0.types == bulk.0.types && current.0.types.count > 512 &&
        current.0.errorCodes == reference.0.errorCodes && current.0.errorCodes == bulk.0.errorCodes &&
        boundedTotals(current.0) == boundedTotals(reference.0) && boundedTotals(current.0) == boundedTotals(bulk.0) &&
        [current.0, reference.0, bulk.0].allSatisfy { $0.collector.fileTypes.count <= 513 } &&
        missing.allSatisfy { $0.0.errorCodes == missing[0].0.errorCodes && !$0.0.errorCodes.isEmpty }
    check(parity, "default, reference and bulk scans preserve every node, extension total and error class across a mixed 540-type filesystem fixture")
    print(String(format: "Metadata fixture: default %.3fs · reference %.3fs · bulk %.3fs (no timing threshold)", current.2, reference.2, bulk.2))

    let capRoot = fixture.path + "/bounded-index"
    func item(_ path: String, directory: Bool, bytes: Int64 = 0) -> FileNode {
        FileNode(path: path, bytes: bytes, logical: bytes, files: 1, directory: directory)
    }
    let capped = StorageScanIndex(root: capRoot, maxEntries: 6)
    capped.append(item(capRoot + "/a/file", directory: false, bytes: 9 * 1024 * 1024))
    capped.append(item(capRoot + "/a", directory: true))
    capped.append(item(capRoot + "/b/file", directory: false))
    capped.append(item(capRoot + "/b", directory: true))
    capped.append(item(capRoot + "/overflow", directory: false))
    capped.append(item(capRoot + "/c", directory: true))
    capped.append(item(capRoot, directory: true))
    capped.finish(completed: true, skipped: 0, rootIdentity: identity)
    let directoryCapped = StorageScanIndex(root: capRoot, maxEntries: 6)
    for number in 0..<5 { directoryCapped.append(item(capRoot + "/folder\(number)", directory: true)) }
    let fileAfterDirectoryCap = directoryCapped.append(item(capRoot + "/file", directory: false))
    directoryCapped.append(item(capRoot, directory: true))
    directoryCapped.finish(completed: true, skipped: 0, rootIdentity: identity)
    let failed = StorageScanIndex(root: capRoot)
    failed.recordError(at: capRoot + "/denied"); failed.append(item(capRoot + "/denied", directory: true))
    failed.finish(completed: true, skipped: 1, rootIdentity: identity)
    let cancelled = StorageScanIndex(root: capRoot)
    cancelled.append(item(capRoot, directory: true)); cancelled.finish(completed: false, skipped: 0, rootIdentity: identity)
    let provisional = StorageScanIndex(root: capRoot)
    let provisionalCollector = ScanCollector(rootPath: capRoot, index: provisional) { _ in }
    provisionalCollector.event(path: capRoot + "/preview", kind: 6, allocated: 100, logical: 100, files: 1, error: 0)
    provisional.finish(completed: true, skipped: 0, rootIdentity: identity)
    let expectedChildren = current.0.collector.nodes.filter { $0.parent == fixture.path }.sorted { $0.path < $1.path }
    check(index.indexedChildren(of: fixture.path)?.sorted { $0.path < $1.path } == expectedChildren &&
        index.indexedChildren(of: empty.path)?.isEmpty == true && index.largeFiles(in: nested.path).count == 1 &&
        capped.isTruncated && capped.fileTruncated && !capped.directoryTruncated && capped.entryCount == 6 &&
        capped.indexedChildren(of: capRoot + "/a")?.count == 1 && capped.indexedChildren(of: capRoot) == nil &&
        capped.indexedDirectoryChildren(of: capRoot)?.count == 3 && capped.node(at: capRoot) != nil &&
        directoryCapped.directoryTruncated && fileAfterDirectoryCap && !directoryCapped.fileTruncated &&
        directoryCapped.indexedDirectoryChildren(of: capRoot) == nil &&
        directoryCapped.indexedDirectoryChildren(of: capRoot + "/folder0")?.isEmpty == true &&
        capped.estimatedBytes <= capped.maxEstimatedBytes && failed.indexedChildren(of: capRoot + "/denied") == nil &&
        failed.indexedDirectoryChildren(of: capRoot + "/denied") == nil &&
        cancelled.indexedChildren(of: capRoot) == nil && provisional.node(at: capRoot + "/preview") == nil &&
        cancelled.indexedDirectoryChildren(of: capRoot) == nil && provisional.indexedChildren(of: capRoot + "/preview") == nil &&
        provisional.indexedDirectoryChildren(of: capRoot + "/preview") == nil,
        "navigation index preserves folder aggregates after the file budget while distinguishing empty, incomplete, failed and provisional views")

    let shallow = run({ handle, path, _, callback, context in ms_scan_shallow(handle, path, callback, context) }, root: fixture.path)
    let shallowNodes = shallow.0.collector.nodes
    let shallowFiles = shallowNodes.filter { !$0.directory }.sorted { $0.path < $1.path }
    let expectedFiles = expectedChildren.filter { !$0.directory }
    let fileCappedIndex = StorageScanIndex(root: fixture.path, maxEntries: 40)
    for node in current.0.collector.nodes { fileCappedIndex.append(node) }
    fileCappedIndex.finish(completed: current.1 == 0, skipped: current.0.collector.skipped, rootIdentity: identity)
    let indexedDirectories = fileCappedIndex.indexedDirectoryChildren(of: fixture.path)
    let composed = ((indexedDirectories ?? []) + shallowFiles).sorted { $0.path < $1.path }
    let shallowParity = shallow.1 == 0 && shallow.0.errorCodes.isEmpty && shallow.0.types.isEmpty &&
        shallowNodes.count == expectedChildren.count && shallowNodes.allSatisfy { $0.path != fixture.path && $0.parent == fixture.path } &&
        shallowNodes.filter(\.directory).allSatisfy { $0.logical == 0 && $0.files == 0 } && shallowFiles == expectedFiles &&
        fileCappedIndex.fileTruncated && !fileCappedIndex.directoryTruncated && fileCappedIndex.indexedChildren(of: fixture.path) == nil &&
        indexedDirectories != nil && composed == expectedChildren

    let overviewFile = directory.appendingPathComponent("performance-overviews.json")
    let overviewStore = ScanOverviewStore(file: overviewFile)
    let snapshot = ScanOverview(root: fixture.path, date: index.scannedAt, identity: identity,
        nodes: current.0.collector.nodes.filter { $0.path == fixture.path || $0.parent == fixture.path },
        largest: current.0.collector.largest, fileTypes: Array(current.0.collector.fileTypes.values),
        skipped: current.0.collector.skipped, errorCounts: current.0.collector.errorCounts, errors: current.0.collector.errors, elapsed: current.2)
    try overviewStore.save(snapshot)
    let loaded = ScanOverviewStore(file: overviewFile)
    let differentIdentity = FileIdentity(device: identity.device, inode: identity.inode ^ 1, length: identity.length,
        modifiedSeconds: identity.modifiedSeconds, modifiedNanoseconds: identity.modifiedNanoseconds, mode: identity.mode)
    let permissions = try manager.attributesOfItem(atPath: overviewFile.path)[.posixPermissions] as? NSNumber
    let persisted = loaded.overview(for: fixture.path, identity: identity)
    try Data("corrupt overview".utf8).write(to: overviewFile)
    let corrupt = ScanOverviewStore(file: overviewFile)
    check(persisted?.nodes == snapshot.nodes && permissions?.intValue == 0o600 &&
        loaded.overview(for: fixture.path, identity: differentIdentity) == nil && corrupt.overviews.isEmpty && corrupt.loadError != nil,
        "saved overview metadata persists privately, rejects replaced folder identities and reports corrupt data")

    let growthStore = GrowthLensStore(file: directory.appendingPathComponent("performance-growth.json"))
    let model = SweepModel(growthStore: growthStore, overviewStore: loaded)
    model.scanIndex = index; model.sessionOverview = snapshot
    model.scan(nested.path)
    let instant = !model.isScanning && model.root == nested.path && model.overviewSource == "Indexed scan" && !model.scanComplete
    let fixtureFile = current.0.collector.nodes.first { !$0.directory && $0.parent == nested.path }
    var indexedCleanupBlocked = false
    if let fixtureFile {
        let reason = model.refusal(fixtureFile)
        model.addToQueue(fixtureFile)
        indexedCleanupBlocked = reason?.localizedCaseInsensitiveContains("refresh") == true && model.queue.isEmpty &&
            model.alert?.localizedCaseInsensitiveContains("refresh") == true
    }
    model.updateGrowthLens()
    let indexedNotFresh = model.latestSnapshot == nil && model.growthComparison == nil && growthStore.baseline(for: nested.path) == nil
    model.root = fixture.path; model.showOverview(snapshot, saved: true); model.updateGrowthLens()
    check(instant && indexedNotFresh && model.isSavedOverview && !model.scanComplete && model.latestSnapshot == nil &&
        model.growthComparison == nil && growthStore.baseline(for: fixture.path) == nil,
        "opening indexed folders avoids a new scan while indexed and saved views cannot create fresh Growth Lens baselines")
    check(shallowParity && indexedCleanupBlocked,
        "shallow file metadata plus retained directory totals matches a full folder view after file-cache saturation, while dated indexed storage blocks cleanup")
}
