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
    func engine(_ body: String, model: EngineModel? = nil) throws -> (GroupProcess, URL, URL) {
        try FileManager.default.createDirectory(at: f.install.engine, withIntermediateDirectories: true)
        let cli = f.install.trellisCLI
        try "#!/bin/bash\n\(body)\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let source = try picture("source.png") { x, _ in x < 50 ? 0 : 255 }
        let glb = f.install.runs.appendingPathComponent("mini/model.glb"), log = f.root.appendingPathComponent("pixal3d.log")
        let p = try GroupProcess(executable: mimic,
                                 arguments: ["_engine", source.path, glb.path, "--seed", "5", "--engine", f.install.engine.path]
                                    + (model.map { ["--model", $0.id] } ?? []),
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
