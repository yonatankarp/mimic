import AppKit
import MimicCore
import Observation
import UserNotifications

/// The sheet over the main window. One at a time, so swapping Make for its progress is a single
/// change rather than a dismiss and a present racing each other.
enum AppSheet: Identifiable, Equatable {
    case make, resize(Mini), rename(Mini), progress
    /// Resize All on a project.
    case resizeAll(String)
    /// A new project, and the mini to move into it when asked from Move to Project.
    case newProject(moving: Mini?)
    case renameProject(String)
    var id: String {
        switch self {
        case .make: "make"
        case .resize(let m): "resize-\(m.name)"
        case .resizeAll(let p): "resize-all-\(p)"
        case .rename(let m): "rename-\(m.name)"
        case .progress: "progress"
        case .newProject(let m): "new-project-\(m?.name ?? "")"
        case .renameProject(let p): "rename-project-\(p)"
        }
    }
}

/// The state every window shares: the Mimic folder, the gallery, the selection and the one job.
/// Views read it from the environment (`@Environment(AppModel.self)`).
@MainActor @Observable
final class AppModel {
    let install: Install
    let jobs: JobRunner
    /// First-launch setup, and Repair from Settings. Here rather than in a view, so a download
    /// carries on when the window closes.
    let setup: SetupModel
    /// Checking for a newer Mimic, and installing it.
    let updates = Updater()
    var minis: [Mini] = []
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
    var selection: Mini.ID?
    /// The job's latest status, updated on the main thread; nil before the first job.
    var job: JobStatus?
    /// Why a job can't start (a required check failed), or nil: the latest health checks.
    var requiredProblem: String? { Health.shared.blocking }
    var sheet: AppSheet?
    /// The job has a place on screen: its sheet, or the toolbar item it went to. Close clears it.
    var jobShown = false
    /// The mini waiting on "Move to Trash?", asked from the sidebar or the Mini menu.
    var trashing: Mini?
    /// A rename or trash that was refused, shown as an alert.
    var problem: String?

    /// Every job this Mac has finished, which the time estimates come from. On this Mac only.
    let timings: Timings
    private(set) var history: [TimingRecord] = []
    /// The jobs waiting their turn, shared with every other Mimic on this Mac; read again
    /// every few seconds, since another Mimic may add or start one.
    private(set) var queue: [QueueEntry] = []
    /// The job another Mimic is running (the dev app, `mimic` in Terminal), when this one isn't.
    private(set) var elsewhere: JobStatus?
    /// Jobs that ended since the progress sheet was last closed, the latest last: the queue can
    /// start the next straight away, so the sheet lists these under the one it shows.
    var ended: [JobStatus] = []
    /// "Added to the queue — …", at the top of the progress sheet until that mini starts.
    var queuedNote: (name: String, text: String)?

