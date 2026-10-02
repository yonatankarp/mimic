import Foundation
import XCTest
@testable import MimicCore

/// Step 2: cutting the picture out and running the 3D engine. The last four tests run the real
/// `mimic _engine` (built beside this test bundle) against a stand-in trellis-cli.
final class EngineTests: XCTestCase {
    var f: Fixture!
    override func setUpWithError() throws { f = try Fixture() }

    /// A width×height picture whose alpha is `alpha(x, y)`.
    func picture(_ name: String, width: Int = 100, height: Int = 100, alpha: (Int, Int) -> UInt8) throws -> URL {
        var p = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let i = (y * width + x) * 4; p[i] = 200; p[i + 1] = 90; p[i + 2] = 40; p[i + 3] = alpha(x, y) } }
        let url = f.root.appendingPathComponent(name)
        try Engine.writePNG(p, width: width, height: height, to: url)
        return url
    }

    /// A photo taken sideways: stored `width` wide and `height` tall, with orientation 6 (turn
    /// it a quarter to the right).
    func sideways(width: Int, height: Int) throws -> URL {
        let photo = f.root.appendingPathComponent("sideways.jpg")
        let src = CGImageSourceCreateWithURL(try picture("wide.png", width: width, height: height) { _, _ in 255 } as CFURL, nil)!
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return photo
    }

    /// The exact command line per model family, each the one proven end to end on this engine
    /// build (app/NOTES.md). TRELLIS.2 names its output: a lone positional after `--image` is
    /// read as a second picture.
    func testTheExactEngineCommand() throws {
        func args(_ m: EngineModel) -> [String] {
            Engine.arguments(model: m, image: URL(fileURLWithPath: "/m/runs/a/source__matted.png"),
                             output: URL(fileURLWithPath: "/m/runs/a/model.glb"),
                             models: URL(fileURLWithPath: "/m/engine/models/\(m.id)"), seed: 7)
        }
        XCTAssertEqual(args(EngineDownload.model("pixal3d-sv")!), ["--sv-image", "/m/runs/a/source__matted.png", "--fov", "0.3490658503988659",
                                                        "--models", "/m/engine/models/pixal3d-sv", "--seed", "7", "--res", "1024",
                                                        "--pixal3d-weights", "sv", "--gss", "10", "/m/runs/a/model.glb"])
        for m in EngineDownload.catalogue where m.family == .trellis2 {
            XCTAssertEqual(args(m), ["--image", "/m/runs/a/source__matted.png", "--models", "/m/engine/models/\(m.id)",
                                     "--seed", "7", "--res", "1024", "--output", "/m/runs/a/model.glb"], m.id)
        }
        XCTAssertEqual(Engine.environment(["PATH": "/bin", "PIXAL3D_STEPS": "12"]), ["PATH": "/bin", "PIXAL3D_STEPS": "8"])
    }

    /// The alpha's content decides, not its presence: opaque noise in an alpha channel is not a cutout.
    func testWhetherAPictureIsCutOut() throws {
        XCTAssertTrue(try Engine.isCutOut(picture("cut.png") { x, _ in x < 50 ? 0 : 255 }))
        XCTAssertFalse(try Engine.isCutOut(picture("noise.png") { x, y in UInt8(219 + (x * 7 + y * 13) % 37) }), "opaque noise read as a cutout")
        XCTAssertFalse(try Engine.isCutOut(picture("speck.png") { x, y in x == 0 && y == 0 ? 0 : 255 }), "one clear pixel read as a cutout")
        let jpeg = f.root.appendingPathComponent("photo.jpg")
        let src = CGImageSourceCreateWithURL(try picture("any.png") { _, _ in 0 } as CFURL, nil)!
        let dest = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertFalse(try Engine.isCutOut(jpeg), "a picture with no alpha at all read as a cutout")
    }

    /// A photo taken sideways (stored 60 wide, 40 tall, orientation 6: turn it a quarter to the
    /// right) is read upright, as New Mini shows it, by the cutout and the grey sculpt alike.
    func testSidewaysPhotosAreReadUpright() throws {
        let photo = try sideways(width: 60, height: 40)
        let image = try Engine.load(photo)
        XCTAssertEqual([image.width, image.height], [40, 60], "the cutout reads the photo on its side")
        let (_, w, h) = try DrawThings.fitForEdit(photo)
        XCTAssertEqual([w, h], [1024, 1536], "the grey sculpt gets the photo on its side")
    }

    /// A picture is tidied when it's added: a big sideways photo is kept upright and no longer
    /// than 2048 on its longest side, as PNG with no orientation left to apply twice; a small
    /// cutout keeps its size and its transparency.
    func testAPictureIsTidiedWhenItsAdded() throws {
        let photo = try sideways(width: 4096, height: 1024)
        let tidied = f.root.appendingPathComponent("tidied.img")
        try Engine.tidied(photo).write(to: tidied)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(tidied as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, "public.png")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual([props[kCGImagePropertyPixelWidth] as? Int, props[kCGImagePropertyPixelHeight] as? Int], [512, 2048],
                       "not turned upright, or not made smaller")
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1, "an orientation left to turn it again")

        let cut = try picture("cut.png", width: 60, height: 30) { x, _ in x < 30 ? 0 : 255 }
        try Engine.tidied(cut).write(to: tidied)
        let image = try Engine.load(tidied)
        XCTAssertEqual([image.width, image.height], [60, 30], "a small picture changed size")
        XCTAssertTrue(try Engine.isCutOut(tidied), "the cutout lost its transparency")
    }

    /// A soft edge pixel takes the character's colour, not the backdrop's; its alpha stays.
    /// Clear pixels beyond reach are black, never the backdrop (trellis-cli sees their RGB).
    func testEdgesTakeTheCharactersColour() {
        var p: [UInt8] = [200, 0, 0, 255,  90, 90, 90, 128,  90, 90, 90, 0,  90, 90, 90, 0,  90, 90, 90, 0,  90, 90, 90, 0]
        Engine.cleanEdges(&p, width: 6, height: 1)
        XCTAssertEqual(Array(p[4..<8]), [200, 0, 0, 128])
        XCTAssertEqual(Array(p[20..<24]), [0, 0, 0, 0], "the backdrop stayed under a clear pixel")
    }

    // MARK: The real `mimic _engine`

    /// The `mimic` binary `swift test` built beside this test bundle.
    var mimic: String {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mimic")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "run swift build first: no \(url.path)")
        return url.path
    }

    /// Runs `mimic _engine` on a cut-out picture with `body` as trellis-cli, in a session of its
    /// own like a job step. Returns the process and its log.
    func engine(_ body: String, model: EngineModel? = nil, extra: [String] = []) throws -> (GroupProcess, URL, URL) {
        try FileManager.default.createDirectory(at: f.install.engine, withIntermediateDirectories: true)
        let cli = f.install.trellisCLI
        try "#!/bin/bash\n\(body)\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let source = try picture("source.png") { x, _ in x < 50 ? 0 : 255 }
        let glb = f.install.runs.appendingPathComponent("mini/model.glb"), log = f.root.appendingPathComponent("pixal3d.log")
        let p = try GroupProcess(executable: mimic,
                                 arguments: ["_engine", source.path, glb.path, "--seed", "5", "--engine", f.install.engine.path]
                                    + (model.map { ["--model", $0.id] } ?? []) + extra,
                                 environment: ["PATH": "/usr/bin:/bin"], log: log.path)
        return (p, glb, log)
    }

    func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    func waitForFile(_ path: String) -> String? {
        for _ in 0..<200 {
            if let s = try? String(contentsOfFile: path, encoding: .utf8), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            usleep(50_000)
        }
        return nil
    }

    func testTheEngineRunsWithTheRightCommandAndAQuietLog() throws {
        let seen = f.root.appendingPathComponent("seen").path
        let (p, glb, log) = try engine("""
            { pwd; echo "steps=$PIXAL3D_STEPS"; printf '%s\\n' "$@"; } > \(seen)
            echo "ggml_metal_init: loaded kernel_add"
            echo "      [flow] PIXAL3D_STEPS=$PIXAL3D_STEPS overrides 12 steps"
            printf '      [flow] [##....]  1/8\\r      [flow] [######]  8/8\\n'
            echo "ggml_metal_free: deallocating"
            echo "[6/6] writing"
            echo glb > "${@: -1}"
            """)
        XCTAssertEqual(p.wait(), 0, text(log))
        let args = text(URL(fileURLWithPath: seen)).split(separator: "\n").map(String.init)
        XCTAssertEqual(args.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, f.install.engine.resolvingSymlinksInPath(), "not run from the engine's folder")
        XCTAssertEqual(args[1], "steps=8")
        XCTAssertEqual(Array(args.dropFirst(2)), Engine.arguments(model: EngineDownload.standard, image: f.root.appendingPathComponent("source.png"),
                                                                  output: glb, models: EngineDownload.standard.folder(in: f.install), seed: 5),
                       "no --model is the standard model")
        let out = text(log)
        XCTAssertFalse(out.contains("ggml_metal"), "Metal noise reached the log")
        for line in ["PIXAL3D_STEPS=8 overrides 12 steps", "1/8", "8/8", "[6/6] writing"] { XCTAssertTrue(out.contains(line), line) }
        XCTAssertFalse(out.contains("cutting"), "an already cut-out picture was cut out again")
    }

    /// A cartoon is made with Pixal3D whatever model is in use: TRELLIS.2, the standard, builds
    /// cartoons out of flat panels (#3). Anything else keeps the one in use.
    func testACartoonIsMadeWithPixal3D() {
        XCTAssertEqual(EngineDownload.standard.family, .trellis2, "the test needs TRELLIS.2 in use")
        XCTAssertEqual(EngineDownload.forMaking(cartoon: true, chosen: EngineDownload.standard).family, .pixal3dSingleView)
        XCTAssertEqual(EngineDownload.forMaking(cartoon: false, chosen: EngineDownload.standard), EngineDownload.standard)
        // New Mini shows the back and side places only for a model that uses them (#254).
        XCTAssertFalse(EngineDownload.forMaking(cartoon: true, chosen: EngineDownload.standard).multiView, "a cartoon uses one picture")
        XCTAssertTrue(EngineDownload.forMaking(cartoon: false, chosen: EngineDownload.standard).multiView)
    }

    /// `--model` picks the command line and the model folder, and the fast-setting guard holds
    /// for it too.
    func testTheEngineRunsTheChosenModel() throws {
        let m = try XCTUnwrap(EngineDownload.catalogue.first { $0.family == .trellis2 })
        let seen = f.root.appendingPathComponent("seen").path
        let (p, glb, log) = try engine("""
            printf '%s\\n' "$@" > \(seen)
            echo "      [flow] PIXAL3D_STEPS=$PIXAL3D_STEPS overrides 12 steps"
            echo glb > "${@: -1}"
            """, model: m)
        XCTAssertEqual(p.wait(), 0, text(log))
        XCTAssertEqual(text(URL(fileURLWithPath: seen)).split(separator: "\n").map(String.init),
                       Engine.arguments(model: m, image: f.root.appendingPathComponent("source.png"), output: glb,
                                        models: m.folder(in: f.install), seed: 5))
        XCTAssertTrue(text(log).contains("model=\(m.id)"), "the log doesn't say which model made it")
    }

    /// Pictures of the back and sides too (#66): each cut out like the front, put together front
    /// first in the order the engine reads them (by name), and given to the multi-image mode.
    /// Its flows print no progress bar and don't take the fast setting (the real engine says
    /// "[flow-mv] 12 steps"), so the guard below must let it run.
    func testSeveralPicturesGoToTheMultiImageMode() throws {
        let back = try picture("back.png") { x, _ in x < 30 ? 0 : 255 }
        let left = try picture("left.png") { x, _ in x < 70 ? 0 : 255 }
        let seen = f.root.appendingPathComponent("seen").path
        let m = EngineDownload.standard
        let (p, glb, log) = try engine("""
            { printf '%s\\n' "$@"; ls "$2"; } > \(seen)
            echo "      [flow-mv] 12 steps, 3 views, 22 forwards, mode=stochastic, 93.5s"
            echo glb > "${@: -1}"
            """, model: m, extra: ["--back", back.path, "--left", left.path])
        XCTAssertEqual(p.wait(), 0, text(log))
        let want = Engine.arguments(model: m, image: f.root.appendingPathComponent("source.png"), output: glb,
                                    models: m.folder(in: f.install), seed: 5, views: Engine.views(glb))
        let lines = text(URL(fileURLWithPath: seen)).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(want.count)), want)
        XCTAssertEqual(Array(lines.dropFirst(want.count)), ["1-front.png", "2-back.png", "3-left.png"])
        XCTAssertTrue(text(log).contains("pictures=3"), text(log))
    }

    func testAnEngineThatIgnoresTheFastSettingIsStopped() throws {
        let pidFile = f.root.appendingPathComponent("cli.pid").path
        let (p, _, log) = try engine("""
            echo $$ > \(pidFile)
            echo "      [flow] [....................]  0/12    0.0s  starting"
            exec sleep 60
            """)
        let started = Date()
        XCTAssertEqual(p.wait(), 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertTrue(text(log).contains("ignores PIXAL3D_STEPS"), text(log))
        let cli = pid_t(waitForFile(pidFile) ?? "") ?? 0
        usleep(100_000)
        XCTAssertNotEqual(kill(cli, 0), 0, "the engine kept running")
    }

    func testAFailedOrEmptyRunFails() throws {
        var (p, _, log) = try engine("echo boom; exit 3")
        XCTAssertEqual(p.wait(), 1)
        XCTAssertTrue(text(log).contains("exit code 3"), text(log))
        (p, _, log) = try engine("echo '[flow] PIXAL3D_STEPS=8 overrides 12 steps'")
        XCTAssertEqual(p.wait(), 1)
        XCTAssertTrue(text(log).contains("without writing"), text(log))
    }

    /// What the job tells the person goes in the report beside model.glb (#305), as the log
    /// can't say it plainly: the engine's own words for people, a plain sentence for trellis-cli
    /// killed (macOS ending it when the Mac runs out of memory), and nothing for an exit code.
    func testTheEngineReportsWhyItFailed() throws {
        var (p, glb, log) = try engine("kill -9 $$")
        XCTAssertEqual(p.wait(), 1)
        XCTAssertEqual(PrepReport.read(glb.deletingLastPathComponent())?.failure,
                       "It looks like your Mac ran out of memory while building the 3D shape. Quit other apps, then try again.")
        XCTAssertTrue(text(log).contains("signal 9"), text(log))

        try? FileManager.default.removeItem(at: PrepReport.file(beside: glb))
        (p, glb, _) = try engine("echo boom; exit 3")
        XCTAssertEqual(p.wait(), 1)
        XCTAssertNil(PrepReport.read(glb.deletingLastPathComponent()), "an exit code isn't for people")

        let missing = f.root.appendingPathComponent("no-engine")
        let source = try picture("cut.png") { x, _ in x < 50 ? 0 : 255 }
        let mini = f.install.runs.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: mini, withIntermediateDirectories: true)
        let q = try GroupProcess(executable: mimic,
                                 arguments: ["_engine", source.path, mini.appendingPathComponent("model.glb").path, "--seed", "5", "--engine", missing.path],
                                 environment: ["PATH": "/usr/bin:/bin"], log: f.root.appendingPathComponent("missing.log").path)
        XCTAssertEqual(q.wait(), 1)
        XCTAssertEqual(PrepReport.read(mini)?.failure,
                       "The 3D engine is missing (\(missing.appendingPathComponent("trellis-cli").path)). Open Mimic's Settings and press Repair next to the 3D engine.")
    }

    /// Stop ends the job's group; trellis-cli has to be in it, not in a group of its own.
    func testStopEndsTheEngineToo() throws {
        let pidFile = f.root.appendingPathComponent("cli.pid").path
        let (p, _, _) = try engine("echo $$ > \(pidFile); echo '[flow] PIXAL3D_STEPS=8 overrides 12 steps'; exec sleep 60")
        let cli = pid_t(try XCTUnwrap(waitForFile(pidFile)))!
        XCTAssertEqual(kill(cli, 0), 0)
        p.terminateGroup()
        XCTAssertEqual(p.wait(), -15)
        usleep(200_000)
        XCTAssertNotEqual(kill(cli, 0), 0, "Stop left trellis-cli running")
    }
}
