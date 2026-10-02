import AppKit
import MimicCore
import SwiftUI

struct MimicApp: App {
    // The delegate owns the model: it has to ask about a running job when the app quits.
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        // One window, not a WindowGroup: there's one gallery and one sheet to share, and a
        // second window (or a tab) would show the same sheet twice.
        Window("Mimic", id: "main") {
            ContentView()
                .modifier(MainWindowChrome())
                .modifier(TourHost())
                // Wide enough that the 3D view keeps about 420 points beside the sidebar and the details.
                .frame(minWidth: 960, minHeight: 680)
                .environment(model)
                .environment(delegate.reporter)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                if model.updates.enabled {
                    Button("Check for Updates…") { model.updates.check() }.disabled(!model.updates.canCheck)
                }
            }
            // An action, not a setting: after Settings in the Mimic menu. The Settings scene adds its
            // own Settings… (⌘,) after the `.appSettings` group, so `after: .appSettings` put the
            // tool above it and `replacing:` gave two Settings items; before Services is below it.
            CommandGroup(before: .systemServices) {
                Button("Install Command-Line Tool…") { CommandLineTool.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Mini…") { model.showWindow(); model.sheet = .make }
                    .keyboardShortcut("n")
                    .disabled(!model.setup.installed || model.sheet != nil)
                // A model made elsewhere, print prep only (#96).
                Button("Import Model…") { ImportModel.choose(model) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.setup.installed || model.sheet != nil)
                // ⌘N is New Mini; ⇧⌘N a new project, as a new folder is in Finder.
                Button("New Project…") { model.showWindow(); model.sheet = .newProject(moving: []) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.setup.installed || model.sheet != nil)
            }
            // The search field only shows past `Gallery.searchAfter` minis.
            CommandGroup(after: .textEditing) {
                Button("Find") { model.showWindow(); model.findRequests += 1 }
                    .keyboardShortcut("f")
                    .disabled(model.minis.count <= Gallery.searchAfter || model.sheet != nil)
            }
            GalleryCommands(model: model)
            SidebarCommands()
            ImportFromDevicesCommands()  // File → Import from iPhone, for New Mini's picture
            MiniCommands(model: model, reporter: delegate.reporter)
            CommandGroup(replacing: .help) {
                Button("Mimic Help") { NSWorkspace.shared.open(Self.help) }
                Button("Show Tour") { TourGuide.shared.begin() }
                    .disabled(!model.setup.installed || model.sheet != nil)
                Divider()
                Button("Report a Problem…") { delegate.reporter.report() }
            }
        }
        Settings {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)
    }

    // The README's own heading, "## 🧙 Making a mini": GitHub drops the emoji and keeps its space.
    // Print tips aren't linked: each mini's page shows them for its nozzle.
    static let help = URL(string: "https://github.com/yonatankarp/mimic#-making-a-mini")!
}

