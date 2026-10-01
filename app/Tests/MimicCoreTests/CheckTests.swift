import Foundation
import XCTest
@testable import MimicCore

/// Ported from tests/test_checks.py: the Settings health checks, proven in both directions.
/// A check that only ever showed green once hid a Mimic that wasn't running at all, so "green
/// on this Mac" proves nothing: each test builds its world from scratch in a temp folder, and
/// the checks really start the stand-in programs.
final class CheckTests: XCTestCase {
    static let ids = ["engine", "models", "space",
                      "drawthings-app", "drawthings-api", "drawthings-model", "slicer"]

    var f: Fixture!
    var apps: URL!, home: URL!

    override func setUpWithError() throws {
        f = try Fixture()
        apps = f.root.appendingPathComponent("Applications")
        home = f.root.appendingPathComponent("home")
        for d in [apps!, home!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// No DRAWTHINGS_MODEL: a pinned model name is taken on trust, which would keep the model
    /// check green with nothing downloaded. Port 9 (discard) refuses the connection.
    func checks(freeGB: Int64, drawThings: String = "http://127.0.0.1:9", model: EngineModel = EngineDownload.standard,
                autoOpen: Bool = false, cli: String? = nil) -> Checks {
        Checks(install: f.install, model: model, appFolders: [apps],
               drawThings: DrawThings(environment: ["DRAWTHINGS_URL": drawThings], home: home, cli: cli), autoOpen: autoOpen,
               freeBytes: { _ in freeGB * 1_000_000_000 })
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

    /// Closed is fine when Mimic opens Draw Things itself: informative, not red. Only when it's
    /// installed, and only with the switch on.
    func testDrawThingsClosedIsFineWhenMimicOpensIt() throws {
        let api = { (c: Checks) in c.all.first { $0.id == "drawthings-api" }!.run() }
        XCTAssertFalse(api(checks(freeGB: 100, autoOpen: true)).ok, "not installed, yet it would open")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Draw Things.app"), withIntermediateDirectories: true)
        let closed = api(checks(freeGB: 100, autoOpen: true))
        XCTAssertTrue(closed.ok)
        XCTAssertEqual(closed.label, Checks.opensWhenNeeded)
        XCTAssertFalse(api(checks(freeGB: 100, autoOpen: false)).ok, "switched off, closed still passed")
        let server = try FakeDrawThings()
        defer { server.stop() }
        XCTAssertEqual(api(checks(freeGB: 100, drawThings: "http://127.0.0.1:\(server.port)", autoOpen: true)).label,
                       "Draw Things is open and connected")
    }

    /// With draw-things-cli, neither the app nor its API server is needed.
    func testTheCommandLineToolIsEnough() {
        let c = checks(freeGB: 100, cli: "/usr/bin/true")
        let got = Dictionary(uniqueKeysWithValues: c.all.map { ($0.id, $0.run()) })
        XCTAssertTrue(got["drawthings-api"]!.ok)
        XCTAssertEqual(got["drawthings-api"]!.label, Checks.commandLine)
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

    /// Every model file, at its full size: one missing, or one cut short by an interrupted
    /// download, is red.
    func modelFiles(short: String? = nil) throws { try f.modelFiles(short: short) }

    func testModelFilesMustAllBeComplete() throws {
        try modelFiles()
        XCTAssertTrue(results(checks(freeGB: 100))["models"]!)
        try modelFiles(short: "tex_dec.gguf")
        XCTAssertFalse(results(checks(freeGB: 100))["models"]!, "a file cut short passed")
        try modelFiles()
        try FileManager.default.removeItem(at: EngineDownload.standard.folder(in: f.install).appendingPathComponent("ss_dec.gguf"))
        XCTAssertFalse(results(checks(freeGB: 100))["models"]!, "a missing file passed")
    }

    /// The models check is about the model in use: another model's complete set doesn't make it
    /// green, and its own set does, whatever else is missing.
    func testTheModelsCheckFollowsTheModelInUse() throws {
        let other = try XCTUnwrap(EngineDownload.catalogue.last)
        try XCTSkipIf(other == EngineDownload.standard, "only one model ships")
        try f.modelFiles()
        XCTAssertFalse(results(checks(freeGB: 100, model: other))["models"]!, "the standard set counted for another model")
        try f.modelFiles(other)
        XCTAssertTrue(results(checks(freeGB: 100, model: other))["models"]!)
        try FileManager.default.removeItem(at: EngineDownload.standard.folder(in: f.install))
        XCTAssertTrue(results(checks(freeGB: 100, model: other))["models"]!, "a model not in use was required")
        XCTAssertFalse(results(checks(freeGB: 100))["models"]!)
        XCTAssertTrue(checks(freeGB: 100, model: other).all[1].label.contains(other.name), "the check doesn't say which model")
    }

    /// A program that hangs is killed and reads as not starting, instead of hanging Settings.
    func testAHungProgramTimesOut() throws {
        let hang = f.root.appendingPathComponent("hang")
        try executable(hang, "exec sleep 30")
        let started = Date()
        XCTAssertNil(Checks.execute(hang.path, [], 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// One that ignores SIGTERM is killed too.
    func testAProgramIgnoringStopTimesOut() throws {
        let hang = f.root.appendingPathComponent("stubborn")
        try executable(hang, "trap '' TERM; exec sleep 30")
        let started = Date()
        XCTAssertNil(Checks.execute(hang.path, [], 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A program that finishes but leaves something running with its output open still
    /// answers, once the time is up.
    func testSomethingLeftHoldingTheOutputDoesNotHang() throws {
        let pidFile = f.root.appendingPathComponent("left.pid")
        let leaves = f.root.appendingPathComponent("leaves")
        try executable(leaves, "sleep 30 & echo $! > \(pidFile.path); echo ok")
        defer {
            let pid = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid.flatMap({ pid_t($0) }) { kill(pid, SIGKILL) }
        }
        let started = Date()
        let result = Checks.execute(leaves.path, [], 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.output, "ok\n")
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

/// Answers every request with 200 and `body`, like Draw Things' API server. While not `ready`
/// it hangs up without answering, like Draw Things opening, or open with its API server off.
final class FakeDrawThings: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var isReady: Bool
    var ready: Bool {
        get { lock.withLock { isReady } }
        set { lock.withLock { isReady = newValue } }
    }

    init(body: String = "{}", ready: Bool = true) throws {
        isReady = ready
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
        Thread.detachNewThread { [self] in
            while case let c = accept(fd, nil, nil), c >= 0 {
                guard self.ready else { close(c); continue }
                Self.readRequest(c)
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }

    /// All of it, body included: replying and closing with a request body unread resets the
    /// connection, and the client sees no reply.
    static func readRequest(_ c: Int32) {
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &buf, buf.count)
            if n <= 0 { return }
            got += buf[0..<n]
            let text = String(decoding: got, as: UTF8.self)
            guard let end = text.range(of: "\r\n\r\n") else { continue }
            let length = text[..<end.lowerBound].split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if got.count >= text[..<end.upperBound].utf8.count + length { return }
        }
    }
}
