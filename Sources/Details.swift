import SwiftUI
import AppKit

struct AppearanceSettings: View {
    @Binding var appearance: String
    @Binding var palette: String
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("Appearance", systemImage: "circle.lefthalf.filled").font(.system(size: 14, weight: .semibold))
            Picker("Appearance", selection: $appearance) {
                Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
            }.pickerStyle(.segmented).labelsHidden()
            Divider()
            Text("STORAGE MAP PALETTE").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
            ForEach(["aurora", "ocean", "copper"], id: \.self) { key in
                Button { palette = key } label: {
                    HStack(spacing: 10) {
                        Text(key.capitalized).font(.system(size: 12, weight: .medium)); Spacer()
                        ForEach(0..<3) { index in
                            Circle().fill(Color(nsColor: Palette.ns((key == "ocean" ? [0x3C89B0,0x557CC4,0x4AA9AD] : key == "copper" ? [0xCB8953,0xC6A25A,0xB86B7A] : [0x66BE99,0x6D9BC4,0xB49BD1])[index]))).frame(width: 11, height: 11)
                        }
                        Image(systemName: palette == key ? "checkmark.circle.fill" : "circle").foregroundStyle(palette == key ? Palette.green : Palette.secondary)
                    }.padding(10).background(palette == key ? Palette.green.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel(key.capitalized + " palette")
            }
            Text("Native glass adapts to your macOS version. Appearance settings stay on this Mac.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.foregroundStyle(Palette.ink)
    }
}

struct FolderContentsView: View {
    @ObservedObject var model: SweepModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var items: [FileNode] {
        model.nodes.filter { $0.parent == model.root && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Folder contents").font(.system(size: 23, weight: .semibold))
                    Text(shortPath(model.root)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            TextField("Filter every item in this folder", text: $query).textFieldStyle(.roundedBorder)
            HStack { Text("NAME").frame(maxWidth: .infinity, alignment: .leading); Text("FILES").frame(width: 95, alignment: .trailing); Text("ALLOCATED").frame(width: 95, alignment: .trailing); Text(" ").frame(width: 25) }.font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { n in
                        Button {
                            if n.directory { model.scan(n.path) } else { model.selected = n }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: n.directory ? "folder.fill" : "doc").foregroundStyle(Palette.tile(n.path)).frame(width: 20)
                                Text(n.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                Text(n.directory ? n.files.formatted() : "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).frame(width: 95, alignment: .trailing)
                                Text(byteText(n.bytes)).font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(width: 95, alignment: .trailing)
                                Image(systemName: n.directory ? "chevron.right" : "arrow.down.right").font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 25)
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button("Reveal in Finder") { model.reveal(n) }
                            Button("Add to cleanup review") { model.addToQueue(n) }
                        }
                        Divider()
                    }
                }
            }.frame(height: 420)
            HStack {
                Text("\(items.count.formatted()) matching items · click a folder to open all its children").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                if model.root != "/" { Button("Parent folder") { model.scan(URL(fileURLWithPath: model.root).deletingLastPathComponent().path); dismiss() }.buttonStyle(QuietButton()) }
            }
        }.padding(25).frame(width: 760).background(Palette.canvas).foregroundStyle(Palette.ink)
    }
}

struct DetailFact: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FileTypesPanel: View {
    let totals: [FileTypeTotal]
    @State private var expanded = false
    var total: Int64 { totals.reduce(0) { $0 + $1.bytes } }
    var displayed: [FileTypeTotal] { expanded ? totals : Array(totals.prefix(8)) }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("What’s taking the space").font(.system(size: 15, weight: .semibold))
                        Text("File types across the entire scan, including files below the large-file cutoff.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Text("\(totals.count) TYPES").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary)
                }
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Array(totals.prefix(8).enumerated()), id: \.element.id) { index, item in
                            RoundedRectangle(cornerRadius: 3).fill(Palette.tiles[index % Palette.tiles.count])
                                .frame(width: total > 0 ? max(0, g.size.width * CGFloat(item.bytes) / CGFloat(total) - 2) : 0)
                                .help("\(item.label): \(byteText(item.bytes))")
                        }
                        Spacer(minLength: 0)
                    }
                }.frame(height: 12)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 9) {
                            Circle().fill(Palette.tiles[index % Palette.tiles.count]).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label).font(.system(size: 11, weight: .medium))
                                Text("\(item.count.formatted()) files").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Text(byteText(item.bytes)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text(total > 0 ? String(format: "%.1f%%", Double(item.bytes) / Double(total) * 100) : "0%")
                                .font(.system(size: 9)).foregroundStyle(Palette.secondary).frame(width: 40, alignment: .trailing)
                        }.padding(.trailing, 13)
                    }
                }
                HStack {
                    Text("Allocated blocks in regular files. Folder metadata and symbolic links are excluded.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    Spacer()
                    if totals.count > 8 { Button(expanded ? "Show fewer" : "Show all types") { expanded.toggle() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green) }
                }
            }
        }
    }
}

