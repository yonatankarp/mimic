import AppKit
import MimicCore
import QuickLook
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The gallery on the left: a collapsible section per project, then Unsorted; search, the
/// right-click menus, drag and drop between projects, and Quick Look. Rename, trash and the
/// project questions are asked at window level (MainWindowChrome), so the Mini menu can ask
/// too, sidebar hidden or not.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var preview: URL?
    /// A mini has been picked in the list since it appeared: the gallery tip can show.
    @State private var picked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only the search field sits inside the branch: anything attached on the other side
        // would be torn down when a mini comes or goes past the seventh.
        Group {
            // Same threshold as the filter, so the field and the filtering never disagree.
            if model.minis.count > Gallery.searchAfter {
                list.searchable(text: $query, placement: .sidebar, prompt: "Find a mini")
            } else {
                list
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .navigationTitle("Minis")
        // The list's shortcuts, the first time a finished mini is picked in it.
        .popoverTip(galleryTip, arrowEdge: .trailing)
        .onChange(of: model.selection) { picked = true }
        // Space previews the print file, as in Finder; a second space closes it.
        .onKeyPress(.space) {
            if preview != nil { preview = nil; return .handled }
            guard let stl = model.selected?.stl else { return .ignored }
            preview = stl
            return .handled
        }
        .quickLookPreview($preview)
    }

    /// Named, not inline: an optional tip chosen in the modifier chain is slow to type-check.
    private var galleryTip: (any Tip)? {
        guard picked, model.selected?.stl != nil else { return nil }
        return Tips.unlessTouring(GalleryTip())
    }

    private var list: some View {
        @Bindable var model = model
        let shown = Gallery.search(model.minis, query)
        let searching = model.minis.count > Gallery.searchAfter && !query.trimmingCharacters(in: .whitespaces).isEmpty
        return List(selection: $model.selection) {
            if model.projects.isEmpty {
                Section { rows(shown, project: nil) } header: { header("Minis") }
            } else {
                ForEach(model.projects, id: \.self) { project in
                    let inside = shown.filter { $0.project == project }
                    if !searching || !inside.isEmpty {
                        Section(isExpanded: expanded(project, searching)) {
                            rows(inside, project: project)
                            if inside.isEmpty {
                                Text("Drag minis here").foregroundStyle(.secondary).font(.callout)
                                    .selectionDisabled()
                                    .dropDestination(for: String.self) { names, _ in model.move(names, to: project); return true }
                            }
                        } header: {
                            HStack {
                                Label(project, systemImage: "folder")
                                Spacer()
                                ProjectFilament(minis: model.minis.filter { $0.project == project })
                            }
                                .contextMenu { projectMenu(project) }
                                .dropDestination(for: String.self) { names, _ in model.move(names, to: project); return true }
                                .help("Drag minis onto it to move them here. Right-click for more.")
                        }
                    }
                }
                Section {
                    rows(shown.filter { $0.project == nil }, project: nil)
                } header: {
                    header("Unsorted")
                        .dropDestination(for: String.self) { names, _ in model.move(names, to: nil); return true }
                        .help("Minis in no project. Drag minis here to take them out of theirs.")
                }
            }
        }
        .listStyle(.sidebar)
        // Like Notes' New Folder: always there, the first project included.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.sheet = .newProject(moving: []) } label: { Label("New Project", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("A folder to group minis in (⇧⌘N). Drag minis onto it to move them.")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        // A new mini slides into the list (and a trashed one out) rather than popping.
        .animation(reduceMotion ? nil : .default, value: shown.map(\.id))
        // Delete (or ⌘⌫ from the Mini menu) moves them to the Trash, as the context menu does.
        .onDeleteCommand { if model.sheet == nil, !model.chosen.isEmpty { model.askToTrash(model.chosen) } }
        .overlay {
            if shown.isEmpty && !model.minis.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func rows(_ minis: [Mini], project: String?) -> some View {
        ForEach(minis) { mini in
            // Per row, not the List's contextMenu(forSelectionType:), which took the project
            // headers' own menus: every selected mini when it's among several, else this one.
            GalleryRow(mini: mini, status: rowStatus(mini))
                .contextMenu {
                    if model.selection.count > 1 && model.selection.contains(mini.id) { SeveralMenu(minis: model.chosen) } else { menu(for: mini) }
                }
                .help("Space to preview; drag onto a project, or out for its print file; ⌘-click to select several")
                .draggable(drag(mini))
                // Dropped on a mini: into that mini's project.
                .dropDestination(for: String.self) { names, _ in model.move(names, to: project); return true }
        }
    }

    /// A section's title with a New Project button, so there's one in the list from the start.
    /// A folder, as at the bottom: + is New Mini, in the toolbar.
    private func header(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { model.sheet = .newProject(moving: []) } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless)
                .help("New Project (⇧⌘N): a folder to group minis in.")
                .accessibilityLabel("New Project")
        }
    }

    /// Open unless collapsed; every project is open while searching, so nothing found is hidden.
    private func expanded(_ project: String, _ searching: Bool) -> Binding<Bool> {
        Binding(get: { searching || !model.collapsed.contains(project) },
                set: { open in if open { model.collapsed.remove(project) } else { model.collapsed.insert(project) } })
    }

    @ViewBuilder private func projectMenu(_ project: String) -> some View {
        Button("New Mini in This Project…", systemImage: "plus") { model.makeInProject = project; model.sheet = .make }
            .disabled(!model.setup.installed)
        Button("Open Together in \(model.slicerName)", systemImage: "printer") { model.openTogether(model.minis.filter { $0.project == project }) }
            .disabled(model.minis.filter { $0.project == project && $0.stl != nil }.count < 2 || model.packing)
        Button("Show in Finder", systemImage: "folder") { model.showInFinder(project: project) }
        Button("Resize All…", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .resizeAll(project) }
            .disabled(!model.minis.contains { $0.project == project && $0.hasModel } || model.cantStart != nil)
        Divider()
        Button("Rename Project…", systemImage: "pencil") { model.sheet = .renameProject(project) }
        Button("Delete Project…", systemImage: "trash", role: .destructive) { model.deletingProject = project }
    }

    /// "Waiting (2nd)" for a mini in the queue, "Being made…" for the one running.
    private func rowStatus(_ mini: Mini) -> String? {
        if let n = model.waiting(mini.name) { return "Waiting (\(AppModel.ordinal(n)))" }
        if let s = model.current, s.name == mini.name { return s.kind == .prep ? "Resizing…" : "Being made…" }
        return nil
    }

    /// One of several selected drags them all, as their names: to a project, never out (one
    /// print file is all a drag out can carry).
    private func drag(_ mini: Mini) -> MiniDrag {
        guard model.selection.count > 1, model.selection.contains(mini.id) else { return MiniDrag(name: mini.name, stl: mini.stl) }
        return MiniDrag(name: Gallery.dragged(model.chosen.map(\.name)), stl: nil)
    }

    @ViewBuilder private func menu(for mini: Mini) -> some View {
        Button("Open in \(model.slicerName)", systemImage: "printer") {
            if let stl = mini.stl { model.openInSlicer(stl) }
        }
        .disabled(mini.stl == nil)  // not made yet: nothing to print
        CopiesButton(minis: [mini])
        Button("Show in Finder", systemImage: "folder") { model.showInFinder([mini]) }
        Button("Resize This Mini…", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .resize(mini) }
            .disabled(!mini.hasModel || model.cantStart != nil || model.waiting(mini.name) != nil)
        Divider()
        AnotherVersionButton(mini: mini)
        NewShapeButton(mini: mini)
        MoveToProjectMenu(minis: [mini])
        Divider()
        if model.canRetry(mini) {
            Button("Try Again", systemImage: "arrow.clockwise") { model.tryAgain(mini) }
                .disabled(model.cantStart != nil)
        }
        Button("Rename…", systemImage: "pencil") { model.sheet = .rename(mini) }
            .disabled(model.waiting(mini.name) != nil)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.askToTrash([mini]) }
    }
}

