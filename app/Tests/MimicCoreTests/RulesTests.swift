import XCTest
@testable import MimicCore

/// Ported from tests/test_serve.py: every value in a request ends up as a program argument.
final class RulesTests: XCTestCase {
    func testNames() {
        for ok in ["dwarf-cleric", "tiefling2", "a"] { XCTAssertTrue(Rules.isValidName(ok), ok) }
        for bad in ["../etc", "a/b", "-rf", "--image", "", "Dwarf", "a b", String(repeating: "x", count: 65), "a\n"] {
            XCTAssertFalse(Rules.isValidName(bad), bad.debugDescription)
        }
    }

    func testSlug() {
        XCTAssertEqual(Rules.slug("Dwarf Cleric!"), "dwarf-cleric")
        XCTAssertEqual(Rules.slug("  --Tiefling  Wizard-- "), "tiefling-wizard")
        XCTAssertEqual(Rules.slug("!!!"), "")
        XCTAssertTrue(Rules.isValidName(Rules.slug("A Name From A Description, Maybe Long")))
    }

    func testNumbersPassThroughAsNumbers() throws {
        XCTAssertEqual(try Sizes(height: "38", base: "25", inflate: "0.08").flags(),
                       ["--height", "38.0", "--base", "25.0", "--inflate", "0.08"])
    }

    func testNonNumbersAreRefused() {
        for bad in ["32; rm -rf ~", "--image", "nan", "inf", "-5", ""] {
            XCTAssertThrowsError(try Sizes(height: bad).flags(), bad)
        }
    }

    func testNozzleIsOneOfTheOfferedSizes() throws {
        XCTAssertEqual(try Sizes(nozzle: "0.2").flags(), ["--nozzle", "0.2"])
        for bad in ["0.3", "0.20", "--image", "1e9"] {
            XCTAssertThrowsError(try Sizes(nozzle: bad).flags(), bad)
        }
    }

    func testNoBase() throws {
        XCTAssertEqual(try Sizes(noBase: true).flags(), ["--no-base"])
        XCTAssertEqual(try Sizes().flags(), [])
    }
}
