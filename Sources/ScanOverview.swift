import Foundation
import Darwin

struct ScanOverview: Codable {
    let root: String
    let date: Date
    let identity: FileIdentity
    let nodes: [FileNode]
    let largest: [FileNode]
    let fileTypes: [FileTypeTotal]
    let skipped: Int
    var errorCounts: [String: Int]? = nil
    let errors: [String]
    let elapsed: TimeInterval
}

@MainActor final class ScanOverviewStore {
    private static let dataLimit = 4 * 1024 * 1024
    private let file: URL
    private(set) var overviews: [ScanOverview] = []
    private(set) var loadError: String?
    var latestRoot: String? { overviews.last?.root }

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniSweep", isDirectory: true).appendingPathComponent("scan-overviews-v1.json")
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            let data = try Self.read(self.file)
            let loaded = try JSONDecoder().decode([ScanOverview].self, from: data)
            guard loaded.count <= 3, Set(loaded.map(\.root)).count == loaded.count,
                  loaded.allSatisfy(Self.valid) else { throw Self.invalidData() }
            overviews = loaded.sorted { $0.date < $1.date }
        } catch {
            loadError = "Saved overviews could not be read. Refresh a folder to replace them."
        }
    }

    // The identity check validates the folder/volume, not the age of its contents.
    // Callers must label saved values with date and refresh before cleanup or a
    // new Growth Lens comparison. Reading this store never starts a disk scan.
    func overview(for root: String, identity: FileIdentity?) -> ScanOverview? {
        guard let identity else { return nil }
        return overviews.first {
            $0.root == root && $0.identity.device == identity.device && $0.identity.inode == identity.inode
        }
    }

    func save(_ snapshot: ScanOverview) throws {
        // Detailed errors are examples, while skipped/errorCounts retain totals.
        let bounded = ScanOverview(root: snapshot.root, date: snapshot.date, identity: snapshot.identity,
            nodes: snapshot.nodes, largest: snapshot.largest, fileTypes: snapshot.fileTypes,
            skipped: snapshot.skipped, errorCounts: snapshot.errorCounts, errors: Array(snapshot.errors.prefix(100)), elapsed: snapshot.elapsed)
        guard Self.valid(bounded), try JSONEncoder().encode([bounded]).count <= Self.dataLimit else { throw Self.invalidData() }
        var next = overviews.filter { $0.root != bounded.root }
        next.append(bounded)
        next.sort { $0.date < $1.date }
        next = Array(next.suffix(3))
        var data = try JSONEncoder().encode(next)
        while data.count > Self.dataLimit && next.count > 1 {
            next.removeFirst()
            data = try JSONEncoder().encode(next)
        }
        guard data.count <= Self.dataLimit else { throw Self.invalidData() }
        try write(data)
        overviews = next
        loadError = nil
    }

    func removeAll() throws {
        try write(JSONEncoder().encode([ScanOverview]()))
        overviews = []
        loadError = nil
    }

    private static func valid(_ value: ScanOverview) -> Bool {
        guard validPath(value.root), value.date.timeIntervalSince1970.isFinite,
              abs(value.date.timeIntervalSince1970) <= 1_000_000_000_000,
              value.identity.mode & 0o170000 == 0o040000,
              value.nodes.count <= 10_001, value.largest.count <= 100,
              value.fileTypes.count <= 513, value.errors.count <= 100,
              value.skipped >= 0, value.elapsed.isFinite, value.elapsed >= 0,
              Set(value.nodes.map(\.path)).count == value.nodes.count,
              Set(value.largest.map(\.path)).count == value.largest.count,
              Set(value.fileTypes.map(\.extensionName)).count == value.fileTypes.count,
              value.nodes.contains(where: { $0.path == value.root && $0.directory }) else { return false }
        guard value.nodes.allSatisfy({
            validNode($0) && ($0.path == value.root || parent(of: $0.path) == value.root)
        }), value.largest.allSatisfy({
            validNode($0) && !$0.directory && $0.path != value.root && contains($0.path, in: value.root)
        }), value.fileTypes.allSatisfy({
            $0.bytes >= 0 && $0.logical >= 0 && $0.extensionName.utf8.count <= 256 && !$0.extensionName.utf8.contains(0)
        }), value.errors.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) else { return false }
        if let counts = value.errorCounts {
            guard counts.count <= 100, counts.allSatisfy({
                $0.key.utf8.count <= 256 && !$0.key.utf8.contains(0) && $0.value >= 0
            }) else { return false }
        }
        return true
    }

    private static func validNode(_ node: FileNode) -> Bool {
        validPath(node.path) && node.bytes >= 0 && node.logical >= 0 && node.category.utf8.count <= 1024
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 32_768 && !path.utf8.contains(0) &&
            URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func invalidData() -> NSError {
        NSError(domain: "MiniSweep", code: 3, userInfo: [NSLocalizedDescriptionKey: "This overview exceeds the saved metadata limits or contains invalid entries."])
    }

    private static func read(_ file: URL) throws -> Data {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              attributes.st_mode & 0o170000 == 0o100000,
              attributes.st_size >= 0, attributes.st_size <= dataLimit else { throw invalidData() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, dataLimit + 1 - data.count))
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= dataLimit else { throw invalidData() }
        }
    }

    private func write(_ data: Data) throws {
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".overview-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor); Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, address.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count < 0 ? errno : EIO)) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
