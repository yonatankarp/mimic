import OSLog
import XCTest
@testable import MimicCore

/// Report a Problem (#100): the zip, what's scrubbed from it, and the issue it opens.
final class ReportTests: XCTestCase {
    let fm = FileManager.default
    let home = "/Users/alice"
    let key = "sk-ant-api03-PLANTEDfakeKEY0123456789abcdefXYZ"

    /// A raven that didn't finish, with its logs, settings and picture. Its job log has the
    /// key in it, the way a program that prints its request would, and the home folder.
    func failedRaven(_ fx: Fixture) throws -> Mini {
        let d = try fx.mini("raven")
        try fm.removeItem(at: d.appendingPathComponent("raven.stl"))
        try "[1/3] Getting the picture ready\nPOST x-api-key: \(key)\nreading /Users/alice/Documents/Mimic/raven/source.png\n"
            .write(to: d.appendingPathComponent("generate.job.log"), atomically: true, encoding: .utf8)
        try "Authorization: Bearer abcdefghijklmnop1234\nengine at /Users/alice/Library/Application Support/Mimic/engine\n"
            .write(to: d.appendingPathComponent("pixal3d.log"), atomically: true, encoding: .utf8)
        try "mini_prep: done\n".write(to: d.appendingPathComponent("prep.log"), atomically: true, encoding: .utf8)
        try MiniSettings.update(d) { s in s.desc = "a raven"; s.failed = "Step 2 failed: /Users/alice/x" }
        return try XCTUnwrap(Gallery.list(fx.install.runs).first { $0.name == "raven" })
    }

    /// Unzips `zip` and returns its folder, and every file in it by path.
    func unzip(_ zip: URL) throws -> (URL, [String: Data]) {
        let out = fm.temporaryDirectory.appendingPathComponent("unzip-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let top = try XCTUnwrap(try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first)
        var files: [String: Data] = [:]
        let walk = try XCTUnwrap(fm.enumerator(atPath: top.path))
        while let f = walk.nextObject() as? String {
            var dir: ObjCBool = false
            if fm.fileExists(atPath: top.appendingPathComponent(f).path, isDirectory: &dir), !dir.boolValue {
                files[f] = fm.contents(atPath: top.appendingPathComponent(f).path)
            }
        }
        return (top, files)
    }

    func testAPlantedKeyAndTheHomeFolderAreScrubbedFromTheZip() throws {
        let fx = try Fixture()
        let raven = try failedRaven(fx)
        let zip = try Report.write(to: fx.root.appendingPathComponent("reports"), mini: raven, picture: false,
                                   build: "Mimic 0.9.0 · build 300 · abc1234", mac: "Mac14,6, Apple M2 Max, 32 GB, macOS 26.0",
                                   appLog: "12:00:00 [shown] Couldn't reach \(key) in /Users/alice/Documents\n", home: home)
        let (_, files) = try unzip(zip)
        XCTAssertEqual(Set(files.keys), ["about.txt", "app.log", "mini/generate.job.log", "mini/pixal3d.log", "mini/prep.log", "mini/settings.json"])
        let all = files.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertFalse(all.contains("PLANTEDfakeKEY"), "the key is in the report")
        XCTAssertFalse(all.contains("abcdefghijklmnop1234"), "the bearer token is in the report")
        XCTAssertFalse(all.contains("alice"), "the home folder is in the report")
        let job = String(decoding: try XCTUnwrap(files["mini/generate.job.log"]), as: UTF8.self)
        XCTAssertTrue(job.contains("reading ~/Documents/Mimic/raven/source.png"), job)
        XCTAssertTrue(job.contains("[1/3] Getting the picture ready"), "the rest of the log went too")
        let about = String(decoding: try XCTUnwrap(files["about.txt"]), as: UTF8.self)
        XCTAssertTrue(about.contains("Mimic 0.9.0 · build 300 · abc1234"))
        XCTAssertTrue(about.contains("Apple M2 Max"))
        XCTAssertTrue(about.contains("Picture: left out"))
    }

    func testThePictureIsOnlyIncludedWhenAskedFor() throws {
        let fx = try Fixture()
        let raven = try failedRaven(fx)
        let folder = fx.root.appendingPathComponent("reports")
        let without = try unzip(try Report.write(to: folder, mini: raven, picture: false, build: "b", mac: "m", appLog: nil, home: home)).1
        XCTAssertFalse(without.keys.contains { $0.contains("picture") }, "the picture went without being asked for")
        let with = try unzip(try Report.write(to: folder, mini: raven, picture: true, build: "b", mac: "m", appLog: nil,
                                              now: Date().addingTimeInterval(1), home: home)).1
        XCTAssertEqual(with["mini/picture.png"], Data("source.png".utf8))
        XCTAssertNil(with["mini/model.glb"], "only logs, settings and the picture")
        XCTAssertNil(with["mini/raven_front.png"])
        XCTAssertTrue(String(decoding: try XCTUnwrap(with["about.txt"]), as: UTF8.self).contains("The app's own log couldn't be read."))
    }

    /// Reports older than a week go when the next is made (#350): the folder may sync to iCloud.
    /// Anything else in it stays.
    func testMakingAReportClearsOutOnesOlderThanAWeek() throws {
        let fx = try Fixture()
        let folder = fx.root.appendingPathComponent("reports")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        func plant(_ name: String, daysOld: Double) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let old = try plant("mimic-report-2026-01-01-120000.zip", daysOld: 8)
        let recent = try plant("mimic-report-raven-2026-01-09-120000.zip", daysOld: 6)
        let notOurs = try plant("my notes.zip", daysOld: 30)
        let made = try Report.write(to: folder, mini: nil, picture: false, build: "b", mac: "m", appLog: nil, now: now, home: home)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "a report older than a week stayed")
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertTrue(fm.fileExists(atPath: notOurs.path), "only Mimic's reports are cleared out")
        XCTAssertTrue(fm.fileExists(atPath: made.path))
    }

