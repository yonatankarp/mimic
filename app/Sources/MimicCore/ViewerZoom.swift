import Foundation
import simd

/// The 3D view's zoom, kept apart from the view so the numbers can be tested: how much one
/// pinch or scroll event zooms, and where the mini moves so the spot under the pointer stays
/// under it.
///
/// Every step is a factor of `exp(k × amount)`, so a wheel click in and a click out cancel
/// exactly, and a pinch zooms as much going out as coming in.
public enum ViewerZoom {
    /// From a little under the default size to four times it.
    public static let range: ClosedRange<Float> = 0.4...4

    /// A pinch: AppKit reports each event's growth (0.02 = 2% bigger), which is what the
    /// fingers did, so it zooms by that.
    public static func factor(magnification: Double) -> Float {
        Float(exp(magnification))
    }

    /// A scroll. A mouse wheel reports whole lines, about 1 a click and more when spun fast:
    /// about 10% a click, capped at three clicks' worth an event so a hard spin can't jump.
    /// A trackpad or Magic Mouse reports points, dozens an event: a long two-finger swipe
    /// (about 300 points) doubles it. Up zooms in.
    public static func factor(scroll delta: Double, precise: Bool) -> Float {
        let amount = precise ? delta * 0.0023 : min(3, max(-3, delta)) * 0.1
        return Float(exp(amount))
    }

    /// The new zoom and offset after zooming by `factor` toward `anchor`, a point in the plane
    /// through the mini's middle facing the camera (where the pointer is, in the scene's
    /// metres). The mini is drawn as offset + turn × zoom × shape, so keeping the anchor still
    /// is offset' = anchor − (zoom'/zoom)(anchor − offset), whatever way it's turned.
    ///
    /// The offset is kept to half the zoom above the default size, so the mini always covers
    /// the middle of the view when zoomed in and slides back to the middle as you zoom out.
    public static func zoomed(scale: Float, offset: SIMD2<Float>, by factor: Float, toward anchor: SIMD2<Float>) -> (scale: Float, offset: SIMD2<Float>) {
        let next = min(range.upperBound, max(range.lowerBound, scale * factor))
        let moved = anchor - (next / scale) * (anchor - offset)
        let limit = max(0, next - 1) / 2  // the mini is 1 m tall at the default size
        return (next, simd_clamp(moved, SIMD2(repeating: -limit), SIMD2(repeating: limit)))
    }

    /// Where a point in the view (points from the top left) falls in that plane, `distance`
    /// in front of a camera whose field of view is `fieldOfView` degrees top to bottom.
    public static func anchor(at point: CGPoint, in size: CGSize, distance: Float, fieldOfView: Float) -> SIMD2<Float> {
        guard size.width > 0, size.height > 0 else { return .zero }
        let halfHeight = distance * tan(fieldOfView * .pi / 360)
        let halfWidth = halfHeight * Float(size.width / size.height)
        return SIMD2(Float(point.x / size.width * 2 - 1) * halfWidth,
                     Float(1 - point.y / size.height * 2) * halfHeight)
    }
}

/// How far through a glide (Face Front, a mini growing into place) the 3D view is: 0 to 1,
/// easing in and out, so it starts and lands softly.
public enum Glide {
    public static func progress(elapsed: Double, over seconds: Double) -> Float {
        guard seconds > 0 else { return 1 }
        let x = Float(min(1, max(0, elapsed / seconds)))
        return x * x * (3 - 2 * x)
    }
}
