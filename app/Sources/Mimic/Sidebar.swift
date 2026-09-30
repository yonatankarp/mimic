import AppKit
import MimicCore
import QuickLook
import SwiftUI

/// The gallery on the left: a collapsible section per project, then Unsorted; search, the
/// right-click menus, drag and drop between projects, and Quick Look. Rename, trash and the
/// project questions are asked at window level (MainWindowChrome), so the Mini menu can ask
/// too, sidebar hidden or not.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var preview: URL?
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
        .navigationTitle("Your Minis")
        .tourStop(.gallery, arrow: .trailing)
        // Space previews the print file, as in Finder; a second space closes it.
        .onKeyPress(.space) {
            if preview != nil { preview = nil; return .handled }
            guard let stl = model.selected?.stl else { return .ignored }
            preview = stl
            return .handled
        }
        .quickLookPreview($preview)
    }

    private var list: some View {
        @Bindable var model = model
        let shown = Gallery.search(model.minis, query)
        let searching = model.minis.count > Gallery.searchAfter && !query.trimmingCharacters(in: .whitespaces).isEmpty
        return List(selection: $model.selection) {
            if model.projects.isEmpty {
                Section { rows(shown, project: nil) } header: { header("Your Minis") }
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
                            Label(project, systemImage: "folder")
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
                Button { model.sheet = .newProject(moving: nil) } label: { Label("New Project", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("A folder to group minis in (⇧⌘N). Drag minis onto it to move them.")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        // A new mini slides into the list (and a trashed one out) rather than popping.
        .animation(reduceMotion ? nil : .default, value: shown.map(\.id))
        // Delete (or ⌘⌫ from the Mini menu) asks before trashing, as the context menu does.
        .onDeleteCommand { if let mini = model.selected, model.sheet == nil { model.trashing = mini } }
        .overlay {
            if shown.isEmpty && !model.minis.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func rows(_ minis: [Mini], project: String?) -> some View {
        ForEach(minis) { mini in
            GalleryRow(mini: mini, status: rowStatus(mini)).contextMenu { menu(for: mini) }
                .help("Press space to preview it. Drag it onto a project to move it. Right-click for more.")
                .draggable(mini.name)
                // Dropped on a mini: into that mini's project.
                .dropDestination(for: String.self) { names, _ in model.move(names, to: project); return true }
        }
    }

    /// A section's title with a + for a new project, so there's one in the list from the start.
    private func header(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { model.sheet = .newProject(moving: nil) } label: { Image(systemName: "plus") }
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

    @ViewBuilder private func menu(for mini: Mini) -> some View {
        Button("Open in \(model.slicerName)", systemImage: "printer") {
            if let stl = mini.stl { model.openInSlicer(stl) }
        }
        .disabled(mini.stl == nil)  // not made yet: nothing to print
        Button("Show in Finder", systemImage: "folder") { model.showInFinder(mini) }
        Button("Resize This Mini…", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .resize(mini) }
            .disabled(!mini.hasModel || model.cantStart != nil || model.waiting(mini.name) != nil)
        Divider()
        AnotherVersionButton(mini: mini)
        MoveToProjectMenu(mini: mini)
        Divider()
        Button("Rename…", systemImage: "pencil") { model.sheet = .rename(mini) }
            .disabled(model.waiting(mini.name) != nil)
        Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.trashing = mini }
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
        let wasSelected = model.selection == mini.id
        // Both in one go, so the window never shows another mini in between.
        model.reload()
        if wasSelected { model.selection = new }
        dismiss()
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
        return MiniSettings.load(mini.folder).made.map(PrintTips.shortLine) ?? mini.madeAt.formatted(.relative(presentation: .named))
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
    @Environment(AppModel.self) private var model
    var body: some View {
        Button("Make Another Version", systemImage: "square.on.square") { model.makeAnotherVersion(mini) }
            .help("Makes it again from the same picture or description, with a different variation number: "
                  + "a detail that came out as a blob may come out right. It goes next to this one, and waits its turn if Mimic is busy.")
            .disabled(model.cantStart != nil || !JobRunner.canMakeAnotherVersion(mini))
    }
}

/// Move to Project ▸, for the right-click menu and the Mini menu. A mini being made or waiting
/// can't move; the menu says so instead of listing projects.
struct MoveToProjectMenu: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu("Move to Project", systemImage: "folder") {
            if let why = model.whyCantMove(mini) {
                Text(why)
            } else {
                Button("Unsorted") { model.move([mini.name], to: nil) }.disabled(mini.project == nil)
                if !model.projects.isEmpty { Divider() }
                ForEach(model.projects, id: \.self) { p in
                    Button(p) { model.move([mini.name], to: p) }.disabled(mini.project == p)
                }
                Divider()
                Button("New Project…") { model.sheet = .newProject(moving: mini) }
            }
        }
    }
}

/// Names a new project (moving a mini into it when asked from Move to Project), or renames one.
struct ProjectNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil: a new project.
    let renaming: String?
    var moving: Mini?
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renaming.map { "Rename “\($0)”" } ?? "New Project").font(.headline)
            if renaming == nil {
                Text(moving.map { "A folder in your minis folder. \($0.displayName) moves into it." }
                     ?? "A folder in your minis folder, to group minis in. Drag minis onto it to move them there.")
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
                if let moving { model.move([moving.name], to: name) }
            }
        } catch {
            problem = model.plainWords(error, else: "Couldn't do that. Is the folder open in another app?"); return
        }
        dismiss()
    }
}