struct FileInspector: View {
    @ObservedObject var model: SweepModel
    let node: FileNode
    @Environment(\.dismiss) private var dismiss
    private var attributes: [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: node.path)) ?? [:] }
    private func date(_ key: FileAttributeKey) -> String {
        guard let d = attributes[key] as? Date else { return "Unavailable" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
    private var permissions: String {
        guard let value = attributes[.posixPermissions] as? NSNumber else { return "Unavailable" }
        return String(format: "%03o", value.uint32Value)
    }
    private func copyPath() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(node.name).font(.system(size: 23, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(node.directory ? "FOLDER DETAILS" : "FILE DETAILS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.green)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton())
            }
            HStack(spacing: 12) {
                Metric(icon: "internaldrive", title: "Allocated at scan", value: byteText(node.bytes), note: "Estimated space on disk")
                Metric(icon: "doc", title: "Logical size", value: byteText(node.logical), note: "File contents before sparse allocation")
                Metric(icon: "doc.on.doc", title: node.directory ? "Nested files" : "Type", value: node.directory ? node.files.formatted() : (URL(fileURLWithPath: node.path).pathExtension.uppercased().isEmpty ? "File" : URL(fileURLWithPath: node.path).pathExtension.uppercased()), note: node.directory ? "Files counted during this scan" : "Based on the filename extension")
            }
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 17) {
                    HStack { DetailFact(title: "Path", value: node.path); Button("Copy path") { copyPath() }.buttonStyle(QuietButton()) }
                    Divider()
                    HStack(alignment: .top, spacing: 24) { DetailFact(title: "Last modified", value: date(.modificationDate)); DetailFact(title: "Created", value: date(.creationDate)) }
                    HStack(alignment: .top, spacing: 24) { DetailFact(title: "Owner", value: attributes[.ownerAccountName] as? String ?? "Unavailable"); DetailFact(title: "Permissions", value: permissions) }
                }
            }
            if let refusal = model.refusal(node) {
                Label(refusal, systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("This item can be added to review. Moving it still requires final confirmation.", systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Palette.green)
            }
            Text("Size totals are from the selected scan; dates and ownership are read now. APFS shared blocks mean allocated size is not a guaranteed cleanup saving.").font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reveal in Finder") { model.reveal(node) }.buttonStyle(QuietButton())
                if node.directory { Button("Explore folder") { dismiss(); model.page = "Storage"; model.scan(node.path) }.buttonStyle(QuietButton()) }
                Spacer()
                Button("Add to cleanup review") { model.addToQueue(node) }.buttonStyle(PrimaryButton()).disabled(model.refusal(node) != nil)
            }
        }.padding(27).frame(width: 770).background(Palette.canvas).foregroundStyle(Palette.ink)
    }
}

struct MemoryInspector: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var storageModel: SweepModel
    let initial: MemoryRow
    @Environment(\.dismiss) private var dismiss
    private var row: MemoryRow { monitor.rows.first { $0.id == initial.id } ?? initial }
    private var available: Bool { monitor.rows.contains { $0.id == initial.id } }
    private var storagePaths: [String] { Array(Set(row.details.map(\.storage).filter { !$0.isEmpty })).sorted() }
    private func mapStorage(_ path: String) { dismiss(); storageModel.page = "Storage"; storageModel.scan(path) }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(row.name).font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(available ? "LIVE PROCESS DETAILS · \(row.processes.count) PROCESSES" : "LAST SAMPLE · NO LONGER OBSERVABLE").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Palette.green)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButton())
            }
            HStack(spacing: 12) {
                Metric(icon: "memorychip", title: "Current footprint", value: byteText(row.bytes), note: "App and attributed helper processes")
                Metric(icon: "chart.line.uptrend.xyaxis", title: "Observed peak", value: byteText(row.peak), note: "Within this observation window")
                Metric(icon: "clock", title: "Observation", value: "\(Int(row.observationSeconds))s", note: "\(row.samples.count) samples · up to 15 minutes")
            }
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Footprint over time").font(.system(size: 13, weight: .semibold)); Spacer()
                        Text((row.delta < 0 ? "−" : "+") + byteText(abs(row.delta))).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(row.growing ? .orange : Palette.green)
                    }
                    if row.samples.count < 2 { Text("Collecting the first samples…").font(.system(size: 11)).foregroundStyle(Palette.secondary).frame(height: 70) }
                    else { Sparkline(samples: row.samples, growing: row.growing).frame(height: 70) }
                    Text(row.growing ? "Sustained growth detected. Inspect the largest helpers below; a growth signal does not establish a leak." : "Growth watch needs 30 seconds, 128 MiB and 20% growth, with repeated rising samples. Process changes reset the baseline.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }
            if !storagePaths.isEmpty {
                Panel(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Virtual machine → disk workspace", systemImage: "externaldrive.connected.to.line.below").font(.system(size: 13, weight: .semibold))
                        ForEach(storagePaths, id: \.self) { path in
                            HStack {
                                Text(shortPath(path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(2).truncationMode(.middle)
                                Spacer(); Button("Map storage") { mapStorage(path) }.buttonStyle(QuietButton())
                            }
                        }
                        Text("Attributed from the VM’s open files. This is workload data, not a cache cleanup suggestion. Storage Explorer keeps protected Library data out of cleanup.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                }
            }
            HStack { Text("Inside this app").font(.system(size: 15, weight: .semibold)); Spacer(); Text("FOOTPRINT / RESIDENT").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.secondary) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(row.details) { process in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(process.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).frame(width: 49, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(process.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(byteText(process.bytes)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text(byteText(process.resident)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                            }.frame(width: 95, alignment: .trailing)
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }
            }.frame(height: 210)
            Text("Footprint includes compressed memory charged to the process. Resident size counts pages currently in RAM and can count shared pages in several processes. These measures are not additive. Protected helpers may be unavailable.").font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reset all baselines") { monitor.reset() }.buttonStyle(QuietButton())
                if row.path.hasSuffix(".app") { Button("Map app storage") { mapStorage(row.path) }.buttonStyle(QuietButton()) }
                Spacer()
                if row.path.hasSuffix(".app"), available { Button("Quit app…") { monitor.quit(row) }.buttonStyle(QuietButton()) }
                Button("Done") { dismiss() }.buttonStyle(PrimaryButton())
            }
        }.padding(27)
        }.frame(width: 800, height: 720).background(Palette.canvas).foregroundStyle(Palette.ink)
    }
}
