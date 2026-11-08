import SwiftUI
import AppKit

struct StorageEntry: Codable {
    let path: String
    let bytes: Int64
    let files: UInt64
    let directory: Bool
}
struct StorageBaseline: Codable {
    let root: String
    let date: Date
    let bytes: Int64
    let device: Int32
    let inode: UInt64
    let entries: [StorageEntry]
    static func capture(root: String, nodes: [FileNode], date: Date = Date()) -> StorageBaseline? {
        guard let item = nodes.first(where: { $0.path == root && $0.directory }), let identity = FileIdentity.read(root) else { return nil }
        let children = nodes.filter { $0.parent == root && $0.path != root }
        guard children.count <= 10_000 else { return nil }
        return StorageBaseline(root: root, date: date, bytes: item.bytes, device: identity.device, inode: identity.inode,
            entries: children.map { StorageEntry(path: $0.path, bytes: $0.bytes, files: $0.files, directory: $0.directory) })
    }
}
struct StorageChange: Identifiable {
    let path: String
    let before: Int64
    let after: Int64
    let wasPresent: Bool
    let isPresent: Bool
    var id: String { path }
    var delta: Int64 { after - before }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var kind: String { !wasPresent ? "Added" : !isPresent ? "Removed" : delta > 0 ? "Grew" : "Shrank" }
}
struct StorageComparison {
    let baseline: StorageBaseline
    let current: StorageBaseline
    var delta: Int64 { current.bytes - baseline.bytes }
    var changes: [StorageChange] {
        let old = Dictionary(baseline.entries.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(current.entries.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).compactMap { path in
            let before = old[path], after = new[path]
            guard before != after else { return nil }
            return StorageChange(path: path, before: before ?? 0, after: after ?? 0, wasPresent: before != nil, isPresent: after != nil)
        }.sorted { abs($0.delta) == abs($1.delta) ? $0.path < $1.path : abs($0.delta) > abs($1.delta) }
    }
}

@MainActor final class GrowthLensStore {
    private let file: URL
    private(set) var baselines: [StorageBaseline] = []
    private(set) var loadError: String?
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniSweep", isDirectory: true).appendingPathComponent("growth-baselines-v1.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: self.file.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 20 * 1024 * 1024 else { throw NSError(domain: "MiniSweep", code: 1) }
                baselines = Array(try JSONDecoder().decode([StorageBaseline].self, from: Data(contentsOf: self.file)).filter { $0.entries.count <= 10_000 }.suffix(10))
            }
            catch { loadError = "Saved baselines could not be read. Reset the baseline to start a new comparison." }
        }
    }
    func baseline(for root: String) -> StorageBaseline? { baselines.first { $0.root == root } }
    func save(_ snapshot: StorageBaseline) throws {
        var next = baselines.filter { $0.root != snapshot.root }; next.append(snapshot); next = Array(next.suffix(10))
        try write(next); baselines = next; loadError = nil
    }
    func remove(_ root: String) throws {
        let next = baselines.filter { $0.root != root }; try write(next); baselines = next; loadError = nil
    }
    private func write(_ values: [StorageBaseline]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count <= 20 * 1024 * 1024 else { throw NSError(domain: "MiniSweep", code: 2, userInfo: [NSLocalizedDescriptionKey: "This baseline is too large; choose a smaller folder."]) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct GrowthLensPanel: View {
    @ObservedObject var model: SweepModel
    private func deltaText(_ n: Int64) -> String { (n < 0 ? "−" : "+") + byteText(abs(n)) }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Storage Growth Lens", systemImage: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold))
                        Text("See which immediate children grew, shrank, appeared or disappeared.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button("Set baseline") { model.setGrowthBaseline() }.buttonStyle(QuietButton()).disabled(model.latestSnapshot == nil || !model.scanComplete || model.skipped > 0)
                    Button { model.clearGrowthBaseline() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Forget this folder’s saved baseline")
                }
                if let comparison = model.growthComparison {
                    HStack {
                        Text(deltaText(comparison.delta)).font(.system(size: 27, weight: .semibold, design: .monospaced)).foregroundStyle(comparison.delta > 0 ? .orange : Palette.green)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("Since " + comparison.baseline.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11, weight: .medium))
                            Text("\(comparison.changes.count) changed items · allocated size").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        }
                    }
                    if comparison.changes.isEmpty { Text("No allocated-size changes since this baseline. Rescan after files change to compare.").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    ForEach(comparison.changes.prefix(12)) { change in
                        HStack(spacing: 12) {
                            Image(systemName: change.isPresent ? "arrow.up.right" : "minus.circle").foregroundStyle(change.delta > 0 ? .orange : Palette.green).frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(change.kind) · \(byteText(change.before)) → \(byteText(change.after))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Text(deltaText(change.delta)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Button("Inspect") { if let item = model.nodes.first(where: { $0.path == change.path }) { model.inspected = item } }.buttonStyle(QuietButton()).disabled(!change.isPresent)
                        }.padding(.vertical, 5)
                    }
                }
                if !model.growthNotice.isEmpty { Text(model.growthNotice).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                Text("Baselines store names and sizes locally for up to 10 folders. Comparisons require a complete readable scan. Shared APFS blocks may be counted more than once; a growth signal does not imply junk or a leak.").font(.system(size: 9)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
