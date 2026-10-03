import Foundation
import XCTest
@testable import MimicCore

/// New Mini's decisions: what Make Mini waits for, the changes a mini's picture has, and the
/// size card it opens with.
final class MakeAdviceTests: XCTestCase {
    private func missing(fromPicture: Bool = true, hasPicture: Bool = true, description: String = "", kind: MiniKind = .character,
                         folder: String = "dwarf", newProject: String? = nil, fix: String = "", pictureNeed: String? = nil) -> String? {
        MakeAdvice.missing(fromPicture: fromPicture, hasPicture: hasPicture, description: description, kind: kind,
                           folder: folder, newProject: newProject, fix: fix, pictureNeed: pictureNeed)
    }

    func testMakeMiniSaysWhatItsWaitingForFirst() {
        XCTAssertNil(missing())
        XCTAssertEqual(missing(hasPicture: false, folder: ""), "Add a picture to start", "the picture before the name")
        XCTAssertEqual(missing(fromPicture: false, hasPicture: false, folder: ""), "Describe your character to start")
        XCTAssertEqual(missing(fromPicture: false, kind: .object), "Describe your object to start")
        XCTAssertNil(missing(fromPicture: false, hasPicture: false, description: "a dwarf"), "a description needs no picture")
        XCTAssertEqual(missing(folder: "", newProject: ""), "Give your mini a name", "the name before the project")
        XCTAssertEqual(missing(newProject: "  ", pictureNeed: "Draw Things"), "Name the new project")
        XCTAssertNil(missing(newProject: "Tiefling Party"))
        XCTAssertEqual(missing(fromPicture: false, description: "a dwarf", pictureNeed: "Draw Things"), "A description needs Draw Things first")
        XCTAssertNil(missing(pictureNeed: "Draw Things"), "a picture as it is needs nothing drawn")
        XCTAssertEqual(missing(fix: "a red cloak", pictureNeed: "a working online key"), "A change needs a working online key first")
        XCTAssertNil(missing(fix: "a red cloak"))
    }

    func testAChangeComesAfterTheEarlierOnes() {
        XCTAssertEqual(MakeAdvice.fixes(fromPicture: false, earlier: ["a hat"], fix: "a cloak", drawn: true), [], "a description has none")
        XCTAssertEqual(MakeAdvice.fixes(fromPicture: true, earlier: ["a hat"], fix: "", drawn: false), ["a hat"], "none typed: the earlier ones")
        XCTAssertEqual(MakeAdvice.fixes(fromPicture: true, earlier: ["a hat"], fix: "a cloak", drawn: true), ["a hat", "a cloak"])
        XCTAssertEqual(MakeAdvice.fixes(fromPicture: true, earlier: ["a hat", "a beard"], fix: "a cloak", drawn: false), ["a hat", "a cloak"],
                       "from the picture it was given, the change takes the place of the last")
        XCTAssertEqual(MakeAdvice.fixes(fromPicture: true, earlier: [], fix: "a cloak", drawn: false), ["a cloak"])
    }

    func testTheSizeCardRemembersTheLastChoices() {
        let suite = UUID().uuidString, d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SizeCard.remembered(defaults: d), SizeCard(), "nothing chosen yet: the defaults")
        // These names are in people's settings already: renaming one forgets their printer.
        for (key, value) in ["purpose": "display", "nozzle": "0.2", "kind": "object", "baseShape": "hex", "baseStyle": "stone", "magnet": "5x2"] {
            d.set(value, forKey: key)
        }
        let card = SizeCard.remembered(defaults: d)
        XCTAssertEqual(card.purpose, .display)
        XCTAssertEqual(card.nozzle, "0.2")
        XCTAssertEqual(card.kind, .object)
        XCTAssertEqual(card.shape, .hex)
        XCTAssertEqual(card.style, .stone)
        XCTAssertEqual(card.magnet, .mm5x2)
        for key in [SettingsKey.purpose, SettingsKey.nozzle, SettingsKey.kind, SettingsKey.baseShape, SettingsKey.baseStyle, SettingsKey.magnet] {
            d.set("junk", forKey: key)
        }
        let junk = SizeCard.remembered(defaults: d)
        XCTAssertEqual(junk, SizeCard(), "what can't be read is the default")
        XCTAssertNil(junk.magnet)
    }
}
