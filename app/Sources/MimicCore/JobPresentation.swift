import Foundation

/// What the toolbar's job item and its popover show around the job itself, and which finished
/// minis haven't been seen yet: changed only by what happens to the job and to the popover. The
/// app says what it knows (whether Mimic is in front, whether anything runs or waits) with each.
public struct JobPresentation: Equatable, Sendable {
    /// "Added to the queue — …", for the mini `name`.
    public struct QueuedNote: Equatable, Sendable {
        public let name: String
        public let text: String
        public init(name: String, text: String) { self.name = name; self.text = text }

        /// "2 minis added to the queue.": how a note for several added at once starts, in the
        /// popover and in Terminal.
        public static func added(_ count: Int) -> String { "\(count) \(count == 1 ? "mini" : "minis") added to the queue." }
    }

    /// What a new status meant: a job started, or one ended.
    public struct Change: Equatable, Sendable {
        public let started: Bool
        public let finished: Bool
    }

    /// The job stays in the toolbar once it ends, until its popover has been seen.
    public private(set) var keptShown = false
    /// The popover has shown how the job ended, with Mimic in front. Only then can closing it
    /// clear the toolbar item.
    public private(set) var shownEnd = false
    /// Jobs that ended since the job's popover was last seen, the latest last: the queue can
    /// start the next straight away, so the popover lists these under the one it shows.
    public private(set) var ended: [JobStatus] = []
    /// At the top of the job's popover until that mini starts or the popover is closed.
    public private(set) var queuedNote: QueuedNote?
    /// Minis that finished while nobody was looking, counted on the Dock icon until seen: picked
    /// in the list with Mimic in front, or the job's popover seen after they ended.
    public private(set) var unseen: Set<String> = []

    public init() {}

    /// A job was started, or added to the queue with `note`: it shows in the toolbar either way.
    public mutating func jobAdded(note: QueuedNote?) {
        queuedNote = note
        keptShown = true
    }

    /// Several added at once: one note for them all, in place of each one's.
    public mutating func noteQueued(_ note: QueuedNote) { queuedNote = note }

    /// Try Again on a job that ended: it leaves the list of those.
    public mutating func retried(_ name: String) { ended.removeAll { $0.name == name } }

    /// This Mimic's job went from `previous` to `s`.
    public mutating func jobChanged(from previous: JobStatus?, to s: JobStatus) -> Change {
        let started = s.running && (previous?.running != true || previous?.name != s.name)
        let finished = !s.running && (previous?.running == true || previous?.name != s.name || previous?.started != s.started)
        // The job the popover showed has ended and another came after it: listed under the new one.
        if let previous, !previous.running, previous.name != s.name || previous.started != s.started { ended.append(previous) }
        if started {
            keptShown = true
            shownEnd = false
            if queuedNote?.name == s.name { queuedNote = nil }
        }
        return Change(started: started, finished: finished)
    }

    /// A job ended: its mini counts as ready and unseen if it succeeded, unless it's on screen.
    public mutating func jobFinished(_ s: JobStatus, onScreen: Bool) {
        if s.succeeded, !onScreen { unseen.insert(s.name) }
    }

    /// Minis seen with Mimic in front. Returns whether any of them was unseen.
    @discardableResult
    public mutating func seen(_ names: Set<String>) -> Bool {
        guard !unseen.isDisjoint(with: names) else { return false }
        unseen.subtract(names)
        return true
    }

    /// The job's popover is showing (`open`): it shows how the job ended when Mimic is in front
    /// (`active`) and nothing runs, here or in another Mimic (`idle`).
    public mutating func popoverShowing(active: Bool, open: Bool, idle: Bool) {
        if active && open && idle { shownEnd = true }
    }

    /// The job's popover closed. A finished job leaves the toolbar only if it was really seen
    /// (`JobProgress.seenEnd`): switching to another app also closes the popover, and the "ready"
    /// item must still be there when you come back. Returns whether it was seen.
    @discardableResult
    public mutating func popoverClosed(active: Bool, busy: Bool) -> Bool {
        defer { shownEnd = false }
        // Seen once is enough: its "ready in" time doesn't change, while the queue's below it
        // do (#141). Not when switching away closed it, though, as then it wasn't read.
        if active { queuedNote = nil }
        guard JobProgress.seenEnd(active: active, busy: busy, shownEnd: shownEnd) else { return false }
        ended = []
        keptShown = false
        unseen = []
        return true
    }
}
