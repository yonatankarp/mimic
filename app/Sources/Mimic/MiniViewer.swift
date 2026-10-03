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
    /// The print file faces +y, as before 0.10.0 (`Mini.facesAway`), so it's turned round.
    let facesAway: Bool
    /// What the print file measures, once loaded: the page's details show it too.
    @Binding var measured: Measured?
    @State private var mini: Entity?
    @State private var failed = false
    /// How to handle it, shown over the view until the first turn or zoom (and always as its tooltip).
    @AppStorage("viewerHintSeen") private var hintSeen = false
    /// Something of a known size drawn at true scale with the mini (`SizeReference`), the same
    /// choice for every mini. Built only when the choice or the print file changes.
    @AppStorage(SizeReference.key) private var reference = SizeReference.none
    @State private var referenceEntity: Entity?
    static let hint = "Drag to turn · scroll to zoom"
    static let help = "Drag or press the arrow keys to turn · pinch, scroll, ⌘= or ⌘− to zoom · double-click to face front"
    /// The stage's size, running up under the toolbar, and the height below the toolbar.
    @State private var stageSize = CGSize.zero
    @State private var seenHeight: CGFloat = 0
    /// The camera in use: the fit, followed as the window, the sidebar or the details change,
    /// except while zoomed in or out, so a zoom isn't undone. Face Front fits it again.
    @State private var camera = ViewerCamera()
    private var unzoomed: Bool { zoom == 1 && offset == .zero }
    /// Another viewer's pose, so the two turn and zoom together (Compare Side by Side, #99);
    /// nil for a pose of its own.
    var shared: Binding<ViewerPose>? = nil
    @State private var own = ViewerPose()
    private var pose: ViewerPose {
        get { shared?.wrappedValue ?? own }
        nonmutating set { if let shared { shared.wrappedValue = newValue } else { own = newValue } }
    }
    private var turn: SIMD2<Float> { get { pose.turn } nonmutating set { pose.turn = newValue } }
    @State private var turnStart: SIMD2<Float>?
    private var zoom: Float { get { pose.zoom } nonmutating set { pose.zoom = newValue } }
    private var offset: SIMD2<Float> { get { pose.offset } nonmutating set { pose.offset = newValue } }
    private var glide: Double { get { pose.glide } nonmutating set { pose.glide = newValue } }
    private var gliding: Bool { glide > 0 }
    /// The mini fades in once loaded, and out while the next one (or a resized one) loads, so
    /// a new print file crossfades rather than popping.
    @State private var shown = false
    /// The view has the keyboard: ← → turn it, ↑ ↓ tilt it, ⌘= ⌘− zoom.
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model

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
        .onChange(of: fit, initial: true) { if unzoomed { camera = fit } }
        .onChange(of: unzoomed) { if unzoomed { camera = fit } }
        .onChange(of: model.faceFrontRequests) { front() }  // View → Face Front
        .onChange(of: model.zoomRequests) { old, new in step(zoom: new > old ? 1 : -1) }  // View → Zoom In, Zoom Out
        .onChange(of: layout, initial: true) { referenceEntity = layout.flatMap(Self.marker(for:)) }
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
                ContentUnavailableView {
                    Label("Couldn't show this mini", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([stl]) }
                }
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
        .task(id: [stl.path, version.description, "\(facesAway)"]) {
            failed = false
            measured = nil  // at once: the page's details shouldn't show the last mini's size while it fades
            // The mini on show fades out first, before it leaves the stage.
            if mini != nil && shown && !reduceMotion {
                withAnimation(.easeIn(duration: 0.2)) { shown = false }
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled else { return }
            }
            shown = false
            turn = .zero; zoom = 1; offset = .zero
            // Off the stage while the next one loads (#141), so the view says it's loading rather
            // than showing the last mini under the new one's name.
            mini = nil
            // The file is read off the main actor, so the view can say so meanwhile; a big print
            // file takes seconds.
            let read = await Task.detached(priority: .userInitiated) { [stl, facesAway] in Result { try Self.read(stl, facesAway: facesAway) } }.value
            // Another mini was picked meanwhile: its own load shows it, not this one.
            guard !Task.isCancelled else { return }
            guard let (entity, mm) = try? await Self.entity(read.get()) else { failed = true; return }
            guard !Task.isCancelled else { return }  // the mesh took a while: the same again
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

    /// Where the size reference goes and how big it is, once the print file is read.
    private var layout: ReferenceLayout? {
        guard let m = measured, m.exact.y > 0 else { return nil }
        return ReferenceLayout(kind: reference, height: m.exact.y, mini: m.exact / m.exact.y, origin: m.origin)
    }

    /// Fits the mini, and the size reference with it, to what's seen: below the toolbar and the
    /// controls, above the hint (whose room is kept after it's gone, so the mini doesn't move).
    private var fit: ViewerCamera {
        ViewerCamera.fitting(layout?.fit ?? sizeInScene, in: stageSize, top: max(0, stageSize.height - seenHeight) + 48, bottom: 56)
    }

    /// "3D view of Raven, 34 mm tall with base, 26 × 25 mm footprint, beside a 32 mm person".
    private var spoken: String {
        guard let measured else { return "3D view of \(name)" }
        var words = "3D view of \(name), \(measured.tall) mm tall with base, \(measured.footprint) footprint"
        if let layout, let extra = layout.kind.spoken(gridSquare: layout.gridSquare) { words += ", \(extra)" }
        return words
    }

    private var pitch: simd_quatf { simd_quatf(angle: turn.y, axis: [1, 0, 0]) }

    private var stage: some View {
        Stage(mini: mini, reference: referenceEntity, glide: glide, camera: camera,
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
        .accessibilityLabel(spoken)
        .accessibilityHint("Arrow keys turn and tilt it; Command-Equals and Command-Minus zoom.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(turn: 1)
            case .decrement: step(turn: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Face Front") { front() }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3).onChanged { g in
            focused = true
            let start = turnStart ?? turn
            turnStart = start
            turn = SIMD2(start.x + Float(g.translation.width) * 0.01,
                         min(1.1, max(-1.1, start.y + Float(g.translation.height) * 0.01)))
        }.onEnded { _ in
            turnStart = nil
            if !hintSeen { hintSeen = true }
        })
        .onTapGesture(count: 2) { front() }
        .onTapGesture { focused = true }
        .focusable(interactions: .edit)  // takes the keyboard without Keyboard Navigation turned on
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            switch press.key {
            case .leftArrow: step(turn: -1)
            case .rightArrow: step(turn: 1)
            case .upArrow: step(tilt: -1)
            default: step(tilt: 1)
            }
            return .handled
        }
        .onKeyPress(characters: ["=", "+", "-"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            step(zoom: press.characters == "-" ? -1 : 1)
            return .handled
        }
        .help(Self.help)
    }

    /// One key press: a 15° turn or tilt, or a zoom step toward the middle. At once, not a
    /// glide: the stage draws once per press and stays idle between them.
    private func step(turn by: Float = 0, tilt: Float = 0, zoom z: Float = 0) {
        guard mini != nil, !gliding else { return }
        let angle = Float.pi / 12
        turn = SIMD2(turn.x + by * angle, min(1.1, max(-1.1, turn.y + tilt * angle)))
        if z != 0 { (zoom, offset) = ViewerZoom.zoomed(scale: zoom, offset: offset, by: exp(0.25 * z), toward: .zero) }
        if !hintSeen { hintSeen = true }
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

    /// Floating over the view, top right: its size, the size reference and Face Front, one piece of glass.
    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if let measured {
                    Text(caption(measured)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .help("Its size with the base: height, then the footprint it stands on.")
                }
                Menu {
                    Picker("Size Reference", selection: $reference) {
                        ForEach(SizeReference.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Size Reference", systemImage: "ruler").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Show something of a known size next to the mini, at its true scale")
                .accessibilityValue(reference.title)
                .disabled(mini == nil)
                Button { front() } label: { Label("Face Front", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.glass)
                    .help("Turn the mini back to face you and zoom back out (⌘0, or double-click it)")
                    .disabled(mini == nil)
            }
        }
    }

    /// The size badge, with the grid's square when the grid is shown: "34 mm tall · 26 × 25 mm · 1 mm squares".
    private func caption(_ measured: Measured) -> String {
        guard let layout, layout.kind == .grid else { return measured.caption }
        return "\(measured.caption) · \(Int(layout.gridSquare)) mm squares"
    }

    /// The size reference as RealityKit draws it: flat colour, no lighting, so it reads as a
    /// marker rather than part of the mini. Nil when there's nothing to draw.
    static func marker(for layout: ReferenceLayout) -> Entity? {
        let pieces = layout.meshes
        guard !pieces.isEmpty else { return nil }
        let blue = NSColor(srgbRed: 0.2, green: 0.5, blue: 0.95, alpha: 1)
        let line = NSColor(white: 0.55, alpha: 1)
        let root = Entity()
        root.name = "size reference"
        for piece in pieces {
            var d = MeshDescriptor(name: "reference")
            d.positions = MeshBuffers.Positions(piece.positions)
            d.primitives = .triangles(piece.indices)
            guard let mesh = try? MeshResource.generate(from: [d]) else { continue }
            let colour = layout.kind == .grid && !piece.bold ? line : blue
            root.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: colour)]))
        }
        return root
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
    /// Off the main actor; `entity` then makes the mini on it.
    nonisolated static func read(_ url: URL, facesAway: Bool) throws -> Read {
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
            let v = ViewerCamera.scene(SIMD3(p[0], p[1], p[2]), facesAway: facesAway)
            points.append(v); lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        let dims = hi - lo
        let centre = (lo + hi) / 2  // the middle of the mini, so it turns in place
        let scale = 1 / max(dims.y, 1)  // 1 m tall: fills the default camera's view
        let size = Measured(tall: Int(dims.y.rounded()), wide: Int(dims.x.rounded()), deep: Int(dims.z.rounded()),
                            volume: Filament.volume(points),  // turned, not yet scaled: still mm
                            exact: SIMD3(dims.x, max(dims.y, 1), dims.z), origin: -centre * scale)
        points = points.map { ($0 - centre) * scale }
        // An STL is a list of separate triangles, so one normal per triangle gives the
        // flat-shaded look every slicer shows.
        var normals = [SIMD3<Float>](repeating: .zero, count: points.count)
        for t in stride(from: 0, to: points.count - 2, by: 3) {
            let n = simd_normalize(simd_cross(points[t + 1] - points[t], points[t + 2] - points[t]))
            normals[t] = n; normals[t + 1] = n; normals[t + 2] = n
        }
        // Every corner its own vertex, in order: millions for a big print file, so made here too.
        return Read(points: points, normals: normals, indices: Array(0..<UInt32(points.count)), measured: size)
    }

    struct Read: Sendable {
        let points: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]
        let measured: Measured
    }

    /// The mini's entity, from what `read` got out of its print file. The mesh is built off the
    /// main actor (the async `MeshResource(from:)`), so a big print file doesn't freeze the
    /// window (#342).
    static func entity(_ r: Read) async throws -> (Entity, Measured) {
        var d = MeshDescriptor(name: "mini")
        d.positions = MeshBuffers.Positions(r.points)
        d.normals = MeshBuffers.Normals(r.normals)
        d.primitives = .triangles(r.indices)
        let mesh = try await MeshResource(from: [d])
        let material = SimpleMaterial(color: .init(white: 0.66, alpha: 1), roughness: 0.75, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "mini"
        return (entity, r.measured)
    }
}

