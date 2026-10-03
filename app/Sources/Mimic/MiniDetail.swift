import AppKit
import MimicCore
import QuickLook
import SwiftUI

/// A mini's page: the 3D view fills it, running up under the toolbar; Open in the slicer and
/// More are in the toolbar (`MiniToolbarItems`); its size, previews, versions and print tips are in the details
/// panel on the right, which the toolbar shows and hides.
struct MiniDetail: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    @Environment(Reporter.self) private var reporter
    /// The preview tile ← → move from while the previews have the keyboard.
    @State private var picked: MiniPreview?
    @FocusState private var previewsFocused: Bool
    /// The preview open in Quick Look, or nil.
    @State private var looking: URL?
    @State private var copied = false
    @State private var copiedDescription = false
    @State private var confirmKeep = false
    /// The plain name offered after Keep This One.
    @State private var offerName: String?
    /// What the viewer measured in the print file.
    @State private var measured: Measured?
    /// Why Build Shape or Draw Again on its picture couldn't start.
    @State private var checkProblem: String?
    /// On the model, so View → Show/Hide Details always names what it will do.
    private var showDetails: Bool { model.showDetails }

    var body: some View {
        @Bindable var model = model
        let settings = mini.settings
        let versions = Gallery.versions(of: mini, in: model.minis)
        // One being made stays where it is.
        let trashable = versions.filter { $0.name != mini.name && $0.name != model.current?.name }.count
        page
            .navigationTitle(mini.displayName)
            .inspector(isPresented: $model.showDetails) {
                details(settings, versions: versions, canKeep: trashable > 0)
                    .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
            }
            .confirmationDialog("Move \(trashable) other \(trashable == 1 ? "version" : "versions") to the Trash?", isPresented: $confirmKeep) {
                Button("Move to Trash", role: .destructive) {
                    let root = mini.settings.versionOf ?? mini.name
                    guard model.keep(mini), root != mini.name, !Gallery.nameInUse(model.install.runs, root),
                          model.waiting(mini.name) == nil, model.current?.name != mini.name else { return }
                    Task { offerName = root }  // once this dialog has gone
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Edit → Undo puts them back.")
            }
            .confirmationDialog("Call it “\(mini.displayName(renamedTo: offerName ?? ""))”?",
                                isPresented: Binding(get: { offerName != nil }, set: { if !$0 { offerName = nil } }),
                                presenting: offerName) { name in
                Button("Rename") { rename(to: name) }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The other versions are in the Trash, so the plain name is free.")
            }
            // Its previews in Quick Look, in page order: ← → go through them there too, and the
            // tile of the one last shown stays picked here, so ← → carry on from it.
            .quickLookPreview($looking, in: mini.previews.map(\.url))
            .onChange(of: looking) { _, url in
                if let p = mini.previews.first(where: { $0.url == url }) { picked = p; previewsFocused = true }
            }
            // Another mini, or a sheet from the toolbar or a menu, takes over from it.
            .onChange(of: mini.name) { looking = nil }
            .onChange(of: model.sheet) { if model.sheet != nil { looking = nil } }
            // Keep This One in Compare Side by Side (#99) asks here, once that sheet has gone.
            .onChange(of: model.askToKeep == mini.name, initial: true) { _, asked in
                if asked { model.askToKeep = nil; confirmKeep = true }
            }
    }

    /// The 3D view, edge to edge; or why there isn't one yet.
    @ViewBuilder private var page: some View {
        if let stl = mini.printFile {
            MiniViewer(stl: stl, version: mini.madeAt, name: mini.displayName, facesAway: mini.facesAway, measured: $measured)
                .overlay(alignment: .topLeading) { notes }
        } else if let n = model.waiting(mini.name) {
            ContentUnavailableView("Waiting to be made", systemImage: "hourglass",
                                   description: Text("\(AppModel.ordinal(n).capitalizedFirst) in the queue. Ready in \(JobProgress.about(model.readyIn(mini.name) ?? 0))."))
        } else if let s = model.current, s.name == mini.name {
            // Being made (#77): which step, and how long it has left, with the progress a click away.
            TimelineView(.periodic(from: .now, by: 5)) { t in
                ContentUnavailableView {
                    Label("Being made", systemImage: "cube")
                } description: {
                    Text("Step \(s.step.rawValue) of 3: \(s.step.during). \(JobProgress.about(model.estimate(s).left(s, now: t.date)).capitalizedFirst) left.")
                } actions: {
                    Button("Show Progress") { model.showWindow(); model.jobPopover = true }
                }
            }
        } else if model.pictureToCheck(mini), let source = mini.source {
            checkPage(source)
        } else if model.canRetry(mini) {
            // Didn't finish (#78): why, as saved when it failed, and Try Again.
            let settings = mini.settings
            ContentUnavailableView {
                Label("This mini didn't finish", systemImage: "exclamationmark.triangle")
            } description: {
                Text(settings.failed ?? "It stopped before it was done.")
            } actions: {
                Button("Try Again") { model.tryAgain(mini) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.requiredProblem != nil)
                    .help(model.requiredProblem ?? "Makes it again from the step that failed")
                Button("Report a Problem…") { reporter.report(mini) }
                    .help("Makes a file of what happened and opens a form on GitHub to send it with")
            }
        } else if mini.settings.isImported && mini.hasModel && model.waiting(mini.name) == nil {
            // An imported model (#96) has nothing of its own to make again: Resize makes its print file.
            ContentUnavailableView {
                Label("This mini didn't finish", systemImage: "exclamationmark.triangle")
            } description: {
                Text(mini.settings.failed ?? "Its print file isn't made yet.")
            } actions: {
                Button("Resize This Mini…") { model.sheet = .resize(mini) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.requiredProblem != nil)
                    .help(model.requiredProblem ?? "Makes its print file. Try Again is off for a model you imported.")
            }
        } else {
            ContentUnavailableView("This mini isn't finished yet", systemImage: "hourglass")
        }
    }

    /// Its picture, redrawn with a change, for you to check before the 3D shape is built (#156).
    private func checkPage(_ source: URL) -> some View {
        VStack(spacing: 16) {
            // By the picture's own time, which is the mini's while it has no print file: Draw
            // Again draws a new one in its place.
            Thumbnail(url: source, version: mini.madeAt)
                .frame(maxWidth: 480, maxHeight: 480)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("The picture of \(mini.displayName)")
            Text("Check the picture").font(.title2.bold())
            Text("If the change came out right, build the 3D shape from it. If not, draw it again.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let checkProblem { Text(checkProblem).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Draw Again") { check { try model.redrawPicture(mini.name) } }
                    .help("Draws the picture again with a new variation number")
                Button("Build Shape") { check { try model.buildShape(mini.name) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Makes the 3D shape from this picture")
            }
            .disabled(model.requiredProblem != nil)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func check(_ start: () throws -> Void) {
        checkProblem = nil
        do { try start() } catch { checkProblem = model.plainWords(error) }
    }

    /// What the run that made it wants you to know, over the view where it can't be missed: kept
    /// with the mini (#80), so it's still said after a relaunch, until a resize replaces it.
    @ViewBuilder private var notes: some View {
        let saved = mini.settings
        let lines = (saved.notes ?? []) + (saved.fragile == true ? [PrepReport.footprintNote] : [])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label { Text(line) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))  // content, not a control: no glass
            .padding(12)
        }
    }

    // MARK: The details panel

    private func details(_ settings: MiniSettings, versions: [Mini], canKeep: Bool) -> some View {
        let kind = settings.kind ?? .character
        return Form {
            sizeSection(settings.made, kind: kind)
            Section { previews } header: { Label("Previews", systemImage: "photo.on.rectangle") }
            if versions.count > 1 { versionsSection(versions, canKeep: canKeep) }
            madeFromSection(MadeFrom(settings, created: mini.created))
            if mini.finished {
                tipsSection(PrintTips(nozzle: settings.made?.nozzle ?? settings.requested?.nozzle ?? SizeCard.remembered().nozzle, kind: kind))
            }
        }
        .formStyle(.grouped)
    }

    /// What it was made at, and what the print file measures.
    @ViewBuilder private func sizeSection(_ made: Sizes?, kind: MiniKind) -> some View {
        let measured = !mini.finished ? nil : measured
        if made != nil || measured != nil {
            Section {
                if let made {
                    ForEach(PrintTips.made(made, kind: kind), id: \.label) { LabeledContent($0.label, value: $0.value) }
                }
                if let measured {
                    LabeledContent("Height with base", value: "\(measured.tall) mm")
                    LabeledContent("Footprint", value: measured.footprint)
                    LabeledContent("Filament", value: Filament.words(measured.volume))
                        .help("Grams of PLA and metres of 1.75 mm filament, printed solid; infill makes a big mini take less")
                }
            } header: {
                Label("Size", systemImage: "ruler")
            }
            .monospacedDigit()
        }
    }

    /// Its picture, wide on top, and its views two by two under it; a click opens one in Quick
    /// Look, a drag gives the print file. Once one is clicked, ← → go through them all in order,
    /// as in Quick Look, ↑ ↓ move up and down the grid, and Space or Return opens Quick Look.
    private var previews: some View {
        let all = mini.previews, views = all.suffix(mini.renders.count), current = picked.flatMap { all.contains($0) ? $0 : nil } ?? all.first
        return VStack(spacing: 12) {
            if let picture = all.dropLast(views.count).first { preview(picture, wide: true, current: current) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(views) { preview($0, current: current) }
            }
        }
        .padding(.vertical, 4)
        .focusable(interactions: .edit)  // takes the keyboard without Keyboard Navigation turned on
        .focused($previewsFocused)
        .focusEffectDisabled()  // the picked tile is ringed instead
        // The one place arrows are handled here: the tiles can't take focus, and every arrow is
        // handled, ends included, so nothing else also moves on the same press.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let current else { return .ignored }
            let next = switch press.key {
            case .leftArrow: all.step(from: current, by: -1)
            case .rightArrow: all.step(from: current, by: 1)
            case .upArrow: all.step(from: current, down: -1, wide: all.count - views.count)
            default: all.step(from: current, down: 1, wide: all.count - views.count)
            }
            if let next {
                picked = next
                if looking != nil { looking = next.url }  // Quick Look follows, if it's open
            }
            return .handled
        }
        // As in Finder and the sidebar: Space opens Quick Look, and closes it again.
        .onKeyPress(keys: [.space, .return]) { _ in
            guard let current else { return .ignored }
            looking = looking == nil ? current.url : nil
            return .handled
        }
    }

    @ViewBuilder private func preview(_ p: MiniPreview, wide: Bool = false, current: MiniPreview?) -> some View {
        let tile = Button {
            picked = p
            previewsFocused = true
            looking = p.url
        } label: {
            VStack(spacing: 4) {
                Thumbnail(url: p.url, version: mini.madeAt)
                    .aspectRatio(wide ? 2 : 1, contentMode: .fit)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))  // renders have no background
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor, lineWidth: previewsFocused && p == current ? 3 : 0)
                    }
                Text(p.caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)  // the section has the keyboard, so arrows don't move focus between tiles
        // Dragging a preview out drops the print file itself, under the mini's name.
        if let stl = mini.printFile {
            tile
                .onDrag { NSItemProvider(contentsOf: stl) ?? NSItemProvider() }
                .help("Click or press Space for Quick Look; drag out for the print file")
        } else {
            tile.help("Click, or press Space, to open it in Quick Look")
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
            let finished = versions.filter { $0.finished }
            Button("Compare Side by Side…") {
                let i = finished.firstIndex { $0.name == mini.name } ?? 0
                model.sheet = .compare(finished[i].name, finished[(i + 1) % finished.count].name)
            }
            .help("Shows two versions in 3D next to each other, turning and zooming together.")
            .disabled(finished.count < 2 || model.sheet != nil)
        } header: {
            Label("Versions", systemImage: "square.on.square")
        }
    }

    private func versionTile(_ v: Mini) -> some View {
        Button { model.selection = [v.id] } label: {
            VStack(spacing: 4) {
                Thumbnail(url: v.thumbnail, version: v.madeAt)
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

    /// How it was made (#83): only what its settings recorded.
    @ViewBuilder private func madeFromSection(_ made: MadeFrom) -> some View {
        if !made.isEmpty {
            Section {
                if let description = made.description {
                    Text(description).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(made.rows, id: \.label) { LabeledContent($0.label, value: $0.value) }
                // What was changed in its picture, oldest first (#156): what tells versions apart.
                ForEach(Array(made.fixes.enumerated()), id: \.offset) { i, fix in
                    LabeledContent(i == 0 ? "Changed" : "Then") {
                        Text(fix).textSelection(.enabled).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if mini.settings.isImported {
                    Text(MiniActionButton.imported).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let description = made.description {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(description, forType: .string)
                        copiedDescription = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copiedDescription = false }
                    } label: {
                        Label(copiedDescription ? "Copied" : "Copy Description", systemImage: copiedDescription ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copies the description it was drawn from, to use again.")
                }
            } header: {
                Label("Made from", systemImage: "wand.and.stars")
            }
        }
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

    /// The kept version takes the plain name. Undo gives it back its own, so a second Undo can
    /// put the version that had the plain name back from the Trash.
    private func rename(to name: String) {
        do { try model.rename(mini, to: name) }
        catch { model.problem = Problem("Couldn't rename it", model.plainWords(error, else: "Is its folder open in another app?")); return }
        model.selection = [name]
    }
}

/// A picture from a mini's folder, read again when the mini changes (a resize rewrites the
/// previews under the same names, which a URL-keyed cache would miss). A new picture fades in
/// over the old one rather than popping; the job's popover and the sidebar use it too.
struct Thumbnail: View {
    let url: URL?
    let version: Date
    /// Fills its frame, cropping, as the sidebar's rows do; whole otherwise.
    var fill = false
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                    .id(ObjectIdentifier(image))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        // With Reduce Motion a new picture takes the old one's place at once.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: image.map(ObjectIdentifier.init))
        // Read off the main thread: a picture can be a few megabytes.
        .task(id: "\(url?.path ?? "")\(version)") { [url] in image = await Task.detached { url.flatMap(NSImage.init(contentsOf:)) }.value }
    }
}

/// The mini page's toolbar items: More (Copies first), Open in the slicer, and the details
/// panel's toggle, one item each so each can be moved or taken out in Customize Toolbar…
/// (#482). In the window's toolbar, empty without a mini's page, rather than on the page: the
/// page's own `.toolbar(id:)` listed them twice, and NSToolbar stopped Mimic on the next mini.
struct MiniToolbarItems: CustomizableToolbarContent {
    let model: AppModel

    /// What the page is showing, as ContentView picks it.
    private var mini: Mini? { model.setup.installed ? model.selected : nil }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "more", placement: .primaryAction) {
            if let mini {
                Menu {
                    MiniActionButton(action: .copies, minis: [mini])
                    MiniActionButton(action: .resize, minis: [mini])
                    MiniActionButton(action: .editAndMakeAgain, minis: [mini])
                    MiniActionButton(action: .exportForTabletop, minis: [mini])
                    MiniActionButton(action: .showInFinder, minis: [mini])
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("Print copies, resize, make it again with changes, export it for a virtual tabletop, or show it in Finder")
            }
        }
        ToolbarItem(id: "open", placement: .primaryAction) {
            // Prominent only once it works: until then the page's own button (Try Again, Build
            // Shape) is the one to press, and a pale disabled one here shouldn't outshine it.
            if let mini, mini.finished {
                MiniActionButton(action: .open, minis: [mini], showsIcon: false)
                    .buttonStyle(.glassProminent)
                    .tourCallout(.mini)
            } else if let mini {
                MiniActionButton(action: .open, minis: [mini], showsIcon: false)
                    .tourCallout(.mini)
            }
        }
        ToolbarItem(id: "details", placement: .primaryAction) {
            if mini != nil {
                Button { model.showDetails.toggle() } label: {
                    Label(model.showDetails ? "Hide Details" : "Show Details", systemImage: "sidebar.trailing")
                }
                .help(model.showDetails ? "Hide the details panel (⌃⌘I)" : "Show size, previews, versions and print tips (⌃⌘I)")
            }
        }
    }
}
