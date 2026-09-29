import Foundation

/// Where Mimic's folder is: the minis (`runs/`), the 3D engine (`engine/`, trellis-cli and its
/// libraries, with the model files in `engine/models/pixal3d-sv/`) and the Blender script
/// (`pipeline/`). The app lives in ~/Applications, far from all of these, so it
/// is told where they are: the installer stores the folder as the `installDir` default, and
/// `MIMIC_HOME` overrides it for development and tests.
public struct Install: Sendable, Equatable {
    public let root: URL
    public var runs: URL { root.appendingPathComponent("runs") }
    public var engine: URL { root.appendingPathComponent("engine") }
    public var trellisCLI: URL { engine.appendingPathComponent("trellis-cli") }
    public var models: URL { engine.appendingPathComponent("models/pixal3d-sv") }
    public var pipeline: URL { root.appendingPathComponent("pipeline") }

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// nil when neither is set, or the folder isn't a Mimic folder: the app then asks.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard) -> Install? {
        let candidates = [environment["MIMIC_HOME"], defaults.string(forKey: "installDir")].compactMap { $0 }
        for path in candidates {
            let install = Install(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            if install.looksRight { return install }
        }
        return nil
    }

    /// A Mimic folder has the installer; every copy of Mimic ships it, whatever else moves.
    public var looksRight: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("setup.sh").path)
    }
}
