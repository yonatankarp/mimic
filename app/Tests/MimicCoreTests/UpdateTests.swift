import CryptoKit
import XCTest
@testable import MimicCore

final class UpdateTests: XCTestCase {
    /// `releases/latest` as GitHub sent it for 0.4.2, trimmed to the fields that matter.
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/release-latest.json")

    static func release(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Release {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        edit(&json)
        return try JSONDecoder().decode(Release.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testReadsTheRealReleaseResponse() throws {
        let r = try Self.release()
        XCTAssertEqual(r.tag, "v0.4.2")
        XCTAssertEqual(r.version?.description, "0.4.2")
        XCTAssertFalse(r.prerelease)
        XCTAssertEqual(r.dmg?.name, "Mimic-0.4.2.dmg")
        XCTAssertEqual(r.dmg?.size, 3_815_881)
        XCTAssertEqual(r.dmg?.url.absoluteString, "https://github.com/yonatankarp/mimic/releases/download/v0.4.2/Mimic-0.4.2.dmg")
        XCTAssertEqual(r.sums?.name, "SHA256SUMS")
        XCTAssertTrue(r.notes.contains("### New"))
    }

    func testVersions() {
        XCTAssertLessThan(AppVersion("0.4.2")!, AppVersion("0.5.0")!)
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!, "numbers, not text")
        XCTAssertLessThan(AppVersion("0.4.9")!, AppVersion("1.0.0")!)
        XCTAssertEqual(AppVersion("0.4.2"), AppVersion(tag: "v0.4.2"))
        for dev in ["dev", "0.4.2-3-gabc1234", "0.4.2-dirty", "0.4.2-3-gabc1234-dirty", "941a66c", "0.4", "0.4.2.1", "v0.4.2", "", "0.4.x", "0..2", "99999999999999999999.0.0", "0.-1.2", "0.+1.2"] {
            XCTAssertNil(AppVersion(dev), "\(dev) is a development build, not a release")
        }
        XCTAssertNil(AppVersion(tag: "pixal3d-d1b4926"), "the engine's pre-release is no version")
        XCTAssertNil(AppVersion(tag: "0.4.2"), "release tags start with v")
    }

    func testOffersOnlyANewerFinishedRelease() throws {
        let latest = try Self.release()
        XCTAssertEqual(Updates.offer(current: "0.4.1", latest: latest), latest)
        XCTAssertEqual(Updates.offer(current: "0.3.9", latest: latest), latest)
        XCTAssertNil(Updates.offer(current: "0.4.2", latest: latest), "already has it")
        XCTAssertNil(Updates.offer(current: "0.5.0", latest: latest), "newer than the release")
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: latest, skipped: "0.4.2"), "skipped")
        XCTAssertEqual(Updates.offer(current: "0.4.1", latest: latest, skipped: "0.4.1"), latest, "an older skip doesn't hide a newer one")
        for dev in ["dev", "0.4.1-3-gabc1234", "0.4.1-dirty"] {
            XCTAssertNil(Updates.offer(current: dev, latest: latest), "a development build (\(dev)) never updates itself")
        }
        let engine = try Self.release { $0["tag_name"] = "pixal3d-d1b4926"; $0["prerelease"] = true }
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: engine), "the engine's download is not an update")
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: try Self.release { $0["prerelease"] = true }), "a pre-release, even one named like a release")
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: try Self.release { $0["draft"] = true }), "draft")
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: try Self.release { $0["tag_name"] = "0.4.2" }), "not a vX.Y.Z tag")
        let noSums = try Self.release { $0["assets"] = ($0["assets"] as! [[String: Any]]).filter { $0["name"] as? String != "SHA256SUMS" } }
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: noSums), "nothing to check the download against")
        let otherDmg = try Self.release { $0["tag_name"] = "v0.4.3" }
        XCTAssertNil(Updates.offer(current: "0.4.1", latest: otherDmg), "its disk image must be Mimic-<its version>.dmg")
    }

    func testChecksAtMostOnceADay() {
        let now = Date()
        XCTAssertTrue(Updates.due(lastTried: nil, now: now), "never checked")
        XCTAssertFalse(Updates.due(lastTried: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(Updates.due(lastTried: now.addingTimeInterval(-Updates.interval + 60), now: now))
        XCTAssertTrue(Updates.due(lastTried: now.addingTimeInterval(-Updates.interval), now: now))
        XCTAssertTrue(Updates.due(lastTried: now.addingTimeInterval(3600), now: now), "a clock set back doesn't stop checks for good")
    }

    func testNeverWhileBusy() {
        XCTAssertFalse(Updates.busy(running: false, waiting: 0, settingUp: false))
        XCTAssertTrue(Updates.busy(running: true, waiting: 0, settingUp: false), "a mini being made")
        XCTAssertTrue(Updates.busy(running: false, waiting: 2, settingUp: false), "minis waiting")
        XCTAssertTrue(Updates.busy(running: false, waiting: 0, settingUp: true), "the engine downloading")
    }

    func testReadsSHA256SUMS() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let sums = Updates.parseSums("\(a)  Mimic-0.4.2.dmg\n\(b) *SHA256SUMS\nnot a line\n\("c")  short\n")
        XCTAssertEqual(sums, ["Mimic-0.4.2.dmg": a, "SHA256SUMS": b.lowercased()])
        // The real file, as the release workflow wrote it.
        XCTAssertEqual(Updates.parseSums("1913d00f5e58031a870344956e1a881aa760a169e8cd5aa812e56eb72aebf1e0  Mimic-0.4.2.dmg\n"),
                       ["Mimic-0.4.2.dmg": "1913d00f5e58031a870344956e1a881aa760a169e8cd5aa812e56eb72aebf1e0"])
    }

    // MARK: Downloading, against a local server

    private func served(dmg: Data, sums: String) throws -> (FileServer, Release) {
        let server = try FileServer(["/Mimic-0.4.2.dmg": dmg, "/SHA256SUMS": Data(sums.utf8)])
        let base = "http://127.0.0.1:\(server.port)"
        let release = try Self.release {
            $0["assets"] = [["name": "Mimic-0.4.2.dmg", "size": dmg.count, "browser_download_url": "\(base)/Mimic-0.4.2.dmg"],
                            ["name": "SHA256SUMS", "size": 82, "browser_download_url": "\(base)/SHA256SUMS"]]
        }
        return (server, release)
    }

    private func tmp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDownloadsAndChecksTheDiskImage() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let (server, release) = try served(dmg: body, sums: "\(SetupTests.sha(body))  Mimic-0.4.2.dmg\n")
        defer { server.stop() }
        let dir = try tmp()
        let file = try await Updates.download(release, into: dir, version: "0.4.1") { _ in }
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testRefusesADiskImageThatDoesntMatchItsChecksum() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let (server, release) = try served(dmg: body, sums: "\(String(repeating: "0", count: 64))  Mimic-0.4.2.dmg\n")
        defer { server.stop() }
        let dir = try tmp()
        do {
            _ = try await Updates.download(release, into: dir, version: "0.4.1") { _ in }
            XCTFail("a disk image that doesn't match its checksum was accepted")
        } catch {
            XCTAssertEqual(error as? UpdateError, .wrongApp("it came down damaged"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("Mimic") }, [], "the bad download is deleted")
    }

    func testRefusesADiskImageMissingFromSHA256SUMS() async throws {
        let body = Data("dmg".utf8)
        let (server, release) = try served(dmg: body, sums: "\(SetupTests.sha(body))  Mimic-0.4.1.dmg\n")
        defer { server.stop() }
        do {
            _ = try await Updates.download(release, into: try tmp(), version: "0.4.1") { _ in }
            XCTFail("a disk image with no checksum was accepted")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notListed("Mimic-0.4.2.dmg"))
        }
        XCTAssertEqual(server.log.map(\.path), ["/SHA256SUMS"], "nothing downloaded without a checksum to check it against")
    }

    // MARK: Installing, with a pretend Mimic in a real disk image

    /// A tiny signed app bundle: what `Updates.check` looks at.
    private func fakeApp(at url: URL, version: String, id: String = Updates.bundleID) throws {
        let macos = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("mimic").path)
        let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "mimic", "CFBundlePackageType": "APPL"]
        plist.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try Updates.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }

    private func dmg(holding version: String, id: String = Updates.bundleID, in dir: URL) throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(version)")
        try fakeApp(at: stage.appendingPathComponent("Mimic.app"), version: version, id: id)
        let dmg = dir.appendingPathComponent("Mimic-\(version).dmg")
        try Updates.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Mimic", "-srcfolder", stage.path, "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path])
        return dmg
    }

    private func version(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func testReplacesTheAppWithTheOneInTheDiskImage() throws {
        let dir = try tmp()
        let apps = dir.appendingPathComponent("Applications")
        let app = apps.appendingPathComponent("Mimic.app")
        try fakeApp(at: app, version: "0.4.1")
        XCTAssertTrue(Updates.canReplace(app))
        let staged = try Updates.stage(dmg: try dmg(holding: "0.4.2", in: dir), beside: app, version: AppVersion("0.4.2")!)
        XCTAssertEqual(staged.deletingLastPathComponent().path, apps.path, "staged beside the app, so the swap is a rename")
        try Updates.swap(staged, into: app)
        XCTAssertEqual(version(app), "0.4.2", "the new app is in place")
        XCTAssertEqual(version(staged), "0.4.1", "the old one is aside, to remove after the relaunch")
    }

    func testRefusesAnAppThatIsntTheRelease() throws {
        let dir = try tmp()
        let app = dir.appendingPathComponent("Applications/Mimic.app")
        try fakeApp(at: app, version: "0.4.1")
        XCTAssertThrowsError(try Updates.stage(dmg: try dmg(holding: "0.4.3", in: dir), beside: app, version: AppVersion("0.4.2")!)) {
            XCTAssertEqual($0 as? UpdateError, .wrongApp("it's version 0.4.3, not 0.4.2"))
        }
        XCTAssertThrowsError(try Updates.stage(dmg: try dmg(holding: "0.4.4", id: "com.example.other", in: dir), beside: app, version: AppVersion("0.4.4")!)) {
            XCTAssertEqual($0 as? UpdateError, .wrongApp("it isn't Mimic"))
        }
        // A signature broken after signing.
        let broken = dir.appendingPathComponent("broken/Mimic.app")
        try fakeApp(at: broken, version: "0.4.2")
        try Data("changed".utf8).write(to: broken.appendingPathComponent("Contents/MacOS/mimic"))
        XCTAssertThrowsError(try Updates.check(broken, version: AppVersion("0.4.2")!)) {
            XCTAssertEqual($0 as? UpdateError, .wrongApp("it has been changed since it was made"))
        }
        XCTAssertEqual(version(app), "0.4.1", "the app is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path), ["Mimic.app"], "nothing left staged")
    }

    func testCantReplaceWhereItCantWrite() throws {
        let dir = try tmp()
        let apps = dir.appendingPathComponent("Applications")
        let app = apps.appendingPathComponent("Mimic.app")
        try fakeApp(at: app, version: "0.4.1")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
        XCTAssertFalse(Updates.canReplace(app))
        XCTAssertThrowsError(try Updates.stage(dmg: try dmg(holding: "0.4.2", in: dir), beside: app, version: AppVersion("0.4.2")!)) {
            XCTAssertEqual($0 as? UpdateError, .notWritable(apps.path))
        }
        XCTAssertFalse(Updates.canReplace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Mimic.app")))
        XCTAssertFalse(Updates.canReplace(URL(fileURLWithPath: "/Volumes/Mimic/Mimic.app")))
    }
}
