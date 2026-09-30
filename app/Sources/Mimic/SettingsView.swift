import AppKit
import MimicCore
import SwiftUI
import TipKit

/// Settings' tabs. Whoever opens Settings for a reason picks the tab first (`select`), and the
/// window, open or not, follows: the key is the tab picker's own.
enum SettingsTab: String {
    case general, model, drawThings, advanced
    static let key = "settingsTab"
    func select() { UserDefaults.standard.set(rawValue, forKey: Self.key) }
}

/// Opens Settings, on `tab` when given, else where it was left: "Open Settings" wherever Mimic
/// needs something set up.
struct OpenSettingsButton<Content: View>: View {
    var tab: SettingsTab?
    @ViewBuilder let label: Content
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { tab?.select(); openSettings() } label: { label }
    }
}

/// The Settings window (⌘,): is everything set up, which 3D model, Draw Things and the AI
/// helper, and the rest.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    private var health: Health { .shared }
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general
    @AppStorage("slicer") private var slicer = ""
    @AppStorage(DrawThingsApp.enabledKey) private var openDrawThings = true
    @AppStorage(Power.key) private var holdOnBattery = false
    /// A MacBook: the battery setting means nothing on a Mac mini.
    @State private var hasBattery = Power.hasBattery()
    @State private var slicers: [Slicer] = []
    /// The same for every tab, so switching changes only the height.
    private static let width: CGFloat = 540

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { pane { general } }
            if EngineDownload.catalogue.count > 1 {
                Tab("3D Model", systemImage: "cube", value: .model) { pane { ModelsSection() } }
            }
            Tab("Draw Things & AI", systemImage: "wand.and.sparkles", value: .drawThings) { pane { drawThings } }
            Tab("Advanced", systemImage: "gearshape.2", value: .advanced) { pane { advanced } }
        }
        // Here, not in a tab: a tab's views go when another is shown, and these must keep going.
        .onChange(of: model.running) { _, running in if !running { health.check(model.install) } }
        .task {
            slicers = Slicer.installed()
            // The checks start the 3D engine, which a running job is already using
            // heavily; they run when it ends instead (above).
            if !model.running { health.check(model.install) }
            // Cancelled when the window closes, which ends the watching.
            await health.watchDrawThings(model.install)
        }
    }

    /// A tab: a grouped form as tall as what's in it, so the window changes height with the
    /// tab. Only past most of the screen (every check failing, say) does it scroll instead.
    private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        Form(content: content).formStyle(.grouped)
            .frame(width: Self.width)
            .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) * 0.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
        Section {
            ForEach(health.checks.filter(\.required)) { row($0) }
        } header: {
            Text("Needed to make minis")
        }
        Section {
            ForEach(health.checks.filter { !$0.required }) { row($0) }
            Toggle(isOn: $openDrawThings) {
                Text("Open Draw Things when needed")
                Text("In the background, and quit afterwards if Mimic opened it.")
            }
                .help("Opens Draw Things in the background when a mini needs a picture")
                .onChange(of: openDrawThings) { if !model.running { health.check(model.install) } }
            if drawThingsProblem {
                // The steps are on their own tab now; this is the way there.
                LabeledContent("Draw Things isn't set up yet") {
                    Button("Set Up Draw Things…") { tab = .drawThings }
                }
            }
        } header: {
            Text("Optional")
        } footer: {
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { health.check(model.install) }.disabled(health.running || model.running)
            }
        }
        Section {
            Picker("Open minis in", selection: slicerChoice) {
                ForEach(slicers) { Text($0.name).tag($0.id) }
                Text("Mac's default app for 3D files").tag(Slicer.macDefault)
            }
            .help("Where Open in … sends a finished mini")
        } footer: {
            Text("Mimic lists the slicers it finds on this Mac. The Mac's default app works with any other slicer.")
                .foregroundStyle(.secondary)
        }
        if hasBattery {
            Section {
                Toggle(isOn: $holdOnBattery) {
                    Text("Don't start minis on battery")
                    Text("The next mini waits until your Mac is plugged in. One already being made carries on.")
                }
                .help("Keeps the queue waiting while your Mac runs on its battery")
            }
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
        UpdatesSection()
    }

    @ViewBuilder private var drawThings: some View {
        if drawThingsProblem {
            Section {
                DrawThingsSteps()
            } header: {
                Text("Set up Draw Things")
            } footer: {
                Text("Pictures work right away. To describe a character or turn a picture into a grey sculpt, Mimic needs the free Draw Things app. This list updates on its own.")
                    .foregroundStyle(.secondary)
            }
        } else if health.drawThingsReady {
            Section {
                SetupStep(done: true, title: "Draw Things is set up.",
                          detail: health.drawThingsOpensWhenNeeded ? "Mimic opens it when it needs it." : nil)
            } header: {
                Text("Draw Things")
            }
        }
        HelperSection()
    }

    @ViewBuilder private var advanced: some View {
        TimingsSection()
        ResetSection()
        Section {
            // Selectable, so it can be copied into a bug report.
            Text(BuildInfo.line).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .help("Which Mimic this is. Include it when you report a problem.")
        }
    }

    /// A Draw Things check came back failed: its setup steps show. Not while it's being
    /// checked, or they'd flash up every time.
    private var drawThingsProblem: Bool {
        Checks.drawThingsIDs.contains { health.results[$0]?.ok == false }
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
        "drawthings-api": "Lets Mimic ask Draw Things for pictures. Mimic opens Draw Things when it needs it, unless you turn that off below.",
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
                if result?.label == Checks.opensWhenNeeded {
                    Text("Its API server has to be on: in Draw Things, Settings → Advanced → API Server, HTTP, port 7860.")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
        } footer: {
            Text("New minis are made with the model in use, and cartoons with Pixal3D. Try Again uses the model a mini was first made with.")
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
                Text(m.described(minutes: model.learnedMinutes(m))).font(.callout).foregroundStyle(.secondary)
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
        SetupStep(done: health.drawThingsConnected, title: "Connect Mimic to it.",
                  detail: "Mimic does this itself, with Draw Things' command line tool: it comes with the 3D engine, and Draw Things doesn't even need to be open. "
                      + "Without it: in Draw Things, Settings → Advanced → API Server. Turn it on, choose HTTP, set the port to 7860.")
        SetupStep(done: health.ok("drawthings-model"), title: "Download FLUX.2 Klein.",
                  detail: "In Draw Things' model list, search for FLUX.2 Klein and download it. It's big, so give it a few minutes.")
    }
}

