import MimicCore
import SwiftUI

struct MimicApp: App {
    @State private var model: AppModel

    init() {
        // A job left running by a Mimic that crashed (or was force-quit) is stopped first:
        // otherwise a 14 GB Blender could run on with nothing watching it.
        if let install = Install.locate() { Leftover.stop(install.runs) }
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Mimic") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(model)
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
