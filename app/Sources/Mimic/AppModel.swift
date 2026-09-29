import AppKit
import MimicCore
import Observation
import UserNotifications

/// The sheet over the main window. One at a time, so swapping Make for its progress is a single
/// change rather than a dismiss and a present racing each other.
enum AppSheet: Identifiable, Equatable {
    case make, resize(Mini), progress
    var id: String {
        switch self {
        case .make: "make"
        case .resize(let m): "resize-\(m.name)"
        case .progress: "progress"
        }
    }
}

/// The state every window shares: the Mimic folder, the gallery, the selection and the one job.
/// Views read it from the environment (`@Environment(AppModel.self)`).
@MainActor @Observable
final class AppModel {
    let install: Install?
    let jobs: JobRunner?
    var minis: [Mini] = []
    var selection: Mini.ID?
    /// The job's latest status, updated on the main thread; nil before the first job.
    var job: JobStatus?
    /// Why a job can't start (a required check failed), or nil: the latest health checks.
    var requiredProblem: String? { Health.shared.blocking }
    var sheet: AppSheet?
    /// The job has a place on screen: its sheet, or the toolbar item it went to. Close clears it.
    var jobShown = false

    init() {
        let install = Install.locate()
        // A job left running by a Mimic that crashed (or was force-quit) is stopped first:
        // otherwise a 14 GB Blender could run on with nothing watching it.
        if let install { Leftover.stop(install.runs) }
        self.install = install
        jobs = install.map { JobRunner(install: $0) }
        jobs?.onChange = { [weak self] s in Task { @MainActor in self?.jobChanged(s) } }
        reload()
        // Run the checks at launch, so Make is blocked (and Settings flagged) before anyone opens Settings.
        Health.shared.check(install)
    }

    var selected: Mini? { minis.first { $0.id == selection } }
    var running: Bool { job?.running == true }

    func reload() {
        guard let install else { return }
        minis = Gallery.list(install.runs)
        if selection == nil || selected == nil { selection = minis.first?.id }
    }

    // MARK: Jobs

    /// Why Make, Resize or Try Again can't start right now, or nil.
    var cantStart: String? {
        if let requiredProblem { return requiredProblem }
        if let job, job.running { return RequestError.busy(job.name).description }
        return nil
    }

    func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes) throws {
        try start { try $0.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes) }
        askForNotifications()
    }

    func resize(_ mini: Mini, sizes: Sizes) throws {
        try start { try $0.resize(name: mini.name, sizes: sizes) }
    }

    /// Runs the last job again with the inputs it saved.
    func retry() throws {
        guard let name = job?.name else { return }
        try start { try $0.retry(name: name) }
    }

    func stop() { jobs?.cancel() }

    /// Hides the progress sheet; the job carries on and shows in the toolbar and the Dock.
    func runInBackground() { if sheet == .progress { sheet = nil } }

    func showProgress() { sheet = .progress }

    /// Closes a finished job's sheet and removes it from the toolbar.
    func closeJob() {
        guard !running else { return runInBackground() }
        jobShown = false
        if sheet == .progress { sheet = nil }
    }

    private func start(_ begin: (JobRunner) throws -> Void) throws {
        if let requiredProblem { throw Refusal(description: requiredProblem) }
        guard let jobs else { return }
        try begin(jobs)
        job = jobs.status  // at once, so the sheet never opens on the previous job
        jobShown = true
        sheet = .progress
        DockProgress.follow(self)
    }

    private func jobChanged(_ s: JobStatus) {
        let finished = job?.running == true && !s.running
        job = s
        guard !s.running else { return }
        reload()
        if s.succeeded { selection = s.name }
        if finished { announce(s) }
    }

    // MARK: Telling you it's done

    /// The Mac asks once; after that this is a no-op. Only an app bundle can use notifications:
    /// the bare binary from `swift build` has none and would crash here.
    private func askForNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func announce(_ s: JobStatus) {
        guard !s.canceled, !NSApp.isActive else { return }
        NSApp.dockTile.badgeLabel = s.succeeded ? "✓" : "!"
        guard Bundle.main.bundleIdentifier != nil else { return }
        let who = Mini.displayName(s.name)
        let content = UNMutableNotificationContent()
        content.title = s.succeeded ? "\(who) is ready" : "\(who) didn't finish"
        content.body = s.succeeded ? "Your mini is ready to print." : "Open Mimic to try again."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "job", content: content, trigger: nil))
    }

    // MARK: Slicer

    /// Opens a print file in the picked slicer, or the Mac's default app for STL files.
    func openInSlicer(_ stl: URL) {
        if let slicer = Slicer.preferred() {
            NSWorkspace.shared.open([stl], withApplicationAt: slicer.app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(stl)
        }
    }

    var slicerName: String { Slicer.preferred()?.name ?? "your slicer" }
}

/// A job refused before it started, in words for people.
struct Refusal: Error, CustomStringConvertible { let description: String }
