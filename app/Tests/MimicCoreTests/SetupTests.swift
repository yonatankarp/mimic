import Foundation
import XCTest
@testable import MimicCore

/// First-launch setup: the pinned manifest, where things live, moving an old install, and the
/// downloads, which run against a local server that logs what it was asked for. A resume that
/// quietly downloaded the whole file again would still end with the right sha256, so the tests
/// check the Range requests and the bytes served, not just the result.
final class SetupTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: The manifest

    func testEveryPinnedFileHasAURLASizeAndASha256() {
        XCTAssertEqual(EngineDownload.standard.id, "trellis2-q8", "the standard model is TRELLIS.2")
        XCTAssertEqual(Set(EngineDownload.catalogue.map(\.id)).count, EngineDownload.catalogue.count, "two models share an id")
        XCTAssertEqual(Set(EngineDownload.catalogue.map(\.name)).count, EngineDownload.catalogue.count, "two models share a name")
        var shaOwner: [String: (name: String, bytes: Int64)] = [:]
        for m in EngineDownload.catalogue {
            XCTAssertNotNil(m.id.wholeMatch(of: /[a-z0-9-]+/), "\(m.id): ids are folder names and command-line words")
            XCTAssertFalse(m.summary.isEmpty, m.id)
            let all = [EngineDownload.engine] + m.files
            for f in all {
                XCTAssertEqual(f.url.scheme, "https", f.name)
                XCTAssertEqual(f.url.host, f == EngineDownload.engine ? "github.com" : "huggingface.co", f.name)
                if f != EngineDownload.engine {
                    XCTAssertNotNil(f.url.path.wholeMatch(of: /.*\/resolve\/[0-9a-f]{40}\/.+/), "\(f.name) isn't pinned to a revision")
                }
                XCTAssertEqual(f.url.lastPathComponent, f.name, "\(f.name) downloads from a URL named otherwise")
                XCTAssertGreaterThan(f.bytes, 0, f.name)
                XCTAssertNotNil(f.sha256.wholeMatch(of: /[0-9a-f]{64}/), "\(f.name): not a sha256")
                // The same bytes may appear in two models (that's what setup copies), but never
                // under two names or two sizes: that would be a pasted hash.
                if let seen = shaOwner[f.sha256] {
                    XCTAssertEqual(seen.name, f.name, "\(m.id): \(f.name) has the sha256 of \(seen.name)")
                    XCTAssertEqual(seen.bytes, f.bytes, f.name)
                }
                shaOwner[f.sha256] = (f.name, f.bytes)
            }
            XCTAssertEqual(Set(all.map(\.name)).count, all.count, "\(m.id): a file is listed twice")
            XCTAssertEqual(Set(all.map(\.sha256)).count, all.count, "\(m.id): two files share a sha256: one was pasted twice")
            XCTAssertTrue(m.files.contains { $0.name == "DINOV3_LICENSE.md" }, "\(m.id): DINOv3's licence must travel with dinov3.gguf")
            XCTAssertEqual(m.weights.count, 9, "\(m.id): trellis-cli loads nine model files")
        }
        XCTAssertEqual(Checks.gigabytes(EngineDownload.totalBytes(EngineDownload.standard)), "9.3", "the standard set is 9.3 GB")
        XCTAssertEqual(Checks.gigabytes(EngineDownload.totalBytes(EngineDownload.model("pixal3d-sv")!)), "8.3", "the Pixal3D set is 8.3 GB")
    }

    // MARK: Where things live

    func testAMimicFolderHoldsEverything() {
        let i = Install(root: dir)
        XCTAssertEqual(i.runs, dir.appendingPathComponent("runs").standardizedFileURL)
        XCTAssertEqual(EngineDownload.standard.folder(in: i), dir.appendingPathComponent("engine/models/trellis2-q8").standardizedFileURL)
        XCTAssertEqual(EngineDownload.model("pixal3d-sv")!.folder(in: i), dir.appendingPathComponent("engine/models/pixal3d-sv").standardizedFileURL)
        XCTAssertEqual(i.legacyLab, dir.appendingPathComponent("image-to-3dlab").standardizedFileURL)
    }

    func testANewMacKeepsMinisInDocumentsAndTheEngineInApplicationSupport() {
        let i = Install.standard(home: dir)
        XCTAssertEqual(i.runs.path, dir.appendingPathComponent("Documents/Mimic").path)
        XCTAssertEqual(i.engine.path, dir.appendingPathComponent("Library/Application Support/Mimic/engine").path)
        XCTAssertNil(i.legacyLab)
    }

    func testLocateOrder() throws {
        let home = dir.appendingPathComponent("home"), old = dir.appendingPathComponent("old"), dev = dir.appendingPathComponent("dev")
        for d in [old, dev] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let suite = "mimic-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func locate(_ env: [String: String]) -> Install { Install.locate(environment: env, defaults: defaults, home: home) }

        XCTAssertEqual(locate([:]), .standard(home: home), "nothing set: the standard layout")
        defaults.set(old.path, forKey: "installDir")
        let inOld = locate([:]), oldFolder = Install(root: old)
        XCTAssertEqual([inOld.runs, inOld.engine, inOld.legacyLab], [oldFolder.runs, oldFolder.engine, oldFolder.legacyLab],
                       "the old installer's folder is still used")
        XCTAssertEqual(inOld.queue, Install.queueFolder(oldFolder.runs, home: home), "but its queue is on this Mac, not in that folder")
        XCTAssertEqual(locate(["MIMIC_HOME": dev.path]), Install(root: dev), "MIMIC_HOME wins")
        XCTAssertEqual(locate(["MIMIC_FAKE_HOME": "/tmp/fake"]), .standard(home: URL(fileURLWithPath: "/tmp/fake")),
                       "a fake home is a new Mac: installDir must not leak into it")
        try FileManager.default.removeItem(at: old)
        XCTAssertEqual(locate([:]), .standard(home: home), "a Mimic folder that's gone falls back to the standard layout")
        XCTAssertEqual(locate(["MIMIC_HOME": old.path]), .standard(home: home))
    }

    /// The folder chosen in Settings (#102) holds the minis, in the standard layout and the old
    /// installer's alike, while it's there; a development Mimic's own folder still wins.
    func testTheChosenMinisFolderIsUsed() throws {
        let home = dir.appendingPathComponent("home"), chosen = dir.appendingPathComponent("chosen"), old = dir.appendingPathComponent("old")
        let dev = dir.appendingPathComponent("dev")
        for d in [chosen, old, dev] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let suite = "mimic-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func locate(_ env: [String: String] = [:]) -> Install { Install.locate(environment: env, defaults: defaults, home: home) }

        defaults.set(chosen.path, forKey: MinisFolder.key)
        // By path: a folder's URL made once it exists ends in a slash.
        XCTAssertEqual(locate().runs.path, chosen.path)
        XCTAssertEqual(locate().queue, Install.standard(home: home, runs: chosen).queue)
        XCTAssertEqual(locate().engine, Install.standard(home: home).engine, "the engine stays where it is")
        defaults.set(old.path, forKey: "installDir")
        XCTAssertEqual(locate().runs.path, chosen.path, "chosen over the old installer's folder")
        XCTAssertEqual(locate().engine, Install(root: old).engine)
        XCTAssertEqual(locate(["MIMIC_HOME": dev.path]), Install(root: dev), "MIMIC_HOME wins")
        XCTAssertEqual(locate(["MIMIC_FAKE_HOME": "/tmp/fake"]), .standard(home: URL(fileURLWithPath: "/tmp/fake")),
                       "a fake home is a new Mac: the chosen folder must not leak into it")
        XCTAssertTrue(Install.minisFolderIsFixed(environment: ["MIMIC_HOME": dev.path]))
        XCTAssertTrue(Install.minisFolderIsFixed(environment: ["MIMIC_FAKE_HOME": "/tmp/fake"]))
        XCTAssertFalse(Install.minisFolderIsFixed(environment: [:]))
        defaults.removeObject(forKey: "installDir")
        try FileManager.default.removeItem(at: chosen)
        XCTAssertEqual(locate(), .standard(home: home), "a chosen folder that's gone falls back to the standard one")
    }

    /// The queue is never in the minis folder (#102), which iCloud may share between Macs: it's
    /// on this Mac, one per minis folder, so Mimics using one folder share a queue (the app and
    /// `mimic` in Terminal, which read the same settings) and Mimics using two never do.
    func testTheQueueIsOnThisMacOnePerMinisFolder() {
        let home = dir.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support/Mimic").standardizedFileURL.path
        let standard = Install.standard(home: home)
        XCTAssertTrue(standard.queue.path.hasPrefix(support + "/"), standard.queue.path)
        XCTAssertFalse(standard.queue.path.hasPrefix(standard.runs.path + "/"), "the queue is in the minis folder")
        XCTAssertEqual(Install.standard(home: home).queue, standard.queue, "the same folder, the same queue")
        let elsewhere = Install.standard(home: home, runs: dir.appendingPathComponent("elsewhere"))
        XCTAssertNotEqual(elsewhere.queue, standard.queue, "two minis folders share one queue")
        let p = dir.appendingPathComponent("elsewhere").path
        XCTAssertEqual(Install.queueFolder(URL(fileURLWithPath: p, isDirectory: true), home: home),
                       Install.queueFolder(URL(fileURLWithPath: p, isDirectory: false), home: home),
                       "a folder made since (its URL ends in a slash) has another queue")
        let fake = Install.standard(home: dir.appendingPathComponent("fake"))
        XCTAssertTrue(fake.queue.path.hasPrefix(dir.appendingPathComponent("fake").standardizedFileURL.path + "/"),
                      "a fake home's queue must stay inside it")
        XCTAssertEqual(Install(root: dir).queue, dir.appendingPathComponent("queue").standardizedFileURL,
                       "a Mimic folder (MIMIC_HOME, tests) keeps its queue inside it")
    }

    // MARK: Downloading one file

    func testAStoppedDownloadCarriesOnFromWhereItStopped() async throws {
        let body = Self.bytes(3_000_000)
        let server = try FileServer(["/big": body], cutAfter: ["/big": 1_000_000])
        defer { server.stop() }
        let file = server.file("/big", body)
        let dest = dir.appendingPathComponent("big")
        let setup = setup(Install(root: dir))

        do {
            try await setup.fetch(file, to: dest) { _ in }
            XCTFail("the cut connection didn't stop it")
        } catch {}
        // What survives the cut depends on how much the Mac had received when the connection
        // dropped (all of it here; 16 KB on a slower CI runner), so resuming is judged against
        // what was kept, not against what the server sent.
        let part = URL(fileURLWithPath: dest.path + ".part")
        let kept = EngineDownload.size(part) ?? 0
        XCTAssert(kept > 0 && kept <= 1_000_000, "the partial file wasn't kept (\(kept) bytes)")

        try await setup.fetch(file, to: dest) { _ in }
        XCTAssertEqual(EngineDownload.sha256(dest), file.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(server.log.map(\.range), [nil, "bytes=\(kept)-"], "the second request didn't resume")
        XCTAssertEqual(Int64(server.served), 1_000_000 + (3_000_000 - kept), "more than the remainder was downloaded")
    }

    func testAServerThatIgnoresRangeStartsTheFileOver() async throws {
        let body = Self.bytes(100_000)
        let server = try FileServer(["/f": body], ignoreRange: true)
        defer { server.stop() }
        let dest = dir.appendingPathComponent("f")
        try Data(body.prefix(40_000)).write(to: URL(fileURLWithPath: dest.path + ".part"))
        try await setup(Install(root: dir)).fetch(server.file("/f", body), to: dest) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), body, "a 200 was appended to the partial file")
    }

    func testAWrongFileIsReplacedAndARightOneKept() async throws {
        let body = Self.bytes(50_000)
        let server = try FileServer(["/f": body])
        defer { server.stop() }
        let dest = dir.appendingPathComponent("f"), file = server.file("/f", body)
        try Data(repeating: 7, count: body.count).write(to: dest)  // right size, wrong bytes
        try await setup(Install(root: dir)).fetch(file, to: dest) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), body)
        XCTAssertEqual(server.log.count, 1)

        try await setup(Install(root: dir)).fetch(file, to: dest) { _ in }
        XCTAssertEqual(server.log.count, 1, "a file already right was downloaded again")
    }

    func testAFullLengthWrongPartIsThrownAway() async throws {
        let body = Self.bytes(50_000)
        let server = try FileServer(["/f": body])
        defer { server.stop() }
        let dest = dir.appendingPathComponent("f")
        try Data(repeating: 1, count: body.count).write(to: URL(fileURLWithPath: dest.path + ".part"))
        try await setup(Install(root: dir)).fetch(server.file("/f", body), to: dest) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), body)
        XCTAssertEqual(server.log.map(\.range), [nil], "it tried to resume a part that was already full length")
    }

    func testADamagedDownloadIsRefusedAndNotKept() async throws {
        let body = Self.bytes(50_000)
        let server = try FileServer(["/f": Data(repeating: 9, count: body.count)])
        defer { server.stop() }
        let dest = dir.appendingPathComponent("f")
        do {
            try await setup(Install(root: dir)).fetch(server.file("/f", body), to: dest) { _ in }
            XCTFail("a file with the wrong sha256 was accepted")
        } catch {
            XCTAssertEqual(error as? SetupError, .damaged("f"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".part"), "Try Again would resume a damaged file")
    }

    func testNoServerIsOffline() async throws {
        let body = Self.bytes(10)
        let file = EngineFile(name: "f", url: URL(string: "http://127.0.0.1:9/f")!, bytes: 10, sha256: Self.sha(body))
        do {
            try await setup(Install(root: dir)).fetch(file, to: dir.appendingPathComponent("f")) { _ in }
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SetupError, .offline)
        }
    }

    // MARK: The whole setup

    func testFirstLaunchDownloadsAndUnpacksEverything() async throws {
        let (tarball, models) = try fakeEngine()
        let cli = Data("#!/bin/sh\nexit 0\n".utf8)
        let server = try FileServer(["/engine.tar.gz": tarball, "/a.gguf": models[0], "/b.json": models[1], "/draw-things-cli": cli])
        defer { server.stop() }
        let install = Install.standard(home: dir.appendingPathComponent("home"))
        var setup = setup(install)
        setup.engineFile = server.file("/engine.tar.gz", tarball)
        setup.drawThingsCLI = server.file("/draw-things-cli", cli)
        setup.model.files = [server.file("/a.gguf", models[0]), server.file("/b.json", models[1])]

        let seen = ProgressLog()
        try await setup.run { seen.add($0) }
        XCTAssertTrue(setup.engineReady(), "the engine didn't unpack into place, or doesn't start")
        XCTAssertEqual(DrawThings.findCLI(install), install.drawThingsCLI.path, "Draw Things' command line tool isn't there, or won't run")
        XCTAssertEqual(try Data(contentsOf: EngineDownload.standard.folder(in: install).appendingPathComponent("a.gguf")), models[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.engine.appendingPathComponent("engine.tar.gz").path),
                       "the tarball was left behind")
        XCTAssertEqual(seen.last?.done, seen.last?.total, "progress didn't reach the end")

        server.log.removeAll()
        try await setup.run { _ in }
        XCTAssertEqual(server.log.count, 0, "a second run downloaded again")
    }

    /// Another model downloads into its own folder, beside the standard one, and a file the two
    /// share byte for byte is copied from the one on disk rather than downloaded. Removing it
    /// frees only what's its own.
    func testAnotherModelDownloadsBesideAndReusesSharedFiles() async throws {
        let (tarball, models) = try fakeEngine()
        let own = Self.bytes(300_000)
        let server = try FileServer(["/engine.tar.gz": tarball, "/a.gguf": models[0], "/b.json": models[1], "/c.gguf": own])
        defer { server.stop() }
        let install = Install.standard(home: dir.appendingPathComponent("home"))
        var first = setup(install)
        first.engineFile = server.file("/engine.tar.gz", tarball)
        first.model.files = [server.file("/a.gguf", models[0]), server.file("/b.json", models[1])]
        try await first.run { _ in }

        let other = EngineModel(id: "other", name: "Other", summary: "test", family: .trellis2,
                                files: [server.file("/a.gguf", models[0]), server.file("/c.gguf", own)])
        var second = first
        second.model = other
        second.catalogue = [first.model, other]
        server.log.removeAll()
        try await second.run { _ in }
        XCTAssertEqual(server.log.map(\.path), ["/c.gguf"], "a file already on disk was downloaded again")
        let folder = install.engine.appendingPathComponent("models/other")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a.gguf")), models[0])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("c.gguf")), own)
        XCTAssertTrue(other.complete(in: install))
        XCTAssertTrue(first.model.complete(in: install), "the first model's files were moved, not copied")

        XCTAssertEqual(EngineDownload.freed(by: other, in: install, catalogue: second.catalogue), Int64(own.count),
                       "the shared file frees nothing while its twin stays")
        try FileManager.default.removeItem(at: first.model.folder(in: install))
        XCTAssertEqual(EngineDownload.freed(by: other, in: install, catalogue: second.catalogue), Int64(own.count + models[0].count))
    }

    func testTooLittleSpaceStopsBeforeDownloading() async throws {
        let (tarball, models) = try fakeEngine()
        let server = try FileServer(["/engine.tar.gz": tarball, "/a.gguf": models[0]])
        defer { server.stop() }
        var setup = setup(Install.standard(home: dir))
        setup.engineFile = server.file("/engine.tar.gz", tarball)
        setup.model.files = [server.file("/a.gguf", models[0])]
        setup.freeBytes = { _ in 100_000_000 }
        do { try await setup.run { _ in }; XCTFail() } catch {
            guard case .diskFull? = error as? SetupError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(server.log.count, 0)
    }

    /// An old install moves its engine out of image-to-3dlab without downloading anything, then
    /// checks every moved file: a damaged one, and only that, is downloaded again.
    func testAnOldInstallIsMovedNotDownloaded() async throws {
        let (tarball, models) = try fakeEngine()
        let server = try FileServer(["/engine.tar.gz": tarball, "/a.gguf": models[0], "/b.json": models[1]])
        defer { server.stop() }
        let root = dir.appendingPathComponent("Mimic")
        let install = Install(root: root)
        let old = root.appendingPathComponent("image-to-3dlab/vendor/pixal3d-cpp")
        let build = old.appendingPathComponent("build"), oldModels = old.appendingPathComponent("models/pixal3d-sv")
        for d in [build, oldModels] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Self.script(build.appendingPathComponent("trellis-cli"))
        try "pixal3d.cpp test1 (abc), Metal\n".write(to: build.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: build.appendingPathComponent("libggml.0.dylib").path, contents: Data("lib".utf8))
        try FileManager.default.createSymbolicLink(atPath: build.appendingPathComponent("libggml.dylib").path, withDestinationPath: "libggml.0.dylib")
        FileManager.default.createFile(atPath: build.appendingPathComponent("CMakeCache.txt").path, contents: Data())
        try models[0].write(to: oldModels.appendingPathComponent("a.gguf"))
        try Data("damaged".utf8).write(to: oldModels.appendingPathComponent("b.json"))

        var setup = setup(install)
        setup.engineFile = server.file("/engine.tar.gz", tarball)
        setup.model.files = [server.file("/a.gguf", models[0]), server.file("/b.json", models[1])]
        try await setup.run { _ in }

        XCTAssertEqual(server.log.map(\.path), ["/b.json"], "only the damaged file should be downloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("image-to-3dlab").path), "image-to-3dlab is still there")
        XCTAssertTrue(setup.engineReady())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: install.engine.appendingPathComponent("libggml.dylib").path),
                       "libggml.0.dylib")
        XCTAssertEqual(try Data(contentsOf: EngineDownload.standard.folder(in: install).appendingPathComponent("a.gguf")), models[0])
        XCTAssertEqual(try Data(contentsOf: EngineDownload.standard.folder(in: install).appendingPathComponent("b.json")), models[1])
    }

    func testAnOldEngineOfAnotherBuildIsDownloadedFresh() async throws {
        let (tarball, models) = try fakeEngine()
        let server = try FileServer(["/engine.tar.gz": tarball, "/a.gguf": models[0]])
        defer { server.stop() }
        let root = dir.appendingPathComponent("Mimic")
        let build = root.appendingPathComponent("image-to-3dlab/vendor/pixal3d-cpp/build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Self.script(build.appendingPathComponent("trellis-cli"))
        try "pixal3d.cpp old999 (abc)\n".write(to: build.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        var setup = setup(Install(root: root))
        setup.engineFile = server.file("/engine.tar.gz", tarball)
        setup.model.files = [server.file("/a.gguf", models[0])]
        try await setup.run { _ in }
        XCTAssertEqual(server.log.map(\.path), ["/engine.tar.gz", "/a.gguf"])
        XCTAssertTrue(setup.engineReady())
    }

    /// The real downloads, but only the small ones: the engine and the licences, never the
    /// 8 GB of weights. `MIMIC_NETWORK_TEST=<folder>` runs it (and leaves the folder, a new
    /// Mac's home with the engine in it, for looking at the setup screen with MIMIC_FAKE_HOME).
    func testRealDownloadOfTheSmallFiles() async throws {
        guard let path = ProcessInfo.processInfo.environment["MIMIC_NETWORK_TEST"] else { throw XCTSkip("set MIMIC_NETWORK_TEST=<folder>") }
        var setup = EngineSetup(install: .standard(home: URL(fileURLWithPath: path)))
        setup.model.files = EngineDownload.standard.files.filter { $0.bytes < 1_000_000 }
        setup.drawThingsCLI = nil
        XCTAssertEqual(setup.model.files.count, 6)
        try await setup.run { _ in }
        XCTAssertTrue(setup.engineReady(), "the real engine didn't unpack or doesn't start")
        for f in setup.model.files {
            XCTAssertEqual(EngineDownload.sha256(EngineDownload.standard.folder(in: setup.install).appendingPathComponent(f.name)), f.sha256, f.name)
        }
    }

    // MARK: Helpers

    func setup(_ install: Install) -> EngineSetup {
        var s = EngineSetup(install: install)
        s.session = URLSession(configuration: .ephemeral)
        s.version = "pixal3d.cpp test1"
        s.freeBytes = { _ in 1_000_000_000_000 }
        s.drawThingsCLI = nil
        return s
    }

    /// A tarball shaped like the real one (one top folder, a trellis-cli that starts, VERSION),
    /// and two model files.
    func fakeEngine() throws -> (Data, [Data]) {
        let src = dir.appendingPathComponent("src/pixal3d")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Self.script(src.appendingPathComponent("trellis-cli"))
        try "pixal3d.cpp test1 (abc), Metal\n".write(to: src.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        let tgz = dir.appendingPathComponent("engine.tar.gz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", tgz.path, "-C", src.deletingLastPathComponent().path, "pixal3d"]
        try p.run()
        p.waitUntilExit()
        return (try Data(contentsOf: tgz), [Self.bytes(200_000), Data("{\"models\": true}".utf8)])
    }

    static func script(_ url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func bytes(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }) }

    static func sha(_ d: Data) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! d.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return EngineDownload.sha256(url)!
    }
    /// Every file Mimic downloads is still where it's pinned, at the size it's pinned at. A
    /// release deleted by hand (the engine's was, on 2026-09-29) breaks every new install and
    /// nothing else notices, so CI runs this once a day and before each release.
    /// `MIMIC_CHECK_DOWNLOADS=1` runs it; it asks for each file's size, downloading nothing.
    func testEveryPinnedDownloadIsReachable() async throws {
        guard ProcessInfo.processInfo.environment["MIMIC_CHECK_DOWNLOADS"] != nil else { throw XCTSkip("set MIMIC_CHECK_DOWNLOADS=1") }
        var files = [EngineDownload.engine, EngineDownload.drawThingsCLI]
        for model in EngineDownload.catalogue { files += model.files }
        var seen = Set<URL>()
        for file in files where seen.insert(file.url).inserted {
            var request = URLRequest(url: file.url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 60
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse, file.name)
            XCTAssertEqual(http.statusCode, 200, "\(file.name) is gone from \(file.url)")
            if http.statusCode == 200, http.expectedContentLength > 0 {
                XCTAssertEqual(http.expectedContentLength, file.bytes, "\(file.name) changed size")
            }
        }
    }

}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SetupProgress] = []
    func add(_ p: SetupProgress) { lock.withLock { items.append(p) } }
    var last: SetupProgress? { lock.withLock { items.last } }
}

