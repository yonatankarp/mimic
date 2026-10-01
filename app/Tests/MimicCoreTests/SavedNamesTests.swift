import XCTest
@testable import MimicCore

/// Names already on people's Macs: renaming one would lose what an older Mimic saved.
final class SavedNamesTests: XCTestCase {
    func testTheSettingsKeysStayAsTheyWere() {
        XCTAssertEqual([SettingsKey.model, SettingsKey.slicer, SettingsKey.installDir], ["model", "slicer", "installDir"])
    }

    func testTheThreeDShapeKeepsItsFileName() {
        XCTAssertEqual(Mini.modelFile, "model.glb")
    }

    /// The app saves through these keys and Terminal reads through the same ones.
    func testTheChosenModelAndSlicerAreReadByTheirKeys() throws {
        let suite = "mimic-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = try XCTUnwrap(EngineDownload.catalogue.first { $0.id != EngineDownload.standard.id })
        defaults.set(other.id, forKey: SettingsKey.model)
        XCTAssertEqual(EngineDownload.selected(defaults: defaults).id, other.id)
        defaults.set(Slicer.macDefault, forKey: SettingsKey.slicer)
        XCTAssertNil(Slicer.preferred(defaults: defaults, in: []))
    }
}
