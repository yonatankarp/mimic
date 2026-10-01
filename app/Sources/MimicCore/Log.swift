import Foundation
import OSLog

/// The app's own log, for what happens outside a job: setup, downloads, the queue starting and
/// stopping, and errors shown to the person. A job's programs write to its folder's logs instead.
/// Values are logged `.public`: the default, private, reads back as "<private>". No key is ever
/// logged, and Report a Problem scrubs what it reads anyway.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.mimic.app"
    public static let setup = Logger(subsystem: subsystem, category: "setup")
    public static let download = Logger(subsystem: subsystem, category: "download")
    public static let queue = Logger(subsystem: subsystem, category: "queue")
    /// Errors shown to the person, in the words they saw.
    public static let shown = Logger(subsystem: subsystem, category: "shown")

    /// This launch's log since `since`, one line per entry, or nil when it can't be read. Only
    /// this process's: reading it needs no permission (the whole Mac's log needs an administrator),
    /// so a report has this launch only, never an earlier one or `mimic` in Terminal. Debug
    /// entries aren't kept, so notice and up are what's logged.
    public static func recent(since: Date, subsystem: String = subsystem) -> String? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since),
                                                  matching: NSPredicate(format: "subsystem == %@", subsystem))
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return entries.compactMap { $0 as? OSLogEntryLog }
            .map { "\(f.string(from: $0.date)) [\($0.category)] \($0.composedMessage)\n" }
            .joined()
    }
}
