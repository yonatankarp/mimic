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

    /// Plurals are the catalog's: the code has only the many form ("2 minis"), so without it a
    /// single one would read "1 minis".
    func testPluralsComeFromTheCatalog() {
        XCTAssertEqual(JobPresentation.QueuedNote.added(1), "1 mini added to the queue.")
        XCTAssertEqual(JobPresentation.QueuedNote.added(2), "2 minis added to the queue.")
        XCTAssertEqual(JobProgress.about(61 * 60), "about 1 hour 1 minute")
        XCTAssertEqual(JobProgress.about(122 * 60), "about 2 hours 2 minutes")
        XCTAssertEqual(SizeCard.severalNote(without: 1, of: 3),
                       "Each character keeps its own real height. One mini has no real height saved, so it gets the Character height below.")
        XCTAssertEqual(SizeCard.severalNote(without: 2, of: 3),
                       "Each character keeps its own real height. 2 minis have no real height saved, so they get the Character height below.")
    }

    /// `mimic` in Terminal reads the English table on its own, whatever the Mac's language.
    func testTerminalReadsTheEnglishTable() {
        let found = Bundle.mimicCore
        defer { Bundle.mimicCore = found }
        Bundle.englishOnly()
        XCTAssertEqual(Bundle.mimicCore.bundleURL.lastPathComponent, "en.lproj")
        XCTAssertEqual(JobPresentation.QueuedNote.added(1), "1 mini added to the queue.")
    }
}