    init() {
        let install = Install.locate()
        self.install = install
        timings = Timings.standard()
        jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
        setup = SetupModel(install: install)
        updates.model = self
        jobs.onChange = { [weak self] s in Task { @MainActor in self?.jobChanged(s) } }
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
        Task { [weak self] in
            while let self {
                self.watchQueue()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        #if DEBUG
        if let spec = ProcessInfo.processInfo.environment["MIMIC_DEMO_PROGRESS"] { demoProgress(spec) }
        #endif
    }

    var selected: Mini? { minis.first { $0.id == selection } }
    var running: Bool { job?.running == true }

    func reload() {
        minis = Gallery.list(install.runs)
        projects = Gallery.projects(install.runs)
        if selection == nil || selected == nil { selection = minis.first?.id }
    }

    // MARK: The queue

    private func watchQueue() {
        // A crashed Mimic's job may still be running with nothing watching it: stopped as soon
        // as no live Mimic holds the job lock, queue or no queue.
        if !running && Leftover.recorded(install.runs) { jobs.cleanUpLeftovers() }
        // Not while a required part is broken (the engine needs Repair): each job would fail in
        // turn, so the queue waits until it's fixed.
        if !running && requiredProblem == nil && setup.installed && !JobQueue(runs: install.runs).entries().isEmpty { jobs.pump() }
        refreshQueue()
        updates.tick()
    }

    func refreshQueue() {
        let q = jobs.queue.entries()
        if q != queue { queue = q; reload() }
        let other = running ? nil : SharedJob.read(install.runs)?.status
        if other?.name != elsewhere?.name { reload() }  // another Mimic started, or finished, a mini
        if other != elsewhere { elsewhere = other }
        updateBadge()
    }

    /// The number waiting, on the Dock icon; a finished job's ✓ or ! when nothing is.
    func updateBadge() {
        let tile = NSApp.dockTile
        if !queue.isEmpty { tile.badgeLabel = "\(queue.count)" }
        else if let label = tile.badgeLabel, Int(label) != nil { tile.badgeLabel = nil }
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
        refreshQueue()
        reload()
    }

    func moveInQueue(_ name: String, by offset: Int) {
        try? jobs.move(name, by: offset)
        refreshQueue()
    }

    // MARK: Time estimates

    func estimate(_ name: String, _ kind: JobKind, sizes: Sizes? = nil) -> Estimate {
        jobs.estimate(name, kind, sizes: sizes, history: history)
    }

    func estimate(_ s: JobStatus) -> Estimate { estimate(s.name, s.kind) }

    /// A new mini with the model in use.
    func estimateNew(drawn: Bool, sizes: Sizes) -> Estimate {
        Estimator.estimate(JobShape(job: .generate, model: setup.chosen.id, drawn: drawn, nozzle: sizes.nozzle ?? "0.4",
                                    height: sizes.height.flatMap(Double.init)), history: history)
    }

    /// Seconds until the running job is done, here or elsewhere.
    func runningLeft(now: Date = Date()) -> TimeInterval {
        guard let s = current else { return 0 }
        return estimate(s).left(s, now: now)
    }

    /// Each waiting job with its estimate and when it should be ready.
    func queueTimes(now: Date = Date()) -> [(entry: QueueEntry, estimate: Estimate, ready: TimeInterval)] {
        jobs.queueTimes(queue, running: current, history: history, now: now)
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

    func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes, kind: MiniKind = .character, project: String? = nil) throws {
        let chosen = setup.chosen
        try start(name) { try $0.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes, kind: kind, model: chosen, project: project) }
    }

    /// Several pictures dropped on New Mini: a mini each, named after its file, all made the same
    /// way, with one note on the progress sheet. A picture that can't be used is skipped and named
    /// there. Returns why, in words, when none could be used.
    func make(pictures: [URL], restyle: Bool, seed: Int, sizes: Sizes, kind: MiniKind, project: String?) -> String? {
        var added: [String] = [], skipped: [String] = [], why = "Mimic can't read these pictures."
        for url in pictures {
            let name = Gallery.name(forPicture: url, in: install.runs)
            do {
                guard Picture(url) != nil else { throw RequestError.noPicture }
                try make(name: name, picture: .image(url), restyle: restyle, seed: seed, sizes: sizes, kind: kind, project: project)
                added.append(name)
            } catch {
                skipped.append(url.lastPathComponent)
                if case RequestError.noPicture = error {} else { why = plainWords(error) }
            }
        }
        guard let last = added.last else { return why }
        let ready = queueTimes().first(where: { $0.entry.name == last })?.ready ?? runningLeft()
        var text = "\(added.count) \(added.count == 1 ? "mini" : "minis") added to the queue — ready in \(JobProgress.about(ready))."
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

    /// Moves minis (one, or several dragged together) into `project`, nil being Unsorted.
    func move(_ names: [String], to project: String?) {
        for name in names where minis.first(where: { $0.name == name })?.project != project {
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



    func resize(_ mini: Mini, sizes: Sizes) throws {
        try start(mini.name) { try $0.resize(name: mini.name, sizes: sizes) }
    }

    /// Resize All: every mini in `project` waits its turn to be resized to `sizes`, with one
    /// note on the progress sheet like several dropped pictures. Returns why, in words, when
    /// none could be added.
    func resizeAll(_ project: String, sizes: Sizes) -> String? {
        let busy = Set(queue.map(\.name) + [current?.name].compactMap { $0 })
        let picked = Gallery.toResize(minis.filter { $0.project == project }, to: sizes, busy: busy)
        var added: [String] = [], skipped = picked.skipped, why = "None of these minis can be resized right now."
        for (mini, sizes) in picked.resize {
            do { try resize(mini, sizes: sizes); added.append(mini.name) }
            catch { skipped += 1; why = plainWords(error) }
        }
        let same = picked.same == 0 ? "" : " \(picked.same) \(picked.same == 1 ? "was" : "were") already that size."
        let left = skipped == 0 ? "" : " Skipped \(skipped): not made yet, or already waiting or being made."
        guard let last = added.last else { return picked.same > 0 && skipped == 0 ? "They're all already that size." : why + same + left }
        let ready = queueTimes().first(where: { $0.entry.name == last })?.ready ?? runningLeft()
        queuedNote = (last, "\(added.count) \(added.count == 1 ? "mini" : "minis") added to the queue — ready in \(JobProgress.about(ready)).\(same)\(left)")
        return nil
    }

    /// Runs a failed mini again with the inputs it saved.
    func retry(_ name: String) throws {
        try start(name) { try $0.retry(name: name) }
        ended.removeAll { $0.name == name }
    }

    func stop() { jobs.cancel() }

    /// A mini that can't be renamed or trashed right now: being made here or in another Mimic.
    var busyWith: String? { current?.name }

    func trash(_ mini: Mini) {
        do {
            // Waiting to be made: out of the queue first (a new mini's folder goes to the Trash then).
            if let entry = queue.first(where: { $0.name == mini.name }) {
                try jobs.remove(mini.name)
                refreshQueue()
                if entry.job == .generate { return reload() }
            }
            try Gallery.moveToTrash(install.runs, name: mini.name, busyWith: busyWith)
        } catch {
            problem = plainWords(error, else: "Couldn't move it to the Trash. Try Show in Finder and delete it there.")
        }
        reload()  // picks the newest mini if this one was selected
    }

    /// Keep This One: moves `mini`'s other versions to the Trash (waiting ones leave the queue).
    /// One being made stays, and says so. Returns whether they all went.
    @discardableResult
    func keep(_ mini: Mini) -> Bool {
        let others = Gallery.versions(of: mini, in: minis).filter { $0.name != mini.name }
        for v in others where v.name != busyWith { trash(v) }
        if let v = others.first(where: { $0.name == busyWith }) {
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

    /// Hides the progress sheet; the job carries on and shows in the toolbar and the Dock.
    func runInBackground() { if sheet == .progress { sheet = nil } }

    func showProgress() { sheet = .progress }

    /// Closes the sheet; a finished job (with nothing running or waiting) leaves the toolbar too.
    func closeJob() {
        if sheet == .progress { sheet = nil }
        queuedNote = nil
        guard !running && queue.isEmpty && elsewhere == nil else { return }
        ended = []
        jobShown = false
    }

    /// Starts the job, or adds it to the queue, and shows the progress sheet either way.
    private func start(_ name: String, _ begin: (JobRunner) throws -> Int?) throws {
        if let requiredProblem { throw Refusal(description: requiredProblem) }
        let ahead = try begin(jobs)
        askForNotifications()
        refreshQueue()
        if let ahead, let ready = queueTimes().first(where: { $0.entry.name == name })?.ready {
            queuedNote = (name, "Added to the queue — \(ahead) ahead of it, ready in \(JobProgress.about(ready)).")
        } else {
            queuedNote = nil
            job = jobs.status  // at once, so the sheet never opens on the previous job
            DockProgress.follow(self)
        }
        jobShown = true
        sheet = .progress
    }

    private func jobChanged(_ s: JobStatus) {
        let previous = job
        let started = s.running && (previous?.running != true || previous?.name != s.name)
        let finished = !s.running && (previous?.running == true || previous?.name != s.name || previous?.started != s.started)
        // The job the sheet showed has ended and another came after it: listed under the new one.
        if let previous, !previous.running, previous.name != s.name || previous.started != s.started { ended.append(previous) }
        job = s
        if started {
            jobShown = true
            if queuedNote?.name == s.name { queuedNote = nil }
            DockProgress.follow(self)
        }
        refreshQueue()
        guard !s.running else { return }
        reload()
        if s.succeeded { selection = s.name }
        if finished {
            history = timings.load()
            announce(s)
        }
    }

    #if DEBUG
    /// Development only: `MIMIC_DEMO_PROGRESS=<mini>[:<speed>][:fail|:hold][:resize]` plays a
    /// pretend job through the progress sheet, so its animations can be looked at without a
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
            job = s; jobShown = true; sheet = .progress
            DockProgress.follow(self)
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
            if s.succeeded { selection = s.name }
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

    private func announce(_ s: JobStatus) {
        guard !s.canceled, !NSApp.isActive else { return }
        if queue.isEmpty { NSApp.dockTile.badgeLabel = s.succeeded ? "✓" : "!" }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let who = Mini.displayName(s.name)
        let content = UNMutableNotificationContent()
        content.title = s.succeeded ? "\(who) is ready" : "\(who) didn't finish"
        content.body = s.succeeded ? "Your mini is ready to print." : "Open Mimic to try again."
        content.sound = .default
        // One identifier per mini: a shared one made each notification replace the last, so of
        // three minis finishing from the queue only the last "ready" was left.
        let id = "job-\(s.name)-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
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

    /// The print file selected in Finder, or the folder when there's no print file yet.
    func showInFinder(_ mini: Mini) { NSWorkspace.shared.activateFileViewerSelecting([mini.stl ?? mini.folder]) }
}

/// A job refused before it started, in words for people.
struct Refusal: Error, CustomStringConvertible { let description: String }
