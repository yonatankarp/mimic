import Foundation

/// What the progress window says while a job runs, ported from the web page. The estimate is a
/// fixed ~9 minutes (a minute for a resize); a slower Mac running past it is told so plainly.
public enum JobProgress {
    /// Seconds the bar takes to reach 95%: it never claims to be done before it is.
    public static func expected(_ kind: JobKind) -> Double { kind == .prep ? 60 : 540 }

    public static func fraction(_ s: JobStatus, now: Date = Date()) -> Double {
        if s.running { return min(0.95, now.timeIntervalSince(s.started) / expected(s.kind)) }
        return s.succeeded ? 1 : 0
    }

    /// "3:07"
    public static func clock(_ elapsed: TimeInterval) -> String {
        let e = max(0, Int(elapsed))
        return "\(e / 60):" + String(format: "%02d", e % 60)
    }

    public static func note(_ kind: JobKind, elapsed: TimeInterval) -> String {
        let t = clock(elapsed)
        if kind == .prep { return "About a minute · \(t) so far." }
        if elapsed > 25 * 60 { return "\(t) so far. This is unusually slow. You can keep waiting, or stop and try again." }
        if elapsed > 12 * 60 { return "\(t) so far. Taking longer than usual. Still working, nothing's wrong." }
        return "About 7–10 minutes · \(t) so far. You can use other apps meanwhile. Your Mac will be busy, and the fan may get loud."
    }

    /// The web version's test: a failure whose reason names Draw Things is fixed in Setup.
    public static func drawThingsCaused(_ s: JobStatus) -> Bool { s.problem?.contains("Draw Things") == true }
}
