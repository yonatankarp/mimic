import Foundation

/// The words people see come from one String Catalog, `Resources/Localizable.xcstrings`, compiled
/// into MimicCore's resource bundle. MimicCore looks its own up here (`String(localized: "…",
/// bundle: .mimicCore)`); the app's views look in Bundle.main, where bundle.sh copies the same
/// compiled table. `app/strings.py` keeps the catalog in step with the code (NOTES.md).
extension Bundle {
    /// MimicCore's resource bundle: in the app's Contents/Resources, also when run through the
    /// Terminal symlink (Bundle.main isn't the app then), beside the binary for `swift run`, or
    /// beside the tests. Not Bundle.module, whose accessor stops the program when it can't find
    /// the bundle; here a missing bundle only means the English in the code is shown.
    public nonisolated(unsafe) static var mimicCore: Bundle = {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let places = [Bundle.main.resourceURL, exe.deletingLastPathComponent().appendingPathComponent("Resources"), exe,
                      Bundle(for: Finder.self).bundleURL.deletingLastPathComponent()]
        return places.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent("Mimic_MimicCore.bundle")) } }
            .first ?? .main
    }()

    /// `mimic` in Terminal stays English whatever the Mac's language: its words are for scripts
    /// and bug reports too. The English table on its own, so no other language is ever chosen.
    public static func englishOnly() {
        if let en = mimicCore.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)) { mimicCore = en }
    }
}

private final class Finder {}
