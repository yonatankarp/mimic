import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture of Mimic's own window for Report a Problem… (#283): Mimic draws its views into an
/// image, which needs no Screen Recording permission, unlike a screen capture. What's drawn by
/// Metal (the 3D view) may come out empty.
@MainActor
public enum WindowPicture {
    /// `window` with its title bar and toolbar, and the sheets over it, as PNG; nil when it has
    /// nothing drawn.
    public static func png(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView, let base = image(view) else { return nil }
        let frame = window.frame, scale = CGFloat(base.width) / max(frame.width, 1)
        guard let cg = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        cg.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        var sheet = window.attachedSheet
        while let s = sheet {
            if let v = s.contentView?.superview ?? s.contentView, let img = image(v) {
                let r = s.frame
                cg.draw(img, in: CGRect(x: (r.minX - frame.minX) * scale, y: (r.minY - frame.minY) * scale,
                                        width: r.width * scale, height: r.height * scale))
            }
            sheet = s.attachedSheet
        }
        return cg.makeImage().flatMap(encode)
    }

    /// `view` as it's drawn now, as PNG.
    public static func png(_ view: NSView) -> Data? { image(view).flatMap(encode) }

    static func image(_ view: NSView) -> CGImage? {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    nonisolated static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
