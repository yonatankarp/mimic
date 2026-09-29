import Foundation

/// Where Mimic's folder is: the minis (`runs/`), the 3D engine (`image-to-3dlab/`) and the
/// Blender script (`pipeline/`). The app lives in ~/Applications, far from all of these, so it
/// is told where they are: the installer stores the folder as the `installDir` default, and
/// `MIMIC_HOME` overrides it for development and tests.
public struct Install: Sendable, Equatable {
    public let root: URL
    public var runs: URL { root.appendingPathComponent("runs") }
    public var lab: URL { root.appendingPathComponent("image-to-3dlab") }
    public var engine: URL { lab.appendingPathComponent("vendor/pixal3d-cpp") }
    public var labPython: URL { lab.appendingPathComponent(".venv/bin/python") }
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

    /// A Mimic folder has the Blender script; that's the one thing only Mimic ships.
    public var looksRight: Bool {
        FileManager.default.fileExists(atPath: pipeline.appendingPathComponent("mini_prep.py").path)
    }
}
