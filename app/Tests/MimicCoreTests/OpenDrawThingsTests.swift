import AppKit
import XCTest
@testable import MimicCore

/// A stand-in Draw Things app, so no test ever opens or quits the real one. `installed: false`
/// (the default) can't be opened; opening an installed one runs `onOpen`, quitting it `onQuit`.
final class FakeApp: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (running: false, opens: 0, quits: 0)
    let installed: Bool
    var enabled = true
    var onOpen: @Sendable () -> Void = {}
    var onQuit: @Sendable () -> Void = {}

    init(installed: Bool = false, running: Bool = false) {
        self.installed = installed
        state.running = running
    }

    var running: Bool {
        get { lock.withLock { state.running } }
        set { lock.withLock { state.running = newValue } }
    }
    var opens: Int { lock.withLock { state.opens } }
    var quits: Int { lock.withLock { state.quits } }

    var app: DrawThingsApp {
        DrawThingsApp(enabled: { self.enabled }, running: { self.running }, open: {
            guard self.installed else { return nil }
            self.lock.withLock { self.state.opens += 1; self.state.running = true }
            self.onOpen()
            return .init(alive: { self.running }, quit: {
                self.lock.withLock { self.state.quits += 1; self.state.running = false }
                self.onQuit()
            })
        })
    }
}

final class OpenDrawThingsTests: XCTestCase {
    /// Both the model question and a drawing get their answer from one reply.
    static let reply = #"{"model":"flux_2_klein_4b_q8p.ckpt","images":["\#(Data("png".utf8).base64EncodedString())"]}"#

    var server: FakeDrawThings!
    override func setUpWithError() throws { server = try FakeDrawThings(body: Self.reply, ready: false) }
    override func tearDown() { server.stop() }

    /// A Draw Things whose API answers once it's opened, and stops when it's quit.
    func fake(installed: Bool = true, running: Bool = false) -> FakeApp {
        let app = FakeApp(installed: installed, running: running)
        let server = server!
        app.onOpen = { server.ready = true }
        app.onQuit = { server.ready = false }
        return app
    }

    func drawThings(_ app: FakeApp) -> DrawThings {
        DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:\(server.port)"], app: app.app, cli: nil)
    }

    func testOpensItWhenItIsNotAnswering() throws {
        let app = fake()
        var opening = false
        let opened = try drawThings(app).openIfNeeded(cap: 5, poll: 0.05, opening: { opening = true })
        XCTAssertNotNil(opened)
        XCTAssertEqual(app.opens, 1)
        XCTAssertTrue(opening, "the progress window wasn't told")
    }

    func testLeavesItAloneWhenItIsAnswering() throws {
        server.ready = true
        let app = fake(running: true)
        XCTAssertNil(try drawThings(app).openIfNeeded(cap: 5, poll: 0.05))
        XCTAssertEqual(app.opens, 0)
    }

    /// Open with its API server off: nothing to open, and it isn't Mimic's to quit. The drawing
    /// then fails with the message saying how to turn the API server on.
    func testNeverOpensOrQuitsOneThatIsAlreadyRunning() throws {
        let app = fake(running: true)
        XCTAssertNil(try drawThings(app).openIfNeeded(cap: 5, poll: 0.05))
        XCTAssertEqual(app.opens, 0)
        XCTAssertEqual(app.quits, 0)
    }

    func testRespectsTheSwitch() throws {
        let app = fake()
        app.enabled = false
        XCTAssertNil(try drawThings(app).openIfNeeded(cap: 5, poll: 0.05))
        XCTAssertEqual(app.opens, 0)
    }

    /// Opens but never answers: almost always its API server is off. Say how to turn it on, and
    /// quit what Mimic opened.
    func testGivesUpWithTheAPIServerStepsWhenItNeverAnswers() throws {
        let app = fake()
        app.onOpen = {}  // opens, never answers
        XCTAssertThrowsError(try drawThings(app).openIfNeeded(cap: 0.3, poll: 0.05)) {
            XCTAssertEqual($0 as? DrawThingsError, .apiOff)
            XCTAssertTrue(String(describing: $0).contains("API Server"))
        }
        XCTAssertEqual(app.quits, 1)
    }

