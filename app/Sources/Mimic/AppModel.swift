import AppKit
import MimicCore
import Observation
import OSLog
import SwiftUI

/// The sheet over the main window, one at a time.
enum AppSheet: Identifiable, Equatable {
    /// New Mini: empty, or filled in with the tour's sample.
    case make(MakeStart?)
    case resize(Mini), rename(Mini)
    /// New Mini filled in from a mini: Edit & Make Again. Nil when it has nothing to make it
    /// again from, which opens it empty.
    case makeAgain(Mini, MakeStart?)
    /// Resize All on a project.
    case resizeAll(String)
    /// Resize on several minis selected together.
    case resizeSeveral([Mini])
    /// A new project, and the minis to move into it when asked from Move to Project.
    case newProject(moving: [Mini])
    case renameProject(String)
    /// Copies of one mini, or of each of several, in one print file.
    case copies([Mini])
    /// Duplicate: the copy's name, then Resize for it.
    case duplicate(Mini)
    /// Import Model: a 3D model file, to name and size.
    case importModel(URL)
    /// Compare Side by Side: two versions of a mini, by name.
    case compare(String, String)
    /// Make Another Version, or New 3D Shape: what to change in its picture, if anything (#156).
    case version(Mini, newShape: Bool)
    /// New Mini, empty or with the sample, as the tour follows it; not Edit & Make Again.
    var isNewMini: Bool { if case .make = self { true } else { false } }
    var id: String {
        switch self {
        case .make: "make"
        case .makeAgain(let m, _): "make-again-\(m.name)"
        case .resize(let m): "resize-\(m.name)"
        case .resizeAll(let p): "resize-all-\(p)"
        case .resizeSeveral(let m): "resize-several-\(Gallery.dragged(m.map(\.name)))"
        case .rename(let m): "rename-\(m.name)"
        case .newProject(let m): "new-project-\(Gallery.dragged(m.map(\.name)))"
        case .renameProject(let p): "rename-project-\(p)"
        case .copies(let m): "copies-\(Gallery.dragged(m.map(\.name)))"
        case .duplicate(let m): "duplicate-\(m.name)"
        case .importModel(let u): "import-\(u.path)"
        case .compare(let a, let b): "compare-\(a)-\(b)"
        case .version(let m, let newShape): "\(newShape ? "new-shape" : "version")-\(m.name)"
        }
    }
}

/// Something that didn't happen, as the window's alert says it: a short title saying what,
/// and why (or what to do) as its message.
struct Problem: Equatable {
    let title: String
    let message: String
    init(_ title: String, _ message: String) { self.title = title; self.message = message }
}

