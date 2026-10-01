import XCTest
@testable import MimicCore

/// A mini from pictures of the front and of its back and sides (#66): each made in step 1 like
/// the front, all given to TRELLIS.2's multi-image mode, and kept for making it again.
final class SidePictureTests: XCTestCase {
    let sizes = Sizes(height: "100", base: "40", nozzle: "0.4")
    let fm = FileManager.default

    /// Every picture gets the front's step 1 and the engine gets all of them; a picture already
    /// made is skipped on its own, so a make stopped mid-way keeps the ones it finished.
    func testEachPictureIsMadeLikeTheFrontAndAllGoToTheEngine() throws {
        let fx = try Fixture()
        let d = fx.install.runs.appendingPathComponent("mini")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let tools = fx.tools(mimic: "/app/mimic")
        var s = MiniSettings()
        s.source = .image; s.restyle = true; s.seed = 7; s.requested = sizes; s.model = "trellis2-q8"; s.sides = [.back, .left]
        func file(_ n: String) -> URL { d.appendingPathComponent(n) }
        // A mini without sides has exactly the plan it had before.
        var front = s
        front.sides = nil
        guard case .run(_, let one, _, _) = try Pipeline.plan(.generate, folder: d, settings: front, tools: tools)[1].step else { return XCTFail() }
        XCTAssertEqual(one, ["_engine", file("source.png").path, file("model.glb").path, "--seed", "7", "--engine", fx.install.engine.path,
                             "--model", "trellis2-q8"])

        let plan = try Pipeline.plan(.generate, folder: d, settings: s, tools: tools)
        XCTAssertEqual(plan.map(\.number), [1, 1, 1, 2, 3])
        XCTAssertEqual(plan.prefix(3).map(\.step), [.sculptPicture(from: file("upload.img"), seed: 7, to: file("source.png")),
                                                    .sculptPicture(from: file("upload-back.img"), seed: 7, to: file("source-back.png")),
                                                    .sculptPicture(from: file("upload-left.img"), seed: 7, to: file("source-left.png"))])
        guard case .run(_, let args, _, _) = plan[3].step else { return XCTFail("step 2 isn't the engine") }
        XCTAssertEqual(Array(args.suffix(4)), ["--back", file("source-back.png").path, "--left", file("source-left.png").path])
        s.restyle = false
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: s, tools: tools)[1].step,
                       .copyPicture(from: file("upload-back.img"), to: file("source-back.png")), "not made as the front is")

        // The front and the back made, the left not yet.
        for n in ["source.png", "source-back.png"] { fm.createFile(atPath: file(n).path, contents: Data([1])) }
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: s, tools: tools).map(\.step).first,
                       .copyPicture(from: file("upload-left.img"), to: file("source-left.png")))
        XCTAssertEqual(Pipeline.skipped(d, sides: [.back, .left]), [], "a picture still to make isn't skipped")
        XCTAssertEqual(Pipeline.skipped(d), [1], "one picture: as before")
        fm.createFile(atPath: file("source-left.png").path, contents: Data([1]))
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: s, tools: tools).map(\.number), [2, 3])
        fm.createFile(atPath: file("model.glb").path, contents: Data([1]))
        XCTAssertEqual(Pipeline.skipped(d, sides: [.back, .left]), [1, 2])
    }

    /// Make keeps each side's picture, tidied, in the mini's folder and says which it has; only a
    /// model with a multi-image mode, and only with a picture of the front.
    func testMakeKeepsThePicturesAndOnlyAModelThatCanUseThem() throws {
        let fx = try Fixture()
        let pixal = try XCTUnwrap(EngineDownload.model("pixal3d-sv"))
        try fx.modelFiles(); try fx.modelFiles(pixal)
        let picture = try fx.picture(), back = fx.root.appendingPathComponent("back.png")
        try Engine.writePNG([UInt8](repeating: 60, count: 8 * 8 * 4), width: 8, height: 8, to: back)
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        XCTAssertFalse(pixal.multiView)
        XCTAssertTrue(EngineDownload.standard.multiView)
        XCTAssertThrowsError(try jobs.make(name: "toon", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                           model: pixal, sides: [.back: back])) {
            XCTAssertEqual($0 as? RequestError, .oneSideOnly(pixal.name))
        }
        XCTAssertThrowsError(try jobs.make(name: "elf", picture: .description("an elf"), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard, sides: [.back: back])) {
            XCTAssertEqual($0 as? RequestError, .sidesNeedAPicture)
        }
        XCTAssertNil(Gallery.folder(fx.install.runs, "toon"), "refused before anything was written")

        // A failed attempt's picture of the back is from what it was asked for then.
        let d = fx.install.runs.appendingPathComponent("mini")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try MiniSettings.update(d) { $0.source = .image; $0.sides = [.left] }
        for n in ["source-back.png", "source-left.png", "upload-left.img"] { fm.createFile(atPath: d.appendingPathComponent(n).path, contents: Data("old".utf8)) }
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard,
                      sides: [.right: picture, .back: back])
        jobs.waitUntilDone()  // copies every picture, then the engine (false) fails
        let s = MiniSettings.load(d)
        XCTAssertEqual(s.sides, [.back, .right], "in the engine's order")
        XCTAssertEqual(s.pictures, 3)
        XCTAssertFalse(fm.fileExists(atPath: d.appendingPathComponent("upload-left.img").path), "the old attempt's picture stayed")
        XCTAssertFalse(fm.fileExists(atPath: d.appendingPathComponent("source-left.png").path))
        func data(_ n: String) throws -> Data { try Data(contentsOf: d.appendingPathComponent(n)) }
        XCTAssertEqual(try data("source-back.png"), try data("upload-back.img"))
        XCTAssertNotEqual(try data("upload-back.img"), try data("upload.img"), "the back wasn't kept from its own picture")
        let mini = try XCTUnwrap(Gallery.list(fx.install.runs).first { $0.name == "mini" })
        XCTAssertEqual(mini.previews.map(\.caption), ["Front picture", "Back picture", "Right picture"])
        XCTAssertEqual(MadeFrom(s, created: .distantPast).rows.first, .init(label: "Source", value: "Pictures of the front, back and right"))
    }

    /// Step 1 makes each picture in turn but is one step: its time left counts down once, not
    /// over again for each picture.
    func testTheFirstStepIsTimedOnceForEveryPicture() throws {
        let fx = try Fixture()
        try fx.modelFiles()
        let picture = try fx.picture()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        let seen = Seen()
        jobs.onChange = { seen.add($0) }
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard,
                      sides: [.back: picture, .left: picture])
        jobs.waitUntilDone()
        let started = Set(seen.all.filter { $0.step == 1 && $0.running }.compactMap(\.stepStarted))
        XCTAssertEqual(started.count, 1, "step 1 started over for a picture")
        XCTAssertTrue(seen.all.contains { $0.step == 2 }, "never reached the 3D step")
    }

    /// Make Another Version and New 3D Shape keep the pictures of the back and sides, as Try
    /// Again does (it plans from the same settings).
    func testVersionsKeepThePictures() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles()
        let picture = try fx.picture()
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        try jobs.setPaused(true)
        try jobs.make(name: "elf", picture: .image(picture), restyle: true, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      sides: [.left: picture])
        let elf = try XCTUnwrap(Gallery.folder(runs, "elf"))
        for n in ["source.png", "source-left.png"] { try Data(n.utf8).write(to: elf.appendingPathComponent(n)) }

        let other = try XCTUnwrap(Gallery.folder(runs, try jobs.makeAnotherVersion(of: "elf").name))
        XCTAssertEqual(MiniSettings.load(other).sides, [.left])
        XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent("upload-left.img").path))
        XCTAssertFalse(fm.fileExists(atPath: other.appendingPathComponent("source-left.png").path), "another version makes it afresh")

        let shape = try XCTUnwrap(Gallery.folder(runs, try jobs.makeNewShape(of: "elf").name))
        XCTAssertEqual(try Data(contentsOf: shape.appendingPathComponent("source-left.png")), Data("source-left.png".utf8), "not kept")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: shape, settings: MiniSettings.load(shape), tools: fx.tools()).map(\.number), [2, 3])
        for n in jobs.queue.entries().map(\.name) { try jobs.remove(n) }
        jobs.waitUntilDone()
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [JobStatus] = []
        var all: [JobStatus] { lock.withLock { statuses } }
        func add(_ s: JobStatus) { lock.withLock { statuses.append(s) } }
    }

    /// The multi-image mode is given a folder of the pictures, not one picture.
    func testTheMultiImageCommand() {
        let m = EngineDownload.standard
        XCTAssertEqual(Engine.arguments(model: m, image: URL(fileURLWithPath: "/m/a/source__matted.png"), output: URL(fileURLWithPath: "/m/a/model.glb"),
                                        models: URL(fileURLWithPath: "/m/models"), seed: 7, views: URL(fileURLWithPath: "/m/a/model.mvviews")),
                       ["--trellis2-mv", "/m/a/model.mvviews", "--models", "/m/models", "--seed", "7", "--res", "1024", "--output", "/m/a/model.glb"])
        XCTAssertEqual(Engine.views(URL(fileURLWithPath: "/m/a/model.glb")).path, "/m/a/model.mvviews")
    }

    /// Step 1 takes as long per picture, and the 3D step from several pictures learns only from
    /// makes like it (it runs the slower way).
    func testTheEstimateCountsEveryPicture() {
        let model = EngineDownload.standard.id
        let one = JobShape(job: .generate, model: model, drawn: true), three = JobShape(job: .generate, model: model, drawn: true, pictures: 3)
        XCTAssertEqual(Estimator.estimate(three, history: []).steps[1], 3 * Estimator.estimate(one, history: []).steps[1]!)
        XCTAssertGreaterThan(Estimator.estimate(three, history: []).steps[2]!, Estimator.estimate(one, history: []).steps[2]!)

        func made(_ pictures: Int, picture: Double, shape: Double) -> TimingRecord {
            var r = TimingRecord(date: Date(), version: "t", machine: .current, job: "make", mini: .character, model: model, source: "picture",
                                 restyled: true, height: 32, nozzle: "0.4", base: 25, steps: ["1": picture, "2": shape, "3": 5],
                                 total: picture + shape + 5, outcome: .finished, imported: nil)
            r.pictures = pictures == 1 ? nil : pictures
            return r
        }
        let history = (0..<3).map { _ in made(1, picture: 50, shape: 200) } + (0..<3).map { _ in made(2, picture: 100, shape: 300) }
        XCTAssertEqual(Estimator.estimate(one, history: history).steps[1], 50, "per picture")
        XCTAssertEqual(Estimator.estimate(three, history: history).steps[1], 150)
        XCTAssertEqual(Estimator.estimate(one, history: history).steps[2], 200)
        XCTAssertEqual(Estimator.estimate(three, history: history).steps[2], 300)
        XCTAssertEqual(JobShape(.generate, settings: { var s = MiniSettings(); s.source = .image; s.sides = [.back, .left]; return s }()).pictures, 3)
    }
}
