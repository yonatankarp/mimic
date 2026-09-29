import XCTest
@testable import MimicCore

final class SearchTests: XCTestCase {
    private func minis(_ names: [String]) -> [Mini] {
        names.map { Mini(name: $0, folder: URL(fileURLWithPath: "/tmp/\($0)"), madeAt: .distantPast) }
    }
    private let seven = ["dwarf-cleric", "elf-ranger", "dwarf-fighter", "orc", "goblin", "troll", "wizard"]

    func testSearchMatchesTheShownNameIgnoringCaseAndSpaces() {
        XCTAssertEqual(Gallery.search(minis(seven), "  DWARF ").map(\.name), ["dwarf-cleric", "dwarf-fighter"], "order kept")
        XCTAssertEqual(Gallery.search(minis(seven), "elf ranger").map(\.name), ["elf-ranger"], "spaces match the dashes")
        XCTAssertEqual(Gallery.search(minis(seven), "").count, 7)
        XCTAssertEqual(Gallery.search(minis(seven), "dragon").count, 0)
    }

    func testSixOrFewerIgnoreTheQuery() {
        // The field is hidden then, so a query left from before must not hide minis.
        XCTAssertEqual(Gallery.search(minis(Array(seven.prefix(6))), "dwarf").count, 6)
    }
}