/// The state every window shares: the Mimic folder, the gallery, the selection and the one job.
/// Views read it from the environment (`@Environment(AppModel.self)`).
@MainActor @Observable
final class AppModel {
    /// Changed only by Settings → General → Change… (`changeMinisFolder`), with the runner.
    private(set) var install: Install
    private(set) var jobs: JobRunner
    /// First-launch setup, and Repair from Settings. Here rather than in a view, so a download
    /// carries on when the window closes.
    let setup: SetupModel
    /// Checking for a newer Mimic, and installing it.
    let updates = Updater()
    var minis: [Mini] = []
    /// What the mini called `name` is shown as ("Élodie"), from the list: no file is read.
    func displayName(_ name: String) -> String { Mini.displayName(name, in: minis) }
    /// A job's mini, by the name it started with: a stopped one's folder is in the Trash (#166).
    func displayName(_ s: JobStatus) -> String { s.shown ?? displayName(s.name) }
    /// The projects (folders of minis), alphabetical, empty ones included.
    var projects: [String] = []
    /// A mini or a project already has `name`, as `Gallery.nameInUse` finds it, from the list:
    /// no folder is read, so a sheet can ask on every redraw (#340).
    func nameInUse(_ name: String) -> Bool {
        minis.contains { $0.name == name } || projects.contains { $0.lowercased() == name.lowercased() }
    }
    /// The project New Mini starts in when asked from a project's own menu; else the selected
    /// mini's. Taken (and cleared) by New Mini.
    var makeInProject: String?
    /// The project waiting on "Delete Project?".
    var deletingProject: String?
    /// The projects shown collapsed in the sidebar, kept between launches.
    var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedProjects") ?? []) {
        didSet { UserDefaults.standard.set(collapsed.sorted(), forKey: "collapsedProjects") }
    }
    /// The minis selected in the sidebar: one, or several (⌘-click, ⇧-click, ⌘A).
    var selection = Set<Mini.ID>() {
        // Picked with Mimic in front: a ready mini has been seen.
        didSet { if NSApp.isActive, present({ $0.seen(selection) }) { updateBadge() } }
    }
    /// The toolbar's job item and its popover around the job: the queued note, the jobs that
    /// ended meanwhile, whether its end was seen, and the minis not yet seen.
    private(set) var presentation = JobPresentation()
    /// The details panel beside a mini's page, kept between launches. Here rather than in
    /// @AppStorage, so View → Show/Hide Details follows it as the menus follow the selection.
    var showDetails = UserDefaults.standard.object(forKey: "showDetails") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showDetails, forKey: "showDetails") }
    }
    /// Opens the main window again after it's been closed (a job carries on without it); set by
    /// the window.
    @ObservationIgnored var openMainWindow: () -> Void = {}
    /// The job's latest status, updated on the main thread; nil before the first job.
    var job: JobStatus?
    /// Why Make, Resize or Try Again can't start right now (a required check failed), or nil: the
    /// latest health checks. A job already running is no reason: the new one waits its turn.
    var requiredProblem: String? { Health.shared.blocking }
    var sheet: AppSheet?
    /// The job's popover under its toolbar item: opened by clicking it, and by itself when a job
    /// starts with Mimic in front. Closing it (a click outside, Esc, the item) may count a
    /// finished job as seen; see `JobPresentation.popoverClosed`.
    var jobPopover = false {
        didSet {
            guard oldValue && !jobPopover else { return }
            if present({ $0.popoverClosed(active: active, busy: running || !queue.isEmpty || elsewhere != nil) }) { updateBadge() }
        }
    }
    /// Mimic is the app in front. Set before the popover closes on switching away (it closes
    /// when the app resigns), which NSApp.isActive may not yet say.
    private var active = true
    /// "Stop making …?", asked from the job's popover, the Mini menu or the Dock menu.
    var confirmingStop = false
    /// The job in the toolbar, which the job's popover hangs from; nil hides both.
    var toolbarJob: JobStatus? { JobProgress.inToolbar(job, keptShown: presentation.keptShown, elsewhere: elsewhere) }
    /// This Mimic's job can be stopped: "Stop Making…" or "Stop Resizing…" in the menus, else nil.
    var stopCommand: String? { JobProgress.stopCommand(job) }
    /// View → Face Front: bumped for the mini's 3D view to turn back to face you.
    var faceFrontRequests = 0
    /// Edit → Find: bumped for the sidebar to put the cursor in its search field.
    var findRequests = 0
    /// Keep This One from Compare Side by Side: the version to ask about once the sheet has
    /// gone (`keepWhenClosed`), then on its page (`askToKeep`), whose dialog does the keeping.
    var keepWhenClosed: String?
    var askToKeep: String?
    /// The waiting job on "Remove it from the queue?", asked from the job's popover.
    var unqueueing: QueueEntry?
    /// Minis on "Move to Trash?", when one of them waits in the queue: Undo can't put it back
    /// in the queue, so it's asked first (see `askToTrash`).
    var trashing: [Mini] = []
    /// The main window's, for Undo Move to Trash; set by the window.
    @ObservationIgnored weak var undo: UndoManager?
    /// A rename or trash that was refused, shown as an alert.
    var problem: Problem? {
        didSet { if let problem, problem != oldValue { Log.shown.error("\(problem.title, privacy: .public): \(problem.message, privacy: .public)") } }
    }

    /// Every job this Mac has finished, which the time estimates come from. On this Mac only.
    let timings: Timings
    private(set) var history: [TimingRecord] = []
    /// The shared queue, as last read (`QueueWatch.swift`).
    let queueWatch = QueueWatch()
    /// Jobs that ended since the job's popover was last seen, the latest last.
    var ended: [JobStatus] { presentation.ended }
    /// "Added to the queue — …", at the top of the job's popover until that mini starts or the
    /// popover is closed.
    var queuedNote: JobPresentation.QueuedNote? { presentation.queuedNote }

    /// Changes `presentation`, which views are told of only when that changed something.
    @discardableResult
    func present<T>(_ change: (inout JobPresentation) -> T) -> T {
        var p = presentation
        let result = change(&p)
        if p != presentation { presentation = p }
        return result
    }

    init() {
        let install = Install.locate()
        self.install = install
        timings = Timings.standard()
        jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
        setup = SetupModel(install: install)
        updates.model = self
        wire(jobs)
        queueWatch.follow(jobs)
        reload()
        // Run the checks at launch, so Make is blocked (and Settings flagged) before anyone opens Settings.
        Health.shared.check(install)
        // Past minis seed the time estimates, once; off the main thread, it reads every folder.
        let timings = timings, runs = install.runs
        Task.detached {
            timings.seedIfNeeded(runs: runs)
            let history = timings.load()
            await MainActor.run { self.history = history }
        }
        // A job left running by a Mimic that crashed (or was force-quit) is stopped, and jobs
        // left waiting start, asking nothing: they were asked for. Then every few seconds,
        // since another Mimic may quit or crash with jobs still waiting.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = false }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.active = true }
        }
        Task { [weak self] in
            while let self {
                await self.watchQueue()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        #if DEBUG
        if let spec = ProcessInfo.processInfo.environment["MIMIC_DEMO_PROGRESS"] { demoProgress(spec) }
        #endif
    }

    private func wire(_ jobs: JobRunner) {
        jobs.onChange = { [weak self] s in Task { @MainActor in self?.jobChanged(s) } }
        jobs.heldForPower = Power.holds(suite: nil)
    }

    // MARK: The minis folder

    /// A mini is being made or waits, here or in another Mimic using this folder: Change… is
    /// refused then, and Settings says why before it's asked.
    var minisFolderBusy: Bool { current != nil || !queue.isEmpty }

    /// Makes `folder` the minis folder (#102), moving the minis there first when asked, or using
    /// whatever minis it already has. Off the main thread, since a move to another disk copies
    /// every file. The setting is saved only once that worked; then the gallery, the folder
    /// watch and the queue follow the new folder.
    func changeMinisFolder(to folder: URL, moving: Bool) async throws {
        let jobs = self.jobs
        // Saved before the move's mark comes off, so a `mimic make` refused meanwhile and asked
        // again finds the new folder.
        try await Task.detached {
            try jobs.changeMinisFolder(to: folder, moving: moving) { UserDefaults.standard.set(folder.path, forKey: MinisFolder.key) }
        }.value
        let install = Install.locate()
        self.install = install
        self.jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
        queueWatch.follow(self.jobs)
        wire(self.jobs)
        selection = []
        reload()
        refreshQueue()
        Health.shared.check(install)  // the free space is the new folder's disk's
    }

    /// Whether `folder` already has minis or projects, so Change… asks whether to move these too.
    nonisolated static func hasMinis(_ folder: URL) -> Bool {
        !Gallery.list(folder).isEmpty || !Gallery.projects(folder).isEmpty
    }

    /// The one selected mini, whose page shows; nil when none or several are.
    var selected: Mini? { selection.count == 1 ? minis.first { selection.contains($0.id) } : nil }
    /// Every selected mini, in the gallery's order.
    var chosen: [Mini] { minis.filter { selection.contains($0.id) } }
    var running: Bool { job?.running == true }

    func reload() {
        // One scan of the minis folder, and another only when one renamed or copied in Finder was taken over.
        var list = Gallery.list(install.runs)
        if !jobs.adoptOddFolders(listed: list).isEmpty { list = Gallery.list(install.runs) }
        let folders = Gallery.projects(install.runs)
        // Only what changed, so a reload from the folder watch doesn't redraw an unchanged list.
        if list != minis { minis = list }
        if folders != projects { projects = folders }
        watch.follow(install.runs, projects: folders)
        let kept = selection.filter { id in minis.contains { $0.id == id } }
        if kept != selection { selection = kept }
        if selection.isEmpty {
            let first = Gallery.keeping([], in: Gallery.arrange(minis, query: listQuery, show: listShow, sort: listSort))
            if first != selection { selection = first }
        }
    }

    /// The search, filter and order the list has (Sidebar keeps them up to date), so a reload
    /// with nothing selected picks the first mini the list shows.
    @ObservationIgnored var listQuery = ""
    @ObservationIgnored var listShow = GalleryShow.all
    @ObservationIgnored var listSort = GallerySort.made

    /// Reloads when a mini or project is added, removed or renamed in the minis folder by
    /// anything else: Finder, `mimic move`, another Mimic (#81).
    @ObservationIgnored private lazy var watch = FolderWatch { [weak self] in self?.reload() }

    // MARK: The Dock and the window (the queue is in QueueWatch.swift)

    /// How many minis are ready and not yet seen, on the Dock icon; nothing when none are. The
    /// only place the badge is set.
    func updateBadge() {
        let label = JobProgress.badge(unseen: presentation.unseen, minis: minis.map(\.name))
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Mimic came to the front: the mini on screen has been seen.
    func becameActive() {
        // Whatever changed in Finder meanwhile, and minis made from the terminal. The only reload
        // on coming to the front (AppDelegate calls this).
        reload()
        updates.becameActive()
        if present({ $0.seen(selection) }) { updateBadge() }
    }

    /// Brings Mimic and its window to the front, opening the window again if it was closed.
    func showWindow() {
        NSApp.activate()
        openMainWindow()
    }

    /// The running job, here or in another Mimic.
    var current: JobStatus? { running ? job : elsewhere }

    /// When a mini just added should be ready, or why it waits.
    private func whenReady(_ ready: TimeInterval) -> String { hold.map { $0.sentence } ?? "Ready in \(JobProgress.about(ready))." }

    // MARK: Time estimates

    func estimate(_ name: String, _ kind: JobKind, sizes: Sizes? = nil) -> Estimate {
        jobs.estimate(name, kind, sizes: sizes, history: history, minis: minis)
    }

    func estimate(_ s: JobStatus) -> Estimate { estimate(s.name, s.kind) }

    /// A new mini with the model it would be made with.
    /// `pictures`: the front and any of the back and sides, each made in step 1.
    func estimateNew(drawn: Bool, sizes: Sizes, cartoon: Bool = false, pictures: Int = 1) -> Estimate {
        Estimator.estimate(JobShape(job: .generate, model: EngineDownload.forMaking(cartoon: cartoon, chosen: setup.engineModel).id, drawn: drawn,
                                    service: ImageService.load(.standard), nozzle: sizes.nozzle ?? "0.4",
                                    height: sizes.height.flatMap(Double.init), pictures: pictures), history: history)
    }

    /// Seconds until the running job is done, here or elsewhere.
    func runningLeft(now: Date = Date()) -> TimeInterval {
        guard let s = current else { return 0 }
        return estimate(s).left(s, now: now)
    }

    /// Each waiting job with its estimate and when it should be ready.
    func queueTimes(now: Date = Date()) -> [(entry: QueueEntry, estimate: Estimate, ready: TimeInterval)] {
        jobs.queueTimes(queue, running: current, history: history, now: now, minis: minis)
    }

    /// When `name`, waiting in the queue, should be ready; nil when it isn't waiting.
    func readyIn(_ name: String) -> TimeInterval? {
        jobs.readyIn(name, queue: queue, running: current, history: history, minis: minis)
    }

    /// Minutes a mini takes with `m` on this Mac, when it has made enough to know (Settings).
    func learnedMinutes(_ m: EngineModel) -> Int? {
        let e = Estimator.estimate(JobShape(job: .generate, model: m.id, drawn: true, service: ImageService.load(.standard)), history: history)
        return e.learned ? Int((e.total / 60).rounded()) : nil
    }

    /// How many minis the estimates have learned from: finished makes on this Mac.
    var learnedFrom: Int {
        history.filter { $0.outcome == .finished && $0.jobKind == .generate && $0.machine == Machine.current }.count
    }

    func clearTimings() {
        timings.clear()
        history = []
    }

    // MARK: Jobs

    func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes, kind: MiniKind = .character,
              project: String? = nil, cartoon: Bool = false, shown: String? = nil, model: EngineModel? = nil, shapeSeed: Int? = nil,
              sides: [PictureSide: URL] = [:], fixes: [String] = [], fixUsed: String? = nil, checkPicture: Bool = false) throws {
        let chosen = EngineDownload.forMaking(cartoon: cartoon, chosen: model ?? setup.engineModel)
        try start(name) {
            try $0.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes, kind: kind, model: chosen, project: project,
                        cartoon: cartoon, shown: shown, shapeSeed: shapeSeed, sides: sides, fixes: fixes, fixUsed: fixUsed, checkPicture: checkPicture)
        }
    }

    /// Several pictures dropped on New Mini: a mini each, named after its file, all made the same
    /// way, with one note in the job's popover. A picture that can't be used is skipped and named
    /// there. Returns why, in words, when none could be used.
    /// `fix`: what to change in each, and the AI helper's rewrite of it (#156).
    func make(pictures: [URL], restyle: Bool, seed: Int, sizes: Sizes, kind: MiniKind, project: String?, cartoon: Bool = false,
              fix: String = "", fixUsed: String? = nil) -> String? {
        let done = jobs.makeEach(pictures) { url, name, shown in
            guard Picture(url) != nil else { throw RequestError.noPicture }
            try self.make(name: name, picture: .image(url), restyle: restyle, seed: seed, sizes: sizes, kind: kind, project: project, cartoon: cartoon,
                          shown: shown, fixes: fix.isEmpty ? [] : [fix], fixUsed: fixUsed, checkPicture: !fix.isEmpty)
        }
        guard let last = done.added.last else { return done.failure.map { plainWords($0) } ?? "Mimic can't read these pictures." }
        let ready = readyIn(last) ?? runningLeft()
        present { $0.noteQueued(.init(name: last, text: "\(JobPresentation.QueuedNote.added(done.added.count)) \(whenReady(ready))\(done.skippedNote)")) }
        return nil
    }

    /// A sibling of `mini` in its project, from the same picture or description, with a new
    /// seed; it waits its turn like any other. With a `change`, its picture is redrawn with it
    /// and it stops for you to check it (#156); `changeUsed` is the AI helper's rewrite.
    func makeAnotherVersion(_ mini: Mini, change: String = "", changeUsed: String? = nil) {
        let new = Gallery.nextVersionName(install.runs, mini.name)
        do {
            try start(new) {
                try $0.makeAnotherVersion(of: mini.name, as: new, change: change, changeUsed: changeUsed, checkPicture: !change.isEmpty).ahead
            }
        } catch { problem = Problem("Couldn't make another version", plainWords(error, else: "Try again.")) }
    }

    /// A sibling of `mini` from the picture it already has, with only a new 3D shape; with a
    /// `change`, that picture redrawn with it first, as Make Another Version's is.
    func makeNewShape(_ mini: Mini, change: String = "", changeUsed: String? = nil) {
        let new = Gallery.nextVersionName(install.runs, mini.name)
        do {
            try start(new) {
                try $0.makeNewShape(of: mini.name, as: new, change: change, changeUsed: changeUsed, checkPicture: !change.isEmpty).ahead
            }
        } catch { problem = Problem("Couldn't make a new 3D shape", plainWords(error, else: "Try again.")) }
    }

    /// Import Model: a new mini from a 3D model file, print prep only.
    func importModel(_ file: URL, name: String, shown: String?, sizes: Sizes, kind: MiniKind, project: String?) throws {
        try start(name) { try $0.importModel(file, name: name, shown: shown, sizes: sizes, kind: kind, project: project) }
        reload()
        selection = [name]
    }

    /// "Making", "Resizing" or "Importing": what the job `s` is doing, in the progress window,
    /// the toolbar and the list. From the list, so a redraw reads no file.
    func doing(_ s: JobStatus) -> String { JobRunner.doing(s.kind, importing: s.importing || importing(s.name)) }

    /// An imported mini whose print file isn't made yet: its print prep is its import.
    func importing(_ name: String) -> Bool { minis.first { $0.name == name }.map { $0.settings.isImported && !$0.finished } ?? false }

    /// A mini imported from a 3D model file, which has nothing of its own to make again.
    func isImported(_ name: String) -> Bool { minis.first { $0.name == name }?.settings.isImported == true }

    func resize(_ mini: Mini, sizes: Sizes) throws {
        try start(mini.name) { try $0.resize(name: mini.name, sizes: sizes) }
    }

    /// Resize All on a project.
    func resizeAll(_ project: String, sizes: Sizes) -> String? { resizeAll(minis.filter { $0.project == project }, sizes: sizes) }

    /// Resize All, or Resize on several selected: each mini waits its turn to be resized to
    /// `sizes` (at a `scale`, each character from its own real height), with one note in the
    /// job's popover like several dropped pictures. Returns why, in words, when none could be added.
    func resizeAll(_ group: [Mini], sizes: Sizes, scale: Int? = nil) -> String? {
        let done = jobs.resizeAll(group, to: sizes, scale: scale) { try self.resize($0, sizes: $1) }
        guard let last = done.added.last else { return done.nothingAdded(done.failure.map { plainWords($0) }) }
        let ready = readyIn(last) ?? runningLeft()
        present { $0.noteQueued(.init(name: last, text: "\(JobPresentation.QueuedNote.added(done.added.count)) \(whenReady(ready))\(done.sameNote)\(done.skippedNote)")) }
        return nil
    }

    /// Runs a failed mini again with the inputs it saved.
    func retry(_ name: String) throws {
        try start(name) { try $0.retry(name: name) }
        present { $0.retried(name) }
    }

    /// A mini waiting for its picture to be checked (#156): not waiting in the queue or being made.
    func pictureToCheck(_ mini: Mini) -> Bool { miniMenu.pictureToCheck(mini) }

    /// Build Shape, for a mini whose picture is ready to check (#156): carries on from it, as a
    /// retry does.
    func buildShape(_ name: String) throws { try retry(name) }

    /// Build Shape from a menu; a refusal is said as an alert.
    func buildShape(_ mini: Mini) {
        do { try buildShape(mini.name) } catch { problem = Problem("Couldn't build the shape", plainWords(error, else: "Check that Mimic's folder is still there, then try again.")) }
    }

    /// Try Again on a picture ready to check (#156): draws it again with a new variation number.
    func redrawPicture(_ name: String) throws {
        try start(name) { try $0.redrawPicture(name: name) }
        present { $0.retried(name) }
    }

    /// A mini that didn't finish and can be tried again: no print file, not waiting or being
    /// made, and it kept what it was asked for.
    /// One whose picture is ready to check has Build Shape and its own Try Again instead (#156).
    func canRetry(_ mini: Mini) -> Bool { miniMenu.canRetry(mini) }

    /// Try Again from a failed mini's page or menus; a refusal is said as an alert.
    func tryAgain(_ mini: Mini) {
        do { try retry(mini.name) } catch { problem = Problem("Couldn't try again", plainWords(error, else: "Check that Mimic's folder is still there, then try again.")) }
    }

    func stop() { jobs.cancel() }

    /// An error in words for people. Mimic's own refusals already are; anything else (a Cocoa
    /// error, a failed launch) gets `fallback`, and its raw text goes only in the tooltip.
    func plainWords(_ error: Error, else fallback: String = "Couldn't start. Check that Mimic's folder is still there, then try again.") -> String {
        MimicCore.plainWords(error, making: current, else: fallback)
    }

    /// The job's popover is showing: note whether it's showing how the job ended, with Mimic in front.
    func popoverShowing() {
        present { $0.popoverShowing(active: active, open: jobPopover, idle: !running && elsewhere == nil) }
    }

    /// Seconds for New Mini or Resize to close before the job's popover opens: both in one update
    /// could drop the popover. Not the sheet's `onDismiss`: Try Again and Redraw start a job with
    /// no sheet up, so it would never come.
    static let showJobDelay = 0.4

    /// Opens the job's popover a moment after New Mini or Resize has gone (`showJobDelay`).
    /// VoiceOver is told, as it doesn't notice a popover opening by itself.
    func showJob() {
        Task {
            try? await Task.sleep(for: .seconds(Self.showJobDelay))
            // Not with another app in front: it would close unseen. The toolbar item stays.
            guard sheet == nil, !jobPopover, active, NSApp.isActive else { return }
            jobPopover = true
            if let words = queuedNote?.text ?? current.map({ "\(doing($0)) \(displayName($0))" }) {
                AccessibilityNotification.Announcement(words).post()
            }
        }
    }

    /// Starts the job, or adds it to the queue, and shows its popover either way; the window
    /// stays free to use.
    private func start(_ name: String, _ begin: (JobRunner) throws -> Int?) throws {
        if let requiredProblem { throw Refusal(requiredProblem) }
        let ahead = try begin(jobs)
        Notifier.ask()
        refreshQueue()
        var note: JobPresentation.QueuedNote?
        if let ahead, let ready = readyIn(name) {
            let before = ahead == 0 ? "" : " \(ahead) ahead of it."
            note = .init(name: name, text: "Added to the queue.\(before) \(whenReady(ready))")
        } else {
            job = jobs.status  // at once, so the popover never opens on the previous job
            DockProgress.follow(self)
        }
        present { $0.jobAdded(note: note) }
        sheet = nil
        showJob()
    }

    private func jobChanged(_ s: JobStatus) {
        let change = present { $0.jobChanged(from: job, to: s) }
        job = s
        if change.started { DockProgress.follow(self) }
        refreshQueue()
        guard !s.running else { return }
        confirmingStop = false
        reload()
        // Not selected: that would pull you away from what you're looking at. The notification
        // and the job's popover go to it. It counts as ready and unseen unless it's on screen.
        if change.finished {
            present { $0.jobFinished(s, onScreen: NSApp.isActive && selection == [s.name]) }
            updateBadge()
            history = timings.load()
            jobEnded(s)
        }
    }

    // MARK: Telling you it's done

    /// A job finished: the app's delegate hands it to `Notifier`, which posts the notification.
    @ObservationIgnored var jobEnded: @MainActor (JobStatus) -> Void = { _ in }

    /// Mimic in front with `name` selected, the window opened again if it was closed.
    func go(to name: String) {
        showWindow()
        reload()
        if minis.contains(where: { $0.name == name }) { selection = [name] }
    }

    /// Minis being put in one print file for Open Together or Copies (`PrintFiles.swift`); their
    /// menu items wait meanwhile.
    var packing = false
}
