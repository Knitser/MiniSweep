import SwiftUI
import AppKit

enum Palette {
    static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in ns(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) })
    }
    static let ink = adaptive(0x18251F, 0xE7EEE9)
    static let secondary = adaptive(0x62716A, 0x9EAEA7)
    static let canvas = adaptive(0xEDF1F0, 0x0C1117)
    static let panel = adaptive(0xFFFFFF, 0x18212B)
    static let sidebar = Color(red: 0.055, green: 0.075, blue: 0.10)
    static var key: String { UserDefaults.standard.string(forKey: "mapPalette") ?? "aurora" }
    static var green: Color {
        switch key {
        case "ocean": return adaptive(0x1768A3, 0x75C9F5)
        case "copper": return adaptive(0x9A4B18, 0xF5B77C)
        default: return adaptive(0x267550, 0x8AE0BE)
        }
    }
    static var button: Color { key == "ocean" ? Color(nsColor: ns(0x1C5F91)) : key == "copper" ? Color(nsColor: ns(0x874315)) : Color(nsColor: ns(0x286A50)) }
    static let mint = Color(nsColor: ns(0xBDE8D2))
    static let line = adaptive(0xD6DFDB, 0x33414D).opacity(0.65)
    static var tiles: [Color] {
        let values: [UInt32]
        switch key {
        case "ocean": values = [0x245B7D,0x295076,0x266B78,0x385489,0x4D4E83,0x28635E,0x35516A,0x4A6685]
        case "copper": values = [0x7B4A29,0x865630,0x6E4B40,0x765E2D,0x71434B,0x795F44,0x6A5357,0x85513E]
        default: values = [0x2D6554,0x30597B,0x6E622F,0x63467C,0x78485F,0x2A6C71,0x455C75,0x4B685C]
        }
        return values.map { Color(nsColor: ns($0)) }
    }
    static func tile(_ path: String) -> Color {
        let hash = path.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return tiles[Int(hash % UInt64(tiles.count))]
    }
}
extension View {
    @ViewBuilder func utilityGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 0.5))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 0.5))
        }
    }
}
struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content
    var body: some View { content.padding(padding).utilityGlass() }
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 17).padding(.vertical, 11)
            .foregroundStyle(.white).background(Palette.button.opacity(configuration.isPressed ? 0.8 : 1)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(Palette.ink).background(configuration.isPressed ? Palette.line : Palette.panel.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
    }
}
struct Metric: View {
    let icon: String, title: String, value: String, note: String
    var accent = Palette.green
    var body: some View {
        Panel(padding: 17) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary); Spacer(); Image(systemName: icon).foregroundStyle(accent) }
                Text(value).font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.ink)
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MainView: View {
    @StateObject var model = SweepModel()
    @StateObject var memory = MemoryMonitor()
    @AppStorage("appearanceMode") private var appearanceMode = "dark"
    @AppStorage("mapPalette") private var mapPalette = "aurora"
    @State private var showAppearance = false
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            VStack(spacing: 0) {
                HStack {
                    Text("LOCAL SYSTEM / MINISWEEP").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
                    Spacer()
                    Circle().fill(model.isScanning || model.findingCleanup ? Color.orange : Palette.green).frame(width: 6, height: 6)
                    Text(model.isScanning ? "Scanning storage" : model.findingCleanup ? "Finding cleanup" : "Local & private").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Button { showAppearance.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(QuietButton()).help("Appearance and map colors")
                        .popover(isPresented: $showAppearance) { AppearanceSettings(appearance: $appearanceMode, palette: $mapPalette).padding(20).frame(width: 300) }
                    Button { model.showReview = true } label: { Label("Review \(model.queue.count)", systemImage: "tray") }.buttonStyle(QuietButton()).disabled(model.queue.isEmpty)
                }.padding(.horizontal, 30).padding(.top, 27).padding(.bottom, 19)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.page == "Storage" { StorageView(model: model) }
                        else if model.page == "Memory" { MemoryView(memory: memory) }
                        else { CleanupView(model: model) }
                    }.padding(.horizontal, 30).padding(.bottom, 30)
                }
            }.background(Palette.canvas)
        }
        .id(mapPalette).frame(minWidth: 1120, minHeight: 760).foregroundStyle(Palette.ink).preferredColorScheme(appearanceMode == "system" ? nil : appearanceMode == "light" ? .light : .dark)
        .sheet(isPresented: $model.showReview) { ReviewView(model: model) }
        .sheet(isPresented: $model.showAccess) { AccessView(model: model) }
        .sheet(isPresented: $model.showContents) { FolderContentsView(model: model) }
        .sheet(item: $model.inspected) { node in FileInspector(model: model, node: node) }
        .sheet(item: $memory.selected) { row in MemoryInspector(monitor: memory, storageModel: model, initial: row) }
        .alert("MiniSweep", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .onAppear { if model.nodes.isEmpty && !model.isScanning { model.scan() }; memory.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.stopScan(); model.cleanupHandle?.cancel()
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: SweepModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 23, weight: .medium)).foregroundStyle(Palette.sidebar).frame(width: 40, height: 40).background(Palette.mint).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("MiniSweep").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Text("DISK · MEMORY · CLEANUP").font(.system(size: 8, weight: .semibold)).tracking(1.7).foregroundStyle(.white.opacity(0.45))
                }
            }.padding(.top, 52).padding(.bottom, 41)
            Text("MONITORS").font(.system(size: 9, weight: .semibold)).tracking(1.7).foregroundStyle(.white.opacity(0.35)).padding(.bottom, 14).padding(.leading, 12)
            ForEach([(name: "Storage", icon: "square.grid.2x2"), (name: "Memory", icon: "waveform.path"), (name: "Cleanup", icon: "sparkle")], id: \.name) { item in
                Button { model.page = item.name } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.icon).font(.system(size: 17)).frame(width: 21)
                        Text(item.name).font(.system(size: 14, weight: .medium))
                        Spacer()
                        if item.name == "Cleanup", !model.queue.isEmpty { Text("\(model.queue.count)").font(.system(size: 10, weight: .semibold)).padding(5).background(Color.white.opacity(0.12)).clipShape(Capsule()) }
                    }.padding(.horizontal, 13).padding(.vertical, 14)
                        .foregroundStyle(model.page == item.name ? Palette.mint : .white.opacity(0.58))
                        .background(model.page == item.name ? Color.white.opacity(0.08) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 13) {
                HStack { Image(systemName: "internaldrive"); Text("Macintosh HD").font(.system(size: 12, weight: .medium)) }.foregroundStyle(.white.opacity(0.9))
                GeometryReader { g in ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(Palette.mint).frame(width: max(0, g.size.width * min(model.disk.fraction, 1)))
                } }.frame(height: 5)
                Text("\(byteText(model.disk.free)) free of \(byteText(model.disk.total))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Text("\(Int(model.disk.fraction * 100))% occupied across APFS volumes").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }.padding(15).background(.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 12))
            Button { model.showAccess = true } label: { Label("Disk access & permissions", systemImage: "lock.shield").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).padding(.top, 19).padding(.bottom, 20)
            HStack { Text("LOCAL SYSTEM UTILITY").font(.system(size: 8, weight: .medium)).tracking(1.4); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1").font(.system(size: 9)) }.foregroundStyle(.white.opacity(0.25)).padding(.bottom, 21)
        }.padding(.horizontal, 18).frame(width: 210).background(Palette.sidebar.opacity(0.86)).background(.ultraThinMaterial).overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 0.5) }
    }
}

