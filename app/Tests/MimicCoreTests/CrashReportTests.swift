import XCTest
@testable import MimicCore

/// Offering a crash at the next launch (#284): which reports are offered, what's kept of one,
/// and the report and issue it makes. The fixture is made up, shaped like a real report, with
/// a home folder, a key and the identifiers a report carries planted in it.
final class CrashReportTests: XCTestCase {
    let fm = FileManager.default
    let home = "/Users/alice"
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mimic-2026-09-30-101500.ips")

    func defaults() -> UserDefaults {
        let suite = UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// An empty DiagnosticReports folder.
    func folder() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The fixture copied into `dir` as `name`, written `ago` seconds before `now`.
    @discardableResult
    func crash(_ name: String, in dir: URL, ago: TimeInterval, now: Date, contents: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) } else { try fm.copyItem(at: fixture, to: url) }
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: url.path)
        return url
    }

    func testTheCrashIsTrimmedToItsThreadAndScrubbed() throws {
        let c = try XCTUnwrap(CrashReport.read(fixture, home: home))
        XCTAssertEqual(c.what, "EXC_BREAKPOINT in closure #1 in JobRunner.run(_:)", "the top frame in Mimic's own code, not the trap")
        XCTAssertEqual(c.version, "0.11.0 (build 412)")
        XCTAssertEqual(c.title, "Mimic quit unexpectedly in 0.11.0 (build 412): EXC_BREAKPOINT in closure #1 in JobRunner.run(_:)")
        XCTAssertEqual(c.pid, 4242)
        XCTAssertEqual(c.crashed.map { Int($0.timeIntervalSince1970) }, 1_790_756_100)
        XCTAssertNotNil(c.launched)

        for gone in ["alice", "PLANTED", "AppKit", "NSApplication", "threadState", "main-thread", "imageIndex", "sharedCache", "userID"] {
            XCTAssertFalse(c.trimmed.contains(gone), "\(gone) is in the trimmed report")
        }
        for kept in ["~/Applications/Mimic.app/Contents/MacOS/mimic", "Fatal error: Unexpectedly found nil", "[key removed]",
                     "_assertionFailure", "SIGTRAP", "Trace/BPT trap: 5", "macOS 26.6", "com.mimic.jobs"] {
            XCTAssertTrue(c.trimmed.contains(kept), "\(kept) is missing from the trimmed report")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.trimmed.utf8)) as? [String: Any])
        let images = try XCTUnwrap(json["usedImages"] as? [[String: Any]])
        XCTAssertEqual(images.compactMap { $0["name"] as? String }, ["libswiftCore.dylib", "mimic", "libdispatch.dylib"],
                       "only the libraries the crashing thread's frames are in")
        let frames = try XCTUnwrap((json["crashedThread"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.compactMap { $0["image"] as? String }, ["libswiftCore.dylib", "mimic", "mimic", "libdispatch.dylib"])
    }

    /// An uncaught exception (an NSToolbar one, in a layout pass) crashes in AppKit's
    /// `_crashOnException`; only `asiBacktraces` says which call threw it.
    func testAnUncaughtExceptionKeepsWhereItWasThrown() throws {
        let thrown = "3   AppKit   0x18d848e08 -[NSToolbar _insertNewItemWithItemIdentifier:atIndex:propertyListRepresentation:notifyFlags:] + 232"
        let text = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: #"  "asi": {"#, with: #"  "asiBacktraces": ["\#(thrown)"],"# + "\n" + #"  "asi": {"#)
        let url = try crash("mimic-2026-09-30-101500.ips", in: try folder(), ago: 0, now: Date(), contents: text)
        XCTAssertTrue(try XCTUnwrap(CrashReport.read(url, home: home)).trimmed.contains("NSToolbar _insertNewItemWithItemIdentifier"))
    }

    func testAFrameWithoutASymbolIsNamedByItsPlace() throws {
        let text = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: #""symbol": "closure #1 in JobRunner.run(_:)","#, with: "")
        let dir = try folder()
        let url = try crash("mimic-2026-09-30-101500.ips", in: dir, ago: 0, now: Date(), contents: text)
        XCTAssertEqual(CrashReport.read(url, home: home)?.what, "EXC_BREAKPOINT in mimic + 812345")
    }

    func testEachCrashIsOfferedOnce() throws {
        let dir = try folder(), d = defaults(), now = Date()
        d.set(now.addingTimeInterval(-3600), forKey: CrashReport.seenKey)
        try crash("mimic-2026-09-30-101500.ips", in: dir, ago: 60, now: now)
        XCTAssertEqual(CrashReport.check(in: dir, defaults: d, now: now, home: home)?.file.lastPathComponent, "mimic-2026-09-30-101500.ips")
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home), "offered again")

        // Two since the last look: the newest is offered, and both are seen.
        try crash("Mimic-2026-09-30-111500.ips", in: dir, ago: 20, now: now)
        try crash("mimic-2026-09-30-121500.000.ips", in: dir, ago: 10, now: now)
        XCTAssertEqual(CrashReport.check(in: dir, defaults: d, now: now, home: home)?.file.lastPathComponent, "mimic-2026-09-30-121500.000.ips")
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home))
    }

    /// Nothing seen yet: a first launch with this, or after Reset. Old crashes aren't dug up.
    func testTheFirstLookOnlyOffersARecentCrash() throws {
        let dir = try folder(), d = defaults(), now = Date()
        try crash("mimic-2026-09-01-101500.ips", in: dir, ago: 3 * 86400, now: now)
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home), "a crash from days ago was offered")
        try crash("mimic-2026-09-30-101500.ips", in: dir, ago: 3600, now: now)
        XCTAssertNotNil(CrashReport.check(in: dir, defaults: d, now: now, home: home), "this morning's crash wasn't offered")
        XCTAssertNotNil(d.object(forKey: CrashReport.seenKey))
    }

    func testDontAskAgainOffersNothing() throws {
        let dir = try folder(), d = defaults(), now = Date()
        d.set(true, forKey: CrashReport.dontAskKey)
        try crash("mimic-2026-09-30-101500.ips", in: dir, ago: 60, now: now)
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home))
    }

    /// The helpers' crashes show as failed jobs; hang reports have no crashing thread.
    func testOnlyMimicsOwnCrashesAreOffered() throws {
        let dir = try folder(), d = defaults(), now = Date()
        d.set(now.addingTimeInterval(-3600), forKey: CrashReport.seenKey)
        for name in ["trellis-cli-2026-09-30-101500.ips", "draw-things-cli-2026-09-30-101500.ips", "Godot-2026-09-30-101500.ips"] {
            try crash(name, in: dir, ago: 60, now: now)
        }
        try crash("mimic-2026-09-30-101501.ips", in: dir, ago: 30, now: now,
                  contents: #"{"app_name":"mimic","bug_type":"288","name":"mimic"}"# + "\n{\"procName\": \"mimic\"}\n")
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home))
        let other = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: #""name":"mimic""#, with: #""name":"trellis-cli""#)
            .replacingOccurrences(of: #""app_name":"mimic""#, with: #""app_name":"trellis-cli""#)
        try crash("mimic-2026-09-30-101502.ips", in: dir, ago: 10, now: now, contents: other)
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home), "another program's report under Mimic's name")
    }

    /// Print prep and the 3D step are this binary too (`mimic _prep`, `mimic _engine`), run by a
    /// job: their crash is a failed job, not Mimic quitting (#319). A report doesn't say which
    /// arguments it ran with, so they're told apart by what started them: Mimic, or Mimic that
    /// has already gone. The app's own crash, older, is still offered.
    func testAJobStepsCrashIsNotOffered() throws {
        let dir = try folder(), d = defaults(), now = Date()
        d.set(now.addingTimeInterval(-3600), forKey: CrashReport.seenKey)
        let text = try String(contentsOf: fixture, encoding: .utf8)
        func startedBy(_ parent: String) -> String {
            text.replacingOccurrences(of: #""parentProc": "launchd""#, with: #""parentProc": "\#(parent)""#)
        }
        XCTAssertNotEqual(startedBy("mimic"), text, "the fixture's parent moved")
        try crash("mimic-2026-09-30-101500.ips", in: dir, ago: 60, now: now)
        try crash("mimic-2026-09-30-101600.ips", in: dir, ago: 30, now: now, contents: startedBy("mimic"))
        try crash("mimic-2026-09-30-101700.ips", in: dir, ago: 10, now: now, contents: startedBy("Exited process"))
        XCTAssertEqual(CrashReport.check(in: dir, defaults: d, now: now, home: home)?.file.lastPathComponent, "mimic-2026-09-30-101500.ips",
                       "a job step's crash was offered as Mimic's")
        XCTAssertNil(CrashReport.check(in: dir, defaults: d, now: now, home: home), "offered again")
        // Run by hand in Terminal (as `mimic _prep` can be), there's no job to show it: offered.
        let byHand = try crash("mimic-2026-09-30-101800.ips", in: dir, ago: 0, now: now, contents: startedBy("zsh"))
        XCTAssertNotNil(CrashReport.read(byHand, home: home))
    }

    func testTheZipHasTheCrashAndTheLogFromBeforeIt() throws {
        let c = try XCTUnwrap(CrashReport.read(fixture, home: home))
        let dir = try folder()
        let zip = try CrashReport.write(c, to: dir, build: "Mimic 0.11.1 · build 420 · abc1234", mac: "Mac14,9, Apple M2 Pro, 32 GB, macOS 26.6",
                                        appLog: "10:14:58 [queue] Started /Users/alice/x\n", home: home)
        func run(_ tool: String, _ args: [String]) throws -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let names = try run("/usr/bin/zipinfo", ["-1", zip.path]).split(separator: "\n").filter { !$0.hasSuffix("/") }
            .map { $0.split(separator: "/").last.map(String.init) ?? "" }
        // ditto keeps each file's extended attributes as a ._ file beside it.
        XCTAssertEqual(Set(names.filter { !$0.hasPrefix("._") }), ["about.txt", "app.log", "crash.json"])
        XCTAssertEqual(try run("/usr/bin/unzip", ["-p", zip.path, "*/crash.json"]), c.trimmed)
        XCTAssertEqual(try run("/usr/bin/unzip", ["-p", zip.path, "*/app.log"]), "10:14:58 [queue] Started ~/x\n")
    }

    func testTheIssueHasTheCrashAndAsksWhatWasHappening() throws {
        let c = try XCTUnwrap(CrashReport.read(fixture, home: home))
        let url = CrashReport.issueURL(c, build: "Mimic 0.11.1 · build 420 · abc1234", mac: "Mac14,9, Apple M2 Pro, 32 GB, macOS 26.6")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(comps.fragment, "the # in the frame cut the link short")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["template"], "bug.yml")
        XCTAssertEqual(q["version"], "Mimic 0.11.1 · build 420 · abc1234")
        XCTAssertEqual(q["title"], c.title)
        let what = try XCTUnwrap(q["what"])
        XCTAssertTrue(what.contains("version 0.11.0 (build 412)"), what)
        XCTAssertTrue(what.contains("closure #1 in JobRunner.run(_:)"), what)
        XCTAssertTrue(what.contains("There's no screenshot"), what)
        XCTAssertTrue(what.hasSuffix("What I was doing when it quit: "), what)
        XCTAssertTrue(q["logs"]?.contains("Drag it into this box") == true)

        // A saved key in what crashed goes from the title and the question too (#352).
        let key = "0f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b"
        let keyed = Crash(file: c.file, date: c.date, what: "Fatal error: \(key)", version: c.version, trimmed: c.trimmed,
                          pid: nil, launched: nil, crashed: nil)
        let link = CrashReport.issueURL(keyed, build: "b", mac: "m", saved: [key]).absoluteString
        XCTAssertFalse(link.contains(key), "the saved key is in the issue")
        XCTAssertTrue(link.contains(Report.newIssue.absoluteString))
    }

    /// The setup as it is now (#283): in the zip as setup.txt and in the issue's Anything else.
    func testTheReportHasTheSetup() throws {
        let c = try XCTUnwrap(CrashReport.read(fixture, home: home))
        let setup = ReportSetup(model: "TRELLIS.2", engineVersion: "pixal3d.cpp d1b4926 in /Users/alice/engine", gpu: "Apple M2 Pro")
        let zip = try CrashReport.write(c, to: try folder(), build: "b", mac: "m", appLog: nil, setup: setup, home: home)
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", zip.path, "*/setup.txt"]
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertTrue(text.contains("Engine: TRELLIS.2, pixal3d.cpp d1b4926 in ~/engine\n"), text)
        let url = CrashReport.issueURL(c, build: "b", mac: "m", setup: setup, home: home)
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let more = try XCTUnwrap(q["more"])
        XCTAssertTrue(more.contains("- GPU: Apple M2 Pro"), more)
        XCTAssertFalse(more.contains("alice"), more)
        XCTAssertEqual(q["title"], c.title, "the crash's own fields stay")
    }

    /// The crashed launch's log is asked of `log show` by its pid, from its launch (at most an
    /// hour before the crash) to just after the crash. Nothing back, a failure or no answer in
    /// time is no log, not a hang.
    func testTheCrashedLaunchsLogIsAskedForByPid() throws {
        let c = try XCTUnwrap(CrashReport.read(fixture, home: home))
        let crashed = try XCTUnwrap(c.crashed)
        let asked = Asked()
        let line = #"{"timestamp":"2026-09-30 10:14:58.123456+0200","category":"queue","eventMessage":"Started raven"}"#
        let answers: [(status: Int32, output: String)?] = [(0, line), (0, ""), (1, line), nil]
        for (i, answer) in answers.enumerated() {
            let log = CrashReport.appLog(c, subsystem: "com.example") { tool, args, timeout in
                asked.add(tool, args, timeout)
                return answer
            }
            XCTAssertEqual(log, i == 0 ? "10:14:58 [queue] Started raven\n" : nil, "answer \(i)")
        }
        let (tool, args, timeout) = try XCTUnwrap(asked.first)
        XCTAssertEqual(tool, "/usr/bin/log")
        XCTAssertTrue((1...120).contains(timeout), "a stuck log would hang the report: \(timeout) s")
        XCTAssertEqual(args.first, "show")
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value("--style"), "ndjson")
        XCTAssertEqual(value("--predicate"), #"processID == 4242 AND subsystem == "com.example""#)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let start = try XCTUnwrap(value("--start").flatMap(f.date(from:))), end = try XCTUnwrap(value("--end").flatMap(f.date(from:)))
        XCTAssertEqual(end.timeIntervalSince1970, (crashed.timeIntervalSince1970 + 1).rounded(.down), accuracy: 1)
        let launched = try XCTUnwrap(c.launched)
        XCTAssertEqual(start.timeIntervalSince1970, max(launched, crashed.addingTimeInterval(-3600)).timeIntervalSince1970.rounded(.down), accuracy: 1)

        let noPid = Crash(file: c.file, date: c.date, what: c.what, version: c.version, trimmed: c.trimmed, pid: nil,
                          launched: c.launched, crashed: c.crashed)
        XCTAssertNil(CrashReport.appLog(noPid) { _, _, _ in XCTFail("asked without a pid"); return nil })
        XCTAssertEqual(CrashReport.folder.path, fm.homeDirectoryForCurrentUser.path + "/Library/Logs/DiagnosticReports")
    }

    func testTheMacsLogReadsLikeTheAppLog() {
        let ndjson = """
        {"timestamp":"2026-09-30 10:14:58.123456+0200","category":"queue","eventMessage":"Started raven","processID":4242}
        {"timestamp":"2026-09-30 10:14:59.000001+0200","category":"shown","eventMessage":"Couldn't reach Draw Things","processID":4242}
        {"count":2,"finished":1}
        """
        XCTAssertEqual(CrashReport.lines(ndjson: ndjson), "10:14:58 [queue] Started raven\n10:14:59 [shown] Couldn't reach Draw Things\n")
    }
}

/// What a runner was asked to run.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(String, [String], TimeInterval)] = []
    func add(_ tool: String, _ args: [String], _ timeout: TimeInterval) { lock.withLock { all.append((tool, args, timeout)) } }
    var first: (String, [String], TimeInterval)? { lock.withLock { all.first } }
}