    func testWithoutAMiniItHasTheBuildTheMacAndTheAppLog() throws {
        let fx = try Fixture()
        let (_, files) = try unzip(try Report.write(to: fx.root, mini: nil, picture: true, build: "b", mac: "m", appLog: "line\n", home: home))
        XCTAssertEqual(Set(files.keys), ["about.txt", "app.log"])
    }

    func testScrubbing() {
        XCTAssertEqual(Report.scrub("key sk-proj-abcdefghijklmnopqrstuv end", home: home), "key [key removed] end")
        XCTAssertEqual(Report.scrub("hf_ABCDEFGHIJKLMNOPQRSTUV", home: home), "[key removed]")
        XCTAssertEqual(Report.scrub(#"{"api_key": "hunter2hunter2"}"#, home: home), #"{"api_key": "[removed]"}"#)
        XCTAssertEqual(Report.scrub("password=letmein", home: home), "password=[removed]")
        XCTAssertEqual(Report.scrub("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENG", home: home), "AWS_SECRET_ACCESS_KEY=[removed]")
        XCTAssertEqual(Report.scrub("client_secret: abc123 refresh_token=xyz", home: home), "client_secret: [removed] refresh_token=[removed]")
        XCTAssertEqual(Report.scrub("/Users/alice/x and /Users/alice", home: home), "~/x and ~")
        XCTAssertEqual(Report.scrub(#"{"failed": "\/Users\/alice\/x"}"#, home: home), #"{"failed": "~\/x"}"#)
        XCTAssertEqual(Report.scrub("x-api-key: sk-ant-abcdefghijkl", home: home), "x-api-key: [key removed]")
        // Black Forest Labs' header (#352). Its keys have no documented shape to match on their own.
        XCTAssertEqual(Report.scrub("x-key: hunter2hunter2", home: home), "x-key: [removed]")
        XCTAssertEqual(Report.scrub(#"{"x-key":"hunter2hunter2"}"#, home: home), #"{"x-key":"[removed]"}"#)
        XCTAssertEqual(Report.scrub("/Users/alicebob/x", home: home), "/Users/alicebob/x", "another person's folder isn't this one")
        // What a job log says that isn't secret stays.
        for kept in ["max_tokens: 400", "task-1234567890abcdefghij", "seed 12345", "941a66c",
                     // A crash report's binary images are UUIDs, which reading the crash needs.
                     #""uuid":"1f2e3d4c-5b6a-4789-9abc-def012345678""#] {
            XCTAssertEqual(Report.scrub(kept, home: home), kept)
        }
    }

    func testTheIssueIsTheBugFormFilledIn() throws {
        let url = Report.issueURL(build: "Mimic 0.9.0 · build 300 · abc1234", mac: "Mac14,6, Apple M2 Max, 32 GB, macOS 26.0",
                                  failure: "Step 2 failed: sk-ant-api03-abcdefghijklmnop & /Users/alice/x", home: home)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "github.com")
        XCTAssertEqual(c.path, "/yonatankarp/mimic/issues/new")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["template"], "bug.yml")
        XCTAssertEqual(q["version"], "Mimic 0.9.0 · build 300 · abc1234")
        XCTAssertEqual(q["mac"], "Mac14,6, Apple M2 Max, 32 GB, macOS 26.0")
        XCTAssertTrue(q["logs"]?.contains("Drag it into this box") == true)
        let what = try XCTUnwrap(q["what"])
        XCTAssertTrue(what.contains("Step 2 failed: [key removed] & ~/x"), what)
        XCTAssertFalse(Report.issueURL(build: "b", mac: "m", failure: nil).absoluteString.contains("what="))
    }

    func testTheBugFormHasTheFieldsTheLinkFills() throws {
        let form = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../.github/ISSUE_TEMPLATE/bug.yml")
        let text = try String(contentsOf: form, encoding: .utf8)
        for id in ["what", "version", "mac", "logs", "more"] { XCTAssertTrue(text.contains("id: \(id)\n"), "bug.yml has no \(id) field") }
    }

    func testTheMacLine() {
        XCTAssertEqual(Report.macLine(model: "Mac14,6", chip: "Apple M2 Max", memory: 34_359_738_368,
                                      os: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)),
                       "Mac14,6, Apple M2 Max, 32 GB, macOS 26.0.1")
        XCTAssertTrue(Report.mac.contains("macOS"))
    }

    /// The question #100 asked: the app's own log, read back with no permission asked for.
    func testThisLaunchsLogCanBeReadBack() throws {
        let subsystem = "com.mimic.test.\(UUID().uuidString)"
        Logger(subsystem: subsystem, category: "queue").notice("Started \("raven", privacy: .public)")
        let text = try XCTUnwrap(Log.recent(since: Date().addingTimeInterval(-3600), subsystem: subsystem))
        XCTAssertTrue(text.contains("[queue] Started raven"), text)
    }
}
