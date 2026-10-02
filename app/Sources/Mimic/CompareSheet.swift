import MimicCore
import SwiftUI

/// Two versions of a mini side by side in 3D (#99): the two viewers share one pose, so turning
/// or zooming either turns and zooms both. Keep This One under each closes this and asks on that
/// version's page, so it does just what the page's own Keep This One does.
struct CompareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// By name, looked up again on every change: a resize or a finished job replaces the mini.
    @State var names: [String]
    let room: CGSize
    @State private var pose = ViewerPose()
    @State private var measured: [Measured?] = [nil, nil]

    /// The versions with a print file, of whichever picked one is still there.
    private var finished: [Mini] {
        guard let any = model.minis.first(where: { names.contains($0.name) }) else { return [] }
        return Gallery.versions(of: any, in: model.minis).filter { $0.stl != nil }
    }

    var body: some View {
        let finished = finished
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                side(0, finished)
                Divider()
                side(1, finished)
            }
            HStack {
                Text("Turning or zooming one turns and zooms both.").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: min(1080, room.width - 40), height: min(720, room.height - 8))
        // One that has gone (moved to the Trash, renamed) gives way to another, or the sheet closes.
        .onChange(of: finished.map(\.name), initial: true) { _, now in
            guard now.count >= 2 else { dismiss(); return }
            for i in 0..<2 where !now.contains(names[i]) {
                names[i] = now.first { !names.contains($0) } ?? now[0]
            }
        }
    }

    @ViewBuilder private func side(_ i: Int, _ finished: [Mini]) -> some View {
        if let v = finished.first(where: { $0.name == names[i] }), let stl = v.stl {
            VStack(spacing: 12) {
                Picker("Version", selection: $names[i]) {
                    ForEach(finished.filter { $0.name != names[1 - i] }) { Text($0.displayName).tag($0.name) }
                }
                .labelsHidden()
                .fixedSize()
                .padding(.top, 16)
                .help("Choose the version to show on this side")
                MiniViewer(stl: stl, version: v.madeAt, name: v.displayName, facesAway: v.facesAway, measured: $measured[i], shared: $pose)
                Button("Keep This One…") {
                    model.selection = [v.id]
                    model.keepWhenClosed = v.name
                    dismiss()
                }
                .disabled(!Gallery.versions(of: v, in: model.minis).contains { $0.name != v.name && $0.name != model.current?.name })
                .help("Keeps this version and moves the others to the Trash.")
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }
}