/// How the mini is turned and zoomed: a viewer's own, or shared by the two in Compare Side by Side.
struct ViewerPose: Equatable {
    var turn = SIMD2<Float>.zero  // yaw, pitch
    var zoom: Float = 1
    /// Where zooming toward the pointer has moved the mini, in the scene's metres.
    var offset = SIMD2<Float>.zero
    /// How long the view takes to glide to its next pose (Face Front, the grow-in on load);
    /// zero the rest of the time, when turning and zooming follow your hand.
    var glide: Double = 0
}

/// The 3D scene, drawn by RealityKit's renderer into a Metal view that redraws only when asked:
/// when the mini turns, zooms, loads or the view resizes, and every frame only while a glide
/// (Face Front, the grow-in on load) plays. RealityView can't be paused and drew every frame,
/// about 20% of a core with nothing moving.
private struct Stage: NSViewRepresentable {
    let mini: Entity?
    /// Drawn with the mini, in its frame (see `MiniViewer.marker`): it turns, zooms and glides along.
    let reference: Entity?
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
        context.coordinator.attach(reference)
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
        private var reference: Entity?
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

        /// Puts the size reference on the mini, as a child so it shares the mini's pose: the old
        /// one comes off, and one that arrived before its mini goes on once the mini is shown.
        func attach(_ entity: Entity?) {
            if entity === reference, entity == nil || entity?.parent === mini { return }
            reference?.removeFromParent()
            if let entity, let mini { mini.addChild(entity) }
            reference = entity
            view.needsDisplay = true
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
            // In a sheet (Compare Side by Side) the Metal layer's scale is left at 0, and every
            // frame was drawn at no size: only the shadow, which SwiftUI draws, showed.
            if let scale = view.window?.backingScaleFactor, view.layer?.contentsScale != scale { view.layer?.contentsScale = scale }
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
