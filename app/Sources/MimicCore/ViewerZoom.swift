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

/// Where the 3D view's camera stands so the whole mini fits the part of the view you can see:
/// below the toolbar and the controls, above the hint, with room to spare on every side, by
/// width as well as height. The camera looks straight ahead; `lift` raises it, which moves the
/// mini down the view to the middle of the part that's seen.
public struct ViewerCamera: Equatable, Sendable {
    public var distance: Float
    public var lift: Float
    /// Degrees, top to bottom.
    public static let fieldOfView: Float = 45

    public init(distance: Float = 1.7, lift: Float = 0) { self.distance = distance; self.lift = lift }

    /// `size` is the mini's in the scene, 1 m tall; `top` and `bottom` are the points of the view
    /// covered at each edge; `margin` is the share of the seen part kept free around it.
    public static func fitting(_ size: SIMD3<Float>, in view: CGSize, top: CGFloat, bottom: CGFloat, margin: Float = 0.15) -> ViewerCamera {
        guard view.width > 0, view.height > 0 else { return ViewerCamera() }
        let t = tan(fieldOfView * .pi / 360)
        let height = Float(view.height)
        // Half the seen band's height, as a share of half the view's (1 = all of it).
        let band = max(0.2, 1 - Float(top + bottom) / height)
        let aspect = Float(view.width) / height
        // It turns, so either side of its footprint can face you, and its nearest edge looks
        // biggest: fit that edge, and everything behind it fits too.
        let wide = max(size.x, size.z, 0.01)
        let perMetre = min((1 - margin) * band / (size.y / 2), (1 - margin) * aspect / (wide / 2))
        let distance = wide / 2 + 1 / (perMetre * t)
        return ViewerCamera(distance: distance, lift: Float(top - bottom) / height * distance * t)
    }

    /// Where a point in the scene lands in the view, in points from the top left.
    public func project(_ p: SIMD3<Float>, in view: CGSize) -> CGPoint {
        guard view.width > 0, view.height > 0 else { return .zero }  // not laid out yet
        let t = tan(Self.fieldOfView * .pi / 360)
        let depth = max(distance - p.z, 0.01)
        let aspect = Float(view.width / max(view.height, 1))
        let x = p.x / (depth * t * aspect), y = (p.y - lift) / (depth * t)
        return CGPoint(x: CGFloat(x + 1) / 2 * view.width, y: CGFloat(1 - y) / 2 * view.height)
    }

    /// Where a point in the view falls in the plane through the mini's middle: for zooming
    /// toward the pointer.
    public func anchor(at point: CGPoint, in view: CGSize) -> SIMD2<Float> {
        ViewerZoom.anchor(at: point, in: view, distance: distance, fieldOfView: Self.fieldOfView) + SIMD2(0, lift)
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
