import MimicCore
import SwiftUI

struct MimicApp: App {
    // The delegate owns the model: it has to ask about a running job when the app quits.
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup("Mimic") {
            ContentView()
                .modifier(MainWindowChrome())
                .frame(minWidth: 900, minHeight: 600)
                .environment(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Mini…") { model.sheet = .make }
                    .keyboardShortcut("n")
                    .disabled(model.install == nil)
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.install != nil {
            NavigationSplitView {
                List(model.minis, selection: $model.selection) { mini in
                    GalleryRow(mini: mini)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .navigationTitle("Your Minis")
            } detail: {
                if let mini = model.selected {
                    MiniDetail(mini: mini)
                } else {
                    ContentUnavailableView("No mini selected", systemImage: "cube",
                                           description: Text("Pick a mini on the left."))
                }
            }
        } else {
            ContentUnavailableView("Can't find the Mimic folder", systemImage: "folder.badge.questionmark",
                                   description: Text("Run the installer, or set MIMIC_HOME."))
        }
    }
}
