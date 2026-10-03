import Foundation
import MimicCore
import Observation

/// The jobs waiting their turn, shared with every other Mimic on this Mac, as last read: every
/// few seconds (`AppModel.watchQueue`), since another Mimic may add or start one, and after each
/// change here (`AppModel.refreshQueue`). Views read it through `AppModel`'s `queue`,
/// `elsewhere`, `hold` and `paused`.
@MainActor @Observable
final class QueueWatch {
    private(set) var entries: [QueueEntry] = []
    /// The job another Mimic is running (the dev app, `mimic` in Terminal), when this one isn't.
    private(set) var elsewhere: JobStatus?
    /// Why the queue's next job waits (paused, or on battery).
    private(set) var hold: QueueHold?
    /// Paused, here or in another Mimic (#89).
    private(set) var paused = false
    /// How many queue files that wouldn't read are put aside, as last seen: one more is said.
    @ObservationIgnored private var setAsideSeen = 0

    /// Starts on `jobs`' queue, at launch or in a new minis folder: what's already put aside isn't said.
    func follow(_ jobs: JobRunner) { setAsideSeen = jobs.queue.setAside().count }

    /// Reads it again. Returns whether a queue that wouldn't read was put aside since it was last
    /// read (#306), by this Mimic or another, and whether the list of minis should be read again
    /// (`QueueState.listChanged`). `running`: this Mimic is running a job.
    func read(_ jobs: JobRunner, running: Bool) -> (setAside: Bool, listChanged: Bool) {
        let aside = jobs.queue.setAside().count
        let newlyAside = aside > setAsideSeen
        setAsideSeen = aside
        let new = QueueState.read(jobs, running: running)
        let changed = new.listChanged(from: QueueState(entries: entries, elsewhere: elsewhere, hold: hold, paused: paused))
        // Each only when it changed, so a view reading one isn't redrawn for another.
        if new.entries != entries { entries = new.entries }
        if new.elsewhere != elsewhere { elsewhere = new.elsewhere }
        if new.hold != hold { hold = new.hold }
        if new.paused != paused { paused = new.paused }
        return (newlyAside, changed)
    }
}

extension AppModel {
    /// The jobs waiting their turn, shared with every other Mimic on this Mac.
    var queue: [QueueEntry] { queueWatch.entries }
    /// The job another Mimic is running (the dev app, `mimic` in Terminal), when this one isn't.
    var elsewhere: JobStatus? { queueWatch.elsewhere }
    /// Why the queue's next job waits (paused, or on battery), read with the queue.
    var hold: QueueHold? { queueWatch.hold }
    /// Paused, here or in another Mimic (#89). Read with the queue.
    var paused: Bool { queueWatch.paused }

    /// Off the main thread: stopping a leftover job waits for it to end (up to 5 s), and the
    /// queue's lock waits while another Mimic holds it, which would freeze the window meanwhile.
    func watchQueue() async {
        let jobs = self.jobs, queueFolder = install.queue
        let idle = !running, canStart = !running && requiredProblem == nil && setup.installed
        let leftover = await Task.detached { () -> Bool in
            // A crashed Mimic's job may still be running with nothing watching it: stopped as soon
            // as no live Mimic holds the job lock, queue or no queue. One that crashed between
            // programs left none running, but its mini still needs saying why it stopped (#436).
            let leftover = idle && (Leftover.recorded(queue: queueFolder) || SharedJob.orphaned(queue: queueFolder) != nil)
            if leftover { jobs.cleanUpLeftovers() }
            // Not while a required part is broken (the engine needs Repair): each job would fail in
            // turn, so the queue waits until it's fixed.
            if canStart && !jobs.queue.entries().isEmpty { jobs.pump() }
            return leftover
        }.value
        // The mini it was making now says why it stopped: shown without waiting for another reload.
        if !refreshQueue() && leftover { reload() }
        updates.tick()
    }

    /// Reads the queue again (`QueueWatch`). Returns whether it reloaded the list, so a caller
    /// about to reload too can skip its own.
    @discardableResult
    func refreshQueue() -> Bool {
        let read = queueWatch.read(jobs, running: running)
        // A queue that wouldn't read was put aside (#306), by this Mimic or another: said once.
        if read.setAside {
            problem = Problem("Couldn't read the queue", "Mimic couldn't read its list of minis waiting to be made, so it put the list aside and started a new one. Minis that were waiting didn't start: make or resize them again.")
        }
        if read.listChanged { reload() }
        updateBadge()
        return read.listChanged
    }

    /// A mini's place in the queue, from 1, or nil when it isn't waiting.
    func waiting(_ name: String) -> Int? { queue.firstIndex { $0.name == name }.map { $0 + 1 } }

    /// "1st", "2nd"…
    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }

    /// A waiting resize, which leaving the queue cancels: the mini keeps the size it has.
    func isResize(_ e: QueueEntry) -> Bool { e.job == .prep && !importing(e.name) }

    func removeFromQueue(_ name: String) {
        do { try jobs.remove(name) } catch { problem = Problem("Couldn't remove it from the queue", plainWords(error, else: "Try again.")) }
        if !refreshQueue() { reload() }
    }

    /// Pause After This One, Pause Queue or Resume Queue, in the job's popover and the Queue menu.
    var pauseCommand: String { JobProgress.pauseCommand(paused: paused, making: current != nil) }

    /// Pausing lets the mini being made finish; resuming starts the next one if none is.
    func togglePause() {
        do { try jobs.setPaused(!paused) } catch { problem = Problem(paused ? "Couldn't resume the queue" : "Couldn't pause the queue", "Try again.") }
        refreshQueue()
    }

    /// The queue's next job waits although nothing is running: the toolbar says so.
    var queueHeld: QueueHold? { current == nil && !queue.isEmpty ? hold : nil }

    func moveInQueue(_ name: String, by offset: Int) {
        _ = try? jobs.move(name, by: offset)
        refreshQueue()
    }

    /// Move to Front, Move to End, or a mini dragged onto another's place (#72).
    func moveInQueue(_ name: String, to place: QueuePlace) {
        _ = try? jobs.move(name, to: place)
        refreshQueue()
    }
}
