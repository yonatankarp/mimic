import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// A triangle mesh in millimetres, z up: what print prep reads, builds and writes.
public struct Mesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var triangles: [SIMD3<UInt32>]

    public init(positions: [SIMD3<Float>] = [], triangles: [SIMD3<UInt32>] = []) {
        self.positions = positions; self.triangles = triangles
    }

    public var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
}

public struct PrepError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// Reads the 3D engine's .glb: every triangle of every mesh in the scene, placed by its node
/// transforms. Materials, textures and normals are skipped: print prep only needs the shape.
/// Model I/O can't read glTF, and the engine only writes this one container.
public enum GLB {
    public static func read(_ url: URL) throws -> Mesh {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> Mesh { try parse(data, painted: false).mesh }

    /// The colours the 3D engine painted a model with: each vertex's place on its picture, and the
    /// picture as stored (WebP or PNG), from the material of its triangles.
    public struct Paint {
        public var uv: [SIMD2<Float>]
        public var image: Data
    }

    /// The model and, when every triangle has a place on one colour picture, its `Paint`.
    public static func read(painted url: URL) throws -> (mesh: Mesh, paint: Paint?) {
        try parse(Data(contentsOf: url), painted: true)
    }

    static func parse(_ data: Data, painted: Bool) throws -> (mesh: Mesh, paint: Paint?) {
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        guard data.count >= 20, u32(0) == 0x4654_6C67 else { throw PrepError("not a .glb file") }
        var json: [String: Any]?, bin: Range<Int>?
        var at = 12
        while at + 8 <= data.count {
            let length = Int(u32(at)), type = u32(at + 4), body = (at + 8)..<min(data.count, at + 8 + length)
            if type == 0x4E4F_534A { json = try JSONSerialization.jsonObject(with: data.subdata(in: body)) as? [String: Any] }
            if type == 0x004E_4942 { bin = body }
            at += 8 + length
        }
        guard let json, let bin else { throw PrepError("the .glb has no scene or no data") }

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let unreadable = PrepError("the .glb stores its shape in a way Mimic can't read")
        /// A count, offset or index: missing is nil, anything but a whole number from zero up is
        /// a broken file, not a default.
        func whole(_ value: Any) throws -> Int {
            guard let n = value as? NSNumber, let i = Int(exactly: n.doubleValue), i >= 0 else { throw unreadable }
            return i
        }
        func int(_ d: [String: Any], _ k: String) throws -> Int? { try d[k].map(whole) }

        /// Element `i`, component `c` of an accessor, as a Double, wherever its view puts it.
        func reader(_ index: Int) throws -> (count: Int, width: Int, get: (Int, Int) -> Double) {
            guard index < accessors.count, let a = Optional(accessors[index]), let v = try int(a, "bufferView"), v < views.count,
                  a["sparse"] == nil else { throw unreadable }
            let view = views[v]
            let type = try int(a, "componentType") ?? 0
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][type] ?? 0
            let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? ""] ?? 0
            guard size > 0, width > 0 else { throw unreadable }
            // Each checked on its own first, so a huge number can't overflow the sums below.
            let viewOffset = try int(view, "byteOffset") ?? 0, offset = try int(a, "byteOffset") ?? 0
            let stride = try int(view, "byteStride") ?? size * width
            let count = try int(a, "count") ?? 0
            guard stride >= size * width else { throw unreadable }  // elements can't overlap
            guard viewOffset <= bin.count, offset <= bin.count else { throw PrepError("the .glb is cut short") }
            let start = bin.lowerBound + viewOffset + offset
            guard count == 0 || (start + size * width <= bin.upperBound && count - 1 <= (bin.upperBound - start - size * width) / stride)
            else { throw PrepError("the .glb is cut short") }
            let get: (Int, Int) -> Double = { i, c in
                data.withUnsafeBytes { b in
                    let o = start + i * stride + c * size
                    switch type {
                    case 5126: return Double(b.loadUnaligned(fromByteOffset: o, as: Float.self))
                    case 5125: return Double(b.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    case 5123: return Double(b.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                    case 5122: return Double(b.loadUnaligned(fromByteOffset: o, as: Int16.self))
                    case 5121: return Double(b.loadUnaligned(fromByteOffset: o, as: UInt8.self))
                    default: return Double(b.loadUnaligned(fromByteOffset: o, as: Int8.self))
                    }
                }
            }
            return (count, width, get)
        }

        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        var out = Mesh()
        // nil once a primitive has no place on a picture, or a different material.
        var uv: [SIMD2<Float>]? = painted ? [] : nil
        var material: Int?

        func local(_ n: [String: Any]) throws -> simd_double4x4 {
            if let m = n["matrix"] as? [NSNumber], m.count == 16 {
                let v = m.map(\.doubleValue)
                return simd_double4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                                SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
            }
            let t = (n["translation"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0]
            let r = (n["rotation"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 1]
            let s = (n["scale"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1, 1]
            guard t.count == 3, r.count == 4, s.count == 3 else { throw PrepError("the .glb places its parts in a way Mimic can't read") }
            let rot = simd_double4x4(simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            let scale = simd_double4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
            var m = rot * scale
            m.columns.3 = SIMD4(t[0], t[1], t[2], 1)
            return m
        }

        func add(mesh index: Int, _ world: simd_double4x4) throws {
            guard index < meshes.count else { return }
            for prim in meshes[index]["primitives"] as? [[String: Any]] ?? [] {
                guard (try int(prim, "mode") ?? 4) == 4 else { continue }  // points and lines have no volume
                guard let attrs = prim["attributes"] as? [String: Any], let pos = try int(attrs, "POSITION") else { continue }
                let p = try reader(pos)
                guard p.width == 3 else { throw PrepError("the .glb's positions aren't 3D") }
                guard out.positions.count + p.count <= Int(UInt32.max) else { throw PrepError("the .glb is too big") }
                let base = UInt32(out.positions.count)
                out.positions.reserveCapacity(out.positions.count + p.count)
                for i in 0..<p.count {
                    let w = world * SIMD4(p.get(i, 0), p.get(i, 1), p.get(i, 2), 1)
                    // glTF is y-up; print prep, slicers and the renders are z-up. The same turn
                    // Blender's importer makes: glTF's front (+z) comes out facing -y.
                    out.positions.append(SIMD3(Float(w.x), Float(-w.z), Float(w.y)))
                }
                if uv != nil, let t = try int(attrs, "TEXCOORD_0"), let m = try int(prim, "material"), material ?? m == m {
                    let r = try reader(t)
                    guard r.width == 2, r.count == p.count else { throw PrepError("the .glb's picture places don't match its corners") }
                    material = m
                    for i in 0..<r.count { uv!.append(SIMD2(Float(r.get(i, 0)), Float(r.get(i, 1)))) }
                } else {
                    uv = nil
                }
                let flip = simd_determinant(world) < 0  // a mirroring transform turns every triangle inside out
                var idx: [UInt32]
                if let ii = try int(prim, "indices") {
                    let r = try reader(ii)
                    let kind = try int(accessors[ii], "componentType")
                    guard r.width == 1, [5121, 5123, 5125].contains(kind) else { throw unreadable }  // unsigned whole numbers only
                    idx = try (0..<r.count).map {
                        guard let i = UInt32(exactly: r.get($0, 0)) else { throw unreadable }
                        return i
                    }
                } else {
                    idx = (0..<UInt32(p.count)).map { $0 }
                }
                guard idx.allSatisfy({ Int($0) < p.count }) else { throw PrepError("the .glb has triangles pointing nowhere") }
                for t in stride(from: 0, to: idx.count - 2, by: 3) {
                    let tri = SIMD3(base + idx[t], base + idx[t + 1], base + idx[t + 2])
                    out.triangles.append(flip ? SIMD3(tri.x, tri.z, tri.y) : tri)
                }
            }
        }

        /// `seen` is every node reached from this root: a node listed twice, or among its own
        /// children, would be walked over and over.
        func walk(_ n: Int, _ parent: simd_double4x4, depth: Int, seen: inout Set<Int>) throws {
            guard n < nodes.count, depth < 64 else { return }
            guard seen.insert(n).inserted else { throw PrepError("the .glb's parts loop back on themselves") }
            let world = try parent * local(nodes[n])
            if let m = try int(nodes[n], "mesh") { try add(mesh: m, world) }
            for c in nodes[n]["children"] as? [Any] ?? [] { try walk(whole(c), world, depth: depth + 1, seen: &seen) }
        }

        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let scene = try int(json, "scene") ?? 0
        let roots = try scene < scenes.count ? (scenes[scene]["nodes"] as? [Any] ?? []).map(whole) : Array(nodes.indices)
        for r in roots {
            var seen = Set<Int>()
            try walk(r, matrix_identity_double4x4, depth: 0, seen: &seen)
        }
        if roots.isEmpty { for m in meshes.indices { try add(mesh: m, matrix_identity_double4x4) } }
        guard !out.triangles.isEmpty else { throw PrepError("no mesh in the .glb") }
        // Material → its base colour texture → that texture's picture → the bytes stored for it.
        func entry(_ list: String, _ i: Int) -> [String: Any]? {
            guard let a = json[list] as? [[String: Any]], a.indices.contains(i) else { return nil }
            return a[i]
        }
        func image() throws -> Data? {
            guard let material, let m = entry("materials", material),
                  let pbr = m["pbrMetallicRoughness"] as? [String: Any], let tex = pbr["baseColorTexture"] as? [String: Any],
                  let t = try int(tex, "index"), let texture = entry("textures", t),
                  // The engine's WebP pictures are named through EXT_texture_webp instead.
                  let i = try int(texture, "source") ?? ((texture["extensions"] as? [String: Any])?["EXT_texture_webp"] as? [String: Any]).flatMap({ try int($0, "source") }),
                  let img = entry("images", i), let v = try int(img, "bufferView"), let view = entry("bufferViews", v) else { return nil }
            // Checked apart first, as `reader`'s are, so a huge number can't overflow the sum.
            let offset = try int(view, "byteOffset") ?? 0, length = try int(view, "byteLength") ?? 0
            guard offset <= bin.count, length <= bin.count - offset else { return nil }
            return data.subdata(in: (bin.lowerBound + offset)..<(bin.lowerBound + offset + length))
        }
        // A picture Mimic can't find leaves the shape, unpainted.
        guard let uv, let picture = try? image() else { return (out, nil) }
        return (out, Paint(uv: uv, image: picture))
    }

    /// A .glb of `mesh` that `parse` reads back exactly: y up, as glTF is, so the turn `parse`
    /// makes undoes this one. One mesh in matte grey (glTF's default material is metal, which
    /// most viewers draw near black), for an imported STL (#96) and Export for Virtual Tabletop.
    /// With `paint`, a JPEG and each vertex's place on it, painted with that instead.
    public static func encode(_ mesh: Mesh, paint: (uv: [SIMD2<Float>], jpeg: Data)? = nil) -> Data {
        var bin = Data(capacity: 12 * mesh.positions.count + 12 * mesh.triangles.count)
        func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
        for p in mesh.positions { f32(p.x); f32(p.z); f32(-p.y) }
        let indexStart = bin.count
        for t in mesh.triangles { for v in [t.x, t.y, t.z] { withUnsafeBytes(of: v.littleEndian) { bin.append(contentsOf: $0) } } }
        var attributes = ["POSITION": 0]
        var accessors: [[String: Any]] = [["bufferView": 0, "componentType": 5126, "count": mesh.positions.count, "type": "VEC3"],
                                          ["bufferView": 1, "componentType": 5125, "count": mesh.triangles.count * 3, "type": "SCALAR"]]
        var views: [[String: Any]] = [["buffer": 0, "byteOffset": 0, "byteLength": indexStart],
                                      ["buffer": 0, "byteOffset": indexStart, "byteLength": bin.count - indexStart]]
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Mimic"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "materials": [["name": "Grey", "pbrMetallicRoughness": ["baseColorFactor": [0.6, 0.6, 0.6, 1],
                                                                   "metallicFactor": 0, "roughnessFactor": 0.8]]],
        ]
        if let paint {
            let uvStart = bin.count
            for t in paint.uv { f32(t.x); f32(t.y) }
            let imageStart = bin.count
            bin.append(paint.jpeg)
            while bin.count % 4 != 0 { bin.append(0) }
            attributes["TEXCOORD_0"] = accessors.count
            accessors.append(["bufferView": views.count, "componentType": 5126, "count": paint.uv.count, "type": "VEC2"])
            views.append(["buffer": 0, "byteOffset": uvStart, "byteLength": imageStart - uvStart])
            json["images"] = [["bufferView": views.count, "mimeType": "image/jpeg"]]
            views.append(["buffer": 0, "byteOffset": imageStart, "byteLength": paint.jpeg.count])
            json["samplers"] = [["magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071]]  // linear, clamped
            json["textures"] = [["source": 0, "sampler": 0]]
            json["materials"] = [["name": "Painted", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0],
                                                                             "metallicFactor": 0, "roughnessFactor": 0.8]]]
        }
        json["meshes"] = [["primitives": [["attributes": attributes, "indices": 1, "material": 0]]]]
        json["accessors"] = accessors
        json["bufferViews"] = views
        json["buffers"] = [["byteLength": bin.count]]
        var text = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data(capacity: 28 + text.count + bin.count)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); out.append(text)
        u32(bin.count); u32(0x004E_4942); out.append(bin)
        return out
    }
}

