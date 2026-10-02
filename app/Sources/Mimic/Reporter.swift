import AppKit
import MimicCore
import Observation

/// Help → Report a Problem…, or a failed mini's (#100): asks about the picture, makes the
/// report, shows it in Finder and opens GitHub's bug form to drag it into. Reports are kept
/// in the minis folder's `_reports`, which Mimic can already write to (Downloads or the
/// Desktop would ask for permission first) and the gallery never lists. Owned by the app's
/// delegate; views read it from the environment (`@Environment(Reporter.self)`).
@MainActor @Observable
final class Reporter {
    @ObservationIgnored weak var model: AppModel?

    func report(_ mini: Mini? = nil) {
        guard let model else { return }
        let question = ReportQuestion(mini: mini?.displayName)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.text
        alert.addButton(withTitle: ReportQuestion.make)
        alert.addButton(withTitle: ReportQuestion.cancel)
        let hasPicture = mini.flatMap { $0.source ?? $0.upload } != nil
        // Its own checkbox: the alert's suppression checkbox means "Don't ask again".
        let include = NSButton(checkboxWithTitle: ReportQuestion.includePicture, target: nil, action: nil)
        include.state = .off
        include.sizeToFit()
        if hasPicture { alert.accessoryView = include }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let picture = hasPicture && include.state == .on
        let folder = model.install.runs.appendingPathComponent("_reports"), build = BuildInfo.line, mac = Report.mac
        let failure = mini.map { $0.settings.failed ?? "It stopped before it was done." }
        Task {
            let made: URL? = await Task.detached {
                let log = Log.recent(since: Date().addingTimeInterval(-3600))
                return try? Report.write(to: folder, mini: mini, picture: picture, build: build, mac: mac, appLog: log)
            }.value
            guard let made else { model.problem = "Couldn't make the report. Check that Mimic's folder is still there, then try again."; return }
            NSWorkspace.shared.activateFileViewerSelecting([made])
            NSWorkspace.shared.open(Report.issueURL(build: build, mac: mac, failure: failure))
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
        Task {
            let made: URL? = await Task.detached {
                try? CrashReport.write(crash, to: folder, build: build, mac: mac, appLog: CrashReport.appLog(crash))
            }.value
            guard let made else { model.problem = "Couldn't make the report. Check that Mimic's folder is still there, then try again."; return }
            NSWorkspace.shared.activateFileViewerSelecting([made])
            NSWorkspace.shared.open(CrashReport.issueURL(crash, build: build, mac: mac))
        }
    }
}
