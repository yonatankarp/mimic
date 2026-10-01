import XCTest
@testable import MimicCore

/// A make that stops once its picture is made, for the person to check it before the slow 3D
/// step (#156): Build Shape carries on from it, Try Again draws it again, and the queue moves on
/// meanwhile.
final class CheckPictureTests: XCTestCase {
    let sizes = Sizes(height: "32", nozzle: "0.4")
    let fm = FileManager.default

    /// It stops after the picture, made but not finished, and the next job in the queue runs.
    func testItStopsOnceThePictureIsMade() throws {
        let fx = try Fixture(); try fx.modelFiles()
        _ = try fx.mini("other")
        let picture = try fx.picture()
        // Step 2 would fail: it must not run.
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        try jobs.setPaused(true)
        try jobs.make(name: "knight", picture: .image(picture), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      checkPicture: true)
        let d = try XCTUnwrap(Gallery.folder(fx.install.runs, "knight"))
        XCTAssertEqual(jobs.estimate("knight", .generate, history: [], waiting: true).steps.keys.sorted(), [.picture],
                       "it's done once its picture is")
        try jobs.resize(name: "other", sizes: sizes)
        let seen = SidePictureTests.Seen()
        jobs.onChange = { if !$0.running { seen.add($0) } }
        try jobs.setPaused(false)
        jobs.waitUntilDone()

        let ended = try XCTUnwrap(seen.all.first { $0.name == "knight" })
        XCTAssertEqual(ended.outcome, .pictureReady)
        XCTAssertFalse(ended.succeeded, "not ready to print")
        XCTAssertEqual(seen.all.last?.name, "other", "the queue moved on to the next job")
        let s = MiniSettings.load(d)
        XCTAssertNil(s.made, "only the picture is made")
        XCTAssertNil(s.failed)
        XCTAssertEqual(s.checkPicture, true)
        XCTAssertTrue(fm.fileExists(atPath: d.appendingPathComponent("source.png").path))
        XCTAssertTrue(Pipeline.pictureToCheck(d, settings: s))
        XCTAssertEqual(jobs.queue.entries(), [], "it waits for the person, not in the queue")
        XCTAssertEqual(MiniNotification.text(ended, who: "Knight"),
                       .init(title: "Check the picture of Knight", body: "Build its 3D shape when it looks right.", category: MiniNotification.picture))
    }

    /// Build Shape is Try Again: the picture is there, so it goes on from the 3D shape, to the end.
    func testBuildShapeCarriesOn() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"), trash: { _ in })
        let d = try checking(fx, jobs)
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: MiniSettings.load(d), tools: fx.tools()).map(\.number), [.shape, .print])
        try jobs.retry(name: "knight")
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.outcome, .finished)
        XCTAssertEqual(MiniSettings.load(d).made, sizes)
    }

    /// Stopped while it builds the shape, it waits to be checked again, with its picture.
    func testStoppingBuildShapeKeepsThePicture() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let started = fx.root.appendingPathComponent("started").path
        let fake = try fx.script("fake-mimic", """
            if [ "$1" = _engine ]; then echo half > "$3"; touch \(started); sleep 60 & wait; fi
            """)
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: fake), trash: { spy($0) })
        let d = try checking(fx, jobs)
        try jobs.retry(name: "knight")
        for _ in 0..<100 where !fm.fileExists(atPath: started) { usleep(50_000) }
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(spy.trashed, [], "stopping Build Shape threw the mini away")
        XCTAssertTrue(Pipeline.pictureToCheck(d, settings: MiniSettings.load(d)), "back to its picture, to check")
    }

    /// Try Again draws the picture again with a new number, and stops again once it's made.
    func testTryAgainDrawsThePictureAgain() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        let d = try checking(fx, jobs)
        try jobs.setPaused(true)
        try jobs.redrawPicture(name: "knight", seed: 99)
        XCTAssertEqual(MiniSettings.load(d).seed, 99)
        XCTAssertFalse(fm.fileExists(atPath: d.appendingPathComponent("source.png").path), "drawn again, not kept")
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["knight"])
        XCTAssertThrowsError(try jobs.redrawPicture(name: "knight")) {
            XCTAssertEqual($0 as? RequestError, .noPictureToCheck("knight"), "its picture isn't made yet")
        }
        try jobs.setPaused(false)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.outcome, .pictureReady)
        XCTAssertTrue(Pipeline.pictureToCheck(d, settings: MiniSettings.load(d)))

        // A mini that doesn't stop for its picture has none to draw again.
        _ = try fx.mini("done")
        XCTAssertThrowsError(try jobs.redrawPicture(name: "done")) { XCTAssertEqual($0 as? RequestError, .noPictureToCheck("done")) }
    }

    /// A make that wasn't asked to stop runs straight through, as before.
    func testOnlyWhenAsked() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"), trash: { _ in })
        try jobs.make(name: "knight", picture: .image(try fx.picture()), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.outcome, .finished)
        XCTAssertNil(MiniSettings.load(try XCTUnwrap(Gallery.folder(fx.install.runs, "knight"))).checkPicture)
    }

    /// The knight, made as far as its picture and waiting to be checked.
    private func checking(_ fx: Fixture, _ jobs: JobRunner) throws -> URL {
        try jobs.make(name: "knight", picture: .image(try fx.picture()), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      checkPicture: true)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.outcome, .pictureReady)
        return try XCTUnwrap(Gallery.folder(fx.install.runs, "knight"))
    }
}
