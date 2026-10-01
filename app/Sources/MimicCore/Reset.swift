import Foundation

/// Puts Mimic back the way it was when first installed, to see the tour (and, with the engine
/// removed, the setup screen) again. Never touches the minis: the folder chosen for them and
/// `installDir` are kept too, because for an install made by the old installer that's where the
/// minis are, and forgetting either would hide them behind a new, empty minis folder.
public enum Reset {
    /// `domain` is the app's settings (its bundle id); only its own settings are cleared.
    public static func run(install: Install, domain: String, removeEngine: Bool,
                           keychainService: String = Keychain.service) throws {
        let defaults = UserDefaults.standard
        let kept = (defaults.persistentDomain(forName: domain) ?? [:]).filter { ["installDir", MinisFolder.key].contains($0.key) }
        defaults.setPersistentDomain(kept, forName: domain)
        Keychain.deleteAll(service: keychainService)
        if removeEngine, FileManager.default.fileExists(atPath: install.engine.path) {
            try FileManager.default.removeItem(at: install.engine)
        }
    }
}
