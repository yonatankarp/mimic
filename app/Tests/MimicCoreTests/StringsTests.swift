import XCTest
@testable import MimicCore

/// The words come from the String Catalog, not only from the English in the code.
final class StringsTests: XCTestCase {
    /// Without its bundle MimicCore would still show English, the keys, so nothing else notices.
    func testMimicCoreFindsItsCompiledCatalog() {
        XCTAssertNotEqual(Bundle.mimicCore.bundleURL, Bundle.main.bundleURL)
        XCTAssertEqual(Bundle.mimicCore.localizations, ["en"])
        XCTAssertNotNil(Bundle.mimicCore.url(forResource: "Localizable", withExtension: "strings"))
    }
}
