import Foundation

/// The first-run tour's stops, in order. The callouts themselves are in the app (`Tour.swift`
/// there); this is when it starts and which stop comes next, so it can be tested.
public enum TourStep: String, CaseIterable, Sendable {
    case welcome, newMini, start, size, make, mini, gallery, settings

    /// Shown inside New Mini, which the tour opens itself, so they're never skipped.
    public var inNewMini: Bool { self == .start || self == .size || self == .make }
}

public enum Tour {
    /// The UserDefaults key saying the tour has been shown once.
    public static let seenKey = "tourSeen"

    /// Once, and only once Mimic can make minis: after first-launch setup, or at the first
    /// launch that doesn't need it.
    public static func shouldStart(seen: Bool, installed: Bool) -> Bool { installed && !seen }

    /// The stops that will be shown: the welcome, New Mini's own, and whichever main-window
    /// stops are on screen (no mini yet, or the sidebar hidden, leaves theirs out).
    public static func steps(onScreen: Set<TourStep>) -> [TourStep] {
        TourStep.allCases.filter { $0 == .welcome || $0.inNewMini || onScreen.contains($0) }
    }

    /// The stop after `step`, or nil when the tour is over.
    public static func next(after step: TourStep, onScreen: Set<TourStep>) -> TourStep? {
        let all = TourStep.allCases
        guard let i = all.firstIndex(of: step) else { return nil }
        return all[(i + 1)...].first { steps(onScreen: onScreen).contains($0) }
    }
}
