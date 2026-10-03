import Foundation

/// What the progress window says while a job runs, ported from the web page. Times come from an
/// `Estimate`: this Mac's own history when it has one, else Mimic's fixed figures. A job running
/// well past it is told so plainly.
public enum JobProgress {
    /// This Mimic's `job` can be stopped: "Stop Making…" or "Stop Resizing…" in the menus, else nil.
    public static func stopCommand(_ job: JobStatus?) -> String? {
        guard let job, job.running else { return nil }
        return job.kind == .prep ? String(localized: "Stop Resizing…", bundle: .mimicCore) : String(localized: "Stop Making…", bundle: .mimicCore)
    }

    /// Pause After This One, Pause Queue or Resume Queue, in the job's popover and the Mini menu.
    /// `making`: a mini is being made, here or in another Mimic.
    public static func pauseCommand(paused: Bool, making: Bool) -> String {
        paused ? String(localized: "Resume Queue", bundle: .mimicCore) : making ? String(localized: "Pause After This One", bundle: .mimicCore) : String(localized: "Pause Queue", bundle: .mimicCore)
    }

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
        if seconds < 45 { return String(localized: "less than a minute", bundle: .mimicCore) }
        if seconds < 90 { return String(localized: "about a minute", bundle: .mimicCore) }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "about \(minutes) minutes", bundle: .mimicCore) }
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
        case .verySlow: return String(localized: "\(t) so far. This is unusually slow. You can keep waiting, or stop and try again.", bundle: .mimicCore)
        case .slow: return String(localized: "\(t) so far. Taking longer than usual. Still working, nothing's wrong.", bundle: .mimicCore)
        case .usual: break
        }
        let left = estimate.left(s, now: now)
        let head = left < 15 ? String(localized: "Nearly done", bundle: .mimicCore)
            : String(localized: "\(about(left).capitalizedFirst) left", bundle: .mimicCore)
        if s.kind == .prep { return String(localized: "\(head) · \(t) so far.", bundle: .mimicCore) }
        return String(localized: "\(head) · \(t) so far. You can use other apps meanwhile. Your Mac will be busy, and the fan may get loud.", bundle: .mimicCore)
    }

    /// Beside a step: how long the one running has left, or how long one to come should take.
    public static func stepNote(_ step: JobStep, of s: JobStatus, estimate: Estimate, now: Date = Date()) -> String? {
        if s.running, step == s.step, s.openingDrawThings { return String(localized: "Opening Draw Things…", bundle: .mimicCore) }
        guard s.running, step >= s.step, let e = estimate.steps[step] else { return nil }
        if step > s.step { return e < 45 ? String(localized: "seconds", bundle: .mimicCore, comment: "How long a step to come takes") : about(e) }
        let left = e - now.timeIntervalSince(s.stepStarted ?? s.started)
        return left < 15 ? String(localized: "nearly done", bundle: .mimicCore) : String(localized: "\(about(left)) left", bundle: .mimicCore)
    }

    /// A failure fixed in Setup: Draw Things isn't running or isn't set up. Decided by what went
    /// wrong, not by its words (#434): a refusal or a timeout means Draw Things answered, or was
    /// on but slow or stuck (#321). A job keeps only the reason's words, so it's matched whole.
    public static func drawThingsCaused(_ s: JobStatus) -> Bool {
        DrawThingsError.setup.contains { $0.description == s.problem }
    }

    /// The first line for a job that didn't finish: what to do, from what went wrong (#435). "A
    /// clearer picture" only when the 3D steps failed: when the picture couldn't be made (Draw
    /// Things slow, a service busy, a picture that can't be read) or the Mac ran out of memory,
    /// the reason itself says what to do, so it's the headline.
    public static func failedHeadline(_ s: JobStatus, imported: Bool) -> String {
        if drawThingsCaused(s) { return String(localized: "Draw Things isn't ready. Check the setup steps, then try again.", bundle: .mimicCore) }
        if imported { return String(localized: "Try Resize This Mini with other sizes, or check the model in the app it came from.", bundle: .mimicCore) }
        if let why = s.problem, s.step == .picture || why == s.step.outOfMemory { return why }
        return String(localized: "Try again, or use a clearer, full-body picture.", bundle: .mimicCore)
    }

    /// Whether closing the job's popover means how the job ended was seen, so it can leave the
    /// toolbar: only with Mimic in front (`active`), nothing running or waiting (`busy`), and the
    /// popover having shown the end while Mimic was in front (`shownEnd`). A popover closed by
    /// switching to another app, or while the job ran, never counts.
    public static func seenEnd(active: Bool, busy: Bool, shownEnd: Bool) -> Bool { active && !busy && shownEnd }

    /// The Dock icon's badge: how many minis are ready and not yet seen, counting only those
    /// still in the gallery (one trashed or renamed since drops out), or nil for none. A count,
    /// never a symbol, and not the queue.
    public static func badge(unseen: Set<String>, minis: [String]) -> String? {
        let n = unseen.intersection(minis).count
        return n == 0 ? nil : "\(n)"
    }

    /// The job the toolbar shows, which its popover hangs from: this Mimic's while it runs, and
    /// once it ends until that's been seen (`keptShown`); else what another Mimic is running.
    public static func inToolbar(_ job: JobStatus?, keptShown: Bool, elsewhere: JobStatus?) -> JobStatus? {
        job.flatMap { keptShown || $0.running ? $0 : nil } ?? elsewhere
    }
}

extension String {
    public var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
