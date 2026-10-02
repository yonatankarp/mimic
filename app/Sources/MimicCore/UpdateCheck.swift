import Foundation

/// Settings → General → Check for updates when Mimic opens (#269): on unless turned off. Mimic's
/// own setting, because Sparkle's automatic checks are its daily schedule, which Mimic leaves off
/// (`SUEnableAutomaticChecks` is false in Info.plist). Up to 0.10 the switch was Sparkle's, so
/// its saved answer carries over once and is then removed: left saved as on, it would override
/// the Info.plist and bring the daily check back, with its window landing mid-queue.
public enum UpdateCheck {
    public static let key = "checkForUpdatesAtLaunch"
    static let sparkleKey = "SUEnableAutomaticChecks"

    /// Whether Mimic checks for updates when it opens. Run before Sparkle starts.
    public static func atLaunch(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: sparkleKey) as? Bool == false { defaults.set(false, forKey: key) }
        defaults.removeObject(forKey: sparkleKey)
        return defaults.object(forKey: key) as? Bool ?? true
    }
}
