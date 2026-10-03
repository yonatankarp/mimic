import Foundation

/// Puts Mimic back the way it was when first installed, to see the tour (and, with the engine
/// removed, the setup screen) again. Never touches the minis: the folder chosen for them and
/// `installDir` are kept too, because for an install made by the old installer that's where the
/// minis are, and forgetting either would hide them behind a new, empty minis folder.
public enum Reset {
    /// `domain` is the app's settings (its bundle id); only its own settings are cleared. The 3D
    /// model in use is kept while its files are: forgetting it would ask for TRELLIS.2, the
    /// standard one, and send a Mac that has only Pixal3D to setup to download it. Saved keys go
    /// only from this app's own Keychain service; outside an app (no bundle id) none are deleted.
    /// The settings `UserDefaults.standard` saves to, the only ones Reset clears (#381): the app's
    /// bundle id, or outside an app (`swift run`, the bare binary) the program's name, as macOS
    /// names them then. Never Mimic's "com.mimic.app" from a copy that isn't Mimic, though
    /// `mimic` in Terminal reads those (CLI.swift): it has no Reset.
    public static func ownDomain(bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        bundleID ?? ProcessInfo.processInfo.processName
    }

    public static func run(install: Install, domain: String, removeEngine: Bool,
                           keychainService: String? = Keychain.ownService) throws {
        let defaults = UserDefaults.standard
        let kept = (defaults.persistentDomain(forName: domain) ?? [:]).filter { [SettingsKey.installDir, MinisFolder.key].contains($0.key) || (!removeEngine && $0.key == SettingsKey.model) }
        defaults.setPersistentDomain(kept, forName: domain)
        if let keychainService { Keychain.deleteAll(service: keychainService) }
        if removeEngine, FileManager.default.fileExists(atPath: install.engine.path) {
            try FileManager.default.removeItem(at: install.engine)
        }
    }
}
