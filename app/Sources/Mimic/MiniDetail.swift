import AppKit
import MimicCore
import SwiftUI

struct MiniDetail: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    @State private var enlarged: Enlarged?
    @State private var copied = false

    var body: some View {
        let settings = MiniSettings.load(mini.folder)
        let kind = settings.kind ?? .character
        let tips = PrintTips(nozzle: settings.made?.nozzle ?? settings.requested?.nozzle ?? SizeCard.remembered().nozzle, kind: kind)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                Button("Resize This Mini…") { model.sheet = .resize(mini) }
                    .help("Remakes the print file with new sizes. About a minute. The \(kind == .object ? "object" : "character") itself doesn't change.")
                    .disabled(!mini.hasModel || model.cantStart != nil)
                    .glassButton()
                Button("Show in Finder") { model.showInFinder(mini) }
                    .help("Shows the print file and the previews in Finder.")
                    .glassButton()
                Button("Open in \(model.slicerName)") { if let stl = mini.stl { model.openInSlicer(stl) } }
                    .help("Opens the print file in \(model.slicerName) to slice and print. Choose another slicer in Settings.")
                    .glassButton(prominent: true)
                    .tourStop(.mini)  // before .disabled, which its popover would inherit
                    .disabled(mini.stl == nil)
            }
            if let job = model.job, job.name == mini.name, job.succeeded, job.fragile {
                Label("Some thin parts may be fragile. Check it in your slicer before printing.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let stl = mini.stl {
                MiniViewer(stl: stl, version: mini.madeAt, name: mini.displayName)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
        // What it was made at, under the name in the title bar, where the Mac puts a document's details.
        .navigationSubtitle(settings.made.map { PrintTips.nowLine($0, kind: kind) } ?? "")
        .sheet(item: $enlarged) { e in
            VStack(spacing: 12) {
                Thumbnail(url: e.url, version: mini.madeAt)
                    .frame(minWidth: 400, idealWidth: 560, minHeight: 400, idealHeight: 560)  // with the caption row, fits the smallest main window
                    .onTapGesture { enlarged = nil }
                HStack {
                    Text("\(mini.displayName) · \(e.caption)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { enlarged = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .background { Button("") { enlarged = nil }.keyboardShortcut(.cancelAction).hidden() }
        }
    }

    private var previews: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach([("Your picture", mini.source)] + mini.renders.map { ($0.view.capitalized, Optional($0.url)) },
                    id: \.0) { caption, url in
                Button { enlarged = url.map { Enlarged(caption: caption, url: $0) } } label: {
                    VStack(spacing: 4) {
                        Thumbnail(url: url, version: mini.madeAt)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .glassCard(cornerRadius: 12)
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(url == nil)
                .help("Click to enlarge")
            }
        }
    }

    private func tipsBox(_ tips: PrintTips) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🖨️ Print tips for a \(tips.nozzle) mm nozzle").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tips.lines, id: \.self) { Text("• " + $0) }
                Button(copied ? "✓ Copied" : "Copy Settings") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tips.copyText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .help("Copies these settings as text, to keep in your slicer's notes.")
                .glassButton()
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 16)
    }
}

/// A preview shown big, and what it's a view of.
private struct Enlarged: Identifiable {
    let caption: String
    let url: URL
    var id: URL { url }
}

/// A picture from a mini's folder, read again when the mini changes (a resize rewrites the
/// previews under the same names, which a URL-keyed cache would miss). A new picture fades in
/// over the old one rather than popping; the progress sheet uses it too.
struct Thumbnail: View {
    let url: URL?
    let version: Date
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .id(ObjectIdentifier(image))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .animation(.easeOut(duration: 0.4), value: image.map(ObjectIdentifier.init))
        .task(id: "\(url?.path ?? "")\(version)") { image = url.flatMap(NSImage.init(contentsOf:)) }
    }
}
