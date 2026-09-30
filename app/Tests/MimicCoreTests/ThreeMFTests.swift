import Foundation
import simd
import XCTest
@testable import MimicCore

final class ThreeMFTests: XCTestCase {
    /// Rows left to right with a gap, a new row when the bed is full, centred on the bed; no two
    /// minis overlap.
    func testLayoutKeepsMinisApart() {
        let sizes: [SIMD2<Float>] = [[25, 25], [50, 50], [100, 30], [80, 80], [25, 25]]
        let corners = ThreeMF.layout(sizes, bed: 200, gap: 5)
        for i in sizes.indices {
            for j in sizes.indices where j > i {
                let apart = corners[i].x + sizes[i].x + 5 <= corners[j].x + 0.001 || corners[j].x + sizes[j].x + 5 <= corners[i].x + 0.001
                    || corners[i].y + sizes[i].y + 5 <= corners[j].y + 0.001 || corners[j].y + sizes[j].y + 5 <= corners[i].y + 0.001
                XCTAssertTrue(apart, "\(i) and \(j) overlap: \(corners)")
            }
        }
        for (c, s) in zip(corners, sizes) {
            XCTAssertGreaterThanOrEqual(min(c.x, c.y), 0, "on the bed")
            XCTAssertLessThanOrEqual(max(c.x + s.x, c.y + s.y), 200, "on the bed")
        }
        XCTAssertEqual(ThreeMF.layout([[20, 10]], bed: 100, gap: 5), [[40, 45]], "one mini in the middle")
    }

    /// Two minis in one 3MF: each an object named after it, its corners shared, placed apart,
    /// standing on the bed.
    func testTwoMinisInOneFile() throws {
        func cube(_ half: Float, lifted: Float) -> [SIMD3<Float>] {
            let m = PrepTests.box(half: [half, half, half])
            return m.triangles.flatMap { t in [t.x, t.y, t.z].map { m.positions[Int($0)] + [0, 0, lifted] } }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("party-\(UUID().uuidString).3mf")
        defer { try? FileManager.default.removeItem(at: url) }
        try ThreeMF.write([("Dwarf Cleric", cube(10, lifted: 10)), ("Elf & \"Bow\"", cube(5, lifted: 3))], to: url)

        let unzip = Process(), pipe = Pipe()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-l", url.path]
        unzip.standardOutput = pipe
        try unzip.run(); unzip.waitUntilExit()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for f in ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"] { XCTAssertTrue(listing.contains(f), listing) }

        let read = Process(), out = Pipe()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        read.arguments = ["-p", url.path, "3D/3dmodel.model"]
        read.standardOutput = out
        try read.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        read.waitUntilExit()
        let doc = try XMLDocument(data: data)
        let objects = try doc.nodes(forXPath: "//*[local-name()='object']") as! [XMLElement]
        XCTAssertEqual(objects.compactMap { $0.attribute(forName: "name")?.stringValue }, ["Dwarf Cleric", "Elf & \"Bow\""])
        for o in objects {
            XCTAssertEqual(try o.nodes(forXPath: ".//*[local-name()='vertex']").count, 8, "a cube's corners, once each")
            XCTAssertEqual(try o.nodes(forXPath: ".//*[local-name()='triangle']").count, 12)
        }
        let items = try doc.nodes(forXPath: "//*[local-name()='item']") as! [XMLElement]
        let moves = items.map { $0.attribute(forName: "transform")!.stringValue!.split(separator: " ").suffix(3).map { Float($0)! } }
        XCTAssertEqual(moves[0][2], -0.0, "the dwarf's bottom (at 0) stays on the bed")
        XCTAssertEqual(moves[1][2], 2, "the elf's bottom (at -2) is lifted to the bed")
        // The dwarf spans x -10…10 moved by moves[0][0]; the elf -5…5 by moves[1][0].
        XCTAssertEqual((moves[1][0] - 5) - (moves[0][0] + 10), ThreeMF.gap, accuracy: 0.001, "side by side, a gap apart")
    }
}
