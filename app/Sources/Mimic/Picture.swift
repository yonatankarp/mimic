import AppKit
import ImageIO
import MimicCore

/// A picture chosen for a new mini, with its warnings worked out from its real pixel size.
struct Picture: Equatable {
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

/// What New Mini opens filled in with (Edit & Make Again, the tour's sample): the form, and its
/// pictures decoded, made once when the sheet is asked for and carried in `AppSheet`. The
/// sheet's content is built again on every frame of a window resize, so `MakeView.init` reads
/// nothing itself (#341).
struct MakeStart: Equatable {
    let form: MakeForm
    let picture: Picture?
    let sides: [PictureSide: Picture]

    init(_ form: MakeForm, again: Mini? = nil) {
        self.form = form
        picture = form.picture.flatMap { Picture($0, caption: again.map { "The picture \($0.displayName) was made from" }) }
        sides = form.sides.compactMapValues { Picture($0) }
    }

    /// Edit & Make Again's: everything `mini` was made from, read from its folder now.
    static func again(_ mini: Mini, install: Install) -> MakeStart? {
        MakeForm.again(mini, install: install, card: .remembered()).map { MakeStart($0, again: mini) }
    }
}
