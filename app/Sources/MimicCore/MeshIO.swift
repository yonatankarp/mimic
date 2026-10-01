import Foundation
import simd

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

    public static func parse(_ data: Data) throws -> Mesh {
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
        func int(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }

        /// Element `i`, component `c` of an accessor, as a Double, wherever its view puts it.
        func reader(_ index: Int) throws -> (count: Int, width: Int, get: (Int, Int) -> Double) {
            guard index < accessors.count, let a = Optional(accessors[index]), let v = int(a, "bufferView"), v < views.count,
                  a["sparse"] == nil else { throw PrepError("the .glb stores its shape in a way Mimic can't read") }
            let view = views[v]
            let type = int(a, "componentType") ?? 0
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][type] ?? 0
            let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? ""] ?? 0
            guard size > 0, width > 0 else { throw PrepError("the .glb stores its shape in a way Mimic can't read") }
            let start = bin.lowerBound + (int(view, "byteOffset") ?? 0) + (int(a, "byteOffset") ?? 0)
            let stride = int(view, "byteStride") ?? size * width
            let count = int(a, "count") ?? 0
            guard count == 0 || start + (count - 1) * stride + size * width <= bin.upperBound else { throw PrepError("the .glb is cut short") }
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

        func local(_ n: [String: Any]) -> simd_double4x4 {
            if let m = n["matrix"] as? [NSNumber], m.count == 16 {
                let v = m.map(\.doubleValue)
                return simd_double4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                                SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
            }
            let t = (n["translation"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0]
            let r = (n["rotation"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 1]
            let s = (n["scale"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1, 1]
            let rot = simd_double4x4(simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            let scale = simd_double4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
            var m = rot * scale
            m.columns.3 = SIMD4(t[0], t[1], t[2], 1)
            return m
        }

        func add(mesh index: Int, _ world: simd_double4x4) throws {
            guard index < meshes.count else { return }
            for prim in meshes[index]["primitives"] as? [[String: Any]] ?? [] {
                guard (int(prim, "mode") ?? 4) == 4 else { continue }  // points and lines have no volume
                guard let attrs = prim["attributes"] as? [String: Any], let pos = int(attrs, "POSITION") else { continue }
                let p = try reader(pos)
                guard p.width == 3 else { throw PrepError("the .glb's positions aren't 3D") }
                let base = UInt32(out.positions.count)
                out.positions.reserveCapacity(out.positions.count + p.count)
                for i in 0..<p.count {
                    let w = world * SIMD4(p.get(i, 0), p.get(i, 1), p.get(i, 2), 1)
                    // glTF is y-up; print prep, slicers and the renders are z-up. The same turn
                    // Blender's importer makes, so the figure faces +y as it did there.
                    out.positions.append(SIMD3(Float(w.x), Float(-w.z), Float(w.y)))
                }
                let flip = simd_determinant(world) < 0  // a mirroring transform turns every triangle inside out
                var idx: [UInt32]
                if let ii = int(prim, "indices") {
                    let r = try reader(ii)
                    idx = (0..<r.count).map { UInt32(r.get($0, 0)) }
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

        func walk(_ n: Int, _ parent: simd_double4x4, depth: Int) throws {
            guard n < nodes.count, depth < 64 else { return }
            let world = parent * local(nodes[n])
            if let m = int(nodes[n], "mesh") { try add(mesh: m, world) }
            for c in nodes[n]["children"] as? [NSNumber] ?? [] { try walk(c.intValue, world, depth: depth + 1) }
        }

        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let scene = int(json, "scene") ?? 0
        let roots = scene < scenes.count ? (scenes[scene]["nodes"] as? [NSNumber] ?? []).map(\.intValue) : Array(nodes.indices)
        for r in roots { try walk(r, matrix_identity_double4x4, depth: 0) }
        if roots.isEmpty { for m in meshes.indices { try add(mesh: m, matrix_identity_double4x4) } }
        guard !out.triangles.isEmpty else { throw PrepError("no mesh in the .glb") }
        return out
    }

    /// A .glb of `mesh` that `parse` reads back exactly: y up, as glTF is, so the turn `parse`
    /// makes undoes this one. Shape only, one mesh, for an imported STL (#96).
    public static func encode(_ mesh: Mesh) -> Data {
        var bin = Data(capacity: 12 * mesh.positions.count + 12 * mesh.triangles.count)
        func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
        for p in mesh.positions { f32(p.x); f32(p.z); f32(-p.y) }
        let indexStart = bin.count
        for t in mesh.triangles { for v in [t.x, t.y, t.z] { withUnsafeBytes(of: v.littleEndian) { bin.append(contentsOf: $0) } } }
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Mimic"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": mesh.positions.count, "type": "VEC3"],
                          ["bufferView": 1, "componentType": 5125, "count": mesh.triangles.count * 3, "type": "SCALAR"]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": indexStart],
                            ["buffer": 0, "byteOffset": indexStart, "byteLength": bin.count - indexStart]],
            "buffers": [["byteLength": bin.count]],
        ]
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