/// Export for Virtual Tabletop (#158): a mini's print file as a small .glb that a virtual
/// tabletop loads, at its true size in metres, facing glTF's front. In the 3D engine's colours
/// when it painted the mini from a colour picture (#256), else grey.
public enum Tabletop {
    /// ponytail: one budget, a guess at "low poly"; Low / Medium choices once tabletops say what they take.
    public static let triangles = 5_000
    /// The colours' picture, square: a cell for each triangle, 28 pixels wide at 5,000.
    static let size = 2048

    /// Made from a colour picture without the grey sculpt: the 3D engine was shown the colours
    /// and painted them all round. With the sculpt it painted grey, as with a fix to the picture
    /// (always redrawn as one, #156), and a description is drawn grey.
    public static func inColour(_ s: MiniSettings) -> Bool { s.source == .image && s.restyle != true && s.change == nil && !s.isImported }

    /// Writes `mini`'s .glb to `url`, and says how many triangles and bytes it came to, and
    /// whether it's in colour.
    @discardableResult
    public static func export(_ mini: Mini, to url: URL, triangles: Int = triangles) throws -> (triangles: Int, bytes: Int, colour: Bool) {
        guard let stl = mini.stl else { throw PrepError("it isn't made yet") }
        // Grey whenever the colours can't be had: the shape is what a tabletop can't do without.
        // `facesAway` and a `Placement` never meet: a record is only ever beside the print file
        // it was written with, and a print file written since 0.10.0 faces front (`Mini.facesAway`
        // goes by its date). A turned print file's colours come from its model placed again.
        let colours = try? EngineColours.of(mini)
        let made = try export(stl, to: url, triangles: triangles, colours: colours, facesAway: mini.facesAway)
        return (made.triangles, made.bytes, colours != nil)
    }

