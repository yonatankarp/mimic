import CryptoKit
import Foundation

/// Where Mimic keeps things: the minis (`runs`), the 3D engine (`engine`, trellis-cli and its
/// libraries, with each model set's files in `engine/models/<id>/`), and the queue's own files
/// (`queue`: what's waiting, and which Mimic is making a mini).
///
/// An app installed from the disk image has no Mimic folder, so by default the minis are in
/// ~/Documents/Mimic, where people look for their files, and the engine in
/// ~/Library/Application Support/Mimic/engine, out of their way. Settings → General can put the
/// minis elsewhere (`MinisFolder`). Installs made by the old installer have one folder with both
/// inside (`runs/`, `engine/`), stored as the `installDir` default; that still wins, and so does
/// `MIMIC_HOME` for development and tests.
///
/// The queue is never in the minis folder (#102): that may be in iCloud, shared by two Macs that
/// each lock only for themselves. It's in Application Support, one folder per minis folder, so
/// every Mimic on this Mac making minis in one folder (the app, a dev build, `mimic` in
/// Terminal) shares one queue, and a Mimic using another folder never sees it.
public struct Install: Sendable, Equatable {
    public let runs: URL
    public let engine: URL
    /// The queue and the running job's files, on this Mac only (`JobQueue`).
    public let queue: URL
    public var trellisCLI: URL { engine.appendingPathComponent("trellis-cli") }
    /// Draw Things' command line tool, which setup downloads beside the engine.
    public var drawThingsCLI: URL { engine.appendingPathComponent("draw-things-cli") }

    /// A Mimic folder with everything inside it, the queue too (development and tests).
    public init(root: URL) {
        let root = root.standardizedFileURL
        self.init(runs: root.appendingPathComponent("runs"), engine: root.appendingPathComponent("engine"),
                  queue: root.appendingPathComponent("queue"))
    }

    public init(runs: URL, engine: URL, queue: URL) {
        self.runs = runs.standardizedFileURL
        self.engine = engine.standardizedFileURL
        self.queue = queue.standardizedFileURL
    }

    /// The layout for an app installed from the disk image, with the minis in `runs` when a
    /// folder was chosen for them.
    public static func standard(home: URL, runs: URL? = nil) -> Install {
        let runs = runs ?? home.appendingPathComponent("Documents/Mimic")
        return Install(runs: runs, engine: support(home).appendingPathComponent("engine"), queue: queueFolder(runs, home: home))
    }

    /// ~/Library/Application Support/Mimic.
    static func support(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Mimic") }

    /// The queue of the minis in `runs`, on this Mac: named after the folder's path as given, not
    /// with links resolved (a folder that doesn't exist yet resolves differently once it does).
    /// The app and `mimic` build that path from the same settings, so they agree.
    public static func queueFolder(_ runs: URL, home: URL) -> URL {
        let digest = SHA256.hash(data: Data(runs.standardizedFileURL.path.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return support(home).appendingPathComponent("queues/\(key)")
    }

    /// Always an answer: `MIMIC_HOME`, then the `installDir` folder if it's still there, then
    /// the standard layout, which setup fills in; with the minis in the folder chosen in Settings
    /// while that's there. `MIMIC_FAKE_HOME` is for trying first launch without touching this
    /// Mac's Mimic: the standard layout inside that folder, as though it were a new Mac's home
    /// folder (so `installDir` and the chosen folder are ignored too).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Install {
        if let root = folder(environment["MIMIC_HOME"]) { return Install(root: root) }
        if let fake = environment["MIMIC_FAKE_HOME"] { return standard(home: URL(fileURLWithPath: fake)) }
        let chosen = folder(defaults.string(forKey: MinisFolder.key))
        if let root = folder(defaults.string(forKey: SettingsKey.installDir)) {
            let old = Install(root: root), runs = chosen ?? old.runs
            return Install(runs: runs, engine: old.engine, queue: queueFolder(runs, home: home))
        }
        return standard(home: home, runs: chosen)
    }

    /// The minis folder is set by how this Mimic was started (`MIMIC_HOME`, `MIMIC_FAKE_HOME`),
    /// so choosing one in Settings would change nothing.
    public static func minisFolderIsFixed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        folder(environment["MIMIC_HOME"]) != nil || environment["MIMIC_FAKE_HOME"] != nil
    }

    static func folder(_ path: String?) -> URL? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue ? url : nil
    }
}
