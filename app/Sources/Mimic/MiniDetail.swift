import AppKit
import MimicCore
import SwiftUI

struct MiniDetail: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    @State private var enlarged: URL?
    @State private var copied = false

    var body: some View {
        let settings = MiniSettings.load(mini.folder)
        let tips = PrintTips(nozzle: settings.made?.nozzle ?? settings.requested?.nozzle ?? SizeCard.remembered().nozzle)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let made = settings.made {
                    Text(PrintTips.nowLine(made)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resize This Mini…") { model.sheet = .resize(mini) }
                    .help("Remakes the print file with new sizes. About 30 seconds. The character itself doesn't change.")
                    .disabled(!hasModel || model.cantStart != nil)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([mini.stl ?? mini.folder]) }
                Button("Open in \(model.slicerName)") { if let stl = mini.stl { model.openInSlicer(stl) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(mini.stl == nil)
            }
            if let job = model.job, job.name == mini.name, job.succeeded, job.fragile {
                Label("Some thin parts may be fragile. Check it in your slicer before printing.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let stl = mini.stl {
                MiniViewer(stl: stl, version: mini.madeAt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView("This mini isn't finished yet.", systemImage: "hourglass")
            }
            // Tips beside the previews when the window is wide enough, under them otherwise.
            if mini.stl == nil {
                previews
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { previews; tipsBox(tips).frame(width: 330) }
                    VStack(alignment: .leading, spacing: 10) { previews; tipsBox(tips) }
                }
            }
        }
        .padding()
        .navigationTitle(mini.displayName)
        .sheet(isPresented: Binding(get: { enlarged != nil }, set: { if !$0 { enlarged = nil } })) {
            Thumbnail(url: enlarged, version: mini.madeAt)
                .frame(minWidth: 400, idealWidth: 700, minHeight: 400, idealHeight: 700)
                .padding()
                .onTapGesture { enlarged = nil }
                .background { Button("") { enlarged = nil }.keyboardShortcut(.cancelAction).hidden() }
        }
    }

    private var previews: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach([("Your picture", mini.source)] + mini.renders.map { ($0.view.capitalized, Optional($0.url)) },
                    id: \.0) { caption, url in
                Button { enlarged = url } label: {
                    VStack(spacing: 4) {
                        Thumbnail(url: url, version: mini.madeAt)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(url == nil)
                .help("Click to enlarge")
            }
        }
    }

    private var hasModel: Bool { FileManager.default.fileExists(atPath: mini.folder.appendingPathComponent("model.glb").path) }

    private func tipsBox(_ tips: PrintTips) -> some View {
        GroupBox("🖨️ Print tips for a \(tips.nozzle) mm nozzle") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tips.lines, id: \.self) { Text("• " + $0) }
                Button(copied ? "✓ Copied" : "Copy Settings") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tips.copyText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .padding(.top, 4)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A picture from a mini's folder, read again when the mini changes (a resize rewrites the
/// previews under the same names, which a URL-keyed cache would miss).
private struct Thumbnail: View {
    let url: URL?
    let version: Date
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.secondary.opacity(0.15) }
        }
        .task(id: "\(url?.path ?? "")\(version)") { image = url.flatMap(NSImage.init(contentsOf:)) }
    }
}
