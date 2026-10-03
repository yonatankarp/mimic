import AppKit
import MimicCore
import SwiftUI
import TipKit

/// Quitting during a job, or while the 3D engine downloads, asks first; a confirmed quit stops the job before leaving and puts it
/// back at the front of the queue, to carry on from its last finished step at the next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let notifier = Notifier()
    let reporter = Reporter()

    override init() {
        super.init()
        notifier.model = model
        reporter.model = model
        model.jobEnded = { [notifier] in notifier.announce($0) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Downloading the 3D engine (#344): asked as for a mini, unless one is being made too,
        // whose question comes next.
        if model.setup.running, model.job?.running != true, !Self.systemQuit {
            let alert = NSAlert()
            alert.messageText = String(localized: "Mimic is still downloading")
            alert.informativeText = String(localized: "Quitting stops the download. Start it again later and it picks up where it left off.")
            // First, so Esc presses it.
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard let s = model.job, s.running else { return .terminateNow }
        let jobs = model.jobs
        // Logging out, restarting or shutting down: a question would hold the Mac up, and
        // nothing is lost by not asking.
        if !Self.systemQuit {
            let alert = NSAlert()
            let who = model.displayName(s)
            alert.messageText = s.kind == .prep ? String(localized: "Mimic is still resizing “\(who)”") : String(localized: "Mimic is still making “\(who)”")
            let waiting = model.queue.count
            alert.informativeText = String(localized: "Quitting stops it for now. The next time you open Mimic, it carries on from the last step it finished.")
                + (waiting == 0 ? "" : " " + String(localized: "The \(waiting) minis waiting in the queue will follow."))
            // First, so Esc presses it.
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        jobs.keepGoing = { _ in false }  // the queue waits for the next launch
        jobs.cancel(keepingWork: true)
        // The job's own thread tidies up (the queue, the lock) once its programs have ended;
        // waiting here on the main thread would block the updates it sends.
        DispatchQueue.global().async {
            jobs.waitUntilDone()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// The quit is the Mac logging out, restarting or shutting down, as its quit event says.
    private static var systemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(why.enumCodeValue)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Tips.startUp()
        notifier.start()
    }

    /// A crash last time is asked about once the window is up.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { reporter.offerCrash() }
    }

    /// Closing the window quits Mimic, except while a mini is being made or waiting, or setup is
    /// downloading: that carries on, with its progress on the Dock icon, and the Dock icon (or
    /// the Window menu) brings the window back. ⌘Q still asks first.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.setup.running && !model.running && model.queue.isEmpty
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.becameActive() }

    /// New Mini, the job's progress and Stop while one runs, and pausing the queue while
    /// minis wait, from the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let free = model.sheet == nil
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if model.setup.installed && free { add(String(localized: "New Mini…"), #selector(newMini)) }
        if model.toolbarJob != nil && free { add(String(localized: "Show Progress"), #selector(showProgress)) }
        if let title = model.stopCommand, free { add(title, #selector(stopJob)) }
        if !model.queue.isEmpty && free { add(model.pauseCommand, #selector(togglePause)) }
        return menu
    }

    // Mimic and its window come to the front first (the window may have been closed while a
    // mini is made), then act: the job's popover keeps track of whether it is.
    @objc private func newMini() { model.showWindow(); Task { model.sheet = .make(nil) } }
    @objc private func showProgress() { model.showWindow(); Task { model.jobPopover = true } }
    @objc private func togglePause() { model.togglePause() }
    @objc private func stopJob() { model.showWindow(); Task { model.confirmingStop = true } }
}