/// What the time estimates are learned from, and a way to forget it.
private struct TimingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var asking = false

    var body: some View {
        Section {
            LabeledContent {
                Button("Clear…") { asking = true }.disabled(model.history.isEmpty)
            } label: {
                Text("Time estimates")
                Text(model.learnedFrom == 0 ? "Mimic's own figures, until you've made a few minis"
                     : "Based on \(model.learnedFrom) mini\(model.learnedFrom == 1 ? "" : "s") made on this Mac")
            }
        } footer: {
            Text("Mimic times every mini it makes on this Mac to tell you how long the next will take. The times are kept on this Mac only and never sent anywhere.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Clear the time estimates?", isPresented: $asking) {
            Button("Clear", role: .destructive) { model.clearTimings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mimic forgets how long your minis took, and uses its own figures until you've made a few more. Your minis are kept.")
        }
    }
}

/// Mimic → Install Command-Line Tool…: the command-line tool lives inside the app, and a disk
/// image can't put it on the PATH: one command does, the same one for everyone.
@MainActor
enum CommandLineTool {
    // /usr/local/bin is on every Mac's PATH (/etc/paths), but a new Mac doesn't have it and
    // only an administrator can make it, hence sudo; ~/.local/bin would need no password but
    // isn't on the PATH, which would take a second step. The app's own path only when it's in
    // Applications: opened from the disk image (or translocated), it's gone after a restart.
    static let command: String = {
        let app = Bundle.main.bundlePath.hasPrefix("/Applications/") ? Bundle.main.bundlePath : "/Applications/Mimic.app"
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(app)/Contents/MacOS/mimic\" /usr/local/bin/mimic"
    }()

    /// The command, selectable, with Copy Command (Return) and Cancel (Esc).
    static func show() {
        let alert = NSAlert()
        alert.messageText = "Install Command-Line Tool"
        alert.informativeText = "Copy this command, paste it into Terminal once, then type mimic to make minis from there. It asks for your Mac password, because it adds mimic to a folder every account on this Mac uses."
        let text = NSTextField(wrappingLabelWithString: command)
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 280
        text.frame.size = NSSize(width: 280, height: text.fittingSize.height)
        alert.accessoryView = text
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
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
                    .help(model.running ? "Wait for the mini being made to finish" : "Forget Mimic's settings and show the tour again")
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
        } footer: {
            Text("Mimic forgets its settings and saved keys, then opens again as it did the first time. Your minis are kept.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset Mimic?", isPresented: $asking) {
            Button("Reset") { reset(removeEngine: false) }
            Button("Reset All", role: .destructive) { reset(removeEngine: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mimic forgets its settings, tips and any saved AI keys, and shows the tour again. Your minis are kept.\n\nReset All also removes the 3D engine: first-launch setup shows again and downloads it again (about 8 GB).")
        }
    }

    private func reset(removeEngine: Bool) {
        do {
            try Reset.run(install: model.install, domain: Bundle.main.bundleIdentifier ?? "com.mimic.app", removeEngine: removeEngine)
        } catch {
            problem = "Couldn't remove the 3D engine. \(model.plainWords(error, else: "Check that Mimic can write to its folder, then try again."))"
            return
        }
        // The tips show again too: their store is cleared as the new copy starts.
        UserDefaults.standard.set(true, forKey: Tips.resetKey)
        // Opens again as a fresh launch would: a new copy of the app, then this one quits.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