/// What can be done to several minis at once: in the right-click menu and on the page that
/// stands in for a mini's when several are selected.
struct SeveralMenu: View {
    let minis: [Mini]
    @Environment(AppModel.self) private var model
    var body: some View {
        Button("Open Together in \(model.slicerName)", systemImage: "printer") { model.openTogether(minis) }
            .disabled(minis.filter { $0.stl != nil }.count < 2 || model.packing)
            .help("One print file with all of them on the bed, each its own object named after it.")
        CopiesButton(minis: minis)
        Button("Show in Finder", systemImage: "folder") { model.showInFinder(minis) }
        Button("Resize \(minis.count) Minis…", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .resizeSeveral(minis) }
            .disabled(!minis.contains(where: \.hasModel) || model.cantStart != nil)
        MoveToProjectMenu(minis: minis)
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.askToTrash(minis) }
    }
}

/// Copies…, next to Open in the slicer: asks how many, for one mini or each of several.
struct CopiesButton: View {
    let minis: [Mini]
    var showsIcon = true
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.sheet = .copies(minis) } label: {
            if showsIcon { Label("Copies…", systemImage: "square.on.square") } else { Text("Copies…") }
        }
        .help(minis.count == 1 ? "Several of this mini on the plate, in one print file" : "Several of each on the plate, in one print file")
        .disabled(!minis.contains { $0.stl != nil } || model.packing || model.sheet != nil)
    }
}

