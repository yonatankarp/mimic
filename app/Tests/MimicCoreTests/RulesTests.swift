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

    /// A project's name is kept as typed, trimmed. It's a folder, so it can't hold a slash or a
    /// colon, nor start with Mimic's own "_" or a hidden ".".
    func testProjectNames() {
        XCTAssertEqual(Rules.projectName("  Tiefling Party \n"), "Tiefling Party")
        XCTAssertEqual(Rules.projectName("Élodie's Band"), "Élodie's Band")
        XCTAssertEqual(Rules.projectName("v1.2_props"), "v1.2_props", "a dot or underscore inside is fine")
        XCTAssertEqual(Rules.projectName(String(repeating: "é", count: 64))?.count, 64)
        XCTAssertNil(Rules.projectName(String(repeating: "a", count: 65)))
        XCTAssertEqual(Rules.projectName("  " + String(repeating: "a", count: 64) + "  ")?.count, 64, "counted once trimmed")
        for bad in ["", " \n ", "  _mine", ".hidden", "a/b", "a:b", "a\tb", "a\u{7}b"] {
            XCTAssertNil(Rules.projectName(bad), bad.debugDescription)
        }
    }

    func testSlug() {
        XCTAssertEqual(Rules.slug("Dwarf Cleric!"), "dwarf-cleric")
        XCTAssertEqual(Rules.slug("  --Tiefling  Wizard-- "), "tiefling-wizard")
        XCTAssertEqual(Rules.slug("!!!"), "")
        XCTAssertTrue(Rules.isValidName(Rules.slug("A Name From A Description, Maybe Long")))
    }

    /// `mimic make` takes any name the app takes (#128): it used the name as the folder, so
    /// "Élodie" was refused as a bad name.
    func testNamesGivenInTerminal() {
        XCTAssertEqual(Rules.typedName("Élodie")?.folder, "elodie")
        XCTAssertEqual(Rules.typedName("Élodie")?.shown, "Élodie")
        XCTAssertEqual(Rules.typedName("  D&D   Bard ")?.folder, "d-d-bard")
        XCTAssertEqual(Rules.typedName("  D&D   Bard ")?.shown, "D&D Bard")
        XCTAssertEqual(Rules.typedName("dwarf-cleric")?.folder, "dwarf-cleric")
        XCTAssertNil(Rules.typedName("dwarf-cleric")?.shown, "a folder-style name is shown as before")
        XCTAssertNil(Rules.typedName("   "))
        for typed in ["Élodie", "Дракон", "Dwarf Cleric", "🐉", "dwarf-cleric"] {
            XCTAssertTrue(Rules.isValidName(Rules.typedName(typed)?.folder ?? ""), typed)
        }
    }

    /// A typed name's folder is never empty (#87): the plain slug made "Élodie" "lodie" and
    /// "Дракон" nothing at all, which blocked Make.
    func testFolderNamesForTypedNames() {
        XCTAssertEqual(Rules.folderName("Élodie"), "elodie")
        XCTAssertEqual(Rules.folderName("Дракон"), "drakon")
        XCTAssertEqual(Rules.folderName("Straße"), "strasse")
        XCTAssertEqual(Rules.folderName("D&D Bard"), "d-d-bard")
        XCTAssertEqual(Rules.folderName("🐉"), "mini", "nothing to write in plain letters")
        for typed in ["Élodie", "Дракон", "日本", "Ελένη", "🐉", String(repeating: "Ä", count: 80)] {
            XCTAssertTrue(Rules.isValidName(Rules.folderName(typed)), typed)
        }
    }

    func testShownNames() {
        XCTAssertEqual(Rules.shownName("  Élodie \n la  Druide "), "Élodie la Druide")
        XCTAssertNil(Rules.shownName(" \n "))
        XCTAssertEqual(Rules.shownName(String(repeating: "a", count: 80))?.count, 64)
        XCTAssertEqual(Rules.shownName(fromFile: "dwarf-cleric"), "Dwarf Cleric", "as before")
        XCTAssertEqual(Rules.shownName(fromFile: "Élodie"), "Élodie")
        XCTAssertEqual(Rules.shownName(fromFile: "McGregor_final"), "McGregor final")
        XCTAssertEqual(Rules.shownName("Élodie", numberedAs: "elodie"), "Élodie")
        XCTAssertEqual(Rules.shownName("Élodie", numberedAs: "elodie-2"), "Élodie 2")
        XCTAssertEqual(Rules.shownName("Raven 2", numberedAs: "raven-3"), "Raven 3")
        XCTAssertEqual(Rules.shownName("Orc 2024", numberedAs: "orc-2024-2"), "Orc 2024 2")
        XCTAssertEqual(Rules.shownName(carrying: "Élodie 2", to: "elodie"), "Élodie")
        XCTAssertEqual(Rules.shownName(carrying: "Élodie", to: "elodie-3"), "Élodie 3")
        XCTAssertNil(Rules.shownName(carrying: "Élodie", to: "orc"))
    }

    func testPrintFileNamesKeepTheShownNameWithoutSlashes() {
        XCTAssertEqual(Rules.printFileName("Élodie ×2"), "Élodie ×2.3mf")
        XCTAssertEqual(Rules.printFileName("AC/DC Roadie ×2"), "AC-DC Roadie ×2.3mf", "not a folder \"AC\"")
        XCTAssertEqual(Rules.printFileName("Bard: Lute"), "Bard- Lute.3mf")
        XCTAssertEqual(Rules.printFileName(".hidden"), "hidden.3mf")
        XCTAssertEqual(Rules.printFileName("🐉"), "minis.3mf")
        XCTAssertEqual(Rules.printFileName("../.."), "minis.3mf")
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
