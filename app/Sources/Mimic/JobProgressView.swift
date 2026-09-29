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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.steps.filter { s.kind == .generate || $0.0 == 3 }, id: \.0) { n, label in
                    HStack(spacing: 8) {
                        StepMark(state: state(of: n, in: s), number: n)
                        Text(label).foregroundStyle(state(of: n, in: s) == .pending ? .secondary : .primary)
                    }
                }
            }
            ProgressView(value: JobProgress.fraction(s, now: now))
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
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tryAgain() {
        retryProblem = nil
        do { try model.retry() } catch { retryProblem = "\(error)" }
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

private struct StepMark: View {
    enum State { case pending, active, done, failed }
    let state: State
    let number: Int
    var body: some View {
        Group {
            switch state {
            case .pending: Image(systemName: "\(number).circle").foregroundStyle(.secondary)
            case .active: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Where the progress goes when it runs in the background: a toolbar button that reopens it.
struct JobToolbarItem: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.jobShown, let s = model.job {
            Button { model.showProgress() } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        if s.running {
                            ProgressView(value: JobProgress.fraction(s, now: context.date))
                                .progressViewStyle(.circular).controlSize(.small)
                        } else {
                            Image(systemName: s.succeeded ? "checkmark.circle.fill" : s.canceled ? "stop.circle" : "exclamationmark.circle.fill")
                                .foregroundStyle(s.succeeded ? .green : s.canceled ? .secondary : .red)
                        }
                        Text(label(s, now: context.date)).monospacedDigit()
                    }
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
                try? await Task.sleep(for: .seconds(2))
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

/// What the main window adds around the gallery: the sheets, and the toolbar's New Mini button
/// and job progress. Kept here so the window's own layout stays about the gallery.
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
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.sheet = .make } label: { Label("New Mini", systemImage: "plus") }
                        .help("Make a new mini (⌘N)")
                        .disabled(model.install == nil)
                }
            }
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .make: MakeView()
                case .resize(let mini): ResizeView(mini: mini)
                case .progress: JobProgressView()
                }
            }
    }
}

/// Quitting during a job asks first, and a confirmed quit stops the job before leaving.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = model.job, s.running, let jobs = model.jobs else { return .terminateNow }
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

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil  // seen it
    }
}
