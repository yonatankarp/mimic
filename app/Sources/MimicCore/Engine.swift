import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Step 2 of a mini: the picture becomes a 3D model. Cuts the character out of the picture,
/// then runs the 3D engine (trellis-cli, pixal3d.cpp built for Metal) on the cutout.
///
/// It runs as `mimic _engine …`, a program of its own in the job's session, so Stop ends it and
/// trellis-cli together. Replaces image-to-3dlab's `pixal3d_generate.py`; the settings below are
/// the ones that wrapper arrived at, and each comment says why.
public enum Engine {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// The gauge camera the single-view weights are designed around: 20 degrees, as radians.
    static let fov = "0.3490658503988659"
    /// Structure guidance. trellis-cli's default of 7.5 dropped a sword blade entirely; 10 keeps
    /// thin parts, 13 detaches them.
    static let gss = "10"
    /// Sampling steps: 8 gave the same shape and front as the stock 12, 16–31% faster. The
    /// packaged build reads this and says "PIXAL3D_STEPS=8 overrides 12 steps".
    static let steps = "8"

    /// The trellis-cli command line for `model`. Paths must be absolute: it runs from its own
    /// folder so it finds its Metal library, and a relative path would resolve against that.
    /// The picture is always cut out already, so neither pipeline removes a background.
    /// - Pixal3D: `--sv-image` (the single-view weights need it), the gauge camera and gss 10.
    /// - TRELLIS.2: the plain one-picture pipeline at its own defaults; gss 10 was tuned on
    ///   Pixal3D only. With `views`, a folder of several pictures of the character (#66), its
    ///   multi-image mode instead, at its own defaults too: it reads them in file-name order.
    public static func arguments(model: EngineModel, image: URL, output: URL, models: URL, seed: Int, views: URL? = nil) -> [String] {
        switch model.family {
        case .pixal3dSingleView:
            ["--sv-image", image.path, "--fov", fov, "--models", models.path, "--seed", String(seed),
             "--res", "1024", "--pixal3d-weights", "sv", "--gss", gss, output.path]
        case .trellis2:
            (views.map { ["--trellis2-mv", $0.path] } ?? ["--image", image.path])
                + ["--models", models.path, "--seed", String(seed), "--res", "1024", "--output", output.path]
        }
    }

    /// Where the pictures for the multi-image mode are put together, beside the 3D model, as
    /// trellis-cli keeps its single-view staging in `model.svviews`.
    static func views(_ output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent("model.mvviews")
    }

    public static func environment(_ base: [String: String]) -> [String: String] {
        base.merging(["PIXAL3D_STEPS": steps]) { $1 }
    }

    // MARK: Is it cut out already?