    /// Writes the .glb of `stl` to `url`, painted with `colours` when given: the trim can stop
    /// short of `triangles` where a collapse would tear the surface. A print file that
    /// `facesAway` is turned round first, to face the front as the model is placed now.
    @discardableResult
    static func export(_ stl: URL, to url: URL, triangles: Int = triangles, colours: EngineColours? = nil,
                       facesAway: Bool = false) throws -> (triangles: Int, bytes: Int) {
        var solid = ModelImport.weld(try STL.read(stl))
        // Half a turn about the vertical: both axes, as one alone would mirror it.
        if facesAway { solid.positions = solid.positions.map { SIMD3(-$0.x, -$0.y, $0.z) } }
        guard !solid.triangles.isEmpty else { throw PrepError("the print file has no triangles") }
        // Trimmed in millimetres: Decimate's thresholds are.
        var mesh = solid.triangles.count > triangles ? Decimate.run(solid, target: triangles) : solid
        var paint: (uv: [SIMD2<Float>], jpeg: Data)?
        if let colours {
            let baked = bake(mesh, colours)
            mesh = baked.mesh
            paint = (baked.uv, try jpeg(baked.pixels, size: size))
        }
        // Print files face -y, which `encode` writes as glTF's front (+z).
        mesh.positions = mesh.positions.map { $0 / 1000 }
        let data = GLB.encode(mesh, paint: paint)
        try data.write(to: url, options: .atomic)
        return (mesh.triangles.count, data.count)
    }

