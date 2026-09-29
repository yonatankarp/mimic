import AppKit
import MimicCore
import SwiftUI

/// The progress sheet: three steps, a bar, the time so far, and what to do when it ends.
/// Run in Background hides it; the job then shows in the toolbar and on the Dock icon.
struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var confirmingStop = false
    @State private var retryProblem: String?
    /// The raw error behind retryProblem, for the tooltip only.
    @State private var retryDetail: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let steps = [(1, "🖼️ Getting the picture ready"), (2, "🧊 Building the 3D shape (the long part)"),
                        (3, "🖨️ Making the print-ready file")]

    var body: some View {
        if let s = model.job {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(s, now: context.date)
            }
            .padding(20)
            .frame(width: 460)
            .onExitCommand { model.closeJob() }  // Esc while running means Run in Background
            .onChange(of: s.running) { _, running in if !running { confirmingStop = false } }
            .alert(stopTitle(s), isPresented: $confirmingStop) {
                Button("Keep Going", role: .cancel) {}
                Button("Stop", role: .destructive) { model.stop() }
            } message: {
                Text(s.kind == .prep ? "It keeps its previous size." : "What's been made so far will be thrown away.")
            }
        }
    }

    private func content(_ s: JobStatus, now: Date) -> some View {
        let who = Mini.displayName(s.name)
        return VStack(alignment: .leading, spacing: 14) {
            Text(title(s, who: who)).font(.title2.bold())
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.steps.filter { s.kind == .generate || $0.0 == 3 }, id: \.0) { n, label in
                        HStack(spacing: 8) {
                            StepMark(state: state(of: n, in: s), number: n)
                            Text(label).foregroundStyle(state(of: n, in: s) == .pending ? .secondary : .primary)
                        }
                    }
                }
                Spacer(minLength: 0)
                JobPicture(status: s, folder: model.install.runs.appendingPathComponent(s.name))
            }
            ProgressView(value: JobProgress.fraction(s, now: now))
                .progressViewStyle(GlidingBar(working: s.running))
            note(s, now: now)
            HStack {
                if s.running {
                    Button("Stop…") { confirmingStop = true }
                    Spacer()
                    Button("Run in Background") { model.runInBackground() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { model.closeJob() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if s.succeeded, let stl = model.minis.first(where: { $0.name == s.name })?.stl {
                        Button("Open in \(model.slicerName)") { model.openInSlicer(stl) }.keyboardShortcut(.defaultAction)
                    } else if !s.succeeded && !s.canceled {
                        if JobProgress.drawThingsCaused(s) {
                            Button("Open Setup") { model.closeJob(); openSettings() }
                        }
                        Button("Try Again") { tryAgain() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.cantStart != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private func note(_ s: JobStatus, now: Date) -> some View {
        let elapsed = now.timeIntervalSince(s.started)
        Group {
            if s.running {
                Text(JobProgress.note(s.kind, elapsed: elapsed))
                    .foregroundStyle(s.kind == .generate && elapsed > 12 * 60 ? Color.orange : .secondary)
                    // The time so far rolls from one second to the next.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .default, value: Int(elapsed))
            } else if s.canceled {
                Text(s.kind == .prep ? "It keeps its previous size." : "Nothing was kept. It's in the Trash if you want the pieces.")
                    .foregroundStyle(.secondary)
            } else if s.succeeded {
                if s.fragile {
                    Label("Your mini is ready, but some thin parts may be fragile. Check it in your slicer before printing.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(JobProgress.drawThingsCaused(s) ? "Draw Things didn't answer. Check the setup steps, then try again."
                                                         : "Try again, or use a clearer, full-body picture.")
                    if let why = retryProblem ?? model.cantStart ?? s.problem {
                        Text(why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .help(retryProblem != nil ? retryDetail ?? "" : "")
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tryAgain() {
        retryProblem = nil
        do { try model.retry() } catch { retryProblem = model.plainWords(error); retryDetail = "\(error)" }
    }

    private func title(_ s: JobStatus, who: String) -> String {
        let prep = s.kind == .prep
        if s.running { return prep ? "🔁 Resizing \(who)" : "⏳ Making \(who)" }
        if s.canceled { return prep ? "⏹ Stopped resizing \(who)" : "⏹ Stopped making \(who)" }
        if s.succeeded { return "🎉 \(who) is ready!" }
        return "❌ Something went wrong while \(JobRunner.label(s.step).lowercased())"
    }

    private func stopTitle(_ s: JobStatus) -> String {
        s.kind == .prep ? "Stop resizing “\(Mini.displayName(s.name))”?" : "Stop making “\(Mini.displayName(s.name))”?"
    }

    private func state(of n: Int, in s: JobStatus) -> StepMark.State {
        if s.running { return n < s.step ? .done : n == s.step ? .active : .pending }
        if s.succeeded { return .done }
        if s.canceled { return .pending }
        return n < s.step ? .done : n == s.step ? .failed : .pending
    }
}

/// A step's number, breathing while it's the one being worked on; it turns into a checkmark
/// (or a cross) in place, and a checkmark gives a small bounce.
private struct StepMark: View {
    enum State { case pending, active, done, failed }
    let state: State
    let number: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .symbolEffect(.breathe, options: .repeat(.periodic(delay: 1.5)), isActive: state == .active && !reduceMotion)
            .symbolEffect(.bounce, value: state == .done && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .default, value: state)
            .frame(width: 18, height: 18)
    }

    private var symbol: String {
        switch state {
        case .pending: "\(number).circle"
        case .active: "\(number).circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .pending: .secondary
        case .active: .accentColor
        case .done: .green
        case .failed: .red
        }
    }
}

/// The character, as soon as there's a picture of it: the picture while it's being made, with
/// a slow scan across it while the 3D shape is built; the finished mini's front view once it's
/// ready. Success gets a checkmark badge; failure a warning badge and a small shake, no fuss.
private struct JobPicture: View {
    let status: JobStatus
    /// runs/<name>, where the job writes source.png and the renders.
    let folder: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read every second with the sheet's clock: cheap (a stat), and the picture appears the
        // moment step 1 writes it.
        let file = shownFile
        let version = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        let building = status.running && status.kind == .generate && status.step == 2
        let failed = !status.running && !status.succeeded && !status.canceled
        let shape = RoundedRectangle(cornerRadius: 12)
        Thumbnail(url: version == nil ? nil : file, version: version ?? .distantPast)
            .frame(width: 84, height: 84)
            .clipShape(shape)
            .glassCard(cornerRadius: 12)  // as the mini's own previews: renders have no background
            // A soft glow while the long step runs, and the scan. Both sit outside the glass and
            // the glow is a still blur: glass or a shadow around the moving scan redrew with it
            // every frame.
            .background { shape.fill(Color.accentColor.opacity(building ? 0.45 : 0)).blur(radius: 8) }
            .overlay { if building && !reduceMotion { LightSweep(vertical: true, crossing: 2.6, rest: 1.6, strength: 0.35).clipShape(shape) } }
            .overlay(alignment: .bottomTrailing) {
                if status.succeeded {
                    badge("checkmark.circle.fill", .green)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                } else if failed {
                    badge("exclamationmark.triangle.fill", .orange).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .bouncy, value: status.running)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: building)
            .keyframeAnimator(initialValue: 0.0, trigger: failed && !reduceMotion) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    for x in [-5.0, 4, -2.5, 1, 0] { CubicKeyframe(x, duration: 0.09) }
                }
            }
            .accessibilityHidden(true)
    }

    private var shownFile: URL {
        let front = folder.appendingPathComponent("\(status.name)_front.png")
        let resized = status.kind == .prep || status.succeeded
        return resized && FileManager.default.fileExists(atPath: front.path) ? front : folder.appendingPathComponent("source.png")
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .background(Circle().fill(.background).padding(2))
            .offset(x: 6, y: 6)
    }
}

/// Where the progress goes when it runs in the background: a toolbar button that reopens it.
struct JobToolbarItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if model.jobShown, let s = model.job {
            Button { model.showProgress() } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        if s.running {
                            ProgressRing(fraction: JobProgress.fraction(s, now: context.date))
                                .transition(.opacity)
                        } else {
                            Image(systemName: s.succeeded ? "checkmark.circle.fill" : s.canceled ? "stop.circle" : "exclamationmark.circle.fill")
                                .foregroundStyle(s.succeeded ? .green : s.canceled ? .secondary : .red)
                                .transition(reduceMotion || !s.succeeded ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                        }
                        Text(label(s, now: context.date)).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .animation(reduceMotion ? nil : .bouncy, value: s.running)
                    .animation(reduceMotion ? nil : .default, value: Int(context.date.timeIntervalSince(s.started)))
                }
            }
            .help("Show progress")
        }
    }

    private func label(_ s: JobStatus, now: Date) -> String {
        let who = Mini.displayName(s.name)
        if s.running { return "\(s.kind == .prep ? "Resizing" : "Making") \(who) · \(JobProgress.clock(now.timeIntervalSince(s.started)))" }
        if s.canceled { return "Stopped \(who)" }
        return s.succeeded ? "\(who) is ready" : "\(who) didn't finish"
    }
}

/// The toolbar's progress: a ring around a dot that pulses now and then to say it's still
/// working. It shows for the whole job with the sheet hidden, so it rests between pulses.
private struct ProgressRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeat(.periodic(delay: 1.5)), isActive: !reduceMotion)
        }
        .frame(width: 14, height: 14)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

/// A progress bar on the Dock icon while a job runs, so it can be followed from any app.
@MainActor
enum DockProgress {
    private static var task: Task<Void, Never>?

    static func follow(_ model: AppModel) {
        task?.cancel()
        task = Task { @MainActor in
            let tile = NSApp.dockTile, view = DockTileView()
            tile.badgeLabel = nil
            tile.contentView = view
            while !Task.isCancelled, let s = model.job, s.running {
                view.fraction = JobProgress.fraction(s)
                tile.display()
                // Every second, like the sheet's clock: a 2-second step read as a stutter.
                try? await Task.sleep(for: .seconds(1))
            }
            tile.contentView = nil
            tile.display()
        }
    }
}

private final class DockTileView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let track = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.06, width: bounds.width * 0.8, height: bounds.height * 0.1)
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inset = track.insetBy(dx: 2, dy: 2)
        var fill = inset
        fill.size.width = max(inset.height, inset.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}

/// What the main window adds around the gallery: the sheets and questions, and the toolbar's
/// New Mini button and job progress. Kept here so the window's own layout stays about the gallery.
struct MainWindowChrome: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) { JobToolbarItem() }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink {
                        Label("Settings", systemImage: Health.shared.needsAttention ? "exclamationmark.triangle.fill" : "gearshape")
                    }
                    .foregroundStyle(Health.shared.needsAttention ? .orange : .primary)
                    .help(Health.shared.blocking ?? "Settings (⌘,)")
                    .tourStop(.settings)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.sheet = .make } label: { Label("New Mini", systemImage: "plus") }
                        .help("Make a new mini (⌘N)")
                        .tourStop(.newMini)  // before .disabled, which its popover would inherit
                        .disabled(!model.setup.installed)
                }
            }
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .make: MakeView()
                case .resize(let mini): ResizeView(mini: mini)
                case .rename(let mini): RenameSheet(mini: mini)
                case .progress: JobProgressView()
                }
            }
            .confirmationDialog("Move “\(model.trashing?.displayName ?? "")” to the Trash?",
                                isPresented: Binding(get: { model.trashing != nil }, set: { if !$0 { model.trashing = nil } }),
                                presenting: model.trashing) { mini in
                Button("Move to Trash", role: .destructive) { model.trash(mini) }
                Button("Keep It", role: .cancel) {}
            } message: { _ in
                Text("You can put it back from the Trash if you change your mind.")
            }
            .alert(model.problem ?? "", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
                Button("OK") {}
            }
            // Minis made from the terminal appear when you come back to the app.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reload()
            }
    }
}

/// Quitting during a job asks first, and a confirmed quit stops the job before leaving.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = model.job, s.running else { return .terminateNow }
        let jobs = model.jobs
        let alert = NSAlert()
        let who = Mini.displayName(s.name)
        alert.messageText = s.kind == .prep ? "Mimic is still resizing “\(who)”" : "Mimic is still making “\(who)”"
        alert.informativeText = s.kind == .prep ? "Quitting stops it, and it keeps its previous size."
                                                : "Quitting stops it, and what's been made so far will be thrown away."
        alert.addButton(withTitle: "Keep Going")
        alert.addButton(withTitle: "Stop and Quit").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        jobs.cancel()
        // The job's own thread tidies up (the Trash, the lock) once its programs have ended;
        // waiting here on the main thread would block the updates it sends.
        DispatchQueue.global().async {
            jobs.waitUntilDone()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Closing the window quits Mimic, except while setup is downloading: that carries on, and
    /// the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.setup.running }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil  // seen it
    }
}
