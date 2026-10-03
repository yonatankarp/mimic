import AppKit
import XCTest
@testable import MimicCore

/// Report a Problem's setup (#283): every field, scrubbed, without names, short in the issue;
/// and the window's picture.
final class ReportSetupTests: XCTestCase {
    let home = "/Users/alice"
    let planted = "sk-ant-api03-PLANTEDfakeKEY0123456789abcdefXYZ in /Users/alice/x"

    func rows(_ s: ReportSetup) -> [String: String] { Dictionary(uniqueKeysWithValues: s.rows(home: home)) }

    /// Each field that holds text from outside Mimic, with a key and the home folder planted in
    /// it: gone from the zip's text and the issue's list.
    func testEveryTextFieldIsScrubbed() {
        let fields: [(String, (inout ReportSetup) -> Void)] = [
            ("model", { $0.model = self.planted }),
            ("engineVersion", { $0.engineVersion = self.planted }),
            ("drawThingsModel", { $0.drawThingsModel = self.planted }),
            ("gpu", { $0.gpu = self.planted }),
            ("sizes.nozzle", { $0.sizes = Sizes(nozzle: self.planted) }),
            ("sizes.base", { $0.sizes = Sizes(base: self.planted) }),
        ]
        for (name, plant) in fields {
            var s = ReportSetup(model: "TRELLIS.2")
            plant(&s)
            for out in [s.text(home: home), s.summary(home: home)] {
                XCTAssertFalse(out.contains("PLANTED"), "\(name)'s key is in \(out)")
                XCTAssertFalse(out.contains("alice"), "\(name)'s home folder is in \(out)")
            }
            XCTAssertTrue(s.text(home: home).contains("[key removed] in ~/x"), name)
        }
    }

    func testTheEngine() {
        XCTAssertEqual(rows(ReportSetup(model: "TRELLIS.2", engineVersion: "pixal3d.cpp d1b4926 metal"))["Engine"],
                       "TRELLIS.2, pixal3d.cpp d1b4926 metal")
        XCTAssertEqual(rows(ReportSetup(model: "Pixal3D"))["Engine"], "Pixal3D, not installed")
    }

    func testDrawThings() {
        XCTAssertEqual(rows(ReportSetup(model: "m", drawThingsModel: "flux_2_klein_4b_q8p.ckpt", drawThingsCLI: true))["Draw Things"],
                       "flux_2_klein_4b_q8p.ckpt, with draw-things-cli")
        XCTAssertEqual(rows(ReportSetup(model: "m"))["Draw Things"], "model unknown, Draw Things isn't answering, with the Draw Things app")
        XCTAssertEqual(rows(ReportSetup(model: "m", openDrawThings: false))["Open Draw Things when needed"], "off")
        var online = ReportSetup(model: "m")
        online.pictures = .bfl
        XCTAssertEqual(rows(online)["Draw Things"], "not used, pictures are made online by Black Forest Labs",
                       "a report from someone using the online service doesn't blame Draw Things")
    }

    func testTheHelperIsItsProviderOnly() {
        XCTAssertEqual(rows(ReportSetup(model: "m"))["AI helper"], "off")
        XCTAssertEqual(rows(ReportSetup(model: "m", helper: .anthropic))["AI helper"], "on, anthropic")
    }

    func testTheDiskMemoryPowerAndGPU() {
        let r = rows(ReportSetup(model: "m", freeBytes: 12_345_000_000, memoryPressure: .warning, power: .battery,
                                 holdOnBattery: true, gpu: "Apple M2 Max"))
        XCTAssertEqual(r["Minis folder disk"], "12.3 GB free")
        XCTAssertEqual(r["Memory pressure"], "warning")
        XCTAssertEqual(r["Power"], "battery")
        XCTAssertEqual(r["Start only when plugged in"], "on")
        XCTAssertEqual(r["GPU"], "Apple M2 Max")
        let none = rows(ReportSetup(model: "m"))
        XCTAssertEqual(none["Minis folder disk"], "unknown")
        XCTAssertEqual(none["Memory pressure"], "unknown")
        XCTAssertEqual(none["Power"], "mains (no battery)")
        XCTAssertEqual(none["GPU"], "unknown")
    }

