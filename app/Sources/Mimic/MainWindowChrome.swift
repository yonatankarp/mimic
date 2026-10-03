import AppKit
import MimicCore
import SwiftUI

/// What the main window adds around the gallery: the sheets and questions, and the toolbar's
/// New Mini button and job progress. Kept here so the window's own layout stays about the gallery.
struct MainWindowChrome: ViewModifier {
    // Named, not written inline: inside the long modifier chain below it made one expression
    // too slow for CI's Swift to type-check.
    private var showsProblem: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    /// The window's size under its toolbar: New Mini and Resize grow up to it.
    @State private var room = CGSize(width: 960, height: 640)

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
            // Customisable (View → Customize Toolbar…), as the mini's page's items are (#482).
            .toolbar(id: "main") {
                // What's going on, then New Mini apart from it; the mini's page adds its own group.
                ToolbarItem(id: "update", placement: .primaryAction) { UpdateToolbarItem() }
                ToolbarItem(id: "progress", placement: .primaryAction) { JobToolbarItem() }
                ToolbarItem(id: "needsSetup", placement: .primaryAction) { NeedsSetupItem() }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(id: "newMini", placement: .primaryAction) {
                    Button { model.sheet = .make(nil) } label: { Label("New Mini", systemImage: "plus") }
                        .help("Make a new mini (⌘N)")
                        .disabled(!model.setup.installed)
                        .tourCallout(.newMini)
                }
            }
            // [room]: read here, so a new window size reaches the sheets (read only inside the
            // closure, the sheet kept getting the starting 640).
            .sheet(item: $model.sheet, onDismiss: { model.askToKeep = model.keepWhenClosed; model.keepWhenClosed = nil }) { [room] sheet in
                switch sheet {
                case .make(let start): MakeView(room: room, start: start)
                case .makeAgain(let mini, let start): MakeView(room: room, start: start, again: mini)
                case .resize(let mini): ResizeView(mini: mini, room: room)
                case .resizeAll(let p):
                    let group = model.minis.filter { $0.project == p }
                    if let first = group.first(where: \.hasModel) { ResizeView(mini: first, group: group, project: p, room: room) }
                case .resizeSeveral(let group):
                    if let first = group.first(where: \.hasModel) { ResizeView(mini: first, group: group, room: room) }
                case .rename(let mini): RenameSheet(mini: mini)
                case .newProject(let group): ProjectNameSheet(renaming: nil, moving: group)
                case .renameProject(let p): ProjectNameSheet(renaming: p)
                case .copies(let group): CopiesSheet(minis: group)
                case .duplicate(let mini): DuplicateSheet(mini: mini)
                case .importModel(let file): ImportSheet(file: file, room: room)
                case .compare(let a, let b): CompareSheet(names: [a, b], room: room)
                case .version(let mini, let newShape): VersionSheet(mini: mini, newShape: newShape)
                }
            }
            .modifier(JobQuestions())
            .modifier(TrashQuestions())
            // Move to Trash registers its Undo with the window's undo manager (Edit → Undo).
            .onChange(of: undoManager, initial: true) { model.undo = undoManager }
            // Kept by the model, so a notification or the Dock menu can bring the window back
            // after it's been closed while a mini is made.
            .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
            .alert(model.problem?.title ?? "", isPresented: showsProblem, presenting: model.problem) { _ in
                Button("OK") {}
            } message: { problem in
                Text(problem.message)
            }
    }
}

/// The questions Move to Trash and Delete Project ask, over the window. A modifier of its own,
/// with named bindings: inline, they made the window's modifier chain too slow for CI's Swift to
/// type-check.
private struct TrashQuestions: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog(model.trashing.count == 1 ? "Move “\(model.trashing[0].displayName)” to the Trash?" : "Move \(model.trashing.count) minis to the Trash?",
                                isPresented: trashing,
                                presenting: model.trashing) { group in
                Button("Move to Trash", role: .destructive) { model.trash(group) }
                Button("Cancel", role: .cancel) {}
            } message: { group in
                Text(group.count == 1 ? "It leaves the queue. You can put it back from the Trash, but not in the queue."
                     : "Those waiting leave the queue. You can put them back from the Trash, but not in the queue.")
            }
            // Deleting a project never trashes its minis silently: keeping them is the default.
            .confirmationDialog("Delete the project “\(model.deletingProject ?? "")”?",
                                isPresented: deletingProject,
                                presenting: model.deletingProject) { project in
                let count = model.minis.filter { $0.project == project }.count
                if count == 0 {
                    Button("Delete Project") { model.deleteProject(project, keepMinis: true) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Keep Minis") { model.deleteProject(project, keepMinis: true) }.keyboardShortcut(.defaultAction)
                    Button("Delete All", role: .destructive) { model.deleteProject(project, keepMinis: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { project in
                let count = model.minis.filter { $0.project == project }.count
                let minis = count == 1 ? "its mini" : "its \(count) minis"
                Text(count == 0 ? "The empty project goes to the Trash."
                     : "Keep Minis moves \(minis) to Unsorted. Delete All moves \(minis) to the Trash with the project. You can put anything back from the Trash.")
            }
    }

    private var trashing: Binding<Bool> {
        Binding(get: { !model.trashing.isEmpty }, set: { if !$0 { model.trashing = [] } })
    }

    private var deletingProject: Binding<Bool> {
        Binding(get: { model.deletingProject != nil }, set: { if !$0 { model.deletingProject = nil } })
    }
}

/// Settings lives in the Mimic menu (⌘,); the toolbar only says so when something needs you,
/// and goes straight to what's missing.
private struct NeedsSetupItem: View {
    private var health: Health { .shared }

    var body: some View {
        if let why = health.blocking {
            OpenSettingsButton(tab: .general) {
                Label {
                    Text("Needs Setup")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .labelStyle(.titleAndIcon)
            }
            .help(why)
        }
    }
}
