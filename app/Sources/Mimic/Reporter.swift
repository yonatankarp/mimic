import AppKit
import MimicCore
import Observation

/// Help → Report a Problem…, or a failed mini's (#100): asks about the pictures, makes the
/// report, shows it in Finder and opens GitHub's bug form to drag it into. Reports are kept for
/// a week in the minis folder's `_reports`, which Mimic can already write to (Downloads or the
/// Desktop would ask for permission first) and the gallery never lists. Owned by the app's
/// delegate; views read it from the environment (`@Environment(Reporter.self)`).
@MainActor @Observable
final class Reporter {
    @ObservationIgnored weak var model: AppModel?

    func report(_ mini: Mini? = nil) {
        guard let model else { return }
        // Before the alert covers it (#283): the main window and its sheets, not Settings.
        let window = Self.mainWindow.flatMap { WindowPicture.png($0) }
        let question = ReportQuestion(mini: mini?.displayName)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.text
        alert.addButton(withTitle: ReportQuestion.make)
        alert.addButton(withTitle: ReportQuestion.cancel)
        let hasPicture = mini.flatMap { $0.source ?? $0.upload } != nil
        // Their own checkboxes: the alert's suppression checkbox means "Don't ask again".
        let include = NSButton(checkboxWithTitle: ReportQuestion.includePicture, target: nil, action: nil)
        include.state = .off
        let includeWindow = NSButton(checkboxWithTitle: ReportQuestion.includeWindow, target: nil, action: nil)
        includeWindow.state = .off  // #350: it can show other minis
        // No preview of the window: the 3D view doesn't draw into it, so it came out mostly blank.
        let rows: [NSView] = (hasPicture ? [include] : []) + (window != nil ? [includeWindow] : [])
        if !rows.isEmpty {
            let stack = NSStackView(views: rows)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame.size = stack.fittingSize  // an alert sizes its accessory by its frame
            alert.accessoryView = stack
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let picture = hasPicture && include.state == .on
        let shot = includeWindow.state == .on ? window : nil
        let folder = model.install.runs.appendingPathComponent("_reports"), build = BuildInfo.line, mac = Report.mac
        let failure = mini.map { $0.settings.failed ?? "It stopped before it was done." }
        make(model, mini: mini) { setup, saved in
            try? Report.write(to: folder, mini: mini, picture: picture, build: build, mac: mac,
                              appLog: Log.recent(since: Date().addingTimeInterval(-3600)), setup: setup, window: shot, saved: saved)
        } issue: { setup, saved in
            Report.issueURL(build: build, mac: mac, failure: failure, setup: setup, saved: saved)
        }
    }

    /// At launch, when Mimic or `mimic` crashed since the last look (#284): asks once, then makes
    /// the same report with the crash and the crashed launch's log in it, and opens the form
    /// titled with the crash. Nothing is sent: the person submits the issue.
    func offerCrash() {
        guard let model, let crash = CrashReport.check() else { return }
        let alert = NSAlert()
        alert.messageText = CrashQuestion.title
        alert.informativeText = CrashQuestion.text
        alert.addButton(withTitle: CrashQuestion.report)
        alert.addButton(withTitle: CrashQuestion.notNow).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: CrashQuestion.dontAsk)
        let answer = alert.runModal()
        if answer == .alertThirdButtonReturn { UserDefaults.standard.set(true, forKey: CrashReport.dontAskKey) }
        guard answer == .alertFirstButtonReturn else { return }
        let folder = model.install.runs.appendingPathComponent("_reports"), build = BuildInfo.line, mac = Report.mac
        // The setup as it is now: the crashed launch's queue and last job went with it.
        make(model, mini: nil) { setup, saved in
            try? CrashReport.write(crash, to: folder, build: build, mac: mac, appLog: CrashReport.appLog(crash), setup: setup, saved: saved)
        } issue: { setup, saved in
            CrashReport.issueURL(crash, build: build, mac: mac, setup: setup, saved: saved)
        }
    }

    /// Makes a report off the main thread with `write`, given the setup and the keys saved in
    /// Settings to take out, then shows it in Finder and opens the form `issue` fills in.
    private func make(_ model: AppModel, mini: Mini?, write: @escaping @Sendable (ReportSetup, [String]) -> URL?,
                      issue: @escaping @Sendable (ReportSetup, [String]) -> URL) {
        let install = model.install, known = setupKnown(mini)
        Task {
            let made: (URL, ReportSetup, [String])? = await Task.detached {
                var setup = ReportSetup.current(install: install)
                known(&setup)
                // The keys saved in Settings, to take out wherever they are (#352). Off the main
                // thread: reading them may wait on a Keychain prompt after an update.
                let saved = Keychain.all()
                return write(setup, saved).map { ($0, setup, saved) }
            }.value
            guard let made else { model.problem = Problem("Couldn't make the report", "Check that Mimic's folder is still there, then try again."); return }
            NSWorkspace.shared.activateFileViewerSelecting([made.0])
            NSWorkspace.shared.open(issue(made.1, made.2))
        }
    }

    /// What only the app knows about the setup, read now on the main thread, to add to what
    /// `ReportSetup.current` reads: the queue, the last job, and the nozzle, base and grey
    /// sculpt of `mini`, else of the last job's mini, else New Mini's last choice. No names.
    func setupKnown(_ mini: Mini?) -> @Sendable (inout ReportSetup) -> Void {
        guard let model else { return { _ in } }
        let running = model.current.map { ReportSetup.Job($0) }, waiting = model.queue.map(\.job), hold = model.hold
        let lastJob = (model.ended.last ?? model.job.flatMap { $0.running ? nil : $0 })
        let last = lastJob.map { ReportSetup.Job($0) }
        let lastMini = lastJob.flatMap { j in model.minis.first { $0.name == j.name } }
        let from: ReportSetup.SettingsFrom = mini != nil ? .mini : lastMini != nil ? .lastJob : .newMini
        let settings = (mini ?? lastMini)?.settings
        let sizes = settings?.requested ?? SizeCard.remembered().sizes
        let sculpt = settings.map { $0.restyle == true }
        return { s in
            s.running = running; s.waiting = waiting; s.hold = hold; s.lastJob = last
            s.sizes = sizes; s.greySculpt = sculpt; s.settingsFrom = from
        }
    }

    /// The gallery's window, when it's open: SwiftUI names it after its scene, "main", else it's
    /// the one as wide as the gallery's smallest (Settings is narrower, sheets have a parent).
    static var mainWindow: NSWindow? {
        let open = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }
        return open.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? open.first { $0.canBecomeMain && $0.frame.width >= 960 }
    }
}
