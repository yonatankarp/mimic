import ModelIO
import RealityKit
import SwiftUI

/// The 3D view of a mini's print file. RealityKit can't open STL, so Model I/O reads it and
/// its triangles become a RealityKit mesh: 0.37 s for a 40 MB, 2.4M-vertex print file in the
/// milestone-0 measurement (SceneKit was faster, but Apple has stopped developing it).
///
/// Dragging turns the mini itself rather than orbiting a camera, so turning, zooming and Front
/// are all one transform this view owns. Zoom is a pinch, locked by default like the web page's.
struct MiniViewer: View {
    let stl: URL
    /// The print file's date: a resize rewrites the file under the same name.
    let version: Date
    /// "Dwarf Cleric", for VoiceOver.
    let name: String
    @State private var mini: Entity?
    @State private var size: String?
    @State private var failed = false
    @State private var turn = SIMD2<Float>.zero  // yaw, pitch
    @State private var turnStart: SIMD2<Float>?
    @State private var zoom: Float = 1
    @State private var zoomStart: Float?
    @AppStorage("zoomOn") private var zoomOn = false
    /// While Front plays its animation, the view leaves the transform to it.
    @State private var gliding = false

    var body: some View {
        RealityView { content in
            content.add(Self.lights())
            // A camera of our own: without camera controls, the default one sits too close.
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 45
            camera.position = [0, 0, 1.7]
            content.add(camera)
        } update: { content in
            guard let mini else { return }
            if mini.parent == nil {
                content.entities.filter { $0.name == "mini" }.forEach { content.remove($0) }
                content.add(mini)
            }
            guard !gliding else { return }
            mini.transform = Transform(scale: SIMD3(repeating: zoom),
                                       rotation: simd_quatf(angle: turn.y, axis: [1, 0, 0]) * simd_quatf(angle: turn.x, axis: [0, 1, 0]),
                                       translation: .zero)
        }
        .realityViewCameraControls(.none)
        .accessibilityElement()
        .accessibilityLabel(size.map { "3D view of \(name), \($0)" } ?? "3D view of \(name)")
        // A soft stage for the mini to stand on, lighter in the middle like a studio backdrop.
        .background(RadialGradient(colors: [Color.primary.opacity(0.07), Color.primary.opacity(0.02)],
                                   center: .center, startRadius: 40, endRadius: 520))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3).onChanged { g in
            let start = turnStart ?? turn
            turnStart = start
            turn = SIMD2(start.x + Float(g.translation.width) * 0.01,
                         min(1.1, max(-1.1, start.y + Float(g.translation.height) * 0.01)))
        }.onEnded { _ in turnStart = nil })
        .simultaneousGesture(MagnifyGesture().onChanged { g in
            guard zoomOn else { return }
            let start = zoomStart ?? zoom
            zoomStart = start
            zoom = min(4, max(0.4, start * Float(g.magnification)))
        }.onEnded { _ in zoomStart = nil })
        .onTapGesture(count: 2) { front() }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Button { front() } label: { Label("Face Front", systemImage: "arrow.counterclockwise") }
                    .help("Turn the mini back to face you (or double-click it)")
                // One label; the button looks pressed while it's on.
                Toggle(isOn: $zoomOn) { Label("Pinch to Zoom", systemImage: "plus.magnifyingglass") }
                    .toggleStyle(.button)
                    .help(zoomOn ? "On: pinch on the trackpad to zoom the mini. Click to turn off." : "Click, then pinch on the trackpad to zoom the mini")
                    .onChange(of: zoomOn) { _, on in if !on { zoom = 1 } }
            }
            .glassButton()
            .controlSize(.small)
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            if let size {
                Text(size).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassCard(cornerRadius: 10)
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if mini != nil {
                Text("Drag to turn · double-click to face front").font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .overlay {
            if failed {
                Text("Couldn't show this mini. Try Show in Finder.").foregroundStyle(.secondary)
            } else if mini == nil {
                ProgressView("Loading your mini…")
            }
        }
        .task(id: [stl.path, version.description]) {
            failed = false
            mini = nil; size = nil
            turn = .zero; zoom = 1
            // ponytail: loads on the main actor (about 0.4 s for the biggest print file); move the
            // file reading off it if bigger minis make that noticeable.
            if let (entity, mm) = try? Self.load(stl) { mini = entity; size = mm } else { failed = true }
        }
    }

    /// Turns the mini back to face you, gliding there rather than jumping, so you can see which
    /// way it went. Jumps instead when the Mac is set to reduce motion.
    private func front() {
        let seconds = 0.45
        guard let mini, !gliding, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            turn = .zero; zoom = 1
            return
        }
        gliding = true
        mini.move(to: Transform(), relativeTo: mini.parent, duration: seconds, timingFunction: .easeInOut)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            turn = .zero; zoom = 1
            gliding = false
        }
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

    /// Print files are Z-up millimetres; the scene is Y-up metres. The mini is centred and
    /// scaled so the default camera's framing fits it. Also returns its size in millimetres,
    /// "34 mm tall with base · 25 × 33 mm footprint".
    static func load(_ url: URL) throws -> (Entity, String) {
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
            // camera looks along -Z.
            let v = SIMD3<Float>(-p[0], p[2], p[1])
            points.append(v); lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        let dims = hi - lo
        let size = "\(Int(dims.y.rounded())) mm tall with base · \(Int(dims.x.rounded())) × \(Int(dims.z.rounded())) mm footprint"
        let centre = (lo + hi) / 2  // the middle of the mini, so it turns in place
        let scale = 1 / max(dims.y, 1)  // 1 m tall: fills the default camera's view
        points = points.map { ($0 - centre) * scale }
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
        return (entity, size)
    }
}
