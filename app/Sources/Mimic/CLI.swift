import Foundation
import MimicCore
import UserNotifications

/// The command-line mode. Milestone 0 has only what the skeleton needs; `make` arrives with the
/// engine in milestone 1.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "list":
            guard let install = Install.locate() else { return fail("Can't find the Mimic folder. Set MIMIC_HOME or run the installer.") }
            for m in Gallery.list(install.runs) {
                print("\(m.name)\t\(m.stl == nil ? "unfinished" : "ready")\t\(m.madeAt)")
            }
            return 0
        case "--probe-notifications":
            // Feasibility check: does the notification system accept this self-assembled app?
            // Reading the settings needs a valid bundle but, unlike asking, shows no prompt.
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var status = "unknown"
            UNUserNotificationCenter.current().getNotificationSettings { s in
                status = String(describing: s.authorizationStatus.rawValue)
                done.signal()
            }
            done.wait()
            print("notifications reachable, authorization status \(status) (0 = not yet asked)")
            return 0
        default:
            return fail("usage: mimic list")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
}
