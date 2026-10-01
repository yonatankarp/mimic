import XCTest
@testable import MimicCore

final class ResetTests: XCTestCase {
    /// Back to a fresh install: settings, keys and (asked for) the engine go; the minis and
    /// where they live stay.
    func testResetKeepsTheMinisAndForgetsTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let install = Install(root: root)
        let mini = install.runs.appendingPathComponent("dwarf")
        try FileManager.default.createDirectory(at: mini, withIntermediateDirectories: true)
        try Data("stl".utf8).write(to: mini.appendingPathComponent("dwarf.stl"))
        try FileManager.default.createDirectory(at: install.engine.appendingPathComponent("models"), withIntermediateDirectories: true)
        let domain = "mimic-reset-test-\(UUID().uuidString)", service = "mimic-reset-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        UserDefaults.standard.setPersistentDomain(["installDir": root.path, MinisFolder.key: install.runs.path, "tourSeen": true, "nozzle": "0.2",
                                                   "model": "trellis2-q8"], forName: domain)
        try Keychain.save("sk-test", account: HelperProvider.anthropic.rawValue, service: service)
        try Keychain.save("sk-test", account: "openai@llm.example.com", service: service)
        defer { Keychain.deleteAll(service: service) }

        try Reset.run(install: install, domain: domain, removeEngine: false, keychainService: service)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: domain)?.keys.sorted(), ["installDir", MinisFolder.key].sorted(), "only where the minis are is kept")
        XCTAssertFalse(Keychain.has(account: HelperProvider.anthropic.rawValue, service: service), "saved keys are forgotten")
        XCTAssertFalse(Keychain.has(account: "openai@llm.example.com", service: service), "so are keys saved for another address")
        XCTAssertTrue(FileManager.default.fileExists(atPath: install.engine.path), "the engine stays unless asked")

        try Reset.run(install: install, domain: domain, removeEngine: true, keychainService: service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.engine.path), "asked: the engine is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mini.appendingPathComponent("dwarf.stl").path), "the minis are never touched")
    }
}
