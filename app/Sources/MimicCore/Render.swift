import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// The preview pictures: grey clay, front, left, right and back, 900 × 900, orthographic, on a
/// transparent background, like the Blender workbench renders they replace. Drawn in software:
/// it needs no window or GPU (the 3D engine may be using it), and takes about a second.
public enum Render {
    static let size = 900
    static let supersample = 2

    /// Print files face -y (z up), as slicers' front views look at them (#275), so the figure's
    /// own left is +x. Each camera sits on the `toward` side looking back at the figure, with
    /// `right` to its right: right × up = toward. "left" and "right" are the figure's sides:
    /// "left" looks at its left side, so its face is on the left of the picture.
    static let cameras: [(String, right: SIMD3<Float>, toward: SIMD3<Float>)] = [
        ("front", [1, 0, 0], [0, -1, 0]), ("left", [0, 1, 0], [1, 0, 0]),
        ("right", [0, -1, 0], [-1, 0, 0]), ("back", [-1, 0, 0], [0, 1, 0]),
    ]
    static let up: SIMD3<Float> = [0, 0, 1]

    /// Writes `<name>_front.png`, `_left.png`, `_right.png` and `_back.png` beside the print
    /// file, then removes the one `_side.png` an older mini has (the view "right" now is).
    public static func views(_ mesh: Mesh, besides stl: URL) throws {
        let stem = stl.deletingPathExtension().path
        let normals = mesh.vertexNormals()
        let (lo, hi) = mesh.bounds
        let mid = (lo + hi) / 2, span = 1.15 * max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: cameras.count) { n in
            let c = cameras[n]
            let pixels = picture(mesh, normals, mid: mid, span: span, right: c.right, up: up, toward: c.toward)
            do { try png(pixels, to: URL(fileURLWithPath: "\(stem)_\(c.0).png")) } catch { failures.add(error) }
        }
        if let e = failures.first { throw e }
        try? FileManager.default.removeItem(atPath: "\(stem)_side.png")
    }

    final class Failures: @unchecked Sendable {
        private var errors: [Error] = []
        private let lock = NSLock()
        func add(_ e: Error) { lock.withLock { errors.append(e) } }
        var first: Error? { lock.withLock { errors.first } }
    }

    /// RGBA, straight alpha, `size` × `size`.
    static func picture(_ mesh: Mesh, _ normals: [SIMD3<Float>], mid: SIMD3<Float>, span: Float,
                        right: SIMD3<Float>, up: SIMD3<Float>, toward: SIMD3<Float>) -> [UInt8] {
        let n = size * supersample
        let scale = Float(n) / span
        var depth = [Float](repeating: -.infinity, count: n * n)
        var normal = [SIMD3<Float>](repeating: .zero, count: n * n)
        let view = mesh.positions.map { p -> SIMD3<Float> in
            let d = p - mid
            return SIMD3(Float(n) / 2 + simd_dot(d, right) * scale, Float(n) / 2 - simd_dot(d, up) * scale, simd_dot(d, toward))
        }
        let viewNormals = normals.map { SIMD3(simd_dot($0, right), simd_dot($0, up), simd_dot($0, toward)) }

        for t in mesh.triangles {
            let a = view[Int(t.x)], b = view[Int(t.y)], c = view[Int(t.z)]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if area == 0 { continue }
            let x0 = max(0, Int(min(a.x, b.x, c.x).rounded(.down))), x1 = min(n - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let y0 = max(0, Int(min(a.y, b.y, c.y).rounded(.down))), y1 = min(n - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            if x0 > x1 || y0 > y1 { continue }
            let na = viewNormals[Int(t.x)], nb = viewNormals[Int(t.y)], nc = viewNormals[Int(t.z)]
            for y in y0...y1 {
                let py = Float(y) + 0.5
                for x in x0...x1 {
                    let px = Float(x) + 0.5
                    let w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area
                    let w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area
                    let w2 = 1 - w0 - w1
                    if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                    let z = w0 * a.z + w1 * b.z + w2 * c.z
                    let i = y * n + x
                    if z > depth[i] { depth[i] = z; normal[i] = w0 * na + w1 * nb + w2 * nc }
                }
            }
        }

        // Clay shading from the view-space normal (a studio light fixed to the camera, as the
        // workbench's is), with screen-space cavity: surfaces curving away from the viewer
        // between neighbouring pixels are creases, darkened, and ridges lightened, which is
        // what makes a beard or a buckle read at thumbnail size.
        let key = simd_normalize(SIMD3<Float>(-0.45, 0.55, 0.7)), fill = simd_normalize(SIMD3<Float>(0.6, 0.1, 0.8))
        var shade = [Float](repeating: 0, count: n * n)
        let pixel = span / Float(n)
        var ring: [(Int, Int)] = []
        for r: Float in [8, 20, 40] {
            for a in 0..<4 {
                let angle = Float(a) * .pi / 4
                ring.append((Int((r * cos(angle)).rounded()), Int((r * sin(angle)).rounded())))
            }
        }
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                guard depth[i] > -.infinity else { continue }
                let nn = simd_normalize(normal[i])
                var v = 0.34 + 0.36 * max(0, simd_dot(nn, key)) + 0.14 * max(0, simd_dot(nn, fill)) + 0.06 * nn.y
                // Divergence of the normal across the neighbours: negative in a crease.
                func at(_ x: Int, _ y: Int) -> SIMD3<Float>? {
                    guard x >= 0, y >= 0, x < n, y < n, depth[y * n + x] > -.infinity else { return nil }
                    return simd_normalize(normal[y * n + x])
                }
                if let l = at(x - 3, y), let r = at(x + 3, y), let u = at(x, y - 3), let d = at(x, y + 3) {
                    let curvature = (r.x - l.x) + (u.y - d.y)
                    v *= 1 + 0.2 * max(-1, min(1, curvature))
                }
                // Deep creases (under a belt, between arm and body) also get less light: how far
                // the surface either side stands in front of this pixel. Opposite sides are
                // averaged so a plane merely tilted away from the camera isn't a crease.
                var hidden: Float = 0
                for (dx, dy) in ring {
                    guard x - dx >= 0, y - dy >= 0, x + dx >= 0, y + dy >= 0,
                          x - dx < n, y - dy < n, x + dx < n, y + dy < n else { continue }
                    let rise = (depth[(y + dy) * n + x + dx] + depth[(y - dy) * n + x - dx]) / 2 - depth[i]
                    if rise > 0 && rise < .infinity { hidden += min(1, rise / (4 * pixel)) }
                }
                shade[i] = v * (1 - 0.35 * hidden / Float(ring.count))
            }
        }

        var out = [UInt8](repeating: 0, count: size * size * 4)
        let s = supersample
        for y in 0..<size {
            for x in 0..<size {
                var sum: Float = 0, covered = 0
                for dy in 0..<s { for dx in 0..<s {
                    let i = (y * s + dy) * n + x * s + dx
                    if depth[i] > -.infinity { sum += shade[i]; covered += 1 }
                } }
                guard covered > 0 else { continue }
                let grey = UInt8(max(0, min(255, (sum / Float(covered)) * 214)))
                let o = (y * size + x) * 4
                out[o] = grey; out[o + 1] = grey; out[o + 2] = UInt8(min(255, Int(grey) + 1))
                out[o + 3] = UInt8(255 * covered / (s * s))
            }
        }
        return out
    }

    static func png(_ rgba: [UInt8], to url: URL) throws {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        guard let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PrepError(String(localized: "couldn't draw \(url.lastPathComponent)", bundle: .mimicCore))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PrepError(String(localized: "couldn't write \(url.lastPathComponent)", bundle: .mimicCore)) }
    }
}

extension Mesh {
    /// Smooth normals: each vertex's triangles' normals, weighted by area.
    func vertexNormals() -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in triangles {
            let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
            let n = simd_cross(b - a, c - a)
            out[Int(t.x)] += n; out[Int(t.y)] += n; out[Int(t.z)] += n
        }
        return out.map { simd_length($0) > 0 ? simd_normalize($0) : $0 }
    }
}