    func testTheQueueAndTheLastJobAreCountsAndSteps() {
        let s = ReportSetup(model: "m", running: .init(kind: .generate, step: .shape, outcome: .running),
                            waiting: [.generate, .prep, .generate], hold: .paused,
                            lastJob: .init(kind: .prep, step: .print, outcome: .failed, importing: true))
        XCTAssertEqual(rows(s)["Queue"], "make running at step 2 of 3 (Building the 3D shape), 3 waiting (2 make, 1 resize), paused")
        XCTAssertEqual(rows(s)["Last job"], "import, failed at step 3 of 3 (Making the print-ready file)")
        XCTAssertEqual(rows(ReportSetup(model: "m", hold: .battery))["Queue"], "nothing running, held on battery")
        XCTAssertEqual(rows(ReportSetup(model: "m"))["Last job"], "none since Mimic opened")
        var status = JobStatus(name: "raven", kind: .generate, step: .picture, started: Date())
        status.running = false; status.exit = 0; status.pictureReady = true; status.shown = "Raven the Bold"; status.problem = "raven broke"
        let fromStatus = ReportSetup(model: "m", running: .init(status), lastJob: .init(status))
        XCTAssertEqual(rows(fromStatus)["Last job"], "make, stopped for its picture to be checked at step 1 of 3 (Getting the picture ready)")
        XCTAssertFalse((fromStatus.text(home: home) + fromStatus.summary(home: home)).lowercased().contains("raven"), "a mini's name is in the setup")
    }

    func testTheSettingsThatChangeWhatItMakes() {
        let s = ReportSetup(model: "m", sizes: Sizes(base: "32", nozzle: "0.2", shape: .hex, style: .stone, magnet: .mm6x2),
                            greySculpt: false, settingsFrom: .mini)
        let r = rows(s)
        XCTAssertEqual(r["Settings from"], "this mini")
        XCTAssertEqual(r["Nozzle"], "0.2 mm")
        XCTAssertEqual(r["Base"], "32 mm, hex, stone floor, magnet 6 × 2 mm")
        XCTAssertEqual(r["Grey sculpt"], "off")
        XCTAssertEqual(r["Priority"], "lower (nice 10)")
        let none = rows(ReportSetup(model: "m", sizes: Sizes(noBase: true)))
        XCTAssertEqual(none["Base"], "none")
        XCTAssertEqual(none["Nozzle"], "0.4 mm")
        XCTAssertEqual(none["Grey sculpt"], "asked each time, on to start")
        XCTAssertEqual(none["Settings from"], "New Mini's last choice")
    }

    func testTheIssueGetsTheShortListAndTheZipAllOfIt() {
        let s = ReportSetup(model: "TRELLIS.2", gpu: "Apple M2 Max")
        let summary = s.summary(home: home)
        XCTAssertTrue(summary.hasPrefix("- Engine: TRELLIS.2"), summary)
        XCTAssertTrue(summary.contains("- GPU: Apple M2 Max"))
        XCTAssertFalse(summary.contains("Nozzle"), "the settings stay in the zip")
        XCTAssertTrue(s.text(home: home).contains("Nozzle: 0.4 mm\n"))
    }

    /// A new-issue link only takes a few KB: with every field at its longest, it stays well under.
    func testTheIssueLinkStaysShortWithTheSetup() throws {
        let long = String(repeating: "x", count: 2_000)
        let s = ReportSetup(model: long, engineVersion: long, drawThingsModel: long, drawThingsCLI: true, helper: .openai,
                            freeBytes: 1, memoryPressure: .critical, power: .charger, gpu: long,
                            running: .init(kind: .generate, step: .shape, outcome: .running), waiting: Array(repeating: .generate, count: 50),
                            hold: .battery, lastJob: .init(kind: .prep, step: .print, outcome: .failed), sizes: Sizes(base: long, nozzle: long))
        let url = Report.issueURL(build: "Mimic 0.9.0 · build 300 · abc1234", mac: "Mac14,6, Apple M2 Max, 32 GB, macOS 26.0",
                                  failure: String(repeating: "Step 2 failed. ", count: 20), setup: s, home: home)
        XCTAssertLessThan(url.absoluteString.utf8.count, 4_000)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let more = try XCTUnwrap(c.queryItems?.first { $0.name == "more" }?.value)
        XCTAssertTrue(more.hasPrefix("Setup, from Mimic:\n- Engine: "), more)
        XCTAssertTrue(more.contains("- Last job: resize, failed at step 3 of 3"), more)
    }

