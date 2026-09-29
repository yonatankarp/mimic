import Foundation

/// Which build this is, as bundle.sh stamped it into the app's Info.plist: shown in Settings and
/// by `mimic --version`, so you can tell what's installed. Read from the Info.plist beside the
/// binary's real path, since run through the Terminal symlink the binary isn't seen as part of
/// its app and Bundle.main has no Info.plist. A bare `swift build` binary has none: "dev".
enum BuildInfo {
    static let info: [String: String] = {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return (NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }()
    static var version: String { info["CFBundleShortVersionString"] ?? "dev" }
    static var build: String? { info["CFBundleVersion"] }
    static var commit: String? { info["MimicCommit"] }

    /// "Mimic 0.4.0 · build 128 · 941a66c"
    static var line: String { (["Mimic \(version)"] + [build.map { "build \($0)" }, commit].compactMap { $0 }).joined(separator: " · ") }
}
