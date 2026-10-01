import AppKit
import ImageIO

/// A picture chosen for a new mini, with its warnings worked out from its real pixel size.
struct Picture {
    let url: URL
    let image: NSImage
    /// Pixels, upright.
    let width: Int, height: Int
    /// What's said under it: its file's name, unless there's something better to say.
    let caption: String

    init?(_ url: URL, caption: String? = nil) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = NSImage(contentsOf: url) else { return nil }
        // Photos taken sideways say so in their orientation; the picture is shown turned upright.
        let turned = [5, 6, 7, 8].contains(props[kCGImagePropertyOrientation] as? Int ?? 1)
        self.url = url
        self.image = image
        self.caption = caption ?? url.lastPathComponent
        (width, height) = turned ? (h, w) : (w, h)
    }
}