/// A mini dragged from the list. Inside Mimic it's its name, which the projects take to move it
/// (never a copy of its files); to Finder or a slicer it's its print file, as a dragged preview is.
/// No bare file URL goes out: Finder could take that as a move out of the minis folder.
struct MiniDrag: Transferable {
    let name: String
    let stl: URL?

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.name).visibility(.ownProcess)
        FileRepresentation(exportedContentType: UTType(filenameExtension: "stl") ?? .data) { SentTransferredFile($0.stl!) }
            .exportingCondition { $0.stl != nil }
    }
}

/// Asks for the new name as people see it ("Dwarf Cleric") and says why one is refused.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mini: Mini
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(mini.displayName)”").font(.headline)
            TextField("New name", text: $text)  // Return presses Rename
            if let problem {
                Text(problem).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { text = mini.displayName }
    }

    private func rename() {
        let install = model.install
        let new = Rules.slug(text)
        guard !new.isEmpty else { problem = "Give it a name with at least one letter or number."; return }
        guard model.waiting(mini.name) == nil else { problem = "It's waiting in the queue. Rename it once it's made."; return }
        do {
            try Gallery.rename(install.runs, from: mini.name, to: new, busyWith: model.busyWith)
        } catch {
            problem = model.plainWords(error, else: "Couldn't rename it. Is its folder open in another app?"); return
        }
        let wasSelected = model.selection.contains(mini.id)
        // Both in one go, so the window never shows another mini in between.
        if wasSelected { model.selection.remove(mini.id); model.selection.insert(new) }
        model.reload()
        dismiss()
    }
}

/// Asks how many copies to print, then opens them in the slicer in one print file.
struct CopiesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let minis: [Mini]
    @State private var copies = 2

    var body: some View {
        let made = minis.filter { $0.stl != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text(made.count == 1 ? "Copies of “\(made[0].displayName)”" : "Copies of \(made.count) minis").font(.headline)
            Stepper(value: $copies, in: ThreeMF.copies) {
                Text(made.count == 1 ? (copies == 1 ? "1 copy" : "\(copies) copies") : "\(copies) of each")
                    .monospacedDigit()
            }
            Text("They go side by side on the plate in one print file.").foregroundStyle(.secondary).font(.callout)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open in \(model.slicerName)") { dismiss(); model.openTogether(made, copies: copies) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct GalleryRow: View {
    let mini: Mini
    /// Shown instead of what it was made at: "Waiting (2nd)".
    var status: String?

    /// Under its name: its status, else "Not finished", else "32 mm · 0.4 mm nozzle"; when it was
    /// made only for a mini from before its sizes were kept.
    private var line: String {
        if let status { return status }
        if mini.stl == nil { return "Not finished" }
        return mini.settings.made.map(PrintTips.shortLine) ?? mini.madeAt.formatted(.relative(presentation: .named))
    }

    var body: some View {
        let line = line
        HStack(spacing: 10) {
            // A mini waiting in the queue has only the picture it was given.
            AsyncImage(url: mini.renders.first?.url ?? mini.source ?? mini.upload) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.secondary.opacity(0.15) }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(mini.displayName).lineLimit(1)
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mini.displayName), \(line)")
    }
}

