import Foundation
import XCTest
@testable import MimicCore

/// A damaged .glb is refused with a reason, never read past its end: the app reads an imported
/// model in its own process, so a file that trips the reader would close Mimic (#176).
final class GLBTests: XCTestCase {
    static let triangle = Mesh(positions: [[0, 0, 0], [1, 0, 0], [0, 0, 1]], triangles: [[0, 1, 2]])

    /// The triangle's .glb, its positions in bytes 0-35 and its indices in 36-47, with `key` of
    /// entry `index` in `list` (accessors, bufferViews, nodes) set to `value`.
    static func damaged(_ list: String, _ index: Int, _ key: String, _ value: Any) -> Data {
        PrepTests.glb(triangle, translation: .zero) { json in set(&json, list, index, key, value) }
    }

    static func set(_ json: inout [String: Any], _ list: String, _ index: Int, _ key: String, _ value: Any) {
        var items = json[list] as! [[String: Any]]
        items[index][key] = value
        json[list] = items
    }

    func assertRefused(_ data: Data, _ reason: String, _ what: String, line: UInt = #line) {
        XCTAssertThrowsError(try GLB.parse(data), what, line: line) {
            XCTAssertEqual(($0 as? PrepError)?.description, reason, what, line: line)
        }
    }

    let unreadable = "the .glb stores its shape in a way Mimic can't read"
    let cutShort = "the .glb is cut short"

    /// The checks that were there before: each one reached, not beaten to it by another.
    func testTheShapesItCantReadAreRefused() {
        XCTAssertEqual(try GLB.parse(Self.damaged("nodes", 0, "mesh", 0)).triangles, [[0, 1, 2]], "the undamaged file reads")
        assertRefused(Self.damaged("accessors", 0, "sparse", ["count": 1]), unreadable, "sparse positions")
        assertRefused(Self.damaged("accessors", 0, "componentType", 9999), unreadable, "an unknown number type")
        assertRefused(Self.damaged("accessors", 0, "type", "MAT9"), unreadable, "an unknown element shape")
        assertRefused(Self.damaged("accessors", 0, "bufferView", 5), unreadable, "a view that isn't there")
        assertRefused(Self.damaged("accessors", 0, "count", 5), cutShort, "more positions than the data holds")
        assertRefused(Self.damaged("accessors", 0, "type", "VEC2"), "the .glb's positions aren't 3D", "flat positions")
        let nowhere = Mesh(positions: Self.triangle.positions, triangles: [[0, 1, 5]])
        assertRefused(PrepTests.glb(nowhere, translation: .zero), "the .glb has triangles pointing nowhere", "a corner past the last")
        assertRefused(Self.damaged("nodes", 0, "mesh", 7), "no mesh in the .glb", "a node's mesh isn't there")
    }

    /// Counts, offsets and indices are whole numbers from zero up, and small enough to be in the file.
    func testBrokenNumbersAreRefused() {
        assertRefused(Self.damaged("accessors", 0, "count", -1), unreadable, "a negative count")
        assertRefused(Self.damaged("accessors", 0, "count", 1 << 61), cutShort, "a count past any file")
        assertRefused(Self.damaged("accessors", 0, "bufferView", -1), unreadable, "a negative view")
        assertRefused(Self.damaged("accessors", 1, "byteOffset", -4), unreadable, "a negative offset")
        assertRefused(Self.damaged("bufferViews", 1, "byteOffset", 36.5), unreadable, "a fractional offset")
        assertRefused(Self.damaged("bufferViews", 0, "byteStride", -12), unreadable, "a negative stride")
        assertRefused(Self.damaged("bufferViews", 0, "byteStride", 0), unreadable, "elements on top of each other")
        assertRefused(Self.damaged("bufferViews", 0, "byteStride", 8), unreadable, "elements overlapping")
        let far = PrepTests.glb(Self.triangle, translation: .zero) { json in
            Self.set(&json, "bufferViews", 0, "byteOffset", 1 << 62)
            Self.set(&json, "accessors", 0, "byteOffset", 1 << 62)
        }
        assertRefused(far, cutShort, "offsets that add up past any number")
        assertRefused(Self.damaged("nodes", 0, "mesh", -1), unreadable, "a negative mesh")
        assertRefused(Self.damaged("nodes", 0, "children", [-1]), unreadable, "a negative child")
        let position = PrepTests.glb(Self.triangle, translation: .zero) { json in
            Self.set(&json, "meshes", 0, "primitives", [["attributes": ["POSITION": -1], "indices": 1] as [String: Any]])
        }
        assertRefused(position, unreadable, "negative positions")
        assertRefused(PrepTests.glb(Self.triangle, translation: .zero) { $0["scene"] = -1 }, unreadable, "a negative scene")
        assertRefused(PrepTests.glb(Self.triangle, translation: .zero) { $0["scenes"] = [["nodes": [-1]]] }, unreadable,
                      "a negative node in the scene")
    }

