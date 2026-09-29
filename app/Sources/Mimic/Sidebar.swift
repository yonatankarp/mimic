import AppKit
import MimicCore
import QuickLook
import SwiftUI

/// The gallery on the left: search, the right-click menu and Quick Look. Rename and trash are
/// asked at window level (MainWindowChrome), so the Mini menu can ask too, sidebar hidden or not.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var preview: URL?

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
        return List(selection: $model.selection) {
            Section("Your Minis") {
                ForEach(shown) { mini in
                    GalleryRow(mini: mini).contextMenu { menu(for: mini) }
                }
            }
        }
        // Delete (or ⌘⌫ from the Mini menu) asks before trashing, as the context menu does.
        .onDeleteCommand { if let mini = model.selected, model.sheet == nil { model.trashing = mini } }
        .overlay {
            if shown.isEmpty && !model.minis.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder private func menu(for mini: Mini) -> some View {
        Button("Open in \(model.slicerName)", systemImage: "printer") {
            if let stl = mini.stl { model.openInSlicer(stl) }
        }
        .disabled(mini.stl == nil)  // not made yet: nothing to print
        Button("Show in Finder", systemImage: "folder") { model.showInFinder(mini) }
        Divider()
        Button("Rename…", systemImage: "pencil") { model.sheet = .rename(mini) }
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
        guard let install = model.install else { return }
        let new = Rules.slug(text)
        guard !new.isEmpty else { problem = "Give it a name with at least one letter or number."; return }
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
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: mini.renders.first?.url ?? mini.source) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.secondary.opacity(0.15) }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(mini.displayName).lineLimit(1)
                Text(mini.madeAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mini.displayName), made \(mini.madeAt.formatted(.relative(presentation: .named)))")
    }
}
