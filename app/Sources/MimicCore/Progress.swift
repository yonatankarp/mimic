import Foundation

/// What the progress window says while a job runs, ported from the web page. Times come from an
/// `Estimate`: this Mac's own history when it has one, else Mimic's fixed figures. A job running
/// well past it is told so plainly.
public enum JobProgress {
    /// The bar never claims to be done before it is.
    public static func fraction(_ s: JobStatus, estimate: Estimate, now: Date = Date()) -> Double {
        if s.running { return min(0.95, estimate.fraction(s, now: now)) }
        return s.succeeded ? 1 : 0
    }

    /// "3:07"
    public static func clock(_ elapsed: TimeInterval) -> String {
        let e = max(0, Int(elapsed))
        return "\(e / 60):" + String(format: "%02d", e % 60)
    }

    /// "about 8 minutes", "about a minute", "about 1 hour 20 minutes".
    public static func about(_ seconds: TimeInterval) -> String {
        if seconds < 45 { return "less than a minute" }
        if seconds < 90 { return "about a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) minutes" }
        let h = minutes / 60, m = minutes % 60
        return "about \(h) hour\(h > 1 ? "s" : "")" + (m == 0 ? "" : " \(m) minute\(m > 1 ? "s" : "")")
    }

    public enum Pace { case usual, slow, verySlow }

    /// Against the estimate, with some slack: a job a little over isn't "slow". The thresholds
    /// are the old fixed ones (12 and 25 minutes against 9) as proportions.
    public static func pace(_ s: JobStatus, estimate: Estimate, now: Date = Date()) -> Pace {
        let elapsed = now.timeIntervalSince(s.started), total = estimate.total
        if elapsed > total * 2.8 && elapsed - total > 300 { return .verySlow }
        if elapsed > total * 1.35 && elapsed - total > 60 { return .slow }
        return .usual
    }

    public static func note(_ s: JobStatus, estimate: Estimate, now: Date = Date()) -> String {
        let t = clock(now.timeIntervalSince(s.started))
        switch pace(s, estimate: estimate, now: now) {
        case .verySlow: return "\(t) so far. This is unusually slow. You can keep waiting, or stop and try again."
        case .slow: return "\(t) so far. Taking longer than usual. Still working, nothing's wrong."
        case .usual: break
        }
        let left = estimate.left(s, now: now)
        let head = left < 15 ? "Nearly done" : "\(about(left).capitalizedFirst) left"
        if s.kind == .prep { return "\(head) · \(t) so far." }
        return "\(head) · \(t) so far. You can use other apps meanwhile. Your Mac will be busy, and the fan may get loud."
    }

    /// Beside a step: how long the one running has left, or how long one to come should take.
    public static func stepNote(_ step: Int, of s: JobStatus, estimate: Estimate, now: Date = Date()) -> String? {
        if s.running, step == s.step, s.openingDrawThings { return "Opening Draw Things…" }
        guard s.running, step >= s.step, let e = estimate.steps[step] else { return nil }
        if step > s.step { return e < 45 ? "seconds" : about(e) }
        let left = e - now.timeIntervalSince(s.stepStarted ?? s.started)
        return left < 15 ? "nearly done" : "\(about(left)) left"
    }

    /// The web version's test: a failure whose reason names Draw Things is fixed in Setup.
    public static func drawThingsCaused(_ s: JobStatus) -> Bool { s.problem?.contains("Draw Things") == true }

    /// Whether closing the job's popover means how the job ended was seen, so it can leave the
    /// toolbar: only with Mimic in front (`active`), nothing running or waiting (`busy`), and the
    /// popover having shown the end while Mimic was in front (`shownEnd`). A popover closed by
    /// switching to another app, or while the job ran, never counts.
    public static func seenEnd(active: Bool, busy: Bool, shownEnd: Bool) -> Bool { active && !busy && shownEnd }

    /// The job the toolbar shows, which its popover hangs from: this Mimic's while it runs, and
    /// once it ends until that's been seen (`keptShown`); else what another Mimic is running.
    public static func inToolbar(_ job: JobStatus?, keptShown: Bool, elsewhere: JobStatus?) -> JobStatus? {
        job.flatMap { keptShown || $0.running ? $0 : nil } ?? elsewhere
    }
}

extension String {
    public var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
