import Foundation
import XCTest
@testable import MimicCore

/// Ported from tests/test_checks.py: the Settings health checks, proven in both directions.
/// A check that only ever showed green once hid a Mimic that wasn't running at all, so "green
/// on this Mac" proves nothing: each test builds its world from scratch in a temp folder, and
/// the checks really start the stand-in programs.
final class CheckTests: XCTestCase {
    static let ids = ["engine", "models", "blender", "space",
                      "drawthings-app", "drawthings-api", "drawthings-model", "slicer"]

    var f: Fixture!
    var apps: URL!, bin: URL!, home: URL!

    override func setUpWithError() throws {
        f = try Fixture()
        apps = f.root.appendingPathComponent("Applications")
        bin = f.root.appendingPathComponent("bin")
        home = f.root.appendingPathComponent("home")
        for d in [apps!, bin!, home!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// No DRAWTHINGS_MODEL: a pinned model name is taken on trust, which would keep the model
    /// check green with nothing downloaded. Port 9 (discard) refuses the connection.
    func checks(freeGB: Int64, drawThings: String = "http://127.0.0.1:9") -> Checks {
        Checks(install: f.install, appFolders: [apps],
               drawThings: DrawThings(environment: ["DRAWTHINGS_URL": drawThings], home: home),
               path: bin.path, freeBytes: { _ in freeGB * 1_000_000_000 })
    }

    func results(_ c: Checks) -> [String: Bool] {
        let got = Dictionary(uniqueKeysWithValues: c.all.map { ($0.id, $0.run().ok) })
        XCTAssertEqual(c.all.map(\.id), Self.ids, "a check was added or removed: update ids")
        return got
    }

    func executable(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testEverythingMissingIsRed() {
        let got = results(checks(freeGB: 1))
        XCTAssertEqual(Self.ids.filter { got[$0]! }, [], "these stayed green with nothing there")
    }

    func testEverythingPresentIsGreen() throws {
        try executable(f.install.trellisCLI, "exit 0")
        try version(EngineDownload.version)
        try modelFiles()
        try executable(bin.appendingPathComponent("blender"), "echo Blender 5.2.2")
        for a in ["Draw Things.app", "OrcaSlicer.app"] {
            try FileManager.default.createDirectory(at: apps.appendingPathComponent(a), withIntermediateDirectories: true)
        }
        let dtModels = home.appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")
        try FileManager.default.createDirectory(at: dtModels, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dtModels.appendingPathComponent("flux_2_klein_4b_q8p.ckpt").path, contents: Data("x".utf8))
        let server = try FakeDrawThings()
        defer { server.stop() }

        let got = results(checks(freeGB: 100, drawThings: "http://127.0.0.1:\(server.port)"))
        XCTAssertEqual(Self.ids.filter { !got[$0]! }, [], "these stayed red with everything there")
    }

    /// Homebrew's launcher outlives the app it points at: it exists, but can't start Blender.
    func testABlenderLauncherWhoseAppIsGoneIsRed() throws {
        try executable(bin.appendingPathComponent("blender"), #"exec "/Applications/Gone.app/Contents/MacOS/Blender" "$@""#)
        XCTAssertFalse(results(checks(freeGB: 100))["blender"]!)
    }

    /// Starting isn't enough either: it has to be Blender that answered.
    func testSomethingElseCalledBlenderIsRed() throws {
        try executable(bin.appendingPathComponent("blender"), "echo hello")
        XCTAssertFalse(results(checks(freeGB: 100))["blender"]!)
    }

    /// Present but broken, like a copy whose libraries went missing: exists is not enough.
    func testAnEngineThatDoesNotStartIsRed() throws {
        try executable(f.install.trellisCLI, "exit 1")
        try version(EngineDownload.version)
        XCTAssertFalse(results(checks(freeGB: 100))["engine"]!)
    }

    /// An older build starts but isn't the one Mimic pins: red, so Repair replaces it.
    func testAnotherEngineBuildIsRed() throws {
        try executable(f.install.trellisCLI, "exit 0")
        try version(EngineDownload.version)
        XCTAssertTrue(results(checks(freeGB: 100))["engine"]!)
        try version("pixal3d.cpp 0000000")
        XCTAssertFalse(results(checks(freeGB: 100))["engine"]!)
    }

    func version(_ v: String) throws {
        try "\(v) (abc), Metal\n".write(to: f.install.engine.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
    }

    /// Every model file, at its full size (sparse here, so 8.1 GB costs nothing): one missing,
    /// or one cut short by an interrupted download, is red.
    func modelFiles(except short: String? = nil) throws {
        try FileManager.default.createDirectory(at: f.install.models, withIntermediateDirectories: true)
        for m in EngineDownload.weights {
            let url = f.install.models.appendingPathComponent(m.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(m.name == short ? m.bytes - 1 : m.bytes))
            try h.close()
        }
    }

    func testModelFilesMustAllBeComplete() throws {
        try modelFiles()
        XCTAssertTrue(results(checks(freeGB: 100))["models"]!)
        try modelFiles(except: "tex_dec.gguf")
        XCTAssertFalse(results(checks(freeGB: 100))["models"]!, "a file cut short passed")
        try modelFiles()
        try FileManager.default.removeItem(at: f.install.models.appendingPathComponent("ss_dec.gguf"))
        XCTAssertFalse(results(checks(freeGB: 100))["models"]!, "a missing file passed")
    }

    /// A program that hangs is killed and reads as not starting, instead of hanging Settings.
    func testAHungProgramTimesOut() throws {
        let hang = f.root.appendingPathComponent("hang")
        try executable(hang, "exec sleep 30")
        let started = Date()
        XCTAssertNil(Checks.execute(hang.path, [], 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testFreeSpaceIsShownInTheLabel() {
        let space = checks(freeGB: 120).all.first { $0.id == "space" }!.run()
        XCTAssertEqual(space.label, "Free disk space (120 GB)")
        XCTAssertTrue(space.ok)
    }

    /// Picking the Mac's default app has to stick even when a slicer is installed; it used to
    /// fall back to the first slicer found.
    func testPickingTheMacsDefaultAppSticks() throws {
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("OrcaSlicer.app"), withIntermediateDirectories: true)
        let d = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(Slicer.preferred(defaults: d, in: [apps])?.id, "orca")
        d.set(Slicer.macDefault, forKey: "slicer")
        XCTAssertNil(Slicer.preferred(defaults: d, in: [apps]))
    }
}

/// Answers every request with 200 and `body`, like Draw Things' API server.
final class FakeDrawThings: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16

    init(body: String = "{}") throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
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
        Thread.detachNewThread {
            while case let c = accept(fd, nil, nil), c >= 0 {
                var buf = [UInt8](repeating: 0, count: 4096)
                _ = read(c, &buf, buf.count)
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}
