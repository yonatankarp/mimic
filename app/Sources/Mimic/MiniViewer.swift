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
    /// What the print file measures, once loaded: the page's details show it too.
    @Binding var measured: Measured?
    @State private var mini: Entity?
    @State private var failed = false
    /// How to handle it, shown over the view until the first turn or zoom (and always as its tooltip).
    @AppStorage("viewerHintSeen") private var hintSeen = false
    static let hint = "Drag to turn · scroll to zoom"
    static let help = "Drag to turn · pinch or scroll to zoom · double-click to face front"
    /// The stage's size, running up under the toolbar, and the height below the toolbar.
    @State private var stageSize = CGSize.zero
    @State private var seenHeight: CGFloat = 0
    @State private var turn = SIMD2<Float>.zero  // yaw, pitch
    @State private var turnStart: SIMD2<Float>?
    @State private var zoom: Float = 1
    /// Where zooming toward the pointer has moved the mini, in the scene's metres.
    @State private var offset = SIMD2<Float>.zero
    /// How long the view takes to glide to its next pose (Face Front, the grow-in on load);
    /// zero the rest of the time, when turning and zooming follow your hand.
    @State private var glide: Double = 0
    private var gliding: Bool { glide > 0 }
    /// The mini fades in once loaded, and out while the next one (or a resized one) loads, so
    /// a new print file crossfades rather than popping.
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            // The stage runs up under the toolbar; the controls below stay clear of it. Not under
            // the sidebar or the details: a scroll over the stage zooms, which would steal theirs.
            floorShadow.ignoresSafeArea(edges: .top)
            stage.ignoresSafeArea(edges: .top)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { seenHeight = $0 }
        .overlay(alignment: .topTrailing) { controls.padding(12) }
        .overlay(alignment: .bottom) {
            if mini != nil && !hintSeen {
                Text(Self.hint).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: hintSeen)
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
            measured = nil  // at once: the page's details shouldn't show the last mini's size while it fades
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
            guard let (entity, mm) = try? Self.load(stl) else { mini = nil; failed = true; return }
            if !reduceMotion {
                entity.scale = SIMD3(repeating: 0.94)
                glide = 0.5  // the stage adds it and grows it into place
            }
            mini = entity; measured = mm
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { shown = true }
            if gliding {
                try? await Task.sleep(for: .seconds(glide))
                glide = 0  // also when cancelled: sleep returns at once
            }
        }
    }

    /// The mini's box in the scene, 1 m tall; a typical one until its print file is read.
    private var sizeInScene: SIMD3<Float> {
        guard let m = measured, m.tall > 0 else { return SIMD3(0.8, 1, 0.8) }
        return SIMD3(Float(m.wide), Float(m.tall), Float(m.deep)) / Float(m.tall)
    }

    /// Fits the mini to what's seen: below the toolbar and the controls, above the hint (whose
    /// room is kept after it's gone, so the mini doesn't move). Follows the window, the sidebar
    /// and the details panel; zooming is on top of it.
    private var camera: ViewerCamera {
        ViewerCamera.fitting(sizeInScene, in: stageSize, top: max(0, stageSize.height - seenHeight) + 48, bottom: 56)
    }

    private var pitch: simd_quatf { simd_quatf(angle: turn.y, axis: [1, 0, 0]) }

    private var stage: some View {
        Stage(mini: mini, glide: glide, camera: camera,
              transform: Transform(scale: SIMD3(repeating: zoom),
                                   rotation: pitch * simd_quatf(angle: turn.x, axis: [0, 1, 0]),
                                   translation: SIMD3(offset, 0)),
              // Pinch and scroll over the mini zoom toward the pointer.
              zoomed: { factor, anchor in
                  guard !gliding else { return false }
                  (zoom, offset) = ViewerZoom.zoomed(scale: zoom, offset: offset, by: factor, toward: anchor)
                  if !hintSeen { hintSeen = true }
                  return true
              })
        .opacity(shown ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel(measured.map { "3D view of \(name), \($0.tall) mm tall with base, \($0.footprint) footprint" } ?? "3D view of \(name)")
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3).onChanged { g in
            let start = turnStart ?? turn
            turnStart = start
            turn = SIMD2(start.x + Float(g.translation.width) * 0.01,
                         min(1.1, max(-1.1, start.y + Float(g.translation.height) * 0.01)))
        }.onEnded { _ in
            turnStart = nil
            if !hintSeen { hintSeen = true }
        })
        .onTapGesture(count: 2) { front() }
        .help(Self.help)
    }

    /// A soft contact shadow under the base, drawn behind the scene (the base hides its middle).
    /// It follows the zoom and the tilt; turning round leaves a round shadow as it is. Seen from
    /// below, it fades away.
    private var floorShadow: some View {
        let radius = max(sizeInScene.x, sizeInScene.z) / 2 * 1.3
        let camera = camera, size = stageSize, zoom = zoom, offset = offset, pitch = pitch
        func at(_ x: Float, _ z: Float) -> CGPoint { camera.project(pitch.act(SIMD3(x, -0.5, z) * zoom) + SIMD3(offset, 0), in: size) }
        let middle = at(0, 0), left = at(-radius, 0), right = at(radius, 0), near = at(0, radius), far = at(0, -radius)
        let base = pitch.act(SIMD3(0, -0.5, 0) * zoom) + SIMD3(offset, 0)
        let fromAbove = simd_dot(pitch.act(SIMD3(0, 1, 0)), simd_normalize(SIMD3(0, camera.lift, camera.distance) - base))
        return EllipticalGradient(colors: [.black.opacity(0.3), .black.opacity(0.12), .clear], center: .center,
                                  startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: abs(right.x - left.x), height: max(2, abs(near.y - far.y)))
            .position(middle)
            .opacity(shown && size != .zero ? Double(min(1, max(0, fromAbove * 5))) : 0)
            .animation(glide > 0 ? .easeInOut(duration: glide) : nil, value: turn)
            .animation(glide > 0 ? .easeInOut(duration: glide) : nil, value: zoom)
            .animation(glide > 0 ? .easeInOut(duration: glide) : nil, value: offset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Floating over the view, top right: its size beside Face Front, one piece of glass.
    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if let measured {
                    Text(measured.caption).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .help("Its size with the base: height, then the footprint it stands on.")
                }
                Button { front() } label: { Label("Face Front", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.glass)
                    .help("Turn the mini back to face you and zoom back out (or double-click it)")
                    .disabled(mini == nil)
            }
        }
    }

    /// A studio backdrop that works light or dark: the window's own colour, a shade deeper
    /// towards the floor (a few percent, never dark).
    private var backdrop: some View {
        LinearGradient(colors: [.primary.opacity(0), .primary.opacity(0.035)], startPoint: .center, endPoint: .bottom)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Turns the mini back to face you, gliding there rather than jumping, so you can see which
    /// way it went. Jumps instead when the Mac is set to reduce motion.
    private func front() {
        guard mini != nil, !gliding else { return }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { glide = 0.45 }
        turn = .zero; zoom = 1; offset = .zero  // the stage glides there, or jumps
        guard gliding else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(glide))
            glide = 0
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
    /// scaled to 1 m tall, which the camera fits to the view. Also returns its size in millimetres.
    static func load(_ url: URL) throws -> (Entity, Measured) {
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
        let size = Measured(tall: Int(dims.y.rounded()), wide: Int(dims.x.rounded()), deep: Int(dims.z.rounded()))
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

/// A print file's size in millimetres, base included.
struct Measured: Equatable {
    let tall: Int, wide: Int, deep: Int
    var footprint: String { "\(wide) × \(deep) mm" }
    /// "34 mm tall · 26 × 25 mm", on its glass badge.
    var caption: String { "\(tall) mm tall · \(footprint)" }
}

/// The 3D scene, drawn by RealityKit's renderer into a Metal view that redraws only when asked:
/// when the mini turns, zooms, loads or the view resizes, and every frame only while a glide
/// (Face Front, the grow-in on load) plays. RealityView can't be paused and drew every frame,
/// about 20% of a core with nothing moving.
private struct Stage: NSViewRepresentable {
    let mini: Entity?
    /// Seconds to glide to a new `transform`; 0 to follow it at once.
    let glide: Double
    let camera: ViewerCamera
    let transform: Transform
    /// A pinch or scroll over the view: how much to zoom and toward which point of the plane
    /// through the mini. Returns whether it was used.
    let zoomed: (Float, SIMD2<Float>) -> Bool

    func makeCoordinator() -> Painter { Painter() }
    func makeNSView(context: Context) -> MTKView { context.coordinator.view }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.zoomed = zoomed
        context.coordinator.frame(camera)
        context.coordinator.show(mini, transform, glide: glide)
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Painter) { coordinator.stopWatching() }

    /// Passes the mouse through to the SwiftUI gestures around it.
    final class PassThrough: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Painter: NSObject, MTKViewDelegate {
        let view = PassThrough(frame: .zero, device: MTLCreateSystemDefaultDevice())
        var zoomed: (Float, SIMD2<Float>) -> Bool = { _, _ in false }
        private let renderer = try? RealityRenderer()
        private var mini: Entity?
        /// The pose asked for, and the one last drawn.
        private var target: Transform?
        private var drawn: Transform?
        /// The glide under way: where it started, when, and for how long.
        private var gliding: (from: Transform, start: CFTimeInterval, seconds: Double)?
        private var zoomEvents: Any?
        private let camera = PerspectiveCamera()
        private var fitted = ViewerCamera()

        override init() {
            super.init()
            view.delegate = self
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.framebufferOnly = false  // RealityKit renders into the drawable's texture
            view.colorPixelFormat = .bgra8Unorm_srgb
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.layer?.isOpaque = false  // the stage's backdrop shows through
            watchZoom()
            guard let renderer else { return }
            // A camera of our own, placed to fit the mini to the view (see `ViewerCamera`).
            camera.camera.fieldOfViewInDegrees = ViewerCamera.fieldOfView
            camera.camera.fieldOfViewOrientation = .vertical
            camera.position = [0, fitted.lift, fitted.distance]
            renderer.entities.append(contentsOf: [MiniViewer.lights(), camera])
            renderer.activeCamera = camera
            renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
            // RealityView's look. Tone mapping (on by default here) squeezed the highlights and
            // left the folds a flat grey.
            renderer.cameraSettings.isToneMappingEnabled = false
            renderer.lighting.resource = Self.studio()
            renderer.lighting.intensityExponent = 0
        }

        /// Soft light from all round, as RealityView gives by default: without it the lamps
        /// leave the shadows black. A plain studio, lighter overhead than underfoot.
        static func studio() -> EnvironmentResource? {
            let width = 64, height = 32
            // Row by row, lighter overhead: written out because Swift 6.3 can't type-check it as one expression.
            var pixels: [UInt8] = []
            for y in 0..<height {
                let shade: Int = 235 - 120 * y / (height - 1)
                pixels += [UInt8](repeating: UInt8(shade), count: width)
            }
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.data?.copyMemory(from: pixels, byteCount: pixels.count)
            return context.makeImage().flatMap { try? EnvironmentResource(equirectangular: $0) }
        }

        /// Pinch and scroll zoom while the pointer is over this view, told by where the event
        /// happened rather than by hover, which can go stale and zoom on a scroll elsewhere.
        /// Watched as window events: SwiftUI has no gesture for a scroll wheel.
        private func watchZoom() {
            zoomEvents = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.zoom(event) ?? false } ? nil : event
            }
        }

        func stopWatching() { zoomEvents.map(NSEvent.removeMonitor); zoomEvents = nil }

        /// Whether the event was a zoom over this view (and so shouldn't go further).
        private func zoom(_ event: NSEvent) -> Bool {
            guard let window = view.window, event.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let at = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(at) else { return false }
            // A pinch reports how much it grew; a scroll how far it moved, in fine steps on a
            // trackpad or Magic Mouse and in lines on a mouse wheel. The glide a trackpad adds
            // after the fingers lift is swallowed: zooming stops when you stop.
            guard event.type == .magnify || event.momentumPhase.isEmpty else { return true }
            let factor = event.type == .magnify ? ViewerZoom.factor(magnification: event.magnification)
                : ViewerZoom.factor(scroll: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
            return zoomed(factor, fitted.anchor(at: CGPoint(x: at.x, y: view.bounds.height - at.y), in: view.bounds.size))
        }

        /// Moves the camera when the fit changes (a resize, the sidebar or details shown or hidden).
        func frame(_ camera: ViewerCamera) {
            guard camera != fitted else { return }
            fitted = camera
            self.camera.position = [0, camera.lift, camera.distance]
            view.needsDisplay = true
        }

        func show(_ entity: Entity?, _ transform: Transform, glide: Double) {
            if entity !== mini, let renderer {
                if let mini { renderer.entities.remove(mini) }
                if let entity { renderer.entities.append(contentsOf: [entity]) }
                mini = entity
                drawn = nil
                // A new mini glides from the pose it arrived in (the grow-in on load).
                gliding = nil
                if let entity, glide > 0 { gliding = (entity.transform, CACurrentMediaTime(), glide) }
            } else if transform != target, let mini, glide > 0 {
                gliding = (mini.transform, CACurrentMediaTime(), glide)
            }
            target = transform
            if glide == 0 { gliding = nil }  // over: land exactly on the pose, frames or not
            view.isPaused = gliding == nil
            if gliding == nil, let mini, transform != drawn || mini.transform != transform {
                mini.transform = transform
                view.needsDisplay = true
            } else if entity == nil {
                view.needsDisplay = true
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            if let glide = gliding, let mini, let target {
                let t = Glide.progress(elapsed: CACurrentMediaTime() - glide.start, over: glide.seconds)
                // Written out step by step: CI's older Swift can't type-check it as one expression.
                let along = SIMD3<Float>(repeating: t)
                let scale: SIMD3<Float> = simd_mix(glide.from.scale, target.scale, along)
                let rotation: simd_quatf = simd_slerp(glide.from.rotation, target.rotation, t)
                let translation: SIMD3<Float> = simd_mix(glide.from.translation, target.translation, along)
                mini.transform = Transform(scale: scale, rotation: rotation, translation: translation)
                if t >= 1 { gliding = nil; view.isPaused = true }
            }
            drawn = mini?.transform
            guard let renderer, let drawable = view.currentDrawable else { return }
            let frame = Frame(drawable: drawable)
            do {
                let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in frame.drawable.present() })
            } catch {
                // Nothing to show this frame; the next change draws again.
            }
        }
    }

    /// The drawable, handed to the renderer's completion, which runs off the main actor.
    private struct Frame: @unchecked Sendable { let drawable: any CAMetalDrawable }
}