struct SectionTitle: View {
    let eyebrow: String, title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.green)
            Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }.padding(.top, 8)
    }
}

struct StorageView: View {
    @ObservedObject var model: SweepModel
    var body: some View {
        SectionTitle(eyebrow: "File system", title: "Storage Explorer", subtitle: "Allocated disk blocks · click a folder block to inspect its contents")
        HStack(spacing: 12) {
            Metric(icon: "internaldrive", title: "Disk space free", value: byteText(model.disk.free), note: "Across the internal APFS container", accent: .orange)
            Metric(icon: "folder", title: model.isScanning ? "Scanned so far" : "Folder on disk", value: byteText(model.folderBytes), note: shortPath(model.root))
            Metric(icon: "doc.on.doc", title: "Files counted", value: (model.nodes.first(where: { $0.path == model.root })?.files ?? model.scannedFiles).formatted(), note: model.isScanning ? "Live scan · cancel at any time" : model.scanComplete ? "Finished in \(Int(model.elapsed)) seconds" : "Partial scan or ready to scan")
        }
        Panel(padding: 16) {
            HStack(spacing: 9) {
                Button { model.navigate(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(QuietButton()).disabled(model.navigationIndex <= 0).help("Back")
                Button { model.navigate(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(QuietButton()).disabled(model.navigationIndex >= model.navigation.count - 1).help("Forward")
                Image(systemName: "folder").foregroundStyle(Palette.green)
                Text(shortPath(model.root)).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(model.root)
                Spacer()
                if model.isScanning { Button("Stop") { model.stopScan() }.buttonStyle(QuietButton()) }
                else { Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButton()).help("Rescan folder") }
                Button("Choose folder…") { model.chooseFolder() }.buttonStyle(PrimaryButton())
            }
            HStack(spacing: 8) {
                Text("QUICK SCAN").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary)
                ForEach([(name: "Home", path: sweepHome), (name: "Applications", path: "/Applications"), (name: "Downloads", path: sweepHome + "/Downloads"), (name: "Caches", path: sweepHome + "/Library/Caches"), (name: "All data", path: "/System/Volumes/Data")], id: \.name) { folder in
                    Button(folder.name) { model.scan(folder.path) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green).padding(.horizontal, 10).padding(.vertical, 6).background(Palette.green.opacity(0.065)).clipShape(Capsule())
                }
                Spacer()
                if model.root != "/" { Button { model.scan(URL(fileURLWithPath: model.root).deletingLastPathComponent().path) } label: { Label("Up", systemImage: "arrow.up") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            }.padding(.top, 7)
            if model.isScanning {
                ProgressView().progressViewStyle(.linear).tint(Palette.green).padding(.top, 7)
                Text(shortPath(model.scanPath)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        HStack(alignment: .top, spacing: 16) {
            Panel(padding: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("The big picture").font(.system(size: 15, weight: .semibold)); Spacer(); Button("All items") { model.showContents = true }.buttonStyle(QuietButton()); Text("ALLOCATED SIZE").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary) }
                    if model.childNodes.isEmpty {
                        VStack(spacing: 13) { Image(systemName: model.isScanning ? "magnifyingglass" : "folder").font(.system(size: 32)).foregroundStyle(Palette.green); Text(model.isScanning ? "Building your storage map…" : "Choose a folder to explore").font(.system(size: 13)); Text("Folder totals appear as each branch finishes.").font(.system(size: 11)).foregroundStyle(Palette.secondary) }.frame(maxWidth: .infinity).frame(height: 310)
                    } else {
                        TreemapView(nodes: model.childNodes, selected: model.selected?.path, select: { model.selected = $0 }, open: { if $0.directory { model.scan($0.path) } else { model.reveal($0) } }, showAll: { model.showContents = true }).frame(height: 310)
                    }
                    Text("Click a folder to drill in · Back to return · All items lists every child").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }.frame(maxWidth: .infinity)
            Panel(padding: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack { Text("Largest items").font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(model.childNodes.count)").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    TextField("Filter this folder", text: $model.storageFilter).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    HStack {
                        Picker("Order", selection: $model.storageSort) { ForEach(StorageSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
                        Picker("Kind", selection: $model.storageKind) { ForEach(["All items", "Folders", "Files"], id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }.font(.system(size: 10))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.childNodes.enumerated()), id: \.element.id) { index, n in
                                Button { model.selected = n } label: {
                                    HStack(spacing: 9) {
                                        RoundedRectangle(cornerRadius: 3).fill(Palette.tile(n.path)).frame(width: 6, height: 24)
                                        VStack(alignment: .leading, spacing: 4) { Text(n.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle); Text(n.directory ? "\(n.files.formatted()) files" : "File").font(.system(size: 9)).foregroundStyle(Palette.secondary) }
                                        Spacer(minLength: 6)
                                        Text(byteText(n.bytes)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    }.padding(.vertical, 10).padding(.horizontal, 5).background(model.selected?.path == n.path ? Palette.green.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).contextMenu {
                                    Button("Inspect details") { model.inspected = n }
                                    Button("Reveal in Finder") { model.reveal(n) }
                                    if n.directory { Button("Scan this folder") { model.scan(n.path) } }
                                    Button("Add to cleanup review") { model.addToQueue(n) }
                                }
                                Divider().overlay(Palette.line)
                            }
                        }
                    }.frame(height: 253)
                }
            }.frame(width: 310)
        }
        if let n = model.selected {
            Panel(padding: 15) {
                HStack(spacing: 13) {
                    Image(systemName: n.directory ? "folder.fill" : "doc.fill").font(.system(size: 22)).foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.name).font(.system(size: 13, weight: .semibold)); Text(shortPath(n.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                    }; Spacer()
                    Text(byteText(n.bytes)).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Button("Details") { model.inspected = n }.buttonStyle(QuietButton())
                    Button("Reveal") { model.reveal(n) }.buttonStyle(QuietButton())
                    if n.directory { Button("Explore") { model.scan(n.path) }.buttonStyle(QuietButton()) }
                    Button("Add to review") { model.addToQueue(n) }.buttonStyle(PrimaryButton()).disabled(model.refusal(n) != nil).help(model.refusal(n) ?? "Add this item to the cleanup queue")
                }
            }
        }
        if model.skipped > 0 {
            HStack { Image(systemName: "lock.shield").foregroundStyle(.orange); Text("\(model.skipped) locations couldn’t be read. Totals are partial.").font(.system(size: 11)); Spacer(); Button("See details") { model.showAccess = true }.buttonStyle(.plain).foregroundStyle(Palette.green).font(.system(size: 11, weight: .medium)) }
        }
        if !model.fileTypes.isEmpty { FileTypesPanel(totals: model.fileTypes) }
        GrowthLensPanel(model: model)
        if !model.largest.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Largest individual files").font(.system(size: 15, weight: .semibold)); Spacer(); Text("ANYWHERE IN THIS SCAN").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary) }
                    HStack {
                        TextField("Filter large files by name, path or extension", text: $model.largestFilter).textFieldStyle(.roundedBorder).frame(maxWidth: 330)
                        Spacer(); Text("\(model.filteredLargest.count) matches · files ≥ 8 MiB").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(model.filteredLargest.prefix(20)) { n in
                        HStack(spacing: 12) {
                            Image(systemName: "doc").foregroundStyle(Palette.secondary)
                            VStack(alignment: .leading, spacing: 4) { Text(n.name).font(.system(size: 11, weight: .medium)).lineLimit(1); Text(shortPath(n.parent)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle) }
                            Spacer(); Text(byteText(n.bytes)).font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(width: 80, alignment: .trailing)
                            Button { model.inspected = n } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("Inspect file details")
                            Button { model.reveal(n) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Reveal in Finder")
                            Button { model.addToQueue(n) } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain).disabled(model.refusal(n) != nil).help(model.refusal(n) ?? "Add to review")
                        }.padding(.vertical, 5)
                    }
                }
            }
        }
        Text("Allocated sizes estimate blocks used on disk. APFS clones and hard links may share blocks; inaccessible folders are excluded. 1 GiB = 1,073,741,824 bytes.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }
}

struct MapTile: Identifiable { let node: FileNode; let rect: CGRect; let color: Int; var id: String { node.id } }
func mapLayout(_ nodes: [FileNode], size: CGSize) -> [MapTile] {
    let sorted = nodes.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    var display = Array(sorted.prefix(64))
    if sorted.count > 64 { display.append(FileNode(path: "__other__", bytes: sorted.dropFirst(64).reduce(0) { $0 + $1.bytes }, logical: 0, files: 0, directory: false)) }
    let total = Double(display.reduce(0) { $0 + $1.bytes }); guard total > 0, size.width > 0, size.height > 0 else { return [] }
    var result: [MapTile] = []
    // Balanced binary treemap: stable ordering and readable rectangles at any window size.
    func split(_ slice: ArraySlice<(offset: Int, element: FileNode)>, _ rect: CGRect) {
        guard let first = slice.first else { return }
        if slice.count == 1 { result.append(MapTile(node: first.element, rect: rect.insetBy(dx: min(2, rect.width / 10), dy: min(2, rect.height / 10)), color: first.offset)); return }
        let sum = Double(slice.reduce(Int64(0)) { $0 + $1.element.bytes }); var cumulative = 0.0; var count = 0
        for item in slice.dropLast() { cumulative += Double(item.element.bytes); count += 1; if cumulative >= sum / 2 { break } }
        let ratio = CGFloat(cumulative / sum)
        if rect.width >= rect.height {
            let width = rect.width * ratio
            split(slice.prefix(count), CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
            split(slice.dropFirst(count), CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        } else {
            let height = rect.height * ratio
            split(slice.prefix(count), CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height))
            split(slice.dropFirst(count), CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
        }
    }
    split(Array(display.enumerated())[...], CGRect(origin: .zero, size: size)); return result
}
struct TreemapView: View {
    let nodes: [FileNode]
    let selected: String?
    let select: (FileNode) -> Void
    let open: (FileNode) -> Void
    let showAll: () -> Void
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(mapLayout(nodes, size: g.size)) { tile in
                    Button {
                        if tile.node.path == "__other__" { showAll() }
                        else if tile.node.directory { open(tile.node) }
                        else { select(tile.node) }
                    } label: {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(Palette.tile(tile.node.path))
                        if tile.rect.width > 64 && tile.rect.height > 38 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tile.node.path == "__other__" ? "Other items" : tile.node.name).font(.system(size: tile.rect.width > 160 ? 13 : 10, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                                if tile.rect.height > 65 { Text(byteText(tile.node.bytes)).font(.system(size: tile.rect.width > 160 ? 19 : 12, weight: .medium, design: .rounded)).lineLimit(1) }
                            }.foregroundStyle(Color.white).padding(tile.rect.width > 100 ? 13 : 8)
                        }
                    }
                    }.buttonStyle(.plain).frame(width: max(0, tile.rect.width), height: max(0, tile.rect.height))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tile.node.path == selected ? Palette.ink : .clear, lineWidth: 3))
                        .position(x: tile.rect.midX, y: tile.rect.midY)
                        .help("\(tile.node.path == "__other__" ? "Remaining items" : tile.node.path)\n\(byteText(tile.node.bytes))")
                        .accessibilityLabel(tile.node.path == "__other__" ? "Other items, open all folder contents" : "\(tile.node.name), \(byteText(tile.node.bytes))" )
                }
            }
        }
    }
}

struct Sparkline: View {
    let samples: [MemorySample]
    var growing = false
    var body: some View {
        GeometryReader { g in
            Path { path in
                guard samples.count > 1 else { return }
                let values = samples.map { Double($0.bytes) }; let lo = values.min() ?? 0; let hi = values.max() ?? 1
                let span = max(hi - lo, max(hi * 0.05, 1))
                for (i, value) in values.enumerated() {
                    let p = CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * g.size.width, y: g.size.height - 3 - CGFloat((value - lo) / span) * (g.size.height - 6))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }.stroke(growing ? Color.orange : Palette.green, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
    }
}

struct MemoryView: View {
    @ObservedObject var memory: MemoryMonitor
    var body: some View {
        SectionTitle(eyebrow: "Process telemetry", title: "Memory Monitor", subtitle: "App footprints · process details · compressed pages · swap allocation")
        HStack(spacing: 12) {
            Metric(icon: "memorychip", title: "Physical RAM", value: memory.stats.memory_valid != 0 ? byteText(Int64(memory.stats.physical)) : "Unavailable", note: "Installed memory on this Mac")
            Metric(icon: "arrow.down.right.and.arrow.up.left", title: "Compressed", value: byteText(Int64(memory.stats.compressed)), note: "macOS compresses pages to make room")
            Metric(icon: "internaldrive", title: "Swap in use", value: memory.stats.swap_valid != 0 ? byteText(Int64(memory.stats.swap_used)) : "Unavailable", note: "Disk space being used for memory", accent: .orange)
        }
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("Who’s using your memory").font(.system(size: 16, weight: .semibold)); Text("Physical footprint · includes compressed memory · updates every 5 seconds").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                    Spacer()
                    Button(memory.paused ? "Resume" : "Pause") { memory.paused.toggle() }.buttonStyle(QuietButton())
                    Button("Reset baseline") { memory.reset() }.buttonStyle(QuietButton())
                }
                HStack {
                    TextField("Find an app or process", text: $memory.search).textFieldStyle(.roundedBorder).frame(maxWidth: 250)
                    Toggle("Growth watch only", isOn: $memory.onlyGrowing).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Picker("Sort", selection: $memory.byGrowth) { Text("Most memory").tag(false); Text("Most growth").tag(true) }.labelsHidden().frame(width: 155)
                }
                HStack {
                    Text("APP / PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                    Text("MEMORY").frame(width: 95, alignment: .trailing)
                    Text("CHANGE").frame(width: 95, alignment: .trailing)
                    Text("TREND").frame(width: 95)
                    Text("ACTIONS").frame(width: 94)
                }.font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary)
                if memory.visibleRows.isEmpty {
                    VStack(spacing: 10) { Image(systemName: "waveform.path").font(.system(size: 28)).foregroundStyle(Palette.green); Text(memory.onlyGrowing ? "No sustained growth detected yet" : "Waiting for a memory sample").font(.system(size: 13)); Text(memory.onlyGrowing ? "Keep monitoring. Growth needs at least 30 seconds of samples." : "macOS may restrict access to some processes.").font(.system(size: 11)).foregroundStyle(Palette.secondary) }.frame(maxWidth: .infinity).padding(40)
                }
                LazyVStack(spacing: 0) {
                    ForEach(memory.visibleRows.prefix(100)) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.path.hasSuffix(".app") ? "app.fill" : "gearshape.fill").font(.system(size: 17)).foregroundStyle(Palette.green).frame(width: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1); if row.growing { Text("GROWING").font(.system(size: 7, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 3).background(Color.orange.opacity(0.14)).foregroundStyle(Color.orange).clipShape(Capsule()) } }
                                Text(row.processes.count > 1 ? "\(row.processes.count) processes" : "PID \(row.processes.first ?? 0)").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(byteText(row.bytes)).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 95, alignment: .trailing)
                            Text(row.samples.count < 2 ? "—" : (row.delta < 0 ? "−" : "+") + byteText(abs(row.delta))).font(.system(size: 10, design: .monospaced)).foregroundStyle(row.growing ? .orange : Palette.secondary).frame(width: 95, alignment: .trailing)
                            Sparkline(samples: row.samples, growing: row.growing).frame(width: 95, height: 29)
                            Button { memory.selected = row } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).foregroundStyle(Palette.green).frame(width: 20).help("Inspect processes and memory history")
                            if row.path.hasSuffix(".app") && row.path != Bundle.main.bundleURL.path { Button("Quit") { memory.quit(row) }.buttonStyle(QuietButton()).frame(width: 62) }
                            else { Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Palette.secondary.opacity(0.5)).frame(width: 62) }
                        }.padding(.vertical, 11).help(row.path)
                        Divider()
                    }
                }
            }
        }
        Panel(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle").foregroundStyle(Palette.green)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Growth is a clue, not proof of a leak.").font(.system(size: 12, weight: .semibold))
                    Text("Growth watch needs at least 30 seconds, 128 MiB and 20% growth, with multiple rising samples. A change in an app’s helper processes resets its baseline. History covers up to 15 minutes and stays in this session. Protected processes may be missing. Swap can remain allocated after apps close.").font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct CleanupView: View {
    @ObservedObject var model: SweepModel
    @State private var cleanupQuery = ""
    @State private var cleanupCategory = "All candidates"
    private var candidates: [FileNode] {
        model.cleanupItems.filter { (cleanupQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(cleanupQuery)) && (cleanupCategory == "All candidates" || $0.category == cleanupCategory) }
    }
    var body: some View {
        SectionTitle(eyebrow: "Staged file operations", title: "Cleanup Review", subtitle: "Inspect candidates, stage paths, and confirm moves to Trash")
        HStack(spacing: 12) {
            Metric(icon: "tray", title: "Queued for review", value: byteText(model.queueBytes), note: "\(model.queue.count) items selected by you")
            Metric(icon: "trash", title: "Moved this session", value: byteText(model.freedThisSession), note: "Still in Trash until you empty it")
            Metric(icon: "checkmark.shield", title: "Cleanup method", value: "Trash first", note: "System folders and running apps protected")
        }
        Panel {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Text("Scan cleanup candidates").font(.system(size: 16, weight: .semibold)); Text("Checks app caches, temporary package downloads and your Downloads folder.").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                Spacer()
                if model.findingCleanup { ProgressView().controlSize(.small); Button("Stop") { model.cleanupHandle?.cancel() }.buttonStyle(QuietButton()) }
                else { Button { model.findCleanup() } label: { Label("Find cleanup", systemImage: "magnifyingglass") }.buttonStyle(PrimaryButton()) }
            }
        }
        if !model.cleanupNote.isEmpty { Text(model.cleanupNote).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
        if model.cleanupItems.isEmpty && !model.findingCleanup {
            Panel {
                HStack(spacing: 20) {
                    Image(systemName: "sparkles").font(.system(size: 35)).foregroundStyle(Palette.green).frame(width: 65, height: 65).background(Palette.green.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 8) { Text("Review caches and downloads").font(.system(size: 17, weight: .semibold)); Text("Caches can be rebuilt, and old downloads can add up. Check the contents of every folder before adding it to review. Storage explorer can queue larger personal files and unused apps, too.").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(.vertical, 18)
            }
        }
        if !model.cleanupItems.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Items to consider").font(.system(size: 16, weight: .semibold)); Spacer(); Text("LARGEST FIRST").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary) }
                    Text("Cache cleanup signs you out of some offline features or makes apps download data again. Downloads can contain your only copy; review them in Finder.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    HStack {
                        TextField("Filter candidate names or paths", text: $cleanupQuery).textFieldStyle(.roundedBorder)
                        Picker("Category", selection: $cleanupCategory) { ForEach(["All candidates", "App cache", "Review download"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 160)
                    }
                    ScrollView {
                    LazyVStack(spacing: 0) {
                    ForEach(candidates) { n in
                        HStack(spacing: 12) {
                            Image(systemName: n.category == "App cache" ? "arrow.triangle.2.circlepath" : "arrow.down.doc").font(.system(size: 17)).foregroundStyle(n.category == "App cache" ? Palette.green : .orange).frame(width: 25)
                            VStack(alignment: .leading, spacing: 5) { HStack { Text(n.name).font(.system(size: 12, weight: .medium)); Text(n.category.uppercased()).font(.system(size: 7, weight: .semibold)).padding(4).background(Palette.canvas).clipShape(Capsule()) }; Text(shortPath(n.path)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle) }
                            Spacer()
                            Text(byteText(n.bytes)).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 85, alignment: .trailing)
                            Button { model.inspected = n } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("Inspect file or folder details")
                            Button("Inspect") { model.reveal(n) }.buttonStyle(QuietButton())
                            let added = model.queue.contains { inside(n.path, $0.node.path) }
                            Button(added ? "Added" : "Add") { model.addToQueue(n) }.buttonStyle(QuietButton()).disabled(added || model.refusal(n) != nil).frame(width: 65).help(model.refusal(n) ?? "Add to cleanup review")
                        }.padding(.vertical, 9)
                        Divider()
                    }
                    }
                    }.frame(height: 420)
                    Text("\(candidates.count) matching candidates · nothing is selected automatically").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }
        }
        if !model.queue.isEmpty {
            Panel {
                HStack { VStack(alignment: .leading, spacing: 6) { Text("\(byteText(model.queueBytes)) ready for your review").font(.system(size: 17, weight: .semibold)); Text("\(model.queue.count) selected items · Final confirmation required").font(.system(size: 11)).foregroundStyle(Palette.secondary) }; Spacer(); Button("Review cleanup") { model.showReview = true }.buttonStyle(PrimaryButton()) }
            }
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: SweepModel
    @Environment(\.dismiss) var dismiss
    @State var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: "tray.full").font(.system(size: 25)).foregroundStyle(Palette.green); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text("Review file operations").font(.system(size: 29, weight: .semibold, design: .rounded))
            Text("\(model.queue.count) items · \(byteText(model.queueBytes)) on disk").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.queue) { e in
                        HStack { VStack(alignment: .leading, spacing: 5) { Text(e.node.name).font(.system(size: 12, weight: .semibold)); Text(shortPath(e.node.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(2) }; Spacer(); Text(byteText(e.node.bytes)).font(.system(size: 11, design: .monospaced)); Button { model.reveal(e.node) } label: { Image(systemName: "folder") }.buttonStyle(.plain); Button { model.queue.removeAll { $0.id == e.id }; confirmed = false } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }.padding(.vertical, 13)
                        Divider()
                    }
                }
            }.frame(minHeight: 120, maxHeight: 290)
            Text("Items will be moved to Trash. You can restore them in Finder. Disk space is only reclaimed when you empty Trash yourself. Close apps that use these files before proceeding.").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("I reviewed these items and want to move them to Trash.", isOn: $confirmed).toggleStyle(.checkbox).font(.system(size: 12))
            HStack { Button("Keep reviewing") { dismiss() }.buttonStyle(QuietButton()); Spacer(); Button { model.moveQueueToTrash() } label: { Label(model.trashBusy ? "Moving…" : "Move \(model.queue.count) items to Trash", systemImage: "trash") }.buttonStyle(PrimaryButton()).disabled(!confirmed || model.queue.isEmpty || model.trashBusy) }
        }.padding(30).frame(width: 630).background(Palette.canvas)
    }
}
struct AccessView: View {
    @ObservedObject var model: SweepModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(Palette.green)
            Text("Storage access").font(.system(size: 25, weight: .semibold, design: .rounded))
            Text("macOS protects Mail, Messages, browser profiles and some Library folders. MiniSweep skips anything it cannot read and reports partial totals. For a complete scan, open Full Disk Access, add MiniSweep using the + button, then quit and reopen the app.").font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Text("MiniSweep only reads file names, metadata and process statistics. It has no network code, scheduled cleanup or background login agent.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            if !model.scanErrors.isEmpty {
                ScrollView { Text(model.scanErrors.joined(separator: "\n")).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
            }
            HStack { Button("Done") { dismiss() }.buttonStyle(QuietButton()); Spacer(); Button("Open Full Disk Access") { model.openPermissions() }.buttonStyle(PrimaryButton()) }
        }.padding(30).frame(width: 570).background(Palette.canvas)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows { w.title = "MiniSweep"; w.titlebarAppearsTransparent = true; w.backgroundColor = NSColor(Palette.canvas); w.setFrameAutosaveName("MiniSweepMain") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MiniSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        if CommandLine.arguments.contains("--self-test") { exit(runSelfTests()) }
        if let index = CommandLine.arguments.firstIndex(of: "--scan-json"), CommandLine.arguments.count > index + 1 { exit(runScanCLI(CommandLine.arguments[index + 1])) }
        if CommandLine.arguments.contains("--memory-json") { exit(runMemoryCLI()) }
        if CommandLine.arguments.contains("--trash-self-test") { exit(runTrashSelfTest()) }
    }
    var body: some Scene {
        WindowGroup { MainView() }.windowStyle(.hiddenTitleBar).defaultSize(width: 1310, height: 930)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
