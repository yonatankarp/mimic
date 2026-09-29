import MetalKit
import MimicCore
import ModelIO
import RealityKit
import SwiftUI

/// The 3D view of a mini's print file. RealityKit can't open STL, so Model I/O reads it and
/// its triangles become a RealityKit mesh: 0.37 s for a 40 MB, 2.4M-vertex print file in the
/// milestone-0 measurement (SceneKit was faster, but Apple has stopped developing it).
///
/// Dragging turns the mini itself rather than orbiting a camera, so turning, zooming and Front
/// are all one transform this view owns. Pinch or scroll zooms toward the pointer.
///
/// The scene is drawn only when something changes (see `Stage`): RealityView redraws every
/// frame, 20% of a core with a mini just standing there.
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
    /// Where zooming toward the pointer has moved the mini, in the scene's metres.
    @State private var offset = SIMD2<Float>.zero
    /// The pointer, while it's over the view.
    @State private var pointer: CGPoint?
    @State private var viewSize = CGSize.zero
    @State private var zoomEvents: Any?
    /// While Front plays its animation, the view leaves the transform to it.
    @State private var gliding = false
    /// The mini fades in once loaded, and out while the next one (or a resized one) loads, so
    /// a new print file crossfades rather than popping.
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Stage(mini: mini, gliding: gliding,
              transform: Transform(scale: SIMD3(repeating: zoom),
                                   rotation: simd_quatf(angle: turn.y, axis: [1, 0, 0]) * simd_quatf(angle: turn.x, axis: [0, 1, 0]),
                                   translation: SIMD3(offset, 0)))
        .opacity(shown ? 1 : 0)
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
        .onTapGesture(count: 2) { front() }
        // Pinch and scroll zoom toward the pointer while it's over the mini. Watched as window
        // events: SwiftUI has no gesture for a scroll wheel, and one monitor handles both.
        .onContinuousHover { phase in if case .active(let at) = phase { pointer = at } else { pointer = nil } }
        .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        .onAppear {
            zoomEvents = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { event in
                // A pinch reports how much it grew; a scroll how far it moved, in fine steps on a
                // trackpad or Magic Mouse and in lines on a mouse wheel. The glide a trackpad adds
                // after the fingers lift is ignored: zooming stops when you stop.
                let factor: Float? = event.type == .magnify ? ViewerZoom.factor(magnification: event.magnification)
                    : event.momentumPhase.isEmpty ? ViewerZoom.factor(scroll: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
                    : nil
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard let pointer, !gliding else { return false }
                    if let factor {
                        let anchor = ViewerZoom.anchor(at: pointer, in: viewSize, distance: Stage.distance, fieldOfView: Stage.fieldOfView)
                        (zoom, offset) = ViewerZoom.zoomed(scale: zoom, offset: offset, by: factor, toward: anchor)
                    }
                    return true
                }
                return used ? nil : event
            }
        }
        .onDisappear { zoomEvents.map(NSEvent.removeMonitor); zoomEvents = nil }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Button { front() } label: { Label("Face Front", systemImage: "arrow.counterclockwise") }
                    .help("Turn the mini back to face you and zoom back out (or double-click it)")
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
                Text("Drag to turn · pinch or scroll to zoom where you point · double-click to face front").font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .overlay {
            if failed {
                Text("Couldn't show this mini. Try Show in Finder.").foregroundStyle(.secondary)
            } else if mini == nil {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 36, weight: .light))
                        .symbolEffect(.breathe, options: .repeat(.continuous), isActive: !reduceMotion)
                    Text("Loading your mini…")
                }
                .foregroundStyle(.secondary)
            }
        }
        .task(id: [stl.path, version.description]) {
            failed = false
            // The mini on show fades out first: loading blocks the main actor, so the fade has to
            // be over before it starts.
            if mini != nil && shown && !reduceMotion {
                withAnimation(.easeIn(duration: 0.2)) { shown = false }
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled else { return }
            }
            shown = false
            turn = .zero; zoom = 1; offset = .zero
            // ponytail: loads on the main actor (about 0.4 s for the biggest print file); move the
            // file reading off it if bigger minis make that noticeable.
            guard let (entity, mm) = try? Self.load(stl) else { mini = nil; size = nil; failed = true; return }
            if !reduceMotion {
                entity.scale = SIMD3(repeating: 0.94)
                gliding = true  // the update adds it and grows it into place
            }
            mini = entity; size = mm
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { shown = true }
            if gliding {
                try? await Task.sleep(for: .seconds(0.5))
                gliding = false  // also when cancelled: sleep returns at once
            }
        }
    }

    /// Turns the mini back to face you, gliding there rather than jumping, so you can see which
    /// way it went. Jumps instead when the Mac is set to reduce motion.
    private func front() {
        let seconds = 0.45
        guard let mini, !gliding, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            turn = .zero; zoom = 1; offset = .zero
            return
        }
        gliding = true
        mini.move(to: Transform(), relativeTo: mini.parent, duration: seconds, timingFunction: .easeInOut)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            turn = .zero; zoom = 1; offset = .zero
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

