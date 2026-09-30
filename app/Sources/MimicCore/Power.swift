import Foundation
import IOKit.ps

/// Settings → Don't start minis on battery (#89): while the Mac runs on its battery, no new
/// mini starts, in the app or in Terminal; one already being made carries on. The app looks
/// every few seconds, so the queue carries on by itself once the Mac is plugged in.
public enum Power {
    /// The setting, off by default.
    public static let key = "dontStartOnBattery"

    /// Running on the battery, not a charger. A Mac without a battery never is.
    public static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// This Mac has a battery, so the setting means something (a MacBook, not a Mac mini).
    public static func hasBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return d?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// For `JobRunner.heldForPower`: the setting in `defaults`, and the battery.
    public static func holds(suite: String?) -> @Sendable () -> Bool {
        { (suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard).bool(forKey: key) && onBattery() }
    }
}
