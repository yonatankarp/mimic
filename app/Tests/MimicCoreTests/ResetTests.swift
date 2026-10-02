import XCTest
@testable import MimicCore

final class ResetTests: XCTestCase {
    /// Back to a fresh install: settings, keys and (asked for) the engine go; the minis and
    /// where they live stay.
    func testResetKeepsTheMinisAndForgetsTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let install = Install(root: root)
        let mini = install.runs.appendingPathComponent("dwarf")
        try FileManager.default.createDirectory(at: mini, withIntermediateDirectories: true)
        try Data("stl".utf8).write(to: mini.appendingPathComponent("dwarf.stl"))
        try FileManager.default.createDirectory(at: install.engine.appendingPathComponent("models"), withIntermediateDirectories: true)
        let domain = "mimic-reset-test-\(UUID().uuidString)", service = "mimic-reset-test-\(UUID().uuidString)"
        // Before anything is saved, so even a test that stops halfway leaves nothing in the login keychain.
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            Keychain.deleteAll(service: service)
        }
        UserDefaults.standard.setPersistentDomain(["installDir": root.path, MinisFolder.key: install.runs.path, "tourSeen": true, "nozzle": "0.2",
                                                   "model": "trellis2-q8"], forName: domain)
        try Keychain.save("sk-test", account: HelperProvider.anthropic.rawValue, service: service)
        try Keychain.save("sk-test", account: "openai@llm.example.com", service: service)

        try Reset.run(install: install, domain: domain, removeEngine: false, keychainService: service)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: domain)?.keys.sorted(), ["installDir", MinisFolder.key, SettingsKey.model].sorted(),
                       "only where the minis are, and the 3D model still on disk, is kept: a Mac with only Pixal3D isn't sent to setup")
        XCTAssertFalse(Keychain.has(account: HelperProvider.anthropic.rawValue, service: service), "saved keys are forgotten")
        XCTAssertFalse(Keychain.has(account: "openai@llm.example.com", service: service), "so are keys saved for another address")
        XCTAssertTrue(FileManager.default.fileExists(atPath: install.engine.path), "the engine stays unless asked")

        try Reset.run(install: install, domain: domain, removeEngine: true, keychainService: service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.engine.path), "asked: the engine is removed")
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: domain)?[SettingsKey.model], "and setup offers every model again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mini.appendingPathComponent("dwarf.stl").path), "the minis are never touched")
    }

    /// Reset in Mimic Dev forgets Mimic Dev's keys, never Mimic's (#313); outside an app (no
    /// bundle id, whose keys are Mimic's) it forgets none. Two made-up services stand in for them.
    func testResetForgetsOnlyItsOwnKeys() throws {
        let install = Install(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let domain = "mimic-reset-test-\(UUID().uuidString)"
        let release = "com.mimic.test.\(UUID().uuidString)", dev = "com.mimic.test.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            Keychain.deleteAll(service: release)
            Keychain.deleteAll(service: dev)
        }
        try Keychain.save("sk-release", account: HelperProvider.anthropic.rawValue, service: release)
        try Keychain.save("sk-dev", account: HelperProvider.anthropic.rawValue, service: dev)

        try Reset.run(install: install, domain: domain, removeEngine: false, keychainService: nil)
        XCTAssertTrue(Keychain.has(account: HelperProvider.anthropic.rawValue, service: release), "outside an app, no key is deleted")
        XCTAssertTrue(Keychain.has(account: HelperProvider.anthropic.rawValue, service: dev))

        try Reset.run(install: install, domain: domain, removeEngine: false, keychainService: dev)
        XCTAssertFalse(Keychain.has(account: HelperProvider.anthropic.rawValue, service: dev), "its own key is forgotten")
        XCTAssertEqual(Keychain.read(account: HelperProvider.anthropic.rawValue, service: release), "sk-release", "the other app's is kept")
    }
}
