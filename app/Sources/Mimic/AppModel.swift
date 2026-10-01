import AppKit
import MimicCore
import Observation
import OSLog
import SwiftUI
import UserNotifications

/// The sheet over the main window, one at a time.
enum AppSheet: Identifiable, Equatable {
    case make, resize(Mini), rename(Mini)
    /// New Mini filled in from a mini: Edit & Make Again.
    case makeAgain(Mini)
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
    var id: String {
        switch self {
        case .make: "make"
        case .makeAgain(let m): "make-again-\(m.name)"
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
        }
    }
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
        didSet { if NSApp.isActive, !unseen.isDisjoint(with: selection) { unseen.subtract(selection); updateBadge() } }
    }
    /// Minis that finished while nobody was looking, counted on the Dock icon until seen: picked
    /// in the list with Mimic in front, or the job's popover seen after they ended.
    private var unseen: Set<String> = []
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
    /// Why a job can't start (a required check failed), or nil: the latest health checks.
    var requiredProblem: String? { Health.shared.blocking }
    var sheet: AppSheet?
    /// The job stays in the toolbar once it ends, until its popover has been seen.
    var jobShown = false
    /// The job's popover under its toolbar item: opened by clicking it, and by itself when a job
    /// starts with Mimic in front. Closing it (a click outside, Esc, the item) may count a
    /// finished job as seen; see `jobSeen`.
    var jobPopover = false {
        didSet {
            guard oldValue && !jobPopover else { return }
            // Seen once is enough: its "ready in" time doesn't change, while the queue's below it
            // do (#141). Not when switching away closed it, though, as then it wasn't read.
            if active { queuedNote = nil }
            jobSeen()
        }
    }
    /// The popover has shown how the job ended, with Mimic in front. Only then can closing it
    /// clear the toolbar item.
    private var shownEnd = false
    /// Mimic is the app in front. Set before the popover closes on switching away (it closes
    /// when the app resigns), which NSApp.isActive may not yet say.
    private var active = true
    /// "Stop making …?", asked from the job's popover, the Mini menu or the Dock menu.
    var confirmingStop = false
    /// The job in the toolbar, which the job's popover hangs from; nil hides both.
    var toolbarJob: JobStatus? { JobProgress.inToolbar(job, keptShown: jobShown, elsewhere: elsewhere) }
    /// This Mimic's job can be stopped: "Stop Making…" or "Stop Resizing…" in the menus, else nil.
    var stopCommand: String? {
        guard let job, job.running else { return nil }
        return job.kind == .prep ? "Stop Resizing…" : "Stop Making…"
    }
    /// View → Face Front: bumped for the mini's 3D view to turn back to face you.
    var faceFrontRequests = 0
    /// Edit → Find: bumped for the sidebar to put the cursor in its search field.
    var findRequests = 0
    /// Keep This One from Compare Side by Side: the version to ask about once the sheet has
    /// gone (`keepWhenClosed`), then on its page (`askToKeep`), whose dialog does the keeping.
    var keepWhenClosed: String?
    var askToKeep: String?
    /// The waiting job on "Take it out of the queue?", asked from the job's popover.
    var unqueueing: QueueEntry?
    /// Minis on "Move to Trash?", when one of them waits in the queue: Undo can't put it back
    /// in the queue, so it's asked first (see `askToTrash`).
    var trashing: [Mini] = []
    /// The main window's, for Undo Move to Trash; set by the window.
    @ObservationIgnored weak var undo: UndoManager?
    /// A rename or trash that was refused, shown as an alert.
    var problem: String? {
        didSet { if let problem, problem != oldValue { Log.shown.error("\(problem, privacy: .public)") } }
    }

    /// Every job this Mac has finished, which the time estimates come from. On this Mac only.
    let timings: Timings
    private(set) var history: [TimingRecord] = []
    /// The jobs waiting their turn, shared with every other Mimic on this Mac; read again
    /// every few seconds, since another Mimic may add or start one.
    private(set) var queue: [QueueEntry] = []
    /// The job another Mimic is running (the dev app, `mimic` in Terminal), when this one isn't.
    private(set) var elsewhere: JobStatus?
    /// Why the queue's next job waits (paused, or on battery), read with the queue.
    private(set) var hold: QueueHold?
    /// Paused, here or in another Mimic (#89). Read with the queue.
    private(set) var paused = false
    /// Jobs that ended since the job's popover was last seen, the latest last: the queue can
    /// start the next straight away, so the popover lists these under the one it shows.
    var ended: [JobStatus] = []
    /// "Added to the queue — …", at the top of the job's popover until that mini starts or the
    /// popover is closed.
    var queuedNote: (name: String, text: String)?

    init() {
        let install = Install.locate()
        self.install = install
        // The queue's files from before they moved out of the minis folder (#102), once.
        try? JobQueue(folder: install.queue).moveOldFiles(from: install.runs)
        timings = Timings.standard()
        jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
        setup = SetupModel(install: install)
        updates.model = self
        wire(jobs)
        reload()
        // Run the checks at launch, so Make is blocked (and Settings flagged) before anyone opens Settings.
        Health.shared.check(install)
        // An old install's engine is only moved, which needs no asking.
        if setup.hasOldInstall { setup.start() }
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
        try? JobQueue(folder: install.queue).moveOldFiles(from: install.runs)
        self.install = install
        self.jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
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

    // MARK: The queue

    /// Off the main thread: stopping a leftover job waits for it to end (up to 5 s), and the
    /// queue's lock waits while another Mimic holds it, which would freeze the window meanwhile.
    private func watchQueue() async {
        let jobs = self.jobs, queueFolder = install.queue
        let idle = !running, canStart = !running && requiredProblem == nil && setup.installed
        await Task.detached {
            // A crashed Mimic's job may still be running with nothing watching it: stopped as soon
            // as no live Mimic holds the job lock, queue or no queue.
            if idle && Leftover.recorded(queue: queueFolder) { jobs.cleanUpLeftovers() }
            // Not while a required part is broken (the engine needs Repair): each job would fail in
            // turn, so the queue waits until it's fixed.
            if canStart && !jobs.queue.entries().isEmpty { jobs.pump() }
        }.value
        refreshQueue()
        updates.tick()
    }

    /// Returns whether it reloaded the list, so a caller about to reload too can skip its own.
    @discardableResult
    func refreshQueue() -> Bool {
        let q = jobs.queue.entries()
        var changed = false
        if q != queue { queue = q; changed = true }
        let other = running ? nil : SharedJob.read(queue: install.queue)?.status
        if other?.name != elsewhere?.name { changed = true }  // another Mimic started, or finished, a mini
        if other != elsewhere { elsewhere = other }
        let h = jobs.hold(), p = jobs.queue.paused
        if h != hold { hold = h }
        if p != paused { paused = p }
        if changed { reload() }
        updateBadge()
        return changed
    }

    /// How many minis are ready and not yet seen, on the Dock icon; nothing when none are. The
    /// only place the badge is set.
    func updateBadge() {
        let label = JobProgress.badge(unseen: unseen, minis: minis.map(\.name))
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Mimic came to the front: the mini on screen has been seen.
    func becameActive() {
        reload()  // whatever changed in Finder meanwhile
        if !unseen.isDisjoint(with: selection) { unseen.subtract(selection); updateBadge() }
    }

    /// Brings Mimic and its window to the front, opening the window again if it was closed.
    func showWindow() {
        NSApp.activate()
        openMainWindow()
    }

    /// The running job, here or in another Mimic.
    var current: JobStatus? { running ? job : elsewhere }

    /// A mini's place in the queue, from 1, or nil when it isn't waiting.
    func waiting(_ name: String) -> Int? { queue.firstIndex { $0.name == name }.map { $0 + 1 } }

    /// "1st", "2nd"…
    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }

    func removeFromQueue(_ name: String) {
        do { try jobs.remove(name) } catch { problem = plainWords(error, else: "Couldn't take it out of the queue. Try again.") }
        if !refreshQueue() { reload() }
    }

    /// Pause After This One, Pause Queue or Resume Queue, in the job's popover and the Mini menu.
    var pauseCommand: String { paused ? "Resume Queue" : current != nil ? "Pause After This One" : "Pause Queue" }

    /// Pausing lets the mini being made finish; resuming starts the next one if none is.
    func togglePause() {
        do { try jobs.setPaused(!paused) } catch { problem = paused ? "Couldn't resume the queue. Try again." : "Couldn't pause the queue. Try again." }
        refreshQueue()
    }

    /// The queue's next job waits although nothing is running: the toolbar says so.
    var queueHeld: QueueHold? { current == nil && !queue.isEmpty ? hold : nil }

    /// When a mini just added should be ready, or why it waits.
    private func whenReady(_ ready: TimeInterval) -> String { hold.map { $0.sentence } ?? "Ready in \(JobProgress.about(ready))." }

    func moveInQueue(_ name: String, by offset: Int) {
        _ = try? jobs.move(name, by: offset)
        refreshQueue()
    }

    /// Move to Front, Move to End, or a mini dragged onto another's place (#72).
    func moveInQueue(_ name: String, to place: QueuePlace) {
        _ = try? jobs.move(name, to: place)
        refreshQueue()
    }

    // MARK: Time estimates

    func estimate(_ name: String, _ kind: JobKind, sizes: Sizes? = nil) -> Estimate {
        jobs.estimate(name, kind, sizes: sizes, history: history, minis: minis)
    }

    func estimate(_ s: JobStatus) -> Estimate { estimate(s.name, s.kind) }

    /// A new mini with the model it would be made with.
    /// `pictures`: the front and any of the back and sides, each made in step 1.
    func estimateNew(drawn: Bool, sizes: Sizes, cartoon: Bool = false, pictures: Int = 1) -> Estimate {
        Estimator.estimate(JobShape(job: .generate, model: EngineDownload.forMaking(cartoon: cartoon, chosen: setup.chosen).id, drawn: drawn, nozzle: sizes.nozzle ?? "0.4",
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

    /// Minutes a mini takes with `m` on this Mac, when it has made enough to know (Settings).
    func learnedMinutes(_ m: EngineModel) -> Int? {
        let e = Estimator.estimate(JobShape(job: .generate, model: m.id, drawn: true), history: history)
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

    /// Why Make, Resize or Try Again can't start right now, or nil. A job already running is
    /// no reason: the new one waits its turn.
    var cantStart: String? { requiredProblem }

    func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes, kind: MiniKind = .character,
              project: String? = nil, cartoon: Bool = false, shown: String? = nil, model: EngineModel? = nil, shapeSeed: Int? = nil,
              sides: [PictureSide: URL] = [:]) throws {
        let chosen = EngineDownload.forMaking(cartoon: cartoon, chosen: model ?? setup.chosen)
        try start(name) { try $0.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes, kind: kind, model: chosen, project: project, cartoon: cartoon, shown: shown, shapeSeed: shapeSeed, sides: sides) }
    }

    /// Several pictures dropped on New Mini: a mini each, named after its file, all made the same
    /// way, with one note in the job's popover. A picture that can't be used is skipped and named
    /// there. Returns why, in words, when none could be used.
    func make(pictures: [URL], restyle: Bool, seed: Int, sizes: Sizes, kind: MiniKind, project: String?, cartoon: Bool = false) -> String? {
        var added: [String] = [], skipped: [String] = [], why = "Mimic can't read these pictures."
        for url in pictures {
            let name = Gallery.name(forPicture: url, in: install.runs)
            let shown = Rules.shownName(fromFile: url.deletingPathExtension().lastPathComponent).map { Rules.shownName($0, numberedAs: name) }
            do {
                guard Picture(url) != nil else { throw RequestError.noPicture }
                try make(name: name, picture: .image(url), restyle: restyle, seed: seed, sizes: sizes, kind: kind, project: project, cartoon: cartoon, shown: shown)
                added.append(name)
            } catch {
                skipped.append(url.lastPathComponent)
                if ![.noPicture, .unreadablePicture].contains(error as? RequestError) { why = plainWords(error) }
            }
        }
        guard let last = added.last else { return why }
        let ready = queueTimes().first(where: { $0.entry.name == last })?.ready ?? runningLeft()
        var text = "\(added.count) \(added.count == 1 ? "mini" : "minis") added to the queue. \(whenReady(ready))"
        if !skipped.isEmpty { text += " Skipped \(skipped.joined(separator: ", ")): Mimic can't use \(skipped.count == 1 ? "it" : "them")." }
        queuedNote = (last, text)
        return nil
    }

    /// A sibling of `mini` in its project, from the same picture or description, with a new
    /// seed; it waits its turn like any other.
    func makeAnotherVersion(_ mini: Mini) {
        let new = Gallery.nextVersionName(install.runs, mini.name)
        do { try start(new) { try $0.makeAnotherVersion(of: mini.name, as: new).ahead } }
        catch { problem = plainWords(error, else: "Couldn't make another version. Try again.") }
    }

    /// A sibling of `mini` from the picture it already has, with only a new 3D shape.
    func makeNewShape(_ mini: Mini) {
        let new = Gallery.nextVersionName(install.runs, mini.name)
        do { try start(new) { try $0.makeNewShape(of: mini.name, as: new).ahead } }
        catch { problem = plainWords(error, else: "Couldn't make a new 3D shape. Try again.") }
    }

    // MARK: Projects

    /// Why `mini` can't be moved to another project right now, or nil.
    func whyCantMove(_ mini: Mini) -> String? {
        waiting(mini.name) != nil || current?.name == mini.name ? RequestError.cantMove(mini.name).description : nil
    }

    @discardableResult
    func createProject(_ text: String) throws -> String {
        let name = try Gallery.createProject(install.runs, text)
        reload()
        return name
    }

    /// Moves minis (one, or several dragged together) into `project`, nil being Unsorted. One
    /// waiting or being made stays, and says so.
    func move(_ names: [String], to project: String?) {
        for name in Gallery.dropped(names) where minis.first(where: { $0.name == name })?.project != project {
            do { try jobs.move(mini: name, toProject: project) }
            catch { problem = plainWords(error, else: "Couldn't move it. Is its folder open in another app?") }
        }
        reload()
    }

    func renameProject(_ old: String, to text: String) throws {
        let new = try jobs.renameProject(old, to: text)
        // A collapsed project stays collapsed under its new name.
        if collapsed.remove(old) != nil { collapsed.insert(new) }
        reload()
    }

    func deleteProject(_ name: String, keepMinis: Bool) {
        do { try jobs.deleteProject(name, keepMinis: keepMinis) }
        catch { problem = plainWords(error, else: "Couldn't delete the project. Try Show in Finder and move it to the Trash there.") }
        reload()
    }

    func showInFinder(project: String) { NSWorkspace.shared.activateFileViewerSelecting([install.runs.appendingPathComponent(project)]) }



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
    /// `sizes`, with one note in the job's popover like several dropped pictures. Returns why, in
    /// words, when none could be added.
    func resizeAll(_ group: [Mini], sizes: Sizes) -> String? {
        let done = jobs.resizeAll(group, to: sizes) { try self.resize($0, sizes: $1) }
        guard let last = done.added.last else { return done.nothingAdded(done.failure.map { plainWords($0) }) }
        let ready = queueTimes().first(where: { $0.entry.name == last })?.ready ?? runningLeft()
        queuedNote = (last, "\(done.added.count) \(done.added.count == 1 ? "mini" : "minis") added to the queue. \(whenReady(ready))\(done.sameNote)\(done.skippedNote)")
        return nil
    }

    /// Runs a failed mini again with the inputs it saved.
    func retry(_ name: String) throws {
        try start(name) { try $0.retry(name: name) }
        ended.removeAll { $0.name == name }
    }

    /// A mini that didn't finish and can be tried again: no print file, not waiting or being
    /// made, and it kept what it was asked for.
    func canRetry(_ mini: Mini) -> Bool {
        mini.stl == nil && waiting(mini.name) == nil && current?.name != mini.name && mini.settings.requested != nil && !mini.settings.isImported
    }

    /// Try Again from a failed mini's page or menus; a refusal is said as an alert.
    func tryAgain(_ mini: Mini) {
        do { try retry(mini.name) } catch { problem = plainWords(error) }
    }

    func stop() { jobs.cancel() }

    /// A mini that can't be renamed or trashed right now: being made here or in another Mimic.
    var busyWith: String? { current?.name }

    /// Move to Trash from the sidebar or the Mini menu, for one mini or several: at once, as
    /// Edit → Undo puts them back; asked first only when one waits in the queue, which Undo
    /// can't put back in it.
    func askToTrash(_ group: [Mini]) {
        if group.contains(where: { waiting($0.name) != nil }) { trashing = group } else { trash(group) }
    }

    /// Moves minis to the Trash; one Undo puts them all back (grouped by event). The one being
    /// made stays, and says so.
    func trash(_ group: [Mini]) {
        let picked = Gallery.toTrash(group, busyWith: busyWith)
        trashEach(picked.trash)
        if let s = picked.staying { problem = "“\(s.displayName)” is being made, so it stayed. Move it to the Trash once it's done." }
    }

    func trash(_ mini: Mini) { trashEach([mini]) }

    /// Moves each to the Trash, then updates the queue and the list once for all of them.
    private func trashEach(_ group: [Mini]) {
        guard !group.isEmpty else { return }
        for mini in group {
            do {
                // Waiting to be made: out of the queue, and a new mini's folder goes to the Trash with it.
                if let moved = try jobs.moveToTrash(mini), let trashed = moved.trashed { undoable(moved.folder, trashed) }
            } catch {
                problem = plainWords(error, else: "Couldn't move it to the Trash. Try Show in Finder and delete it there.")
            }
        }
        if !refreshQueue() { reload() }  // picks the newest mini if one of these was selected
    }

    /// Undo puts it back from the Trash and shows it; Redo moves it there again. Several moved at
    /// once (Keep This One) come back with one Undo: the undo manager groups them by event.
    private func undoable(_ folder: URL, _ trashed: URL) {
        let name = folder.lastPathComponent
        undo?.registerUndo(withTarget: self) { model in
            do { try Gallery.putBack(model.install.runs, from: trashed, to: folder) }
            catch { model.problem = model.plainWords(error, else: "Couldn't put it back. Is it still in the Trash?"); return }
            model.reload()
            model.selection = [name]
            model.undo?.registerUndo(withTarget: model) { model in
                if let mini = model.minis.first(where: { $0.name == name }) { model.trash(mini) }
            }
            model.undo?.setActionName("Move to Trash")
        }
        undo?.setActionName("Move to Trash")
    }

    /// Keep This One: moves `mini`'s other versions to the Trash (waiting ones leave the queue).
    /// One being made stays, and says so. Returns whether they all went.
    @discardableResult
    func keep(_ mini: Mini) -> Bool {
        let picked = Gallery.toKeep(mini, in: minis, busyWith: busyWith)
        trashEach(picked.trash)
        if let v = picked.staying {
            problem = (problem.map { $0 + " " } ?? "") + "“\(v.displayName)” is being made, so it wasn't moved to the Trash. Move it there once it's done."
            return false
        }
        return problem == nil
    }

    /// An error in words for people. Mimic's own refusals already are; anything else (a Cocoa
    /// error, a failed launch) gets `fallback`, and its raw text goes only in the tooltip.
    func plainWords(_ error: Error, else fallback: String = "Couldn't start. Check that Mimic's folder is still there, then try again.") -> String {
        switch error {
        // Gallery doesn't know what the job is doing; the running job does.
        case RequestError.busy(let n, _) where n == current?.name: RequestError.busy(n, current?.kind ?? .generate).description
        case let e as RequestError: e.description
        case let e as Refusal: e.description
        case let e as DrawThingsError: e.description
        default: fallback
        }
    }

    /// The job's popover is showing: note whether it's showing how the job ended, with Mimic in front.
    func popoverShowing() {
        if active && jobPopover && !running && elsewhere == nil { shownEnd = true }
    }

    /// The job's popover closed. A finished job leaves the toolbar only if it was really seen:
    /// switching to another app also closes the popover, and the "ready" item must still be
    /// there when you come back.
    private func jobSeen() {
        defer { shownEnd = false }
        guard JobProgress.seenEnd(active: active, busy: running || !queue.isEmpty || elsewhere != nil, shownEnd: shownEnd) else { return }
        queuedNote = nil
        ended = []
        jobShown = false
        unseen = []
        updateBadge()
    }

    /// Opens the job's popover a moment after New Mini or Resize has gone: both in one update
    /// could drop the popover. VoiceOver is told, as it doesn't notice a popover opening by itself.
    private func showJob() {
        Task {
            try? await Task.sleep(for: .seconds(0.4))
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
        if let requiredProblem { throw Refusal(description: requiredProblem) }
        let ahead = try begin(jobs)
        askForNotifications()
        refreshQueue()
        if let ahead, let ready = queueTimes().first(where: { $0.entry.name == name })?.ready {
            let before = ahead == 0 ? "" : " \(ahead) ahead of it."
            queuedNote = (name, "Added to the queue.\(before) \(whenReady(ready))")
        } else {
            queuedNote = nil
            job = jobs.status  // at once, so the popover never opens on the previous job
            DockProgress.follow(self)
        }
        jobShown = true
        sheet = nil
        showJob()
    }

    private func jobChanged(_ s: JobStatus) {
        let previous = job
        let started = s.running && (previous?.running != true || previous?.name != s.name)
        let finished = !s.running && (previous?.running == true || previous?.name != s.name || previous?.started != s.started)
        // The job the popover showed has ended and another came after it: listed under the new one.
        if let previous, !previous.running, previous.name != s.name || previous.started != s.started { ended.append(previous) }
        job = s
        if started {
            jobShown = true
            shownEnd = false
            if queuedNote?.name == s.name { queuedNote = nil }
            DockProgress.follow(self)
        }
        refreshQueue()
        guard !s.running else { return }
        confirmingStop = false
        reload()
        // Not selected: that would pull you away from what you're looking at. The notification
        // and the job's popover go to it. It counts as ready and unseen unless it's on screen.
        if finished {
            if s.succeeded, !(NSApp.isActive && selection == [s.name]) { unseen.insert(s.name) }
            updateBadge()
            history = timings.load()
            announce(s)
        }
    }

    #if DEBUG
    /// Development only: `MIMIC_DEMO_PROGRESS=<mini>[:<speed>][:fail|:hold][:resize]` plays a
    /// pretend job through the job's popover, so its animations can be looked at without a
    /// real ten-minute job. Nothing runs and nothing is written; speed 20 (the default) plays
    /// a make in about half a minute, and hold stays in its long step.
    private func demoProgress(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let speed = parts.dropFirst().compactMap(Double.init).first ?? 20
        let resize = parts.contains("resize"), fail = parts.contains("fail"), hold = parts.contains("hold")
        // Pretend seconds at which each step starts, and the end.
        let plan: [(step: Int, at: Double)] = resize ? [(3, 0)] : [(1, 0), (2, 25), (3, 480)]
        let end = resize ? 50.0 : 530
        Task {
            try? await Task.sleep(for: .seconds(1))  // the window first
            var s = JobStatus(name: parts[0], kind: resize ? .prep : .generate, step: plan[0].step, started: Date())
            s.stepStarted = s.started
            job = s; jobShown = true
            DockProgress.follow(self)
            showJob()
            var t = 0.0
            while hold || t < end {
                try? await Task.sleep(for: .seconds(0.25))
                t += 0.25 * speed
                if hold { t = min(t, 300) }
                s.started = Date().addingTimeInterval(-t)
                let at = plan.last { $0.at <= t }!
                s.stepStarted = s.started.addingTimeInterval(at.at)
                s.step = at.step
                if fail && s.step == 3 { break }
                job = s
            }
            s.running = false
            s.exit = fail ? 1 : 0
            if fail { s.step = 2; s.problem = "The 3D engine stopped early (pretend)." }
            job = s
            reload()
        }
    }
    #endif

    // MARK: Telling you it's done

    /// The Mac asks once; after that this is a no-op. Only an app bundle can use notifications:
    /// the bare binary from `swift build` has none and would crash here.
    private func askForNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A notification when a mini ends and Mimic isn't in front (or its window was closed), with
    /// Open in the slicer on a ready one and Try Again on a failed one. Clicking it goes to the mini.
    private func announce(_ s: JobStatus) {
        guard !s.canceled, !(NSApp.isActive && NSApp.mainWindow != nil), Bundle.main.bundleIdentifier != nil else { return }
        let who = displayName(s)
        let content = UNMutableNotificationContent()
        content.title = s.succeeded ? "\(who) is ready" : "\(who) didn't finish"
        content.body = s.succeeded ? "Ready to print." : "Something went wrong while \(JobRunner.label(s.step).lowercased())."
        content.categoryIdentifier = s.succeeded ? MiniNotification.ready : MiniNotification.failed
        content.userInfo = [MiniNotification.mini: s.name]
        // Again each time: the ready one names the slicer, which can change in Settings.
        MiniNotification.register(slicer: slicerName)
        content.sound = .default
        // One identifier per mini: a shared one made each notification replace the last, so of
        // three minis finishing from the queue only the last "ready" was left.
        let id = "job-\(s.name)-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A notification about `name` was clicked (`action` is the default action) or one of its
    /// buttons pressed.
    func notificationAnswered(_ action: String, mini name: String) {
        switch action {
        case MiniNotification.retry:
            // In the background, as the job's popover's Try Again; only a refusal brings Mimic forward.
            do { try retry(name) } catch {
                problem = plainWords(error, else: "Couldn't try again. Open the mini and try again from there.")
                go(to: name)
            }
        case MiniNotification.open:
            reload()
            if let stl = minis.first(where: { $0.name == name })?.stl { openInSlicer(stl) } else { go(to: name) }
        default:
            go(to: name)
        }
    }

    /// Mimic in front with `name` selected, the window opened again if it was closed.
    func go(to name: String) {
        showWindow()
        reload()
        if minis.contains(where: { $0.name == name }) { selection = [name] }
    }

    // MARK: Slicer

    /// Opens a print file in the picked slicer, or the Mac's default app for STL files.
    func openInSlicer(_ stl: URL) { Slicer.open(stl, in: Slicer.preferred()) }

    var slicerName: String { Slicer.preferred()?.name ?? "your slicer" }

    /// Minis being put in one print file for Open Together or Copies; their menu items wait meanwhile.
    var packing = false

    /// Open Together: one 3MF with every made mini of `group` laid out on the bed, each its own
    /// object named after it, opened in the slicer; with `copies`, that many of each. Named after
    /// the mini, or their project when they share one. Written off the main thread (a party's file
    /// is tens of MB), kept in the temporary folder: the slicer's own project is where it's saved.
    func openTogether(_ group: [Mini], copies: Int = 1) {
        let made = group.filter { $0.stl != nil }
        guard !made.isEmpty, !packing else { return }
        // One of one mini is its own print file.
        if made.count == 1 && copies == 1 { openInSlicer(made[0].stl!); return }
        let projects = Set(made.map(\.project))
        var name = made.count == 1 ? made[0].displayName
            : projects.count == 1 ? (projects.first! ?? "Unsorted") : "\(made.count) Minis"
        if copies > 1 { name += " ×\(copies)" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Open Together")
        let url = dir.appendingPathComponent(Rules.printFileName(name))
        let parts = made.map { ($0.displayName, $0.stl!) }
        packing = true
        Task {
            let failed: Error? = await Task.detached {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try ThreeMF.write(try parts.map { ($0.0, try STL.read($0.1)) }, copies: copies, to: url)
                    return nil
                } catch { return error }
            }.value
            packing = false
            if let failed { problem = plainWords(failed, else: "Couldn't put them in one print file. Open them one at a time instead.") }
            else { openInSlicer(url) }
        }
    }

    /// The print file selected in Finder, or the folder when there's no print file yet.
    func showInFinder(_ minis: [Mini]) { NSWorkspace.shared.activateFileViewerSelecting(minis.map { $0.stl ?? $0.folder }) }

    /// Help → Report a Problem…, or a failed mini's (#100): asks about the picture, makes the
    /// report, shows it in Finder and opens GitHub's bug form to drag it into. Reports are kept
    /// in the minis folder's `_reports`, which Mimic can already write to (Downloads or the
    /// Desktop would ask for permission first) and the gallery never lists.
    func reportProblem(_ mini: Mini? = nil) {
        let alert = NSAlert()
        alert.messageText = mini.map { "Report a problem with “\($0.displayName)”?" } ?? "Report a problem?"
        let what = mini == nil ? "its notes on what happened" : "its notes on making this mini, the mini's settings"
        alert.informativeText = "Mimic puts \(what), and which Mac and version this is, into one file, "
            + "with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to."
        alert.addButton(withTitle: "Make Report")
        alert.addButton(withTitle: "Cancel")
        let hasPicture = mini.flatMap { $0.source ?? $0.upload } != nil
        // Its own checkbox: the alert's suppression checkbox means "Don't ask again".
        let include = NSButton(checkboxWithTitle: "Include the picture (the issue is public)", target: nil, action: nil)
        include.state = .off
        include.sizeToFit()
        if hasPicture { alert.accessoryView = include }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let picture = hasPicture && include.state == .on
        let folder = install.runs.appendingPathComponent("_reports"), build = BuildInfo.line, mac = Report.mac
        let failure = mini.map { $0.settings.failed ?? "It stopped before it was done." }
        Task {
            let made: URL? = await Task.detached {
                let log = Log.recent(since: Date().addingTimeInterval(-3600))
                return try? Report.write(to: folder, mini: mini, picture: picture, build: build, mac: mac, appLog: log)
            }.value
            guard let made else { problem = "Couldn't make the report. Check that Mimic's folder is still there, then try again."; return }
            NSWorkspace.shared.activateFileViewerSelecting([made])
            NSWorkspace.shared.open(Report.issueURL(build: build, mac: mac, failure: failure))
        }
    }
}

/// A job refused before it started, in words for people.
struct Refusal: Error, CustomStringConvertible { let description: String }

/// What a finished mini's notification carries, and its buttons.
enum MiniNotification {
    static let ready = "mini-ready", failed = "mini-failed"
    static let retry = "try-again", open = "open-in-slicer"
    /// The userInfo key holding the mini's name.
    static let mini = "mini"

    static func register(slicer: String) {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: ready, actions: [UNNotificationAction(identifier: open, title: "Open in \(slicer)")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: failed, actions: [UNNotificationAction(identifier: retry, title: "Try Again")],
                                   intentIdentifiers: []),
        ])
    }
}

