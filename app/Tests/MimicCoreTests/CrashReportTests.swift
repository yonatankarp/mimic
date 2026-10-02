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