/// The Mini menu: what the buttons and the right-click menu do to the selected mini, with
/// keyboard shortcuts. Disabled whenever a sheet is up, so a shortcut can't swap it out.
/// The mini page's own toolbar and 3D view controls are in the View menu.
struct MiniCommands: Commands {
    let model: AppModel
    let reporter: Reporter
    @AppStorage(SizeReference.key) private var reference = SizeReference.none

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            // ⌃⌘I as the system's inspector toggle, next to Show Sidebar's ⌃⌘S. The title follows
            // the panel through the model, which the menus observe (as they do the selection).
            Button(model.showDetails ? "Hide Details" : "Show Details") { model.showDetails.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(model.selected == nil)
            Button("Face Front") { model.faceFrontRequests += 1 }
                .keyboardShortcut("0")
                .disabled(model.selected?.stl == nil || model.sheet != nil)
            // The 3D view's ruler, one choice for the whole app.
            Picker("Size Reference", selection: $reference) {
                ForEach(SizeReference.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(model.selected?.stl == nil || model.sheet != nil)
        }
        CommandMenu("Mini") {
            let mini = model.selected, chosen = model.chosen, several = chosen.count > 1
            let free = model.sheet == nil
            if several {
                Button("Open Together in \(model.slicerName)") { model.openTogether(chosen) }
                    .keyboardShortcut("o")
                    .disabled(chosen.filter { $0.stl != nil }.count < 2 || model.packing)
            } else {
                Button("Open in \(model.slicerName)") { if let stl = mini?.stl { model.openInSlicer(stl) } }
                    .keyboardShortcut("o")
                    .disabled(mini?.stl == nil)
            }
            CopiesButton(minis: chosen, showsIcon: false).environment(model)
            Button("Show in Finder") { model.showInFinder(chosen) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(chosen.isEmpty)
            Divider()
            if several {
                Button("Resize \(chosen.count) Minis…") { model.sheet = .resizeSeveral(chosen) }
                    .keyboardShortcut("r")
                    .disabled(!chosen.contains(where: \.hasModel) || model.requiredProblem != nil || !free)
            } else {
                Button("Resize This Mini…") { if let mini { model.sheet = .resize(mini) } }
                    .keyboardShortcut("r")
                    .disabled(mini?.hasModel != true || model.requiredProblem != nil || !free || mini.flatMap { model.waiting($0.name) } != nil)
            }
            if let mini, model.pictureToCheck(mini) {
                Button("Build Shape") { model.buildShape(mini) }
                    .disabled(model.requiredProblem != nil || !free)
            }
            if let mini, model.canRetry(mini) {
                Button("Try Again") { model.tryAgain(mini) }
                    .disabled(model.requiredProblem != nil || !free)
                Button("Report a Problem…") { reporter.report(mini) }
                    .disabled(!free)
            }
            Button("Rename…") { if let mini { model.sheet = .rename(mini) } }
                .disabled(mini == nil || !free || mini.flatMap { model.waiting($0.name) } != nil)
            Divider()
            // No icons in the menu bar: the other items have none.
            if let mini, free {
                AnotherVersionButton(mini: mini, showsIcon: false).environment(model)
                NewShapeButton(mini: mini, showsIcon: false).environment(model)
                EditAndMakeAgainButton(mini: mini, showsIcon: false).environment(model)
            } else {
                Button("Make Another Version…") {}.disabled(true)
                Button("New 3D Shape…") {}.disabled(true)
                Button("Edit & Make Again…") {}.disabled(true)
            }
            if let mini, free { DuplicateButton(mini: mini, showsIcon: false).environment(model) } else { Button("Duplicate…") {}.disabled(true) }
            if free && !chosen.isEmpty {
                MoveToProjectMenu(minis: chosen, showsIcon: false).environment(model)
            } else {
                Button("Move to Project") {}.disabled(true)
            }
            Divider()
            // The job's toolbar item, from the keyboard.
            Button("Show Progress") { model.showWindow(); model.jobPopover = true }
                .disabled(model.toolbarJob == nil || !free)
            Button(model.stopCommand ?? "Stop Making…") { model.showWindow(); model.confirmingStop = true }
                .disabled(model.stopCommand == nil || !free)
            // The selected mini's place in the queue, while it waits (#72).
            MoveInQueueMenu(mini: mini, showsIcon: false).environment(model)
            // Shared with every Mimic on this Mac: resuming here resumes a pause made anywhere.
            Button(model.pauseCommand) { model.togglePause() }
                .disabled(!model.paused && model.current == nil && model.queue.isEmpty)
            Divider()
            Button("Move to Trash") { model.askToTrash(chosen) }
                .keyboardShortcut(.delete)
                .disabled(chosen.isEmpty || !free)
        }
    }
}

/// Move in Queue ▸, for a mini waiting its turn: in the Mini menu and the mini's right-click
/// menu, as the job popover's queue rows have it.
struct MoveInQueueMenu: View {
    let mini: Mini?
    var showsIcon = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let place = mini.flatMap { model.waiting($0.name) }
        let entry = mini.flatMap { m in model.queue.first { $0.name == m.name } }
        Menu {
            Button("Move to Front") { if let mini { model.moveInQueue(mini.name, to: .front) } }
                .disabled(place == nil || place == 1)
            Button("Move Up") { if let mini { model.moveInQueue(mini.name, by: -1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(place == nil || place == 1)
            Button("Move Down") { if let mini { model.moveInQueue(mini.name, by: 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(place == nil || place == model.queue.count)
            Button("Move to End") { if let mini { model.moveInQueue(mini.name, to: .end) } }
                .disabled(place == nil || place == model.queue.count)
            Divider()
            // Asks first, as the queue row's button does; a waiting resize keeps its size.
            Button(entry.map { $0.job == .prep && !model.importing($0.name) } == true ? "Don't Resize…" : "Take Out of Queue…") {
                model.showWindow(); model.unqueueing = entry
            }
            .disabled(entry == nil)
        } label: {
            if showsIcon { Label("Move in Queue", systemImage: "arrow.up.arrow.down") } else { Text("Move in Queue") }
        }
        .disabled(place == nil || model.sheet != nil)
    }
}

/// View → Sort By and Show, the sidebar's own choices (kept per window), as in Finder's View menu.
struct GalleryCommands: Commands {
    let model: AppModel
    @FocusedValue(\.gallerySort) private var sort
    @FocusedValue(\.galleryShow) private var show

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Sort By", selection: sort ?? .constant(.made)) {
                ForEach(GallerySort.allCases, id: \.self) { Text(Sidebar.title($0)).tag($0) }
            }
            .disabled(sort == nil || model.sheet != nil)
            Picker("Show", selection: show ?? .constant(.all)) {
                ForEach(GalleryShow.allCases, id: \.self) { Text(Sidebar.title($0)).tag($0) }
            }
            .disabled(show == nil || model.sheet != nil)
            Divider()
        }
    }
}

extension FocusedValues {
    @Entry var gallerySort: Binding<GallerySort>?
    @Entry var galleryShow: Binding<GalleryShow>?
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    var body: some View {
        if model.setup.installed {
            NavigationSplitView {
                Sidebar(listFocused: $listFocused)
            } detail: {
                if let mini = model.selected {
                    MiniDetail(mini: mini)
                } else if model.selection.count > 1 {
                    ContentUnavailableView {
                        Label("\(model.chosen.count) minis selected", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Resize them together, move them to a project, or move them to the Trash.")
                    } actions: {
                        HStack { SeveralMenu(minis: model.chosen) }.fixedSize()
                    }
                } else if model.minis.isEmpty {
                    ContentUnavailableView {
                        Label("No minis yet", systemImage: "cube")
                    } description: {
                        Text("Make your first mini from a picture or a description. It takes about \(model.setup.chosen.minutes) minutes.")
                    } actions: {
                        Button("New Mini", systemImage: "plus") { model.sheet = .make }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("No mini selected", systemImage: "cube",
                                           description: Text("Pick a mini on the left."))
                }
            }
            // As in Finder and Mail, the keyboard starts on the list (the 3D view takes it when clicked).
            .defaultFocus($listFocused, true)
        } else {
            SetupView()
        }
    }
}