    /// Bounded by the app being alive, not only by the clock: quit while opening ends the wait.
    func testStopsWaitingWhenTheAppExits() throws {
        let app = fake()
        app.onOpen = { app.running = false }  // quit as soon as it's opened, before it answers
        let started = Date()
        XCTAssertThrowsError(try drawThings(app).openIfNeeded(cap: 30, poll: 0.05)) {
            XCTAssertEqual($0 as? DrawThingsError, .closedWhileOpening)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: In a job

    func runner(_ app: FakeApp, _ fx: Fixture) -> JobRunner {
        JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), drawThings: drawThings(app), trash: { _ in })
    }

    func describe(_ jobs: JobRunner, _ fx: Fixture, _ name: String) throws {
        try jobs.make(name: name, picture: .description("a dwarf"), restyle: false, seed: 1, sizes: Sizes(), model: EngineDownload.standard)
    }

    /// Opened for the picture, quit once it's drawn; step 1 says it's opening meanwhile.
    func testAJobOpensItAndQuitsItAfter() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let app = fake()
        let jobs = runner(app, fx)
        let seen = Seen()
        jobs.onChange = { if $0.openingDrawThings { seen.opening = true } }
        try describe(jobs, fx, "dwarf")
        jobs.waitUntilDone()
        XCTAssertEqual(try Data(contentsOf: fx.install.runs.appendingPathComponent("dwarf/source.png")), Data("png".utf8))
        XCTAssertEqual(app.opens, 1)
        XCTAssertEqual(app.quits, 1, "Mimic opened it and left it open")
        XCTAssertFalse(app.running)
        XCTAssertTrue(seen.opening, "never said it was opening Draw Things")
    }

    func testAJobNeverQuitsOneThePersonOpened() throws {
        let fx = try Fixture(); try fx.modelFiles()
        server.ready = true
        let app = fake(running: true)
        let jobs = runner(app, fx)
        try describe(jobs, fx, "dwarf")
        jobs.waitUntilDone()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("dwarf/source.png").path))
        XCTAssertEqual(app.opens, 0)
        XCTAssertEqual(app.quits, 0)
        XCTAssertTrue(app.running)
    }

    /// The next job needs it too: left open between them, quit after the last.
    func testLeftOpenForTheNextJobThatNeedsIt() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let app = fake()
        let server = server!
        // Answers only once the second mini is queued, so it's queued before the first one's picture is drawn.
        app.onOpen = {}
        let jobs = runner(app, fx)
        try describe(jobs, fx, "first")
        XCTAssertTrue(eventually { app.opens == 1 }, "the first mini never opened it")
        XCTAssertEqual(try jobs.make(name: "second", picture: .description("an elf"), restyle: false, seed: 1, sizes: Sizes(),
                                     model: EngineDownload.standard), 1)
        server.ready = true
        jobs.waitUntilDone()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("second/source.png").path))
        XCTAssertEqual(app.opens, 1, "quit and opened again between two minis that both need it")
        XCTAssertEqual(app.quits, 1)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var opening: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// The real NSWorkspace, from a command-line process (as `mimic` in Terminal is), with the main
/// thread blocked. Only with MIMIC_LIVE_OPEN set: it opens and quits a real app. Draw Things
/// itself is only asked whether it runs; the open and quit are tried on Chess, so a Draw Things
/// someone is using is never touched.
final class LiveOpenTests: XCTestCase {
    func testTheRealLauncher() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MIMIC_LIVE_OPEN"] == nil, "opens a real app")
        let dt = DrawThings()
        if DrawThingsApp.mac.running() && dt.reachable() {
            XCTAssertNil(try dt.openIfNeeded(), "opened (and would quit) a Draw Things the person has open")
        }
        let chess = DrawThingsApp.workspace("com.apple.Chess")
        try XCTSkipIf(chess.running(), "Chess is open: not Mimic's to quit")
        let started = Date()
        let opened = try XCTUnwrap(chess.open())
        print("LIVE opened in \(Date().timeIntervalSince(started))s, running: \(chess.running())")
        XCTAssertTrue(opened.alive())
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.Chess", "took focus")
        opened.quit()
        for _ in 0..<100 where opened.alive() { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(opened.alive(), "didn't quit when asked")
    }
}
