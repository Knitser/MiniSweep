import Foundation

// A worker builds this index from every file event and postorder directory event.
// After finish(), ownership transfers to the main actor and the index is read-only.
// The budget measures retained metadata, not the process's exact allocator usage.
final class StorageScanIndex: @unchecked Sendable {
    let root: String
    let maxEntries: Int
    let maxEstimatedBytes: Int
    private(set) var rootIdentity: FileIdentity?
    private(set) var scannedAt = Date()
    private(set) var completed = false
    private(set) var skipped = 0
    private(set) var directoryTruncated = false
    private(set) var fileTruncated = false
    private var directoryBytes = 0
    private var fileBytes = 0
    private var directoryRecords = 0
    private var fileRecords = 0
    private let directoryEntryLimit: Int
    private let fileEntryLimit: Int
    private let directoryByteLimit: Int
    private let fileByteLimit: Int
    var isTruncated: Bool { directoryTruncated || fileTruncated }
    var estimatedBytes: Int { directoryBytes + fileBytes }
    private var finished = false
    private var byPath: [String: FileNode] = [:]
    private var childrenByParent: [String: [String]] = [:]
    private var finalizedDirectories: Set<String> = []
    private var directoryOnlyFinalized: Set<String> = []
    private var failedDirectories: Set<String> = []
    private var largeNodes: [FileNode] = []
    var entryCount: Int { byPath.count }

    init(root: String, maxEntries: Int = 200_000, maxEstimatedBytes: Int = 64 * 1024 * 1024) {
        self.root = root
        self.maxEntries = max(0, maxEntries)
        self.maxEstimatedBytes = max(0, maxEstimatedBytes)
        let entries = max(0, maxEntries), bytes = max(0, maxEstimatedBytes)
        // Reserve directory aggregates independently: a million tiny files must
        // not prevent the scan's useful folder totals from remaining navigable.
        directoryEntryLimit = entries == 0 ? 0 : max(1, (entries / 10) * 7 + (entries % 10) * 7 / 10)
        fileEntryLimit = entries - directoryEntryLimit
        directoryByteLimit = bytes - bytes / 3
        fileByteLimit = bytes / 3
    }

    @discardableResult func append(_ node: FileNode) -> Bool {
        guard !finished, Self.contains(node.path, in: root),
              node.directory ? !directoryTruncated : !fileTruncated else { return false }
        if byPath[node.path] != nil {
            byPath[node.path] = node
            return true
        }
        let parent = Self.parent(of: node.path)
        let newBucket = node.path != root && childrenByParent[parent] == nil
        let isLargeFile = !node.directory && node.bytes >= 8 * 1024 * 1024
        // Includes dictionary slots, child references, directory-set membership,
        // string storage and (when applicable) the large-file reference.
        let cost = node.path.utf8.count + 192 + (newBucket ? parent.utf8.count + 112 : 0) + (isLargeFile ? 80 : 0) + (node.directory ? 32 : 0)
        if node.directory {
            guard directoryRecords < directoryEntryLimit, cost <= directoryByteLimit - directoryBytes else {
                directoryTruncated = true
                return false
            }
            directoryRecords += 1; directoryBytes += cost
        } else {
            guard fileRecords < fileEntryLimit, cost <= fileByteLimit - fileBytes else {
                fileTruncated = true
                return false
            }
            fileRecords += 1; fileBytes += cost
        }
        byPath[node.path] = node
        if node.path != root { childrenByParent[parent, default: []].append(node.path) }
        if isLargeFile { largeNodes.append(node) }
        if node.directory && !failedDirectories.contains(node.path) {
            directoryOnlyFinalized.insert(node.path)
            if !fileTruncated { finalizedDirectories.insert(node.path) }
        }
        return true
    }

    func recordError(at path: String) {
        guard !finished, !directoryTruncated, Self.contains(path, in: root), !failedDirectories.contains(path) else { return }
        let cost = path.utf8.count + 96
        guard directoryRecords < directoryEntryLimit, cost <= directoryByteLimit - directoryBytes else {
            directoryTruncated = true
            return
        }
        directoryRecords += 1; directoryBytes += cost
        failedDirectories.insert(path)
        finalizedDirectories.remove(path)
        directoryOnlyFinalized.remove(path)
    }

    func finish(completed: Bool, skipped: Int, rootIdentity: FileIdentity?, date: Date = Date()) {
        guard !finished else { return }
        self.completed = completed
        self.skipped = skipped
        self.rootIdentity = rootIdentity
        self.scannedAt = date
        finished = true
    }

    // nil means the folder needs a new scan; [] means a retained empty folder.
    // A completed ancestor may have inaccessible descendants, so consumers must
    // keep the scan's skipped/partial label instead of treating its totals as full.
    func indexedChildren(of path: String) -> [FileNode]? {
        guard finished, completed, finalizedDirectories.contains(path) else { return nil }
        return (childrenByParent[path] ?? []).compactMap { byPath[$0] }
    }

    // A shallow metadata refresh can supply current immediate files while these
    // retained directory aggregates avoid recursively rescanning their contents.
    // nil means even the directory list's coverage is incomplete; [] is valid.
    func indexedDirectoryChildren(of path: String) -> [FileNode]? {
        guard finished, completed, directoryOnlyFinalized.contains(path) else { return nil }
        return (childrenByParent[path] ?? []).compactMap { child in
            guard let node = byPath[child], node.directory else { return nil }
            return node
        }
    }

    func node(at path: String) -> FileNode? { byPath[path] }

    // This list is complete for a finalized folder even if a later sibling caused
    // the index to hit its budget. Uncached folders must be rescanned instead.
    func largeFiles(in path: String, limit: Int = 100) -> [FileNode] {
        guard finished, completed, finalizedDirectories.contains(path), limit > 0 else { return [] }
        return Array(largeNodes.filter { Self.contains($0.path, in: path) }.sorted {
            $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
        }.prefix(limit))
    }

    // Matching the anchor prevents reuse after a volume/folder is replaced. It
    // does not imply nested paths are unchanged: the UI must retain scan time and
    // offer Refresh, and cached totals must not create a fresh growth baseline.
    func matchesRootIdentity(_ current: FileIdentity?) -> Bool {
        guard let saved = rootIdentity, let current else { return false }
        return saved.device == current.device && saved.inode == current.inode
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
