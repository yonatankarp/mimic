import Foundation

/// A crash of Mimic or the `mimic` command that macOS wrote down (#284), trimmed to what
/// fixing it needs and scrubbed.
public struct Crash: Equatable, Sendable {
    public let file: URL
    /// When macOS wrote it: what the newest one seen is remembered by.
    public let date: Date
    /// "EXC_BREAKPOINT in closure #1 in JobRunner.run(_:)": the exception and the top frame in
    /// Mimic's own code.
    public let what: String
    /// "0.11.0 (build 412)", or "" when the report doesn't say.
    public let version: String
    /// The exception, the crashing thread's frames and the libraries they're in, as JSON.
    public let trimmed: String
    public let pid: Int?
    public let launched: Date?, crashed: Date?

    /// The issue's title.
    public var title: String { "Mimic quit unexpectedly" + (version.isEmpty ? "" : " in \(version)") + ": \(what)" }
}

/// Finds crashes in `~/Library/Logs/DiagnosticReports` at launch and offers each once. Crashes of
/// the programs Mimic runs (trellis-cli, draw-things-cli, and its own `_prep` and `_engine`) aren't
/// offered: they show as failed jobs, with their logs, and Report a Problem on the mini has those.
public enum CrashReport {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }
    /// The UserDefaults key holding the newest crash report seen, and the one for Don't Ask Again.
    public static let seenKey = "crashSeen", dontAskKey = "crashDontAsk"
    /// With nothing seen yet (a first launch, or after Reset), crashes older than this aren't offered.
    static let firstLook: TimeInterval = 24 * 3600

    /// The newest crash since the last look, or nil. Remembers every report it looked at as seen,
    /// so each is offered once, whatever the answer.
    public static func check(in folder: URL = CrashReport.folder, defaults: UserDefaults = .standard, now: Date = Date(),
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Crash? {
        guard !defaults.bool(forKey: dontAskKey) else { return nil }
        let since = defaults.object(forKey: seenKey) as? Date ?? now.addingTimeInterval(-firstLook)
        let found = reports(in: folder).filter { $0.date > since }
        guard let newest = found.map(\.date).max() else { return nil }
        defaults.set(newest, forKey: seenKey)
        return found.sorted { $0.date > $1.date }.lazy.compactMap { read($0.url, date: $0.date, home: home) }.first
    }

    /// `mimic-2026-09-30-101500.ips` and `Mimic-….000.ips`: the app and the command are one binary.
    static func reports(in folder: URL) -> [(url: URL, date: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasPrefix("mimic-") && $0.hasSuffix(".ips") }.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (url, date)
        }
    }

    // MARK: Trimming

    /// The report at `url`, trimmed and scrubbed, or nil when it isn't a crash (a hang or a
    /// spin report has no crashing thread) or can't be read.
    public static func read(_ url: URL, date: Date = Date(), home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Crash? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let split = text.firstIndex(of: "\n"),
              let header = (try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8))) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: Data(text[split...].utf8))) as? [String: Any],
              (header["name"] as? String ?? header["app_name"] as? String)?.lowercased() == "mimic",
              !startedByAJob(body),
              let exception = body["exception"] as? [String: Any],
              let threads = body["threads"] as? [[String: Any]],
              let faulting = body["faultingThread"] as? Int, threads.indices.contains(faulting)
        else { return nil }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let own = body["procPath"] as? String

        // Each frame names its library, so only those libraries are kept and the numbers
        // pointing into the full list go.
        func image(_ frame: [String: Any]) -> [String: Any]? {
            (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil }
        }
        let rawFrames = threads[faulting]["frames"] as? [[String: Any]] ?? []
        let frames: [[String: Any]] = rawFrames.map { f in
            var out = f.filter { ["symbol", "symbolLocation", "imageOffset", "sourceFile", "sourceLine"].contains($0.key) }
            out["image"] = image(f)?["name"] ?? "?"
            return out
        }
        var used: [[String: Any]] = [], seen = Set<Int>()
        for f in rawFrames {
            guard let i = f["imageIndex"] as? Int, images.indices.contains(i), seen.insert(i).inserted else { continue }
            used.append(images[i].filter { ["name", "path", "uuid", "arch", "base", "size", "CFBundleShortVersionString", "CFBundleVersion"].contains($0.key) })
        }

        let top = rawFrames.firstIndex { own != nil && image($0)?["path"] as? String == own } ?? (rawFrames.isEmpty ? nil : 0)
        let place = top.map { i -> String in
            let f = rawFrames[i]
            if let s = f["symbol"] as? String { return s }
            return "\(image(f)?["name"] as? String ?? "?") + \(f["imageOffset"] as? Int ?? 0)"
        }
        let kind = exception["type"] as? String ?? "A crash"
        let what = String((kind + (place.map { " in \($0)" } ?? "")).prefix(160))

        let bundle = body["bundleInfo"] as? [String: Any]
        let short = header["app_version"] as? String ?? bundle?["CFBundleShortVersionString"] as? String ?? ""
        let build = header["build_version"] as? String ?? bundle?["CFBundleVersion"] as? String ?? ""
        let version = short.isEmpty ? "" : short + (build.isEmpty || build == short ? "" : " (build \(build))")

        var kept = body.filter { ["exception", "termination", "asi", "procName", "procPath", "parentProc", "pid", "procLaunch",
                                  "captureTime", "osVersion", "cpuType", "translated", "bundleInfo"].contains($0.key) }
        var thread = threads[faulting].filter { ["name", "queue", "id"].contains($0.key) }
        thread["frames"] = frames
        kept["crashedThread"] = thread
        kept["usedImages"] = used
        let json = (try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()

        return Crash(file: url, date: date, what: Report.scrub(what, home: home), version: version,
                     trimmed: Report.scrub(String(decoding: json, as: UTF8.self), home: home) + "\n",
                     pid: body["pid"] as? Int, launched: time(body["procLaunch"]), crashed: time(body["captureTime"]))
    }

    /// Print prep and the 3D step (`mimic _prep`, `mimic _engine`) are this binary too, and their
    /// crash shows as a failed job (#319). A report doesn't keep the arguments, so they're told
    /// apart by what started them: Mimic, or "Exited process" when it exited before the report.
    /// The app's parent is launchd, and `mimic` in Terminal's is the shell.
    static func startedByAJob(_ body: [String: Any]) -> Bool {
        ["mimic", "exited process"].contains((body["parentProc"] as? String)?.lowercased())
    }

    /// "2026-09-30 10:15:00.1234 +0200", as the report writes its times.
    static func time(_ value: Any?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return (value as? String).flatMap(f.date(from:))
    }

    // MARK: The log before it

    /// The crashed launch's own log, its last hour, from the Mac's log. Reading another launch's
    /// log needs an administrator account, so nil on a standard one; about.txt then says so. nil
    /// too when `log` hasn't answered within a minute: a stuck one mustn't hang the report.
    public static func appLog(_ crash: Crash, subsystem: String = Log.subsystem, run: Checks.Runner = Checks.execute) -> String? {
        guard let pid = crash.pid else { return nil }
        let end = crash.crashed ?? crash.date
        let start = max(crash.launched ?? .distantPast, end.addingTimeInterval(-3600))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        guard let result = run("/usr/bin/log", ["show", "--style", "ndjson", "--start", f.string(from: start),
                                                "--end", f.string(from: end.addingTimeInterval(1)),
                                                "--predicate", "processID == \(pid) AND subsystem == \"\(subsystem)\""], 60),
              result.status == 0 else { return nil }
        let text = lines(ndjson: result.output)
        return text.isEmpty ? nil : text
    }

    /// `log show --style ndjson`'s entries as Log.recent writes them: "10:14:58 [queue] Started raven".
    static func lines(ndjson: String) -> String {
        ndjson.split(separator: "\n").compactMap { line -> String? in
            guard let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let message = e["eventMessage"] as? String, let time = e["timestamp"] as? String else { return nil }
            let clock = time.split(separator: " ").dropFirst().first.map { String($0.prefix(8)) } ?? time
            return "\(clock) [\(e["category"] as? String ?? "")] \(message)\n"
        }.joined()
    }

    // MARK: The report

    /// Report a Problem's zip, with the trimmed crash as crash.json, and the setup as now (#283).
    public static func write(_ crash: Crash, to folder: URL, build: String, mac: String, appLog: String?,
                             setup: ReportSetup? = nil, saved: [String] = [], now: Date = Date(),
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> URL {
        try Report.write(to: folder, mini: nil, picture: false, build: build, mac: mac, appLog: appLog,
                         extra: ["crash.json": crash.trimmed], setup: setup, saved: saved, now: now, home: home)
    }

    /// Report a Problem's issue, titled with the crash and asking what the person was doing:
    /// there's no screenshot, since Mimic had already gone.
    public static func issueURL(_ crash: Crash, build: String, mac: String, setup: ReportSetup? = nil, saved: [String] = [],
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> URL {
        let what = "Mimic quit unexpectedly" + (crash.version.isEmpty ? "" : " (version \(crash.version))") + ": \(crash.what)\n\n"
            + "There's no screenshot: Mimic had already quit.\n\nWhat I was doing when it quit: "
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let more = [("title", crash.title), ("what", what)]
            .map { k, v in "\(k)=\(Report.removing(saved, from: v).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: Report.issueURL(build: build, mac: mac, failure: nil, setup: setup, saved: saved, home: home).absoluteString + "&" + more)!
    }
}

/// What Mimic asks at launch after a crash.
public enum CrashQuestion {
    public static let title = "Mimic quit unexpectedly last time. Report it?"
    public static let text = "Mimic puts what macOS noted about the crash, its own notes from before it, and which Mac and version this is "
        + "into one file, with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to. "
        + "Nothing is sent unless you send it."
    public static let report = "Report", notNow = "Not Now", dontAsk = "Don't Ask Again"
}