    /// The base's grey, and anything else the model isn't near.
    static let grey = SIMD3<UInt8>(150, 150, 150)

    /// Colours `low`, the trimmed print file: each triangle gets a cell of its own on a
    /// `size`-pixel square, every pixel of it the engine's colour under it (`EngineColours`). A cell
    /// is the whole square around its triangle, so a pixel the texture's smoothing reaches past
    /// the edge has the edge's colour, not a neighbour's. Corners aren't shared any more: a
    /// corner's place differs in each of its triangles' cells.
    static func bake(_ low: Mesh, _ colours: EngineColours, size: Int = size) -> (mesh: Mesh, uv: [SIMD2<Float>], pixels: [UInt8]) {
        let n = Int(Double(low.triangles.count).squareRoot().rounded(.up)), cell = size / n
        let inset: Float = 1  // pixels between a cell's edge and its triangle
        var mesh = Mesh(), uv: [SIMD2<Float>] = []
        mesh.positions.reserveCapacity(3 * low.triangles.count); uv.reserveCapacity(3 * low.triangles.count)
        for (k, t) in low.triangles.enumerated() {
            let x0 = Float(k % n * cell), y0 = Float(k / n * cell), c = Float(cell)
            for (corner, at) in [(t.x, SIMD2(x0 + inset, y0 + inset)), (t.y, SIMD2(x0 + c - inset, y0 + inset)), (t.z, SIMD2(x0 + inset, y0 + c - inset))] {
                mesh.positions.append(low.positions[Int(corner)])
                uv.append(at / Float(size))
            }
            let i = UInt32(3 * k)
            mesh.triangles.append(SIMD3(i, i + 1, i + 2))
        }

        // Each corner's normal, its triangles' weighted by their area, for a smooth one across a triangle.
        var normals = [SIMD3<Float>](repeating: .zero, count: low.positions.count)
        for t in low.triangles {
            let n = simd_cross(low.positions[Int(t.y)] - low.positions[Int(t.x)], low.positions[Int(t.z)] - low.positions[Int(t.x)])
            normals[Int(t.x)] += n; normals[Int(t.y)] += n; normals[Int(t.z)] += n
        }
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: low.triangles.count) { k in
                let t = low.triangles[k]
                let a = low.positions[Int(t.x)], b = low.positions[Int(t.y)], c = low.positions[Int(t.z)]
                let na = normals[Int(t.x)], nb = normals[Int(t.y)], nc = normals[Int(t.z)]
                let x0 = k % n * cell, y0 = k / n * cell, span = Float(cell) - 2 * inset
                for y in y0..<(y0 + cell) {
                    for x in x0..<(x0 + cell) {
                        // Where this pixel is on the triangle, the square's far half folded back onto it.
                        var s = max(0, (Float(x - x0) + 0.5 - inset) / span), r = max(0, (Float(y - y0) + 0.5 - inset) / span)
                        if s + r > 1 { let sum = s + r; s /= sum; r /= sum }
                        let rgb = colours.colour(at: a * (1 - s - r) + b * s + c * r, along: na * (1 - s - r) + nb * s + nc * r) ?? grey
                        let o = 4 * (y * size + x)
                        out[o] = rgb.x; out[o + 1] = rgb.y; out[o + 2] = rgb.z
                    }
                }
            }
        }
        return (mesh, uv, pixels)
    }

    static func jpeg(_ pixels: [UInt8], size: Int) throws -> Data {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PrepError("couldn't make the colours' picture")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PrepError("couldn't make the colours' picture") }
        return data as Data
    }
}

