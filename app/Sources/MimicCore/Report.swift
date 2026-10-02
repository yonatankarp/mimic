import Darwin
import Foundation

/// Help → Report a Problem… (#100): one zip with what someone fixing it needs, and a GitHub issue
/// filled in to drag it into (a link can't attach a file). The zip always has the build line,
/// the Mac, and the app's log; the setup (#283) when given; for a mini, its logs and settings.json.
/// Its picture, and the window's, only when the person ticks the box, since the issue is public.
/// Everything written is scrubbed first.
public enum Report {
    public static let newIssue = URL(string: "https://github.com/yonatankarp/mimic/issues/new")!
    /// The most of one log kept, from its end: where a failure is. pixal3d.log can grow large.
    static let logLimit = 2_000_000

    // MARK: Scrubbing

    /// Keys of the services the AI helper talks to, and of the ones a program's log might print.
    private static let keys = [
        #"\bsk-ant-[A-Za-z0-9_\-]{8,}"#, #"\bsk-[A-Za-z0-9_\-]{16,}"#, #"\b(?:hf|gsk)_[A-Za-z0-9]{16,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=\-]{8,}"#)
    /// `api_key=…`, `"token": "…"`, `x-api-key: …`, `x-key: …` (Black Forest Labs'),
    /// `AWS_SECRET_ACCESS_KEY=…`: the value goes, the name stays. `max_tokens: 400` stays whole:
    /// the s before the colon isn't a name's end.
    private static let named = try! NSRegularExpression(pattern:
        #"(?i)\b([A-Za-z0-9_\-]*(?:api[_-]?key|access[_-]?key|x-key|token|secret|password|passwd|authorization))(["']?\s*[:=]\s*["']?)(?!\[)([^\s"',;}]+)"#)

    /// `text` without anything secret: API keys and tokens, and the home folder (which says who
    /// the person is) as ~.
    public static func scrub(_ text: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var s = text
        func replace(_ re: NSRegularExpression, _ with: String) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
        }
        for re in keys { replace(re, "[key removed]") }
        replace(bearer, "$1[key removed]")
        replace(named, "$1$2[removed]")
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        // As JSON writes it too: settings.json has "\/Users\/…".
        for spelling in [home, home.replacingOccurrences(of: "/", with: "\\/")] where home.count > 1 {
            if let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: spelling) + #"(?![A-Za-z0-9._\-])"#) {
                replace(re, "~")
            }
        }
        return s
    }

    // MARK: The Mac

    /// "Mac14,6, Apple M2 Max, 32 GB, macOS 26.0.1": what bug.yml's Mac field asks for.
    public static func macLine(model: String, chip: String, memory: UInt64, os: OperatingSystemVersion) -> String {
        let gb = Int((Double(memory) / 1_073_741_824).rounded())
        let v = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        return [model, chip, "\(gb) GB", "macOS \(v)"].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// This Mac's line.
    public static var mac: String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let p = ProcessInfo.processInfo
        return macLine(model: sysctl("hw.model"), chip: sysctl("machdep.cpu.brand_string"), memory: p.physicalMemory,
                       os: p.operatingSystemVersion)
    }

    // MARK: The zip

    /// Writes the report into `folder` and returns the zip. `mini` adds its logs and
    /// settings.json, and its picture when `picture` is set. `appLog` nil means it couldn't be
    /// read, which about.txt says. `extra` adds files by name, scrubbed too: a crash's report.
    /// `setup` goes in as setup.txt, `window` (a PNG) as window.png.
    public static func write(to folder: URL, mini: Mini?, picture: Bool, build: String, mac: String, appLog: String?,
                             extra: [String: String] = [:], setup: ReportSetup? = nil, window: Data? = nil,
                             now: Date = Date(), home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> URL {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "mimic-report-" + (mini.map { $0.name + "-" } ?? "") + stamp.string(from: now)
        let scratch = fm.temporaryDirectory.appendingPathComponent("mimic-report-\(UUID().uuidString)")
        let top = scratch.appendingPathComponent(name)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        func text(_ s: String, _ file: String, in dir: URL = top) throws {
            try Data(scrub(s, home: home).utf8).write(to: dir.appendingPathComponent(file))
        }

        var about = [build, mac, ISO8601DateFormatter().string(from: now)]
        if let appLog { try text(appLog, "app.log") } else { about.append("The app's own log couldn't be read.") }
        for (file, s) in extra { try text(s, file) }
        if let setup { try text(setup.text(home: home), "setup.txt") }
        if let window { try window.write(to: top.appendingPathComponent("window.png")) }
        about.append("Window picture: " + (window == nil ? "left out" : "included"))
        if let mini {
            let dir = top.appendingPathComponent("mini")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(atPath: mini.folder.path)) ?? []
            for file in files.sorted() where file.hasSuffix(".log") || file == "settings.json" {
                guard let data = fm.contents(atPath: mini.folder.appendingPathComponent(file).path) else { continue }
                let cut = data.count > logLimit
                try text((cut ? "[cut to its last \(logLimit / 1_000_000) MB]\n" : "") + String(decoding: data.suffix(logLimit), as: UTF8.self), file, in: dir)
            }
            about.append("Mini: \(mini.name)")
            let pic = picture ? (mini.source ?? mini.upload) : nil
            if let pic { try fm.copyItem(at: pic, to: dir.appendingPathComponent("picture." + (pic == mini.source ? "png" : "img"))) }
            about.append("Picture: " + (pic == nil ? "left out" : "included"))
        }
        try text(about.joined(separator: "\n") + "\n", "about.txt")

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Reports from more than a week ago go (#350): sent or not, they'd pile up, and the minis
        // folder may sync to iCloud. Only Mimic's own, and never a reason not to make this one.
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("mimic-report-") && old.pathExtension == "zip" {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < weekAgo {
                try? fm.removeItem(at: old)
            }
        }
        let zip = folder.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", top.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    // MARK: The issue

    /// bug.yml's form filled in through its field ids. The picture and logs can't go in a link,
    /// so the logs box says to drag the zip in; the setup's summary goes in Anything else.
    public static func issueURL(build: String, mac: String, failure: String?, setup: ReportSetup? = nil,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> URL {
        var fields = [("template", "bug.yml"), ("version", build), ("mac", mac),
                      ("logs", "Mimic made a report and showed it in Finder. Drag it into this box to attach it.")]
        if let setup { fields.append(("more", "Setup, from Mimic:\n" + setup.summary(home: home))) }
        if let failure {
            fields += [("title", "A mini didn't finish"),
                       ("what", "A mini didn't finish. Mimic said: \(scrub(failure, home: home))\n\nWhat I did: ")]
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = fields.map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: newIssue.absoluteString + "?" + query)!
    }
}