/// A local HTTP server for downloads that honours Range (unless told not to), can cut a
/// response short the first time, and logs every request and every byte it sent.
final class FileServer: @unchecked Sendable {
    struct Request: Equatable { let path: String; let range: String? }
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var requests: [Request] = []
    private var sent = 0
    var log: [Request] {
        get { lock.withLock { requests } }
        set { lock.withLock { requests = newValue } }
    }
    var served: Int { lock.withLock { sent } }

    init(_ files: [String: Data], ignoreRange: Bool = false, cutAfter: [String: Int] = [:]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in
            var cuts = cutAfter  // the server thread's own: nothing else touches it
            while case let c = accept(fd, nil, nil), c >= 0 {
                var nosig: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                var head = Data(), buf = [UInt8](repeating: 0, count: 4096)
                while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    head.append(contentsOf: buf[0..<n])
                }
                let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
                let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                lock.withLock { requests.append(Request(path: path, range: range)) }
                var status = "200 OK", body = files[path] ?? Data(), extra = ""
                if files[path] == nil { status = "404 Not Found" }
                if let range, !ignoreRange, let start = Int(range.dropFirst(6).dropLast()) {
                    if start >= body.count {
                        status = "416 Range Not Satisfiable"; body = Data()
                    } else {
                        extra = "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n"
                        status = "206 Partial Content"; body = body.subdata(in: start..<body.count)
                    }
                }
                var reply = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n".utf8)
                let cut = cuts.removeValue(forKey: path)
                if let cut { body = body.prefix(cut) }
                reply.append(body)
                // A cut download trickles out in small chunks first, like a real one over the
                // internet: sent in one burst with the close, URLSession reports the lost
                // connection without ever handing over the data (seen on the CI runner).
                let chunk = cut == nil ? reply.count : 64 * 1024
                let written = reply.withUnsafeBytes { p -> Int in
                    var off = 0
                    while off < p.count {
                        let n = write(c, p.baseAddress! + off, min(chunk, p.count - off)); if n <= 0 { break }; off += n
                        if cut != nil { usleep(2_000) }
                    }
                    return off
                }
                lock.withLock { sent += max(0, written - (reply.count - body.count)) }
                // A gentle close: stop sending, let the client read what was sent, then close.
                // Closing at once can reset the connection, and a reset throws away whatever the
                // client hadn't read yet: on a slow CI runner, all of a cut download's bytes.
                shutdown(c, SHUT_WR)
                var wait = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                var drain = [UInt8](repeating: 0, count: 4096)
                while read(c, &drain, drain.count) > 0 {}
                close(c)
            }
        }
    }

    func file(_ path: String, _ body: Data) -> EngineFile {
        EngineFile(name: String(path.dropFirst()), url: URL(string: "http://127.0.0.1:\(port)\(path)")!,
                   bytes: Int64(body.count), sha256: SetupTests.sha(body))
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}