    /// Whether the picture is already cut out, judged by its alpha *content*: a model can write
    /// RGBA whose alpha is opaque noise, and trusting the channel's presence once turned a grey
    /// backdrop into two huge sheets beside a fox's head. A real cutout is 30–60% transparent;
    /// 2% only has to tell that apart from an alpha that cuts nothing.
    public static func isCutOut(_ url: URL) throws -> Bool {
        let image = try load(url)
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let pixels = try rgba(image)
        var clear = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] < 16 { clear += 1 }
        return Double(clear) / Double(image.width * image.height) >= 0.02
    }

    // MARK: Cutting out

    /// Cuts the character out with Apple's Vision and writes `<name>__matted.png` beside the
    /// picture. Compared with rembg on the four minis made so far, Vision kept every thin part
    /// (it kept the bow tips rembg ate): see app/NOTES.md.
    public static func cutOut(_ source: URL) throws -> URL {
        let image = try load(source)
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let found = request.results?.first, !found.allInstances.isEmpty else {
            throw Failure("Couldn't find the character in the picture. Try one with a plain background.")
        }
        let mask = try found.generateScaledMaskForImage(forInstances: found.allInstances, from: handler)
        // ponytail: the picture's own alpha is dropped here (drawn over black), like the wrapper's
        // convert("RGB"); a half-transparent input darkens slightly. Only an already-cut-out one
        // has meaningful alpha, and that one never gets here.
        var pixels = try rgba(image, opaque: true)
        guard CVPixelBufferGetWidth(mask) == image.width, CVPixelBufferGetHeight(mask) == image.height,
              CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else {
            throw Failure("Vision's cutout didn't match the picture.")
        }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        let row = CVPixelBufferGetBytesPerRow(mask)
        let base = CVPixelBufferGetBaseAddress(mask)!
        for y in 0..<image.height {
            let line = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<image.width {
                pixels[(y * image.width + x) * 4 + 3] = UInt8(max(0, min(1, line[x])) * 255 + 0.5)
            }
        }
        CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        cleanEdges(&pixels, width: image.width, height: image.height)

        let out = source.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent + "__matted.png")
        try writePNG(pixels, width: image.width, height: image.height, to: out)
        return out
    }

    /// Gives half-transparent edge pixels the colour of the character, not the old backdrop: a
    /// soft edge keeps part of the backdrop's colour, a light rim the 3D engine then paints onto
    /// the model. Colours spread in from solid pixels, one pixel per round; alpha is untouched.
    /// Straight (not premultiplied) RGBA. Same as image-to-3dlab's clean_edges.
    ///
    /// Fully clear pixels start black, as rembg left them: trellis-cli hands the picture's RGB
    /// to the model as it is, clear or not, and a backdrop left under alpha 0 was measured
    /// reaching the staged input.
    static func cleanEdges(_ p: inout [UInt8], width: Int, height: Int, solid: UInt8 = 250, reach: Int = 4) {
        for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] == 0 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0 }
        var known = (0..<width * height).map { p[$0 * 4 + 3] >= solid }
        for _ in 0..<reach {
            var grown: [(Int, UInt8, UInt8, UInt8)] = []
            for y in 0..<height {
                for x in 0..<width where !known[y * width + x] {
                    var r = 0, g = 0, b = 0, n = 0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let yy = y + dy, xx = x + dx
                            guard yy >= 0, yy < height, xx >= 0, xx < width, known[yy * width + xx] else { continue }
                            let j = (yy * width + xx) * 4
                            r += Int(p[j]); g += Int(p[j + 1]); b += Int(p[j + 2]); n += 1
                        }
                    }
                    if n > 0 {
                        func avg(_ v: Int) -> UInt8 { UInt8((Double(v) / Double(n)).rounded()) }
                        grown.append((y * width + x, avg(r), avg(g), avg(b)))
                    }
                }
            }
            if grown.isEmpty { break }
            for (i, r, g, b) in grown {
                p[i * 4] = r; p[i * 4 + 1] = g; p[i * 4 + 2] = b
                known[i] = true
            }
        }
    }

    // MARK: Running

    /// ggml logs every Metal pipeline it compiles: hundreds of lines nobody reads.
    static func keep(_ line: String) -> Bool {
        !line.hasPrefix("ggml_metal") && !line.contains("loaded kernel")
    }

    /// A flow has started sampling (its progress bar) without the override being announced:
    /// this trellis-cli ignores PIXAL3D_STEPS and would quietly run the slower 12 steps.
    static func samplingStarted(_ line: String) -> Bool { line.contains("[flow] [") }

    /// Cuts the picture out if it needs it, then runs trellis-cli from `engine` with `model`,
    /// writing its output (minus the noise) through `say`. Throws with a sentence for the log on
    /// failure. PIXAL3D_STEPS applies to every flow of either pipeline, so the same guard holds.
    ///
    /// `sides`: pictures of the back and sides besides `source`, the front (#66). Each is cut out
    /// the same way, and the front and they go to TRELLIS.2's multi-image mode, front first.
    public static func make(source: URL, output: URL, seed: Int, engine: URL, model: EngineModel,
                            sides: [(PictureSide, URL)] = [], environment: [String: String], say: (String) -> Void) throws {
        let source = source.standardizedFileURL, output = output.standardizedFileURL
        let cli = engine.appendingPathComponent("trellis-cli")
        for picture in [source] + sides.map(\.1) where !FileManager.default.fileExists(atPath: picture.path) {
            throw Failure("The picture is missing: \(picture.path)")
        }
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw Failure("The 3D engine is missing (\(cli.path)). Open Mimic's Settings and press Repair next to the 3D engine.")
        }
        if !sides.isEmpty && !model.multiView { throw Failure(RequestError.oneSideOnly(model.name).description) }
        func cutOutIfNeeded(_ picture: URL) throws -> URL {
            guard try !isCutOut(picture) else { return picture }
            say("[pixal3d] cutting the character out of \(picture.lastPathComponent) with Apple Vision")
            let cut = try cutOut(picture)
            say("[pixal3d] cut out: \(cut.path)")
            return cut
        }
        let image = try cutOutIfNeeded(source)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var views: URL?
        if !sides.isEmpty {
            // Numbered, since the engine reads them in name order: the front, then the sides in
            // PictureSide's order. Made afresh, so a picture left from a run before can't join in.
            let folder = Self.views(output)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var pictures = [("front", image)]
            for (side, picture) in sides { pictures.append((side.rawValue, try cutOutIfNeeded(picture))) }
            for (i, (name, picture)) in pictures.enumerated() {
                try FileManager.default.copyItem(at: picture, to: folder.appendingPathComponent("\(i + 1)-\(name).png"))
            }
            views = folder
        }
        say("[pixal3d] model=\(model.id) seed=\(seed)\(model.family == .pixal3dSingleView ? " gss=\(gss)" : "")"
            + (views == nil ? " steps=\(steps)" : " pictures=\(sides.count + 1)"))

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw Failure("Couldn't start the 3D engine (no pipe).") }
        // Not a new session: trellis-cli stays in this program's group, so Stop ends both.
        let process: GroupProcess
        do {
            process = try GroupProcess(executable: cli.path,
                                       arguments: arguments(model: model, image: image, output: output,
                                                            models: engine.appendingPathComponent("models/\(model.id)"), seed: seed, views: views),
                                       environment: Self.environment(environment),
                                       workingDirectory: engine.path, output: (fds[1], fds[0]), newSession: false)
        } catch {
            close(fds[0]); close(fds[1])
            throw Failure("The 3D engine didn't start: \(error)")
        }
        close(fds[1])
        defer { close(fds[0]) }

        var overridden = false
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func handle(_ line: String) -> Bool {
            overridden = overridden || line.contains("PIXAL3D_STEPS=")
            if !overridden && samplingStarted(line) { return false }
            if keep(line) { say(line) }
            return true
        }
        reading: while true {
            let n = read(fds[0], &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            // Progress bars redraw with \r, so it ends a line as much as \n does.
            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                if line.isEmpty { continue }
                if !handle(line) {
                    // Only trellis-cli: stopping the group would end this program before it
                    // could say why.
                    kill(process.pid, SIGKILL)
                    process.wait()
                    throw Failure("This 3D engine ignores PIXAL3D_STEPS, so it would run the slow way. "
                                  + "Stopped it before wasting the run. Open Mimic's Settings and press Repair next to the 3D engine.")
                }
            }
        }
        if !pending.isEmpty { _ = handle(String(decoding: pending, as: UTF8.self)) }
        let code = process.wait()
        guard code == 0 else { throw Failure("The 3D engine stopped with exit code \(code).") }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw Failure("The 3D engine finished without writing \(output.path).")
        }
    }

    // MARK: Pictures

    /// The longest side a new mini's picture is kept at: a 48 MP photo made every step (the
    /// cutout, its edge cleaning) work on twenty times the pixels, for a 3D engine that sees
    /// 1024 or 1536 of them.
    public static let pictureSide = 2048

    /// A new mini's picture as it's kept in its folder: upright, no longer than `pictureSide`
    /// on its longest side (never enlarged), as PNG with its transparency. Tidied once, when
    /// it's added, so every step after reads the same picture.
    public static func tidied(_ url: URL) throws -> Data {
        let image = try load(url, longest: pictureSide)
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("Couldn't read the picture \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure("Couldn't read the picture \(url.lastPathComponent).") }
        return png as Data
    }

    /// The picture upright, at full size or no longer than `longest`: a photo taken sideways is
    /// stored on its side with an orientation that says so, and New Mini shows it turned
    /// upright, so every step reads it that way too.
    static func load(_ url: URL, longest: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), longest ?? max(w, h)),
              ] as CFDictionary) else {
            throw Failure("Couldn't read the picture \(url.lastPathComponent).")
        }
        return image
    }

    /// The picture as 8-bit RGBA rows, top row first. `opaque` ignores its alpha.
    static func rgba(_ image: CGImage, opaque: Bool = false) throws -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure("Couldn't read the picture's pixels.") }
        return pixels
    }

    /// Straight alpha, so edge colours are exactly what cleanEdges chose.
    static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("Couldn't write \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure("Couldn't write \(url.lastPathComponent).") }
    }
}
