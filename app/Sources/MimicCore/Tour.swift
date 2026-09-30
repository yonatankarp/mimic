import Foundation

/// The first-run tour's stops, in order: five short ones. The callouts themselves are in the app
/// (`TourGuide.swift`); this is when it starts and which stop comes next, so it can be tested.
/// What the tour leaves out (the gallery's shortcuts, size and nozzle) are tips shown in place
/// the first time they're used.
public enum TourStep: String, CaseIterable, Sendable {
    case welcome, newMini, make, mini, settings

    /// Shown inside New Mini, which the tour opens itself, so it's never skipped.
    public var inNewMini: Bool { self == .make }

    /// A card in the middle of the window, pointing at nothing: the welcome, and Settings, which
    /// is in the Mimic menu rather than on a control. Always shown.
    public var centred: Bool { self == .welcome || self == .settings }
}

public enum Tour {
    /// The UserDefaults key saying the tour has been shown once.
    public static let seenKey = "tourSeen"

    /// Once, and only once Mimic can make minis: after first-launch setup, or at the first
    /// launch that doesn't need it.
    public static func shouldStart(seen: Bool, installed: Bool) -> Bool { installed && !seen }

    /// The stops that will be shown: the centred cards, New Mini's own, and whichever
    /// main-window stops are on screen (no mini yet leaves the mini's page out).
    public static func steps(onScreen: Set<TourStep>) -> [TourStep] {
        TourStep.allCases.filter { $0.centred || $0.inNewMini || onScreen.contains($0) }
    }

    /// The stop after `step`, or nil when the tour is over.
    public static func next(after step: TourStep, onScreen: Set<TourStep>) -> TourStep? {
        let all = TourStep.allCases
        guard let i = all.firstIndex(of: step) else { return nil }
        return all[(i + 1)...].first { steps(onScreen: onScreen).contains($0) }
    }
}
