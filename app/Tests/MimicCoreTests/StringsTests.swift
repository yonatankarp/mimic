import XCTest
@testable import MimicCore

/// The words come from the String Catalog's table, not only from the English in the code.
final class StringsTests: XCTestCase {
    /// Without its bundle MimicCore would still show English, the keys, so nothing else notices.
    func testMimicCoreFindsItsCompiledCatalog() {
        let bundle = Bundle.mimicCore
        XCTAssertNotEqual(bundle.bundleURL, Bundle.main.bundleURL)
        let files = FileManager.default.enumerator(atPath: bundle.bundlePath)?.allObjects ?? []
        XCTAssertNotNil(bundle.url(forResource: "Localizable", withExtension: "strings"), "\(bundle.bundlePath): \(files)")
    }
}
