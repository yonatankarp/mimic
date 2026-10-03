import MimicCore
import SwiftUI

/// Asks for the copy's name, makes the copy, then opens Resize for it.
struct DuplicateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mini: Mini
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicate “\(mini.displayName)”").font(.headline)
            Text("The copy has the same shape. Next, choose its size: making it takes about a minute.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name of the copy", text: $text)  // Return presses Duplicate
            if let problem {
                Text(problem).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Duplicate", action: duplicate).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { text = Gallery.duplicateName(model.install.runs, mini).shown }
    }

    private func duplicate() {
        guard let shown = Rules.shownName(text) else { problem = "Give it a name."; return }
        let new = Rules.folderName(shown)
        do {
            try model.duplicate(mini, as: new, shown: shown)
        } catch {
            problem = model.plainWords(error, else: "Couldn't make the copy. Is the disk full, or its folder open in another app?"); return
        }
        // Straight on to its size: the sheet's item changes, so this one closes as Resize opens.
        if let copy = model.minis.first(where: { $0.name == new }) { model.sheet = .resize(copy) } else { dismiss() }
    }
}