/// Make Another Version, for the right-click menu and the Mini menu.
struct AnotherVersionButton: View {
    let mini: Mini
    var showsIcon = true
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.makeAnotherVersion(mini) } label: {
            if showsIcon { Label("Make Another Version", systemImage: "square.on.square") } else { Text("Make Another Version") }
        }
            .help("Makes it again from the same picture or description, with a different variation number: "
                  + "a detail that came out as a blob may come out right. It goes next to this one, and waits its turn if Mimic is busy.")
            .disabled(model.cantStart != nil || !JobRunner.canMakeAnotherVersion(mini))
    }
}

/// New 3D Shape, next to Make Another Version: the same picture, only the 3D shape made again.
struct NewShapeButton: View {
    let mini: Mini
    var showsIcon = true
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.makeNewShape(mini) } label: {
            if showsIcon { Label("New 3D Shape", systemImage: "cube") } else { Text("New 3D Shape") }
        }
            .help("Keeps this picture and makes only the 3D shape again, with a different variation number: "
                  + "quicker than Make Another Version, and a picture you like stays. It goes next to this one, and waits its turn if Mimic is busy.")
            .disabled(model.cantStart != nil || !JobRunner.canMakeNewShape(mini))
    }
}

/// Move to Project ▸, for the right-click menu and the Mini menu, for one mini or several. One
/// mini being made or waiting can't move, and the menu says so instead of listing projects;
/// among several, it stays and says so.
struct MoveToProjectMenu: View {
    let minis: [Mini]
    var showsIcon = true
    @Environment(AppModel.self) private var model
    var body: some View {
        let names = minis.map(\.name)
        Menu {
            if let why = minis.count == 1 ? minis.first.flatMap(model.whyCantMove) : nil {
                Text(why)
            } else {
                Button("Unsorted") { model.move(names, to: nil) }.disabled(minis.allSatisfy { $0.project == nil })
                if !model.projects.isEmpty { Divider() }
                ForEach(model.projects, id: \.self) { p in
                    Button(p) { model.move(names, to: p) }.disabled(minis.allSatisfy { $0.project == p })
                }
                Divider()
                Button("New Project…") { model.sheet = .newProject(moving: minis) }
            }
        } label: {
            if showsIcon { Label("Move to Project", systemImage: "folder") } else { Text("Move to Project") }
        }
    }
}

/// Names a new project (moving a mini into it when asked from Move to Project), or renames one.
struct ProjectNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil: a new project.
    let renaming: String?
    var moving: [Mini] = []
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renaming.map { "Rename “\($0)”" } ?? "New Project").font(.headline)
            if renaming == nil {
                Text(moving.isEmpty ? "A folder in your minis folder, to group minis in. Drag minis onto it to move them there."
                     : "A folder in your minis folder. \(moving.count == 1 ? moving[0].displayName + " moves" : "The \(moving.count) minis move") into it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Project name", text: $text, prompt: Text("e.g. Tiefling Party"))  // Return presses the button
            if let problem {
                Text(problem).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(renaming == nil ? "Create" : "Rename", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { text = renaming ?? "" }
    }

    private func save() {
        do {
            if let renaming {
                try model.renameProject(renaming, to: text)
            } else {
                let name = try model.createProject(text)
                if !moving.isEmpty { model.move(moving.map(\.name), to: name) }
            }
        } catch {
            problem = model.plainWords(error, else: "Couldn't do that. Is the folder open in another app?"); return
        }
        dismiss()
    }
}

/// "up to 23 g" beside a project's name: its minis' filament added up. Read from their print
/// files off the main thread, again whenever one is made or resized.
private struct ProjectFilament: View {
    let minis: [Mini]

    @State private var total: Double?

    var body: some View {
        Text(total.map(Filament.short) ?? "")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .help("Roughly the filament for every mini in it, printed solid")
            .task(id: minis.map { "\($0.stl?.path ?? "")@\($0.madeAt.timeIntervalSince1970)" }) {
                let stls = minis.compactMap(\.stl)
                total = stls.isEmpty ? nil : await Task.detached { stls.compactMap(Filament.volume(stl:)).reduce(0, +) }.value
            }
    }
}
