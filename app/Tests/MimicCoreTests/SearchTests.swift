import XCTest
@testable import MimicCore

final class SearchTests: XCTestCase {
    private func minis(_ names: [String]) -> [Mini] {
        names.map { Mini(name: $0, folder: URL(fileURLWithPath: "/tmp/\($0)"), madeAt: .distantPast) }
    }
    private let seven = ["dwarf-cleric", "elf-ranger", "dwarf-fighter", "orc", "goblin", "troll", "wizard"]

    /// A mini asked for `hoursAgo` ago, with what its settings.json would hold. Its folder is
    /// never there: all of this must work from what the gallery read.
    private func mini(_ name: String, hoursAgo: Double = 0, object: Bool = false, height: String? = nil, made: Bool = true,
                      desc: String? = nil, typed: String? = nil, finished: Bool = true) -> Mini {
        var s = MiniSettings()
        if object { s.kind = .object }
        s.desc = desc; s.descOriginal = typed
        if let height { if made { s.made = Sizes(height: height) } else { s.requested = Sizes(height: height) } }
        return Mini(name: name, folder: URL(fileURLWithPath: "/tmp/\(name)"), madeAt: .distantPast,
                    created: Date(timeIntervalSince1970: 1_000_000 - hoursAgo * 3600), settings: s, finished: finished)
    }

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

    func testSearchMatchesTheDescriptionToo() {
        let all = minis(seven) + [mini("bob", desc: "a halfling bard with a lute"),
                                  mini("tim", desc: "A cheerful HALFLING cook", typed: "a teapot shaped like a dragon")]
        XCTAssertEqual(Gallery.search(all, "halfling").map(\.name), ["bob", "tim"], "the description, ignoring case")
        XCTAssertEqual(Gallery.search(all, "dragon").map(\.name), ["tim"], "what was typed, when the helper's text was used")
        XCTAssertEqual(Gallery.search(all, "bard").map(\.name), ["bob"])
    }

    func testSearchIgnoresAccentsAndCapitals() {
        var s = MiniSettings()
        s.name("Élodie", folder: "elodie")
        let elodie = Mini(name: "elodie", folder: URL(fileURLWithPath: "/tmp/elodie"), madeAt: .distantPast, settings: s)
        let all = minis(seven) + [elodie, mini("cafe", desc: "a tiny CAFÉ counter")]
        XCTAssertEqual(elodie.displayName, "Élodie")
        XCTAssertEqual(Gallery.search(all, "elodie").map(\.name), ["elodie"])
        XCTAssertEqual(Gallery.search(all, "ÉLO").map(\.name), ["elodie"])
        XCTAssertEqual(Gallery.search(all, "cafe").map(\.name), ["cafe"], "in the description too")
    }

    func testDateMadeIsNewestFirstByWhenAskedFor() {
        // Not by madeAt, which a resize changes: the list would jump on every resize.
        let old = Mini(name: "old", folder: URL(fileURLWithPath: "/tmp/old"), madeAt: Date(timeIntervalSince1970: 2_000_000),
                       created: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(Gallery.sorted([old, mini("new")], by: .made).map(\.name), ["new", "old"])
    }

    func testNameSortsByTheShownNameAsFinderDoes() {
        let list = [mini("orc-10", hoursAgo: 1), mini("goblin", hoursAgo: 2), mini("orc-2", hoursAgo: 3), mini("Elf", hoursAgo: 4)]
        XCTAssertEqual(Gallery.sorted(list, by: .name).map(\.name), ["Elf", "goblin", "orc-2", "orc-10"],
                       "capitals don't matter, and 2 comes before 10")
        // "orc" and "Orc" are both shown as "Orc": newest first.
        XCTAssertEqual(Gallery.sorted([mini("orc", hoursAgo: 5), mini("Orc", hoursAgo: 1)], by: .name).map(\.name), ["Orc", "orc"])
    }

    func testSizeIsTallestFirstAndMinisWithoutSizesLast() {
        let list = [mini("none-new", hoursAgo: 0), mini("small", hoursAgo: 1, height: "25"),
                    mini("asked", hoursAgo: 2, height: "100", made: false), mini("default", hoursAgo: 3, height: "0"),
                    mini("none-old", hoursAgo: 4), mini("big", hoursAgo: 5, height: "75.5")]
        XCTAssertEqual(Gallery.sorted(list, by: .size).map(\.name), ["asked", "big", "default", "small", "none-new", "none-old"],
                       "as made, else as asked for; 0 is the default 32 mm; none last, newest first")
    }

    func testShowFiltersByKindAndFinished() {
        let list = [mini("dwarf"), mini("teapot", object: true), mini("waiting", finished: false), mini("lamp", object: true, finished: false)]
        XCTAssertEqual(Gallery.arrange(list, query: "", show: .all, sort: .made).count, 4)
        XCTAssertEqual(Gallery.arrange(list, query: "", show: .characters, sort: .made).map(\.name), ["dwarf", "waiting"])
        XCTAssertEqual(Gallery.arrange(list, query: "", show: .objects, sort: .made).map(\.name), ["teapot", "lamp"])
        XCTAssertEqual(Gallery.arrange(list, query: "", show: .unfinished, sort: .made).map(\.name), ["waiting", "lamp"])
        // Its menu is there at any count, unlike the search field: a filter on a few minis still hides.
        XCTAssertTrue(Gallery.narrowed(list, query: "", show: .objects))
        XCTAssertFalse(Gallery.narrowed(list, query: "dwarf", show: .all), "the query is ignored at six or fewer")
    }

    func testArrangeSearchesFiltersAndSorts() {
        let list = (1...8).map { mini("dwarf-\($0)", hoursAgo: Double($0), object: $0 % 2 == 0, height: "\($0 * 10)") } + [mini("elf")]
        XCTAssertEqual(Gallery.arrange(list, query: "dwarf", show: .objects, sort: .size).map(\.name), ["dwarf-8", "dwarf-6", "dwarf-4", "dwarf-2"])
        XCTAssertTrue(Gallery.narrowed(list, query: " dwarf ", show: .all))
        XCTAssertFalse(Gallery.narrowed(list, query: "  ", show: .all))
    }

    func testFinishedIsReadOnceWhenListed() throws {
        let f = try Fixture()
        for name in ["done", "failed"] {
            let dir = f.install.runs.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try MiniSettings.update(dir) { $0.requested = Sizes(height: "32") }
        }
        try Data().write(to: f.install.runs.appendingPathComponent("done/done.stl"))
        let list = Gallery.list(f.install.runs)
        XCTAssertEqual(Gallery.arrange(list, query: "", show: .unfinished, sort: .made).map(\.name), ["failed"])
        // Kept from the listing: a print file that appears later shows at the next reload.
        try Data().write(to: f.install.runs.appendingPathComponent("failed/failed.stl"))
        XCTAssertEqual(list.filter { !$0.finished }.map(\.name), ["failed"])
        XCTAssertEqual(Gallery.list(f.install.runs).filter { !$0.finished }.count, 0)
    }

    func testWhatASearchOrFilterHidesIsDeselected() {
        let shown = Gallery.arrange([mini("dwarf"), mini("teapot", object: true)], query: "", show: .objects, sort: .made)
        XCTAssertEqual(Gallery.visible(["dwarf", "teapot"], in: shown), ["teapot"])
        XCTAssertEqual(Gallery.visible([], in: shown), [])
    }
}
