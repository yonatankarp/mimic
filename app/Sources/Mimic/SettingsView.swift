import AppKit
import MimicCore
import SwiftUI

/// The Settings window (⌘,): is everything set up, which app opens minis, and where they are.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    private var health: Health { .shared }
    @AppStorage("slicer") private var slicer = ""
    @State private var slicers: [Slicer] = []

    var body: some View {
        Form {
            Section {
                ForEach(health.checks.filter(\.required)) { CheckRow(check: $0, result: health.results[$0.id]) }
            } header: {
                Text("Needed to make minis")
            }
            Section {
                ForEach(health.checks.filter { !$0.required }) { CheckRow(check: $0, result: health.results[$0.id]) }
            } header: {
                Text("Optional")
            } footer: {
                HStack {
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { health.check(model.install) }.disabled(health.running)
                }
            }
            if Checks.drawThingsIDs.contains(where: { health.results[$0]?.ok == false }) { drawThingsSteps }
            Section {
                Picker("Open minis in", selection: slicerChoice) {
                    ForEach(slicers) { Text($0.name).tag($0.id) }
                    Text("Mac's default app for 3D files").tag(Slicer.macDefault)
                }
            } footer: {
                Text("Mimic lists the slicers it finds on this Mac. The Mac's default app works with any other slicer.")
                    .foregroundStyle(.secondary)
            }
            if let install = model.install {
                Section {
                    LabeledContent("Where your minis are saved") {
                        Button("Open Minis Folder") { NSWorkspace.shared.open(install.runs) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .task {
            slicers = Slicer.installed()
            health.check(model.install)
            // Cancelled when the window closes, which ends the watching.
            await health.watchDrawThings(model.install)
        }
    }

    /// The picked slicer, or the first one found when the pick is gone, as Slicer.preferred does.
    private var slicerChoice: Binding<String> {
        Binding(get: { slicer == Slicer.macDefault || slicers.contains { $0.id == slicer } ? slicer : slicers.first?.id ?? Slicer.macDefault },
                set: { slicer = $0 })
    }

    private var summary: String {
        if health.running { return "Checking…" }
        guard let when = health.lastChecked else { return "" }
        let bad = health.results.values.filter { !$0.ok }.count
        let head = bad == 0 ? "Everything's ready." : "\(bad) thing\(bad > 1 ? "s" : "") to look at."
        return "\(head) Last checked at \(when.formatted(date: .omitted, time: .standard))."
    }

    private var drawThingsSteps: some View {
        Section {
            SetupStep(done: health.ok("drawthings-api"), title: "Open Draw Things.")
            SetupStep(done: health.ok("drawthings-api"), title: "Turn on its connection.",
                      detail: "In Draw Things: Settings → Advanced → API Server. Turn it on, choose HTTP, set the port to 7860.")
            SetupStep(done: health.ok("drawthings-model"), title: "Download FLUX.2 Klein.",
                      detail: "In Draw Things' model list, search for FLUX.2 Klein and download it. It's big, so give it a few minutes.")
        } header: {
            Text("Set up Draw Things")
        } footer: {
            Text("Pictures work right away. To describe a character or turn a picture into a grey sculpt, Mimic needs the free Draw Things app. This list updates on its own.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct CheckRow: View {
    let check: Check
    let result: CheckResult?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            mark.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result?.label ?? check.label)
                if let result, !result.ok {
                    Text(result.fix).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var mark: some View {
        switch result.map({ ($0.ok, $0.required) }) {
        case nil: ProgressView().controlSize(.small)
        case (true, _)?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case (false, true)?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case (false, false)?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct SetupStep: View {
    let done: Bool
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}