/// The 3D scene, drawn by RealityKit's renderer into a Metal view that redraws only when asked:
/// when the mini turns, zooms, loads or the view resizes, and every frame only while a glide
/// (Face Front, the grow-in on load) plays. RealityView can't be paused and drew every frame,
/// about 20% of a core with nothing moving.
private struct Stage: NSViewRepresentable {
    static let distance: Float = 1.7
    static let fieldOfView: Float = 45  // degrees, top to bottom
    let mini: Entity?
    let gliding: Bool
    let transform: Transform

    func makeCoordinator() -> Painter { Painter() }
    func makeNSView(context: Context) -> MTKView { context.coordinator.view }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.show(mini, transform, gliding: gliding) }

    /// Passes the mouse through to the SwiftUI gestures around it.
    final class PassThrough: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Painter: NSObject, MTKViewDelegate {
        let view = PassThrough(frame: .zero, device: MTLCreateSystemDefaultDevice())
        private let renderer = try? RealityRenderer()
        private var mini: Entity?
        private var drawn: Transform?
        private var lastFrame: CFTimeInterval?

        override init() {
            super.init()
            view.delegate = self
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.framebufferOnly = false  // RealityKit renders into the drawable's texture
            view.colorPixelFormat = .bgra8Unorm_srgb
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.layer?.isOpaque = false  // the stage's backdrop shows through
            guard let renderer else { return }
            // A camera of our own: the default one sits too close.
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = Stage.fieldOfView
            camera.camera.fieldOfViewOrientation = .vertical
            camera.position = [0, 0, Stage.distance]
            renderer.entities.append(contentsOf: [MiniViewer.lights(), camera])
            renderer.activeCamera = camera
            renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
            renderer.lighting.resource = Self.studio()
            renderer.lighting.intensityExponent = Self.ambience
        }

        /// Soft light from all round, as RealityView gives by default: without it the lamps
        /// leave the shadows black. A plain studio, lighter overhead than underfoot.
        static let ambience: Float = 2
        static func studio() -> EnvironmentResource? {
            let (width, height) = (64, 32)
            let pixels = (0..<height).flatMap { y in
                [UInt8](repeating: UInt8(235 - 120 * y / (height - 1)), count: width)
            }
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.data?.copyMemory(from: pixels, byteCount: pixels.count)
            return context.makeImage().flatMap { try? EnvironmentResource(equirectangular: $0) }
        }

        func show(_ entity: Entity?, _ transform: Transform, gliding: Bool) {
            if entity !== mini, let renderer {
                if let mini { renderer.entities.remove(mini) }
                if let entity {
                    renderer.entities.append(contentsOf: [entity])
                    // Grows the last few percent into place as it fades in (the task set it smaller).
                    if gliding { entity.move(to: Transform(), relativeTo: nil, duration: 0.5, timingFunction: .easeOut) }
                }
                mini = entity
                drawn = nil
                view.needsDisplay = true
            }
            view.isPaused = !gliding
            guard !gliding else { drawn = nil; return }  // the animation owns the transform, drawn every frame
            lastFrame = nil
            // SwiftUI asks again whenever anything on the page changes; redraw only for the mini.
            guard let mini, transform != drawn || mini.transform != transform else { return }
            mini.transform = transform
            drawn = transform
            view.needsDisplay = true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let renderer, let drawable = view.currentDrawable else { return }
            // Animations advance by the time since the last frame; a redraw while still is a
            // step of zero.
            let now = CACurrentMediaTime()
            let step = view.isPaused ? 0 : lastFrame.map { now - $0 } ?? 0
            lastFrame = view.isPaused ? nil : now
            let frame = Frame(drawable: drawable)
            do {
                let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
                try renderer.updateAndRender(deltaTime: step, cameraOutput: output, onComplete: { _ in frame.drawable.present() })
            } catch {
                // Nothing to show this frame; the next change draws again.
            }
        }
    }

    /// The drawable, handed to the renderer's completion, which runs off the main actor.
    private struct Frame: @unchecked Sendable { let drawable: any CAMetalDrawable }
}
