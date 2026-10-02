import MimicCore
import SwiftUI

/// What to change in the picture, in words (#156): the redraw makes the change, then Mimic
/// stops for you to check the picture before it builds the 3D shape.
struct FixBox: View {
    @Binding var text: String
    /// What was changed before, oldest first: the picture already has these.
    var earlier: [String] = []
    var kind = MiniKind.character
    /// The grey sculpt is off, so a change turns it on for this mini.
    var turnsSculptOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("What to change (optional)", text: $text,
                      prompt: Text(kind == .object ? "e.g. remove the stand, make the handle thicker" : "e.g. close the cape so both arms show"),
                      axis: .vertical)
                .lineLimit(1...3)
                .help("Mimic redraws the picture with this change and shows it to you before building the 3D shape")
            if !earlier.isEmpty {
                Text("Changed before: \(earlier.joined(separator: "; "))")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if turnsSculptOn && !trimmed.isEmpty {
                Text("A change redraws the picture, so it gets the grey sculpt too.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum FixWriter {
    /// The AI helper's edit instruction for `fix`, or nil when no helper is set up or it fails:
    /// the fix is then used as typed. Off the main thread, as reading the key may wait on a
    /// Keychain prompt.
    static func rewrite(_ fix: String, kind: MiniKind) async -> String? {
        let raw = kind.rawValue
        return await Task.detached { try? DescriptionHelper.configured(defaults: .standard)?.rewriteFix(fix, kind: raw) }.value
    }

    /// Whether an AI helper is chosen in Settings, so Make waits for its rewrite.
    static var helperOn: Bool {
        HelperProvider(rawValue: UserDefaults.standard.string(forKey: HelperConfig.providerKey) ?? "") ?? .off != .off
    }
}

/// Make Another Version and New 3D Shape: what to change, if anything, then make it.
struct VersionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mini: Mini
    /// New 3D Shape: the same picture unless a change is typed.
    let newShape: Bool
    @State private var change = ""
    @State private var working = false
    /// The AI helper writing the change; Cancel or closing the sheet stops it making it.
    @State private var writing: Task<Void, Never>?

    var body: some View {
        let settings = mini.settings
        VStack(alignment: .leading, spacing: 12) {
            Text(newShape ? "New 3D Shape of “\(mini.displayName)”" : "Another Version of “\(mini.displayName)”").font(.headline)
            Text(newShape ? "Keeps its picture and makes only the 3D shape again. Type a change to redraw the picture with it first."
                          : "Makes it again with a new variation number. Type a change to redraw its picture with it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            FixBox(text: $change, earlier: settings.fixes ?? [], kind: settings.kind ?? .character,
                   turnsSculptOn: settings.source == .image && settings.restyle != true)
                .disabled(!canChange)
            if !canChange {
                Text(mini.source == nil ? "A change needs the picture it was drawn as, and it isn't made yet."
                                        : "A change needs \(Health.shared.pictureNeed). Open Settings to set it up.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Writing the change…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { writing?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || model.requiredProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear { writing?.cancel() }
    }

    private var canChange: Bool { mini.source != nil && Health.shared.picturesReady }

    private func make() {
        let typed = canChange ? change.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !typed.isEmpty, FixWriter.helperOn else { return finish(typed, used: nil) }
        working = true
        writing = Task {
            let used = await FixWriter.rewrite(typed, kind: mini.settings.kind ?? .character)
            working = false
            if !Task.isCancelled { finish(typed, used: used) }
        }
    }

    private func finish(_ typed: String, used: String?) {
        dismiss()
        if newShape { model.makeNewShape(mini, change: typed, changeUsed: used) }
        else { model.makeAnotherVersion(mini, change: typed, changeUsed: used) }
    }
}