    func testTheSetupIsReadFromThisMac() throws {
        let fx = try Fixture()
        try FileManager.default.createDirectory(at: fx.install.engine, withIntermediateDirectories: true)
        try "pixal3d.cpp d1b4926 metal\nmore\n".write(to: fx.install.engine.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mimic-setup-\(UUID().uuidString)"))
        defaults.set(EngineDownload.pixal3d.id, forKey: SettingsKey.model)
        defaults.set(HelperProvider.ollama.rawValue, forKey: HelperConfig.providerKey)
        defaults.set("http://secret.example:11434", forKey: HelperConfig.urlKey)
        defaults.set(false, forKey: DrawThingsApp.enabledKey)
        let s = ReportSetup.current(install: fx.install, defaults: defaults, drawThings: fx.noDrawThings())
        XCTAssertEqual(s.model, "Pixal3D")
        XCTAssertEqual(s.engineVersion, "pixal3d.cpp d1b4926 metal")
        XCTAssertEqual(s.drawThingsModel, "x", "the pinned model, without asking Draw Things")
        XCTAssertFalse(s.drawThingsCLI)
        XCTAssertFalse(s.openDrawThings)
        XCTAssertEqual(s.helper, .ollama)
        XCTAssertNotNil(s.freeBytes)
        XCTAssertFalse(s.text().contains("secret.example"), "the helper's address is in the setup")
    }

    func testTheZipHasTheSetupAndTheWindowWhenGiven() throws {
        let fx = try Fixture()
        let s = ReportSetup(model: "TRELLIS.2", engineVersion: "v in /Users/alice/engine")
        let zip = try Report.write(to: fx.root.appendingPathComponent("reports"), mini: nil, picture: false, build: "b", mac: "m",
                                   appLog: nil, setup: s, window: Data("png".utf8), home: home)
        let out = fx.root.appendingPathComponent("unzipped")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run(); p.waitUntilExit()
        let top = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first)
        let setup = try String(contentsOf: top.appendingPathComponent("setup.txt"), encoding: .utf8)
        XCTAssertTrue(setup.contains("Engine: TRELLIS.2, v in ~/engine\n"), setup)
        XCTAssertEqual(try Data(contentsOf: top.appendingPathComponent("window.png")), Data("png".utf8))
        XCTAssertTrue(try String(contentsOf: top.appendingPathComponent("about.txt"), encoding: .utf8).contains("Window picture: included"))
    }

    /// Mimic draws a view of its own into a PNG, with no window on screen and no permission asked.
    @MainActor
    func testAViewIsDrawnIntoAPNG() throws {
        final class Red: NSView {
            override func draw(_ dirtyRect: NSRect) { NSColor.red.setFill(); bounds.fill() }
        }
        let data = try XCTUnwrap(WindowPicture.png(Red(frame: NSRect(x: 0, y: 0, width: 40, height: 30))))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 40)
        XCTAssertGreaterThanOrEqual(rep.pixelsHigh, 30)
        let c = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // Drawn in the screen's colours, red is about (1, 0.15, 0) once back in sRGB.
        XCTAssertGreaterThan(c.redComponent, 0.9)
        XCTAssertLessThan(c.greenComponent, 0.4)
        XCTAssertLessThan(c.blueComponent, 0.4)
        XCTAssertNil(WindowPicture.png(NSView(frame: .zero)), "nothing drawn, no picture")
    }

    /// A window comes out with its title bar, and a sheet over it is drawn where it sits: a blue
    /// sheet over a red window. Both are see-through on screen, as beginSheet shows the window.
    @MainActor
    func testAWindowIsDrawnWithItsSheet() throws {
        final class Filled: NSView {
            var colour = NSColor.red
            override func draw(_ dirtyRect: NSRect) { colour.setFill(); bounds.fill() }
        }
        func filled(_ colour: NSColor, _ size: NSSize) -> NSView {
            let v = Filled(frame: NSRect(origin: .zero, size: size)); v.colour = colour; return v
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        defer { window.close() }
        window.contentView = filled(.red, NSSize(width: 300, height: 200))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.alphaValue = 0
        sheet.contentView = filled(.blue, NSSize(width: 100, height: 60))
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        XCTAssertEqual(window.attachedSheet, sheet)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(WindowPicture.png(window))))
        let scale = CGFloat(rep.pixelsWide) / window.frame.width
        XCTAssertEqual(CGFloat(rep.pixelsHigh), window.frame.height * scale, accuracy: 1, "the title bar is missing")
        func colour(atWindow p: NSPoint) throws -> NSColor {
            // The bitmap's rows run top down; the window's points bottom up.
            try XCTUnwrap(rep.colorAt(x: Int(p.x * scale), y: rep.pixelsHigh - 1 - Int(p.y * scale))?.usingColorSpace(.sRGB))
        }
        let s = sheet.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let red = try colour(atWindow: NSPoint(x: 40, y: 40))
        // Behind a sheet, macOS pales the window (about (0.84, 0.54, 0.55) here), as on screen.
        XCTAssertGreaterThan(red.redComponent, 0.8); XCTAssertGreaterThan(red.redComponent - red.blueComponent, 0.2)
        let blue = try colour(atWindow: NSPoint(x: s.midX, y: s.midY))
        XCTAssertGreaterThan(blue.blueComponent, 0.8, "the sheet isn't drawn"); XCTAssertLessThan(blue.redComponent, 0.4)
    }
}
