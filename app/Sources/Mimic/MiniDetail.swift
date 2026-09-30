import AppKit
import MimicCore
import SwiftUI

/// A mini's page: the 3D view fills it, running up under the toolbar; Open in the slicer and
/// More are in the toolbar; its size, previews, versions and print tips are in the details
/// panel on the right, which the toolbar shows and hides.
struct MiniDetail: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    @State private var enlarged: Enlarged?
    @State private var copied = false
    @State private var confirmKeep = false
    /// The plain name offered after Keep This One.
    @State private var offerName: String?
    /// What the viewer measured in the print file.
    @State private var measured: Measured?
    @AppStorage("showDetails") private var showDetails = true

    var body: some View {
        let settings = MiniSettings.load(mini.folder)
        let versions = Gallery.versions(of: mini, in: model.minis)
        // One being made stays where it is.
        let trashable = versions.filter { $0.name != mini.name && $0.name != model.busyWith }.count
        page
            .navigationTitle(mini.displayName)
            .toolbar { toolbar(kind: settings.kind ?? .character) }
            .inspector(isPresented: $showDetails) {
                details(settings, versions: versions, canKeep: trashable > 0)
                    .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
            }
            .confirmationDialog("Move \(trashable) other \(trashable == 1 ? "version" : "versions") to the Trash?", isPresented: $confirmKeep) {
                Button("Move to Trash", role: .destructive) {
                    let root = MiniSettings.load(mini.folder).versionOf ?? mini.name
                    guard model.keep(mini), root != mini.name, !Gallery.nameInUse(model.install.runs, root),
                          model.waiting(mini.name) == nil, model.busyWith != mini.name else { return }
                    Task { offerName = root }  // once this dialog has gone
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can get them back from the Trash.")
            }
            .confirmationDialog("Call it “\(Mini.displayName(offerName ?? ""))”?",
                                isPresented: Binding(get: { offerName != nil }, set: { if !$0 { offerName = nil } }),
                                presenting: offerName) { name in
                Button("Rename") { rename(to: name) }.keyboardShortcut(.defaultAction)
                Button("Keep “\(mini.displayName)”", role: .cancel) {}
            } message: { _ in
                Text("The other versions are in the Trash, so the plain name is free.")
            }
            .sheet(item: $enlarged) { e in
                VStack(spacing: 12) {
                    Thumbnail(url: e.url, version: mini.madeAt)
                        .frame(minWidth: 400, idealWidth: 560, minHeight: 400, idealHeight: 560)  // with the caption row, fits the smallest main window
                        .onTapGesture { enlarged = nil }
                    HStack {
                        Text("\(mini.displayName) · \(e.caption)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { enlarged = nil }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .background { Button("") { enlarged = nil }.keyboardShortcut(.cancelAction).hidden() }
            }
    }

    /// The 3D view, edge to edge; or why there isn't one yet.
    @ViewBuilder private var page: some View {
        if let stl = mini.stl {
            MiniViewer(stl: stl, version: mini.madeAt, name: mini.displayName, measured: $measured)
                .overlay(alignment: .topLeading) { notes }
        } else if let n = model.waiting(mini.name) {
            ContentUnavailableView("Waiting to be made (\(AppModel.ordinal(n)) in the queue).", systemImage: "hourglass",
                                   description: Text("Ready in \(JobProgress.about(model.queueTimes()[n - 1].ready))."))
        } else {
            ContentUnavailableView("This mini isn't finished yet.", systemImage: "hourglass")
        }
    }

    /// What the job that just made it wants you to know, over the view where it can't be missed.
    @ViewBuilder private var notes: some View {
        if let job = model.job, job.name == mini.name, job.succeeded {
            let lines = job.notes + (job.fragile ? ["Some thin parts may be fragile. Check it in your slicer before printing."] : [])
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.self) { line in
                        Label { Text(line) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(12)
            }
        }
    }

    @ToolbarContentBuilder private func toolbar(kind: MiniKind) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Resize This Mini…", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .resize(mini) }
                    .help("Remakes the print file with new sizes. About a minute. The \(kind == .object ? "object" : "character") itself doesn't change.")
                    .disabled(!mini.hasModel || model.cantStart != nil || model.waiting(mini.name) != nil)
                Button("Show in Finder", systemImage: "folder") { model.showInFinder(mini) }
                    .help("Shows the print file and the previews in Finder.")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Resize this mini, or show it in Finder")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Open in \(model.slicerName)") { if let stl = mini.stl { model.openInSlicer(stl) } }
                .buttonStyle(.glassProminent)
                .help("Opens the print file in \(model.slicerName) to slice and print. Choose another slicer in Settings → General.")
                .disabled(mini.stl == nil)
                .tourCallout(.mini)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showDetails.toggle() } label: {
                Label(showDetails ? "Hide Details" : "Show Details", systemImage: "sidebar.trailing")
            }
            .help(showDetails ? "Hide the details panel" : "Show its size, previews, versions and print tips")
        }
    }

    // MARK: The details panel

    private func details(_ settings: MiniSettings, versions: [Mini], canKeep: Bool) -> some View {
        let kind = settings.kind ?? .character
        return Form {
            sizeSection(settings.made, kind: kind)
            Section { previews } header: { Label("Previews", systemImage: "photo.on.rectangle") }
            if versions.count > 1 { versionsSection(versions, canKeep: canKeep) }
            if mini.stl != nil {
                tipsSection(PrintTips(nozzle: settings.made?.nozzle ?? settings.requested?.nozzle ?? SizeCard.remembered().nozzle, kind: kind))
            }
        }
        .formStyle(.grouped)
    }

    /// What it was made at, and what the print file measures.
    @ViewBuilder private func sizeSection(_ made: Sizes?, kind: MiniKind) -> some View {
        let measured = mini.stl == nil ? nil : measured
        if made != nil || measured != nil {
            Section {
                if let made {
                    ForEach(PrintTips.made(made, kind: kind), id: \.label) { LabeledContent($0.label, value: $0.value) }
                }
                if let measured {
                    LabeledContent("Height with base", value: "\(measured.tall) mm")
                    LabeledContent("Footprint", value: measured.footprint)
                }
            } header: {
                Label("Size", systemImage: "ruler")
            }
            .monospacedDigit()
        }
    }

    /// Its picture and the three views; a click enlarges one, a drag gives the print file.
    private var previews: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach([("Your picture", mini.source ?? mini.upload)] + mini.renders.map { ($0.view.capitalized, Optional($0.url)) },
                    id: \.0) { caption, url in
                preview(caption, url)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func preview(_ caption: String, _ url: URL?) -> some View {
        let tile = Button { enlarged = url.map { Enlarged(caption: caption, url: $0) } } label: {
            VStack(spacing: 4) {
                Thumbnail(url: url, version: mini.madeAt)
                    .aspectRatio(1, contentMode: .fit)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))  // renders have no background
                    .clipShape(.rect(cornerRadius: 10))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        // Dragging a preview out drops the print file itself, under the mini's name.
        if let stl = mini.stl {
            tile
                .onDrag { NSItemProvider(contentsOf: stl) ?? NSItemProvider() }
                .help("Click to enlarge. Drag to Finder or your slicer to copy the print file.")
        } else {
            tile.help("Click to enlarge")
        }
    }

    /// Its versions side by side, this one marked; clicking one shows it.
    private func versionsSection(_ versions: [Mini], canKeep: Bool) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                ForEach(versions) { versionTile($0) }
            }
            .padding(.vertical, 4)
            Button("Keep This One…") { confirmKeep = true }
                .help("Keeps this version and moves the others to the Trash.")
                .disabled(!canKeep)
        } header: {
            Label("Versions", systemImage: "square.on.square")
        }
    }

    private func versionTile(_ v: Mini) -> some View {
        Button { model.selection = v.id } label: {
            VStack(spacing: 4) {
                Thumbnail(url: v.renders.first?.url ?? v.source ?? v.upload, version: v.madeAt)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: v.name == mini.name ? 3 : 0) }
                Text(v.displayName).font(.caption).lineLimit(1)
                    .foregroundStyle(v.name == mini.name ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(v.name == mini.name ? "The version you're looking at." : "Shows this version.")
    }

    private func tipsSection(_ tips: PrintTips) -> some View {
        Section {
            ForEach(tips.lines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tips.copyText, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Settings", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copies these settings as text, to keep in your slicer's notes.")
        } header: {
            Label("Print tips for a \(tips.nozzle) mm nozzle", systemImage: "printer")
        }
    }

    /// The kept version takes the plain name.
    private func rename(to name: String) {
        do { try Gallery.rename(model.install.runs, from: mini.name, to: name, busyWith: model.busyWith) }
        catch { model.problem = model.plainWords(error, else: "Couldn't rename it. Is its folder open in another app?"); return }
        model.reload()
        model.selection = name
    }
}

/// A preview shown big, and what it's a view of.
private struct Enlarged: Identifiable {
    let caption: String
    let url: URL
    var id: URL { url }
}

/// A picture from a mini's folder, read again when the mini changes (a resize rewrites the
/// previews under the same names, which a URL-keyed cache would miss). A new picture fades in
/// over the old one rather than popping; the progress sheet uses it too.
struct Thumbnail: View {
    let url: URL?
    let version: Date
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .id(ObjectIdentifier(image))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .animation(.easeOut(duration: 0.4), value: image.map(ObjectIdentifier.init))
        .task(id: "\(url?.path ?? "")\(version)") { image = url.flatMap(NSImage.init(contentsOf:)) }
    }
}
