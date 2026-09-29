import AppKit
import MimicCore
import Observation
import SwiftUI

/// Getting the 3D engine onto this Mac: first launch, or Repair in Settings. Runs in the app,
/// not in a window, so closing the window doesn't stop it.
@MainActor @Observable
final class SetupModel {
    /// The Settings checks that setup fixes.
    static let checkIDs: Set<String> = ["engine", "models"]
    static let drawThingsStore = URL(string: "https://apps.apple.com/app/id6444050820")!

    let install: Install
    /// The engine and every model file are there (not hashed: setup does that). Until they are,
    /// the main window shows the setup screen.
    private(set) var installed: Bool
    private(set) var running = false
    /// Why the last run stopped, in words for people.
    private(set) var problem: String?
    private(set) var progress: SetupProgress?
    /// The moment between first-launch setup finishing and the gallery taking over the window.
    private(set) var justFinished = false
    /// Recent (time, bytes done), for the speed and the time left.
    private var samples: [(at: Date, done: Int64)] = []

    init(install: Install) {
        self.install = install
        installed = EngineDownload.present(install)
    }

    /// An install from the old installer whose engine is still inside image-to-3dlab.
    var hasOldInstall: Bool { install.legacyLab.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func start() {
        guard !running else { return }
        running = true
        problem = nil
        progress = nil
        samples = []
        var setup = EngineSetup(install: install)
        // Development: try setup against a local copy of the files instead of the internet.
        if let mirror = ProcessInfo.processInfo.environment["MIMIC_DOWNLOAD_MIRROR"].flatMap(URL.init(string:)) {
            let local = { (f: EngineFile) in EngineFile(name: f.name, url: mirror.appendingPathComponent(f.name), bytes: f.bytes, sha256: f.sha256) }
            setup.engineFile = local(setup.engineFile)
            setup.models = setup.models.map(local)
        }
        Task {
            #if DEBUG
            // Development: MIMIC_DEMO_SETUP plays a pretend download (about 30 s) and a finish,
            // to look at the setup screen's animations without downloading 8.1 GB.
            if ProcessInfo.processInfo.environment["MIMIC_DEMO_SETUP"] != nil {
                let total = EngineDownload.totalBytes
                for i in 1...150 {
                    try? await Task.sleep(for: .seconds(0.2))
                    update(SetupProgress(activity: .downloading, done: total * Int64(i) / 150, total: total))
                }
                return await finish(present: true)
            }
            #endif
            do {
                try await setup.run { p in Task { @MainActor in self.update(p) } }
            } catch let e as SetupError {
                problem = e.description
            } catch {
                problem = "Setup stopped (\(error.localizedDescription)). Press Try Again: it carries on where it stopped."
            }
            await finish(present: EngineDownload.present(install))
        }
    }

    /// On first launch a finished setup shows it's done for a moment, then the gallery fades in
    /// in its place. A Repair from Settings just ends.
    private func finish(present: Bool) async {
        running = false
        if present && !installed {
            justFinished = true
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.5)) {
                installed = true
                justFinished = false
            }
        } else {
            installed = present
        }
        Health.shared.check(install)
    }

    private func update(_ p: SetupProgress) {
        guard running else { return }
        progress = p
        let now = Date()
        samples.append((now, p.done))
        samples.removeAll { now.timeIntervalSince($0.at) > 10 }
    }

    var fraction: Double {
        guard let p = progress, p.total > 0 else { return 0 }
        return min(1, Double(p.done) / Double(p.total))
    }

    /// Bytes a second over the last few seconds, once there's enough to tell.
    private var speed: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        return seconds >= 2 && last.done > first.done ? Double(last.done - first.done) / seconds : nil
    }

    /// "2.1 of 8.1 GB · 24 MB/s · about 4 minutes left"
    var status: String {
        guard let p = progress else { return "Starting…" }
        switch p.activity {
        case .moving: return "Moving the 3D engine out of your old Mimic folder…"
        case .checking where speed == nil: return "Checking the files already here…"
        default: break
        }
        let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1e9) }
        var parts = ["\(gb(p.done)) of \(gb(p.total)) GB"]
        if let speed {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
            let left = Double(p.total - p.done) / speed
            parts.append(left < 90 ? "about a minute left" : "about \(Int((left / 60).rounded())) minutes left")
        }
        return parts.joined(separator: " · ")
    }
}

/// The main window until the 3D engine is there: what's about to be downloaded, the download,
/// and Draw Things, which is optional.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var setup: SetupModel { model.setup }

    /// 8.1 GB at 100 Mbit/s, rounded to five minutes.
    private var minutes: Int {
        let at100Mbit = Double(EngineDownload.totalBytes) / 12.5e6 / 60
        return max(5, Int((at100Mbit / 5).rounded()) * 5)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 96, height: 96)
                    Text("Welcome to Mimic 👋").font(.largeTitle.bold())
                    Text("One thing before your first mini: Mimic needs its 3D engine, the part that turns a picture into a model. It runs on your Mac, so nothing you make is uploaded.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                engineCard
                drawThingsCard
                Text("You can close this window while it downloads. Mimic carries on, and if the download stops, it picks up where it left off.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        // Ticks the Draw Things steps off as they're done.
        .task { await Health.shared.watchDrawThings(model.install) }
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                // Breathes while it downloads, and becomes a checkmark with a bounce when it's done.
                Image(systemName: setup.justFinished ? "checkmark.circle.fill" : "cube.transparent")
                    .font(.system(size: 30))
                    .foregroundStyle(setup.justFinished ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .symbolEffect(.breathe, options: .repeat(.periodic(delay: 1.5)), isActive: setup.running && !reduceMotion)
                    .symbolEffect(.bounce, value: setup.justFinished && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .default, value: setup.justFinished)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The 3D engine").font(.headline)
                    Text("\(gigabytes) GB, about \(minutes) minutes on a fast connection")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !setup.running && !setup.justFinished {
                    Button(setup.problem == nil ? "Download" : "Try Again") { setup.start() }
                        .glassButton(prominent: true)
                        .controlSize(.large)
                }
            }
            if setup.running || setup.justFinished {
                ProgressView(value: setup.fraction)
                    .progressViewStyle(GlidingBar(working: setup.running))
                Text(setup.status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    // GB, speed and time left roll rather than flicker.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .default, value: setup.status)
            }
            // Told before the 8.1 GB download rather than after it: Mimic is only tested on 32 GB.
            if ProcessInfo.processInfo.physicalMemory < 30_000_000_000 && !setup.justFinished {
                Label("This Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB of memory. Mimic is made for Macs with 32 GB, so making a mini may be very slow or fail here.",
                      systemImage: "memorychip")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let problem = setup.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 16)
    }

    private var drawThingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Draw Things").font(.headline)
                Text("Optional").font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text("A free app that lets Mimic draw a character from a description, and turn drawings into grey sculpts. Your own pictures work without it, and you can set it up any time in Settings.")
                .foregroundStyle(.secondary)
            DrawThingsSteps()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    private var gigabytes: String { String(format: "%.1f", Double(EngineDownload.totalBytes) / 1e9) }
}
