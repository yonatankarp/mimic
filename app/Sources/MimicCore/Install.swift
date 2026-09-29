import Foundation

/// Where Mimic keeps things: the minis (`runs`), the 3D engine (`engine`, trellis-cli and its
/// libraries, with each model set's files in `engine/models/<id>/`).
///
/// An app installed from the disk image has no Mimic folder, so by default the minis are in
/// ~/Documents/Mimic, where people look for their files, and the engine in
/// ~/Library/Application Support/Mimic/engine, out of their way. Installs made by the old
/// installer have one folder with both inside (`runs/`, `engine/`), stored as the `installDir`
/// default; that still wins, and so does `MIMIC_HOME` for development and tests.
public struct Install: Sendable, Equatable {
    public let runs: URL
    public let engine: URL
    /// Where installs before the Swift engine kept it: `image-to-3dlab` in the Mimic folder.
    /// Setup moves it out. nil for the default layout, which never had one.
    public let legacyLab: URL?
    public var trellisCLI: URL { engine.appendingPathComponent("trellis-cli") }
    /// Draw Things' command line tool, which setup downloads beside the engine.
    public var drawThingsCLI: URL { engine.appendingPathComponent("draw-things-cli") }

    /// A Mimic folder with everything inside it.
    public init(root: URL) {
        let root = root.standardizedFileURL
        runs = root.appendingPathComponent("runs")
        engine = root.appendingPathComponent("engine")
        legacyLab = root.appendingPathComponent("image-to-3dlab")
    }

    public init(runs: URL, engine: URL) {
        self.runs = runs.standardizedFileURL
        self.engine = engine.standardizedFileURL
        legacyLab = nil
    }

    /// The layout for an app installed from the disk image.
    public static func standard(home: URL) -> Install {
        Install(runs: home.appendingPathComponent("Documents/Mimic"),
                engine: home.appendingPathComponent("Library/Application Support/Mimic/engine"))
    }

    /// Always an answer: `MIMIC_HOME`, then the `installDir` folder if it's still there, then
    /// the standard layout, which setup fills in. `MIMIC_FAKE_HOME` is for trying first launch
    /// without touching this Mac's Mimic: the standard layout inside that folder, as though it
    /// were a new Mac's home folder (so `installDir` is ignored too).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Install {
        func folder(_ path: String?) -> URL? {
            guard let path else { return nil }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue ? url : nil
        }
        if let root = folder(environment["MIMIC_HOME"]) { return Install(root: root) }
        if let fake = environment["MIMIC_FAKE_HOME"] { return standard(home: URL(fileURLWithPath: fake)) }
        if let root = folder(defaults.string(forKey: "installDir")) { return Install(root: root) }
        return standard(home: home)
    }
}