    /// A triangle's corners are listed as unsigned whole numbers, one at a time.
    func testOnlyWholeNumberCornersAreRead() {
        let small = try? GLB.parse(Self.damaged("accessors", 1, "componentType", 5121))
        XCTAssertEqual(small?.triangles, [[0, 0, 0]], "8-bit corners are read (here the low bytes of the 32-bit ones)")
        assertRefused(Self.damaged("accessors", 1, "componentType", 5126), unreadable, "corners as decimals")
        assertRefused(Self.damaged("accessors", 1, "componentType", 5122), unreadable, "corners that could be negative")
        assertRefused(Self.damaged("accessors", 1, "componentType", 5120), unreadable, "corners that could be negative")
        let grouped = PrepTests.glb(Self.triangle, translation: .zero) { json in
            Self.set(&json, "accessors", 1, "type", "VEC3")
            Self.set(&json, "accessors", 1, "count", 1)
        }
        assertRefused(grouped, unreadable, "corners grouped in threes")
    }

    /// A placement has three numbers to move by, four to turn by and three to scale by.
    func testAPlacementOfTheWrongSizeIsRefused() {
        let reason = "the .glb places its parts in a way Mimic can't read"
        assertRefused(Self.damaged("nodes", 0, "rotation", [0, 0, 0]), reason, "a turn of three numbers")
        assertRefused(Self.damaged("nodes", 0, "translation", [1, 2]), reason, "a move of two numbers")
        assertRefused(Self.damaged("nodes", 0, "scale", [1, 1]), reason, "a scale of two numbers")
    }

    /// A node inside itself, or listed twice, would be walked without end.
    func testPartsThatLoopAreRefused() {
        let reason = "the .glb's parts loop back on themselves"
        assertRefused(Self.damaged("nodes", 0, "children", [0]), reason, "a node inside itself")
        let twice = PrepTests.glb(Self.triangle, translation: .zero) { $0["nodes"] = [["children": [1, 1]], ["mesh": 0]] as [[String: Any]] }
        assertRefused(twice, reason, "a node listed twice")
    }

    /// The same parts, data or corners listed over and over are read only so far (#334): a file of
    /// a few MB could otherwise be read out to tens of GB, or walked for hours.
    func testDataListedOverAndOverIsReadOnlySoFar() throws {
        func refused(_ data: Data, most: Int, _ what: String, line: UInt = #line) {
            XCTAssertThrowsError(try GLB.parse(data, painted: false, most: most), what, line: line) {
                XCTAssertEqual(($0 as? PrepError)?.description, "the .glb is too big", what, line: line)
            }
        }
        let primitive: [String: Any] = ["attributes": ["POSITION": 0], "indices": 1]
        let thrice = PrepTests.glb(Self.triangle, translation: .zero) { json in
            Self.set(&json, "meshes", 0, "primitives", [primitive, primitive, primitive])
        }
        XCTAssertEqual(try GLB.parse(thrice, painted: false, most: 9).mesh.positions.count, 9)
        refused(thrice, most: 8, "one mesh's positions read three times")
        let fourTimes = Mesh(positions: Self.triangle.positions, triangles: Array(repeating: [0, 1, 2], count: 4))
        XCTAssertEqual(try GLB.parse(PrepTests.glb(fourTimes, translation: .zero), painted: false, most: 12).mesh.triangles.count, 4)
        refused(PrepTests.glb(fourTimes, translation: .zero), most: 10, "more corners than the most")
        let empty = PrepTests.glb(Self.triangle, translation: .zero) { json in
            json["nodes"] = [["children": []], ["mesh": 0]] as [[String: Any]]
            json["scenes"] = [["nodes": Array(repeating: 0, count: 20) + [1]]]
        }
        refused(empty, most: 20, "an empty part listed over and over")
    }

    /// Parts nested 64 deep are read; any deeper are left out.
    func testPartsNestedTooDeepAreLeftOut() throws {
        func chain(_ length: Int) -> Data {
            PrepTests.glb(Self.triangle, translation: .zero) { json in
                json["nodes"] = (0..<length).map { i -> [String: Any] in i < length - 1 ? ["children": [i + 1]] : ["mesh": 0] }
            }
        }
        XCTAssertEqual(try GLB.parse(chain(64)).triangles, [[0, 1, 2]])
        assertRefused(chain(65), "no mesh in the .glb", "a mesh 65 deep")
    }
}
