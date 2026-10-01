import Foundation
import ImageIO
import XCTest
@testable import MimicCore

/// A throwaway Mimic folder with fake tools: the job runner runs real processes, just not
/// print prep or the 3D engine. Removed once its test is over.
struct Fixture {
    let root: URL
    let install: Install
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        FixtureFolders.add(root)
        install = Install(root: root)
        // The queue's folder is made by the first change to the queue; some tests write a
        // running job's record before any.
        try FileManager.default.createDirectory(at: install.queue, withIntermediateDirectories: true)
    }

    /// A shell script to stand in for print prep or the 3D engine.
    func script(_ name: String, _ body: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// `mimic` stands in for Mimic's own binary, which steps 2 and 3 run as `mimic _engine …`
    /// and `mimic _prep …`. `drawThings` is step 1's: by default one that fails at once, so a
    /// test never reaches the real Draw Things on a Mac that has it (#140).
    func tools(mimic: String = "/usr/bin/true", drawThings: DrawThings? = nil) -> Tools {
        Tools(mimic: mimic, engine: install.engine.path,
              environment: ["PATH": "/usr/bin:/bin"], drawThings: drawThings ?? noDrawThings())
    }

    /// A Draw Things that isn't there: no command line tool, nothing answering (port 9 refuses at
    /// once), a pinned model and a home of its own so its models folder isn't read, and an app
    /// that's switched off and never opens.
    func noDrawThings() -> DrawThings {
        DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:9", "DRAWTHINGS_MODEL": "x"], home: root,
                   app: DrawThingsApp(enabled: { false }, running: { false }, open: { nil }), cli: nil)
    }

    /// Every weight file of `model` at its full size, sparse so gigabytes cost nothing; `short`
    /// is left a byte short, as an interrupted download would.
    func modelFiles(_ model: EngineModel = EngineDownload.standard, short: String? = nil) throws {
        let folder = model.folder(in: install)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for m in model.weights {
            let url = folder.appendingPathComponent(m.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(m.name == short ? m.bytes - 1 : m.bytes))
            try h.close()
        }
    }

    /// A small real picture to make a mini from: New Mini tidies it, so a stand-in's bytes won't
    /// do. A JPEG for a name ending .jpg, else a PNG.
    func picture(_ name: String = "pic.png") throws -> URL {
        let png = root.appendingPathComponent(name.hasSuffix(".jpg") ? "pic-source.png" : name)
        try Engine.writePNG([UInt8](repeating: 200, count: 8 * 8 * 4), width: 8, height: 8, to: png)
        guard name.hasSuffix(".jpg") else { return png }
        let url = root.appendingPathComponent(name)
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A mini folder with a 3D model, ready to resize.
    func mini(_ name: String) throws -> URL {
        let d = install.runs.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for f in ["model.glb", "\(name).stl", "\(name)_front.png", "\(name)_left.png", "\(name)_right.png", "\(name)_back.png", "source.png"] {
            FileManager.default.createFile(atPath: d.appendingPathComponent(f).path, contents: Data(f.utf8))
        }
        return d
    }
}

/// Every Fixture's folder, removed once its test is over (setUp, the test and tearDown): a
/// Fixture is made in many places, none of them with the test at hand to add a teardown to.
final class FixtureFolders: NSObject, XCTestObservation, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var folders: [URL] = []
    nonisolated(unsafe) private static var watching = false

    nonisolated static func add(_ folder: URL) {
        let first = lock.withLock { () -> Bool in
            folders.append(folder)
            defer { watching = true }
            return !watching
        }
        // XCTest runs every test on the main thread.
        if first { MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(FixtureFolders()) } }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let done = Self.lock.withLock { defer { Self.folders = [] }; return Self.folders }
        for f in done { try? FileManager.default.removeItem(at: f) }
    }
}

/// Waits up to `timeout` seconds for `done`, looking every 50 ms: for the event itself (a marker
/// file, a request taken away) rather than a sleep that hopes it happened. False if it never did.
func eventually(timeout: TimeInterval = 10, _ done: () -> Bool) -> Bool {
    let until = Date().addingTimeInterval(timeout)
    while !done() {
        if Date() > until { return false }
        usleep(50_000)
    }
    return true
}

final class TrashSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    var trashed: [URL] { lock.withLock { items } }
    @discardableResult func callAsFunction(_ u: URL) -> URL? { lock.withLock { items.append(u) }; return nil }
}
