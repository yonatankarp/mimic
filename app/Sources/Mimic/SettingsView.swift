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
            if EngineDownload.catalogue.count > 1 { ModelsSection() }
            HelperSection()
            Section {
                Picker("Open minis in", selection: slicerChoice) {
                    ForEach(slicers) { Text($0.name).tag($0.id) }
                    Text("Mac's default app for 3D files").tag(Slicer.macDefault)
                }
                .help("Where Open in … sends a finished mini. The Mac's default app is whatever opens .stl files when you double-click one.")
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
            ResetSection()
            Section {
                // Selectable, so it can be copied into a bug report.
                Text(BuildInfo.line).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help("Which Mimic this is. Include it when you report a problem.")
            }
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
    /// What each part is for, in a sentence: the labels name the parts, this says why they matter.
    static let what: [String: String] = [
        "engine": "Turns your picture into a 3D shape, on your Mac's graphics chip.",
        "models": "What the 3D engine has learned, for the 3D model in use. Downloaded once.",
        "space": "Each mini needs about 150 MB while it's being made.",
        "drawthings-app": "A free app that draws characters from a description and turns pictures into grey sculpts.",
        "drawthings-api": "Lets Mimic ask Draw Things for pictures. Draw Things has to be open.",
        "drawthings-model": "The picture model Mimic asks Draw Things to use.",
        "slicer": "Turns a mini into instructions for your printer.",
    ]
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
                    .help(Self.what[check.id] ?? "")
                if let result, !result.ok {
                    Text(setup.running && SetupModel.checkIDs.contains(check.id) ? setup.status : result.fix)
                        .font(.callout).foregroundStyle(.secondary)
                    if check.id == "slicer" {
                        Link("Get OrcaSlicer, a free slicer for most printers", destination: URL(string: "https://github.com/OrcaSlicer/OrcaSlicer/releases/latest")!)
                            .font(.callout)
                    }
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

/// Which 3D model new minis are made with: switch to one that's here, download one that isn't
/// (resumable and checked, as on first launch), or remove one that isn't in use.
private struct ModelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var removing: EngineModel?

    var body: some View {
        let setup = model.setup
        // Look at the disk again after a removal, and with every health check (opening
        // Settings, Check Again), which catches files that changed behind Mimic's back.
        let _ = (setup.removals, Health.shared.lastChecked)
        Section {
            ForEach(EngineDownload.catalogue) { row($0, setup) }
        } header: {
            Text("3D model")
        } footer: {
            Text("New minis are made with the model in use. Try Again uses the model a mini was first made with.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { m in
            Button("Remove \(m.name)", role: .destructive) { setup.remove(m) }
        } message: { m in
            Text("This frees about \(Checks.gigabytes(EngineDownload.freed(by: m, in: model.install))) GB. Minis you made with it stay. You can download it again any time.")
        }
    }

    private func row(_ m: EngineModel, _ setup: SetupModel) -> some View {
        let complete = m.complete(in: model.install)
        let downloading = setup.running && setup.target == m
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(m.name) · \(Checks.gigabytes(m.bytes)) GB")
                Text(m.summary).font(.callout).foregroundStyle(.secondary)
                if downloading {
                    ProgressView(value: setup.fraction)
                    Text(setup.status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else if let problem = setup.problem, setup.target == m {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
            Spacer()
            if m == setup.chosen {
                Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                if complete {
                    Button("Use") { setup.use(m) }
                } else if !downloading {
                    Button(m.anyOnDisk(in: model.install) ? "Resume Download" : "Download") { setup.start(m) }
                        .disabled(setup.running)
                }
                if m.anyOnDisk(in: model.install) {
                    Button("Remove…") { removing = m }
                        .disabled(model.running || downloading)
                        .help(model.running ? "Wait for the mini being made to finish." : "")
                }
            }
        }
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

/// Back to how Mimic was when first installed: see the tour, or with the engine removed the
/// whole setup, again. The minis always stay.
private struct ResetSection: View {
    @Environment(AppModel.self) private var model
    @State private var asking = false
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent("Start over") {
                Button("Reset Mimic…") { asking = true }
                    .disabled(model.running)
                    .help(model.running ? "Wait for the mini being made to finish." : "Forget Mimic's settings and show the tour again. Your minis stay.")
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
        } footer: {
            Text("Mimic forgets its settings and saved keys, then opens again as it did the first time. Your minis are kept.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset Mimic?", isPresented: $asking) {
            Button("Reset") { reset(removeEngine: false) }
            Button("Reset and Remove the 3D Engine", role: .destructive) { reset(removeEngine: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mimic forgets its settings and any saved AI keys, and shows the tour again. Your minis are kept.\n\nAlso removing the 3D engine shows the first-launch setup again, and downloads the engine again (about 8 GB).")
        }
    }

    private func reset(removeEngine: Bool) {
        do {
            try Reset.run(install: model.install, domain: Bundle.main.bundleIdentifier ?? "com.mimic.app", removeEngine: removeEngine)
        } catch {
            problem = "Couldn't remove the 3D engine. \(model.plainWords(error, else: "Check that Mimic can write to its folder, then try again."))"
            return
        }
        // Opens again as a fresh launch would: a new copy of the app, then this one quits.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
