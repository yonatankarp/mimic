import Foundation

/// Puts Mimic back the way it was when first installed, to see the tour (and, with the engine
/// removed, the setup screen) again. Never touches the minis: `installDir` is kept too, because
/// for an install made by the old installer it's where the minis are, and forgetting it would
/// hide them behind a new, empty minis folder.
public enum Reset {
    /// `domain` is the app's settings (its bundle id); only its own settings are cleared.
    public static func run(install: Install, domain: String, removeEngine: Bool,
                           keychainService: String = Keychain.service) throws {
        let defaults = UserDefaults.standard
        let kept = (defaults.persistentDomain(forName: domain) ?? [:]).filter { $0.key == "installDir" }
        defaults.setPersistentDomain(kept, forName: domain)
        for provider in HelperProvider.allCases where provider.isCloud {
            Keychain.delete(account: provider.rawValue, service: keychainService)
        }
        if removeEngine, FileManager.default.fileExists(atPath: install.engine.path) {
            try FileManager.default.removeItem(at: install.engine)
        }
    }
}
