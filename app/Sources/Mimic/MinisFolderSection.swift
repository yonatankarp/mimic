import AppKit
import MimicCore
import SwiftUI

/// Settings → General: where the minis are kept, and Change… (#102). The minis can move to the
/// folder chosen, or stay where they are when it already has minis of its own. The checks and the
/// move are `JobRunner.changeMinisFolder`; this only asks.
struct MinisFolderSection: View {
    @Environment(AppModel.self) private var model
    /// The folder chosen, while Mimic asks whether to move the minis there.
    @State private var picked: URL?
    @State private var changing = false
    @State private var problem: String?
    /// Started with a folder of its own (development): Settings can't change it.
    private let fixed = Install.minisFolderIsFixed()

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Open Minis Folder") {
                        // A new Mac has none until the first mini.
                        try? FileManager.default.createDirectory(at: model.install.runs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.install.runs)
                    }
                    Button("Change…") { choose() }
                        .disabled(fixed || changing || model.minisFolderBusy)
                        .help("Keep your minis in another folder")
                }
            } label: {
                Text("Your minis are saved in")
                Text((model.install.runs.path as NSString).abbreviatingWithTildeInPath)
            }
        } footer: {
            if changing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Moving your minis…").foregroundStyle(.secondary)
                }
            } else if fixed {
                Text("This copy of Mimic was started with a folder of its own, so it can't be changed here.").foregroundStyle(.secondary)
            } else if model.minisFolderBusy {
                Text("You can change the folder once no mini is being made or waiting in the queue.").foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Move your minis to “\(picked?.lastPathComponent ?? "")”?",
                            isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })) {
            Button("Move Minis") { change(moving: true) }
            Button("Don't Move") { change(moving: false) }
            Button("Cancel", role: .cancel) { picked = nil }
        } message: {
            Text(picked.map(AppModel.hasMinis) == true
                 ? "That folder already has minis, and Mimic shows them either way. Yours stay where they are now unless you move them."
                 : "Yours stay where they are now unless you move them, and Mimic won't show them there.")
        }
        .alert("Couldn't change the folder", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Mimic keeps your minis."
        panel.directoryURL = model.install.runs.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MinisFolder.check(from: model.install.runs, to: url)
        } catch {
            problem = model.plainWords(error, else: "Mimic can't use that folder. Choose another one.")
            return
        }
        picked = url  // asks whether to move them
        if model.minis.isEmpty && model.projects.isEmpty { change(moving: false) }  // nothing to move
    }

    private func change(moving: Bool) {
        guard let url = picked else { return }
        picked = nil
        changing = true
        Task {
            do {
                try await model.changeMinisFolder(to: url, moving: moving)
            } catch {
                problem = model.plainWords(error, else: "Couldn't move your minis, so they're still where they were. Check that Mimic can write to that folder, then try again.")
            }
            changing = false
        }
    }
}
