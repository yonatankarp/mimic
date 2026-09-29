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
                ForEach(health.checks.filter(\.required)) { row($0) }
            } header: {
                Text("Needed to make minis")
            }
            Section {
                ForEach(health.checks.filter { !$0.required }) { row($0) }
            } header: {
                Text("Optional")
            } footer: {
                HStack {
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { health.check(model.install) }.disabled(health.running || model.running)
                }
            }
            if Checks.drawThingsIDs.contains(where: { health.results[$0]?.ok == false }) {
                Section {
                    DrawThingsSteps()
                } header: {
                    Text("Set up Draw Things")
                } footer: {
                    Text("Pictures work right away. To describe a character or turn a picture into a grey sculpt, Mimic needs the free Draw Things app. This list updates on its own.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Open minis in", selection: slicerChoice) {
                    ForEach(slicers) { Text($0.name).tag($0.id) }
                    Text("Mac's default app for 3D files").tag(Slicer.macDefault)
                }
            } footer: {
                Text("Mimic lists the slicers it finds on this Mac. The Mac's default app works with any other slicer.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Open Minis Folder") {
                        // A new Mac has none until the first mini.
                        try? FileManager.default.createDirectory(at: model.install.runs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.install.runs)
                    }
                } label: {
                    Text("Your minis are saved in")
                    Text((model.install.runs.path as NSString).abbreviatingWithTildeInPath)
                }
            }
            TerminalSection()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onChange(of: model.running) { _, running in if !running { health.check(model.install) } }
        .task {
            slicers = Slicer.installed()
            // The checks start the 3D engine, which a running job is already using
            // heavily; they run when it ends instead (below).
            if !model.running { health.check(model.install) }
            // Cancelled when the window closes, which ends the watching.
            await health.watchDrawThings(model.install)
        }
    }

    /// A check's row. Its place in the list staggers its result a little, so answers that come
    /// back together still arrive one after another.
    private func row(_ check: Check) -> some View {
        CheckRow(check: check, result: health.results[check.id], setup: model.setup,
                 stagger: Double(health.checks.firstIndex { $0.id == check.id } ?? 0) * 0.04)
    }

    /// The picked slicer, or the first one found when the pick is gone, as Slicer.preferred does.
    private var slicerChoice: Binding<String> {
        Binding(get: { slicer == Slicer.macDefault || slicers.contains { $0.id == slicer } ? slicer : slicers.first?.id ?? Slicer.macDefault },
                set: { slicer = $0 })
    }

    private var summary: String {
        if health.running { return "Checking…" }
        if model.running { return "Checks paused while a mini is being made." }
        guard let when = health.lastChecked else { return "" }
        let bad = health.results.values.filter { !$0.ok }.count
        let head = bad == 0 ? "Everything's ready." : "\(bad) thing\(bad > 1 ? "s" : "") to look at."
        return "\(head) Last checked at \(when.formatted(date: .omitted, time: .shortened))."
    }

}

private struct CheckRow: View {
    let check: Check
    let result: CheckResult?
    let setup: SetupModel
    var stagger = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            mark.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result?.label ?? check.label)
                if let result, !result.ok {
                    Text(setup.running && SetupModel.checkIDs.contains(check.id) ? setup.status : result.fix)
                        .font(.callout).foregroundStyle(.secondary)
                    if let problem = setup.problem, SetupModel.checkIDs.contains(check.id) {
                        Text(problem).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            if let result, !result.ok, SetupModel.checkIDs.contains(check.id) {
                if setup.running {
                    ProgressView(value: setup.fraction).frame(width: 80)
                } else {
                    Button(check.id == "engine" ? "Repair" : "Download") { setup.start() }
                }
            }
        }
    }

    /// A turning dotted circle while the check runs, which becomes its answer in place.
    private var mark: some View {
        let (symbol, color): (String, Color) = switch result.map({ ($0.ok, $0.required) }) {
        case nil: ("circle.dotted", .secondary)
        case (true, _)?: ("checkmark.circle.fill", .green)
        case (false, true)?: ("xmark.circle.fill", .red)
        case (false, false)?: ("exclamationmark.triangle.fill", .orange)
        }
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: result == nil && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .default.delay(stagger), value: result)
    }
}

struct SetupStep: View {
    let done: Bool
    let title: String
    var detail: String?
    var link: (title: String, url: URL)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            if let link, !done {
                Spacer()
                Link(link.title, destination: link.url)
            }
        }
    }
}

/// The Draw Things steps, ticking off as they're done: Settings and the setup screen.
struct DrawThingsSteps: View {
    private var health: Health { .shared }

    var body: some View {
        SetupStep(done: health.ok("drawthings-app"), title: "Get Draw Things from the App Store.",
                  detail: "It's free.", link: ("Open the App Store", SetupModel.drawThingsStore))
        SetupStep(done: health.ok("drawthings-api"), title: "Open Draw Things.")
        SetupStep(done: health.ok("drawthings-api"), title: "Turn on its connection.",
                  detail: "In Draw Things: Settings → Advanced → API Server. Turn it on, choose HTTP, set the port to 7860.")
        SetupStep(done: health.ok("drawthings-model"), title: "Download FLUX.2 Klein.",
                  detail: "In Draw Things' model list, search for FLUX.2 Klein and download it. It's big, so give it a few minutes.")
    }
}

/// The command-line tool lives inside the app, and a disk image can't put it on the PATH:
/// one command does, the same one for everyone.
private struct TerminalSection: View {
    // /usr/local/bin is on every Mac's PATH (/etc/paths), but a new Mac doesn't have it and
    // only an administrator can make it, hence sudo; ~/.local/bin would need no password but
    // isn't on the PATH, which would take a second step. The app's own path only when it's in
    // Applications: opened from the disk image (or translocated), it's gone after a restart.
    static let command: String = {
        let app = Bundle.main.bundlePath.hasPrefix("/Applications/") ? Bundle.main.bundlePath : "/Applications/Mimic.app"
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(app)/Contents/MacOS/mimic\" /usr/local/bin/mimic"
    }()
    @State private var copied = false

    var body: some View {
        Section {
            HStack {
                Text(Self.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                    copied = true
                }
            }
        } header: {
            Text("Use Mimic from Terminal")
        } footer: {
            Text("Paste this into Terminal once, then type mimic to make minis from there. It asks for your Mac password, because it adds mimic to a folder every account on this Mac uses.")
                .foregroundStyle(.secondary)
        }
    }
}
