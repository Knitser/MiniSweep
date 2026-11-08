import SwiftUI

struct SpaceGuide: View {
    @ObservedObject var model: SweepModel
    var body: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: "externaldrive.badge.minus").font(.system(size: 27)).foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find space to reclaim").font(.system(size: 19, weight: .semibold))
                        Text("Start with caches and downloads. Review a batch, then move only the items you choose to Trash.").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { model.openCleanup() } label: { Label("Find cleanup", systemImage: "magnifyingglass") }.buttonStyle(PrimaryButton())
                }
                HStack(spacing: 10) {
                    Button("Review Downloads") { model.openCleanup(category: "Review download") }.buttonStyle(QuietButton())
                    Button("Map all local data") { model.scan("/System/Volumes/Data") }.buttonStyle(QuietButton())
                    Spacer()
                    if !model.cleanupItems.isEmpty {
                        Button("\(byteText(model.cleanupItems.reduce(0) { $0 + $1.bytes })) to review →") { model.page = "Cleanup" }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green)
                    }
                }
                if let bytes = model.trashBytes, bytes > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "trash.fill").foregroundStyle(.orange)
                        Text("Already in Trash: \(byteText(bytes))").font(.system(size: 13, weight: .semibold))
                        Text("Review it, then empty it in Finder to reclaim space.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button("Review Trash") { model.openTrash() }.buttonStyle(QuietButton())
                    }
                }
                Text("The map below explains what uses space. A large block is not automatically junk. System data, VM disks and app workspaces need investigation; cleanup review focuses on recognized caches and personal downloads.").font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
