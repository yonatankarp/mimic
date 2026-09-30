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
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                if model.updates.enabled {
                    Button("Check for Updates…") { model.updates.check() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Mini…") { model.sheet = .make }
                    .keyboardShortcut("n")
                    .disabled(!model.setup.installed)
            }
            SidebarCommands()
            MiniCommands(model: model)
            CommandGroup(replacing: .help) {
                Button("Mimic Help") { NSWorkspace.shared.open(Self.help) }
                Button("Show Tour") { TourGuide.shared.begin() }
                    .disabled(!model.setup.installed || model.sheet != nil)
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
struct MiniCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Mini") {
            let mini = model.selected
            let free = model.sheet == nil
            Button("Open in \(model.slicerName)") { if let stl = mini?.stl { model.openInSlicer(stl) } }
                .keyboardShortcut("o")
                .disabled(mini?.stl == nil)
            Button("Show in Finder") { if let mini { model.showInFinder(mini) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(mini == nil)
            Divider()
            Button("Resize This Mini…") { if let mini { model.sheet = .resize(mini) } }
                .keyboardShortcut("r")
                .disabled(mini?.hasModel != true || model.cantStart != nil || !free || mini.flatMap { model.waiting($0.name) } != nil)
            Button("Rename…") { if let mini { model.sheet = .rename(mini) } }
                .disabled(mini == nil || !free || mini.flatMap { model.waiting($0.name) } != nil)
            Divider()
            if let mini, free {
                AnotherVersionButton(mini: mini).environment(model)
                MoveToProjectMenu(mini: mini).environment(model)
            } else {
                Button("Make Another Version") {}.disabled(true)
                Button("Move to Project") {}.disabled(true)
            }
            // ⌘N is New Mini; ⇧⌘N a new project, as a new folder is in Finder.
            Button("New Project…") { model.sheet = .newProject(moving: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!free || !model.setup.installed)
            Divider()
            Button("Move to Trash…") { model.trashing = mini }
                .keyboardShortcut(.delete)
                .disabled(mini == nil || !free)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.setup.installed {
            NavigationSplitView {
                Sidebar()
            } detail: {
                if let mini = model.selected {
                    MiniDetail(mini: mini)
                } else if model.minis.isEmpty {
                    ContentUnavailableView {
                        Label("No minis yet", systemImage: "cube")
                    } description: {
                        Text("Make your first mini from a picture or a description. It takes about 10 minutes.")
                    } actions: {
                        Button("New Mini", systemImage: "plus") { model.sheet = .make }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("No mini selected", systemImage: "cube",
                                           description: Text("Pick a mini on the left."))
                }
            }
            .overlay { EnlargedPreview() }
            .animation(.easeOut(duration: 0.15), value: model.enlarged)
            // Another mini, or a sheet from the toolbar or a menu, takes over from it.
            .onChange(of: model.selection) { model.enlarged = nil }
            .onChange(of: model.sheet) { if model.sheet != nil { model.enlarged = nil } }
        } else {
            SetupView()
        }
    }
}