/// Binary STL: what every slicer opens.
public enum STL {
    /// Written beside it and renamed into place: a resize stopped mid-write keeps the old print
    /// file whole instead of leaving half of a new one.
    public static func write(_ mesh: Mesh, to url: URL) throws {
        var data = Data(count: 84 + 50 * mesh.triangles.count)
        data.withUnsafeMutableBytes { b in
            let header = Array("Mimic print file".utf8)
            for (i, c) in header.enumerated() { b[i] = c }
            b.storeBytes(of: UInt32(mesh.triangles.count).littleEndian, toByteOffset: 80, as: UInt32.self)
            var o = 84
            for t in mesh.triangles {
                let a = mesh.positions[Int(t.x)], bb = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
                let n = simd_normalize(simd_cross(bb - a, c - a))
                for v in [n.x.isFinite ? n : .zero, a, bb, c] {
                    b.storeBytes(of: v.x, toByteOffset: o, as: Float.self)
                    b.storeBytes(of: v.y, toByteOffset: o + 4, as: Float.self)
                    b.storeBytes(of: v.z, toByteOffset: o + 8, as: Float.self)
                    o += 12
                }
                o += 2
            }
        }
        let part = url.path.hasSuffix(".stl") ? String(url.path.dropLast(4)) + ".part.stl" : url.path + ".part.stl"
        try data.write(to: URL(fileURLWithPath: part))
        guard rename(part, url.path) == 0 else { throw PrepError("couldn't put \(url.lastPathComponent) in place") }
    }

    /// Reads a binary STL back as separate triangles (tests, and anything checking a print file).
    public static func read(_ url: URL) throws -> [SIMD3<Float>] {
        let data = try Data(contentsOf: url)
        guard data.count >= 84 else { throw PrepError("not an STL file") }
        return data.withUnsafeBytes { b in
            let n = Int(b.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
            var out: [SIMD3<Float>] = []
            out.reserveCapacity(3 * n)
            for t in 0..<min(n, (data.count - 84) / 50) {
                for v in 1...3 {
                    let o = 84 + t * 50 + v * 12
                    out.append(SIMD3(b.loadUnaligned(fromByteOffset: o, as: Float.self),
                                     b.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                     b.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                }
            }
            return out
        }
    }
}
