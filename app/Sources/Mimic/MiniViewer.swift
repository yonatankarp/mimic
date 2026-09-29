import ModelIO
import RealityKit
import SwiftUI

/// The 3D view of a mini's print file. RealityKit can't open STL, so Model I/O reads it and
/// its triangles become a RealityKit mesh: 0.37 s for a 40 MB, 2.4M-vertex print file in the
/// milestone-0 measurement (SceneKit was faster, but Apple has stopped developing it).
struct MiniViewer: View {
    let stl: URL
    @State private var failed = false

    var body: some View {
        RealityView { content in
            content.add(Self.lights())
        } update: { content in
            content.entities.filter { $0.name == "mini" }.forEach { content.remove($0) }
            if let mini = try? Self.load(stl) { content.add(mini) }
        }
        .realityViewCameraControls(.orbit)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    static func lights() -> Entity {
        let key = DirectionalLight()
        key.light.intensity = 2500
        key.look(at: .zero, from: [0.4, 0.8, 0.6], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: .zero, from: [-0.6, 0.3, -0.5], relativeTo: nil)
        let rig = Entity()
        rig.addChild(key); rig.addChild(fill)
        return rig
    }

    /// Print files are Z-up millimetres; the scene is Y-up metres. The mini is centred on its
    /// base and scaled so the orbit camera's default framing fits it.
    static func load(_ url: URL) throws -> Entity {
        let asset = MDLAsset(url: url)
        guard let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else { throw CocoaError(.fileReadCorruptFile) }
        let desc = mesh.vertexDescriptor
        guard let pos = desc.attributeNamed(MDLVertexAttributePosition),
              let layout = desc.layouts[pos.bufferIndex] as? MDLVertexBufferLayout else { throw CocoaError(.fileReadCorruptFile) }
        let buf = mesh.vertexBuffers[pos.bufferIndex].map()
        var points = [SIMD3<Float>](); points.reserveCapacity(mesh.vertexCount)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<mesh.vertexCount {
            let p = buf.bytes.advanced(by: i * layout.stride + pos.offset).assumingMemoryBound(to: Float.self)
            // Z-up → Y-up, turned to face the camera: minis face +Y in the print file, and the
            // orbit camera looks along -Z.
            let v = SIMD3<Float>(-p[0], p[2], p[1])
            points.append(v); lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        let centre = SIMD3<Float>((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        let scale = 1 / max(hi.y - lo.y, 1)  // 1 m tall: fills the orbit camera's default view
        points = points.map { ($0 - centre) * scale - SIMD3(0, 0.5, 0) }
        // An STL is a list of separate triangles, so one normal per triangle gives the
        // flat-shaded look every slicer shows.
        var normals = [SIMD3<Float>](repeating: .zero, count: points.count)
        for t in stride(from: 0, to: points.count - 2, by: 3) {
            let n = simd_normalize(simd_cross(points[t + 1] - points[t], points[t + 2] - points[t]))
            normals[t] = n; normals[t + 1] = n; normals[t + 2] = n
        }
        var d = MeshDescriptor(name: "mini")
        d.positions = MeshBuffers.Positions(points)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles((0..<UInt32(points.count)).map { $0 })
        let material = SimpleMaterial(color: .init(white: 0.66, alpha: 1), roughness: 0.75, isMetallic: false)
        let entity = ModelEntity(mesh: try MeshResource.generate(from: [d]), materials: [material])
        entity.name = "mini"
        return entity
    }
}
