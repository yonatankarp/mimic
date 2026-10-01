import Foundation
import simd

/// One print file holding several minis, for Open Together and Copies: each mini its own object,
/// named after it, laid out on the bed with a gap between them, so the slicer can move or remove
/// any one. A copy is the same object placed again, so six goblins are one goblin's worth of file.
/// A 3MF is a zip of XML; the XML is written here and zipped by the Mac's own `zip`.
public enum ThreeMF {
    /// A common bed (Bambu's X1 and P1, 256 mm). A party that doesn't fit runs off it, and the
    /// slicer's Arrange puts it right on whatever bed it has.
    public static let bed: Float = 256
    public static let gap: Float = 5
    /// How many copies of each mini one file can hold.
    public static let copies = 1...20

    /// What's typed in Copies' number field, kept within `copies`; nil when it isn't a number.
    public static func copies(typed: String) -> Int? {
        Int(typed.trimmingCharacters(in: .whitespaces)).map { min(max($0, Self.copies.lowerBound), Self.copies.upperBound) }
    }

    /// Where each footprint (width, depth) goes: rows left to right, a new row when one is
    /// full, the whole centred on the bed. Returns each one's lower-left corner.
    public static func layout(_ sizes: [SIMD2<Float>], bed: Float = bed, gap: Float = gap) -> [SIMD2<Float>] {
        var corners: [SIMD2<Float>] = [], x: Float = 0, y: Float = 0, row: Float = 0, width: Float = 0
        for s in sizes {
            if x > 0 && x + s.x > bed { x = 0; y += row + gap; row = 0 }
            corners.append(SIMD2(x, y))
            width = max(width, x + s.x)
            x += s.x + gap
            row = max(row, s.y)
        }
        let shift = (SIMD2(bed, bed) - SIMD2(width, y + row)) / 2
        return corners.map { $0 + shift }
    }

    /// Writes `parts` (a name, and a print file's triangles as three corners each) as one 3MF,
    /// with `copies` of each.
    public static func write(_ parts: [(name: String, corners: [SIMD3<Float>])], copies: Int = 1, to url: URL) throws {
        let copies = min(max(copies, Self.copies.lowerBound), Self.copies.upperBound)
        var bounds: [(lo: SIMD3<Float>, hi: SIMD3<Float>)] = []
        for p in parts {
            var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
            for c in p.corners { lo = simd_min(lo, c); hi = simd_max(hi, c) }
            bounds.append((lo, hi))
        }
        // Each mini's copies next to each other: the goblins, then the orcs.
        let corners = layout(bounds.flatMap { b in repeatElement(SIMD2(b.hi.x - b.lo.x, b.hi.y - b.lo.y), count: copies) })

        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
            <resources>

            """
        var build = "<build>\n"
        for (n, p) in parts.enumerated() {
            // An STL repeats each corner in every triangle it's in; a 3MF lists it once.
            var index: [SIMD3<Float>: Int] = [:], vertices = "", triangles = ""
            var tri: [Int] = []
            for c in p.corners {
                if let i = index[c] { tri.append(i); continue }
                index[c] = index.count
                tri.append(index.count - 1)
                vertices += "<vertex x=\"\(c.x)\" y=\"\(c.y)\" z=\"\(c.z)\"/>\n"
            }
            for t in stride(from: 0, to: tri.count - 2, by: 3) {
                triangles += "<triangle v1=\"\(tri[t])\" v2=\"\(tri[t + 1])\" v3=\"\(tri[t + 2])\"/>\n"
            }
            xml += "<object id=\"\(n + 1)\" name=\"\(escaped(p.name))\" type=\"model\"><mesh><vertices>\n"
            xml += vertices + "</vertices><triangles>\n" + triangles + "</triangles></mesh></object>\n"
            // Moved, not rewritten: its lower-left corner to its place, its bottom on the bed.
            for c in 0..<copies {
                let move = corners[n * copies + c] - SIMD2(bounds[n].lo.x, bounds[n].lo.y)
                build += "<item objectid=\"\(n + 1)\" transform=\"1 0 0 0 1 0 0 0 1 \(move.x) \(move.y) \(-bounds[n].lo.z)\"/>\n"
            }
        }
        xml += "</resources>\n" + build + "</build>\n</model>\n"

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("3mf-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("3D"), withIntermediateDirectories: true)
        try Data(contentTypes.utf8).write(to: dir.appendingPathComponent("[Content_Types].xml"))
        try Data(relationships.utf8).write(to: dir.appendingPathComponent("_rels/.rels"))
        try Data(xml.utf8).write(to: dir.appendingPathComponent("3D/3dmodel.model"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        // Fastest compression: 1.5 s instead of 4.3 for four minis, and 47 MB instead of 38 for
        // a file that only goes to the slicer.
        zip.arguments = ["-q", "-X", "-1", "-r", "together.3mf", "[Content_Types].xml", "_rels", "3D"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw PrepError("couldn't pack \(url.lastPathComponent)") }
        try? fm.removeItem(at: url)
        try fm.moveItem(at: dir.appendingPathComponent("together.3mf"), to: url)
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
        """
    static let relationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """
}
