import XCTest
import simd
@testable import MimicCore

final class ViewerZoomTests: XCTestCase {
    func testAWheelClickInAndOutCancel() {
        let click = ViewerZoom.factor(scroll: 1, precise: false)
        XCTAssertEqual(click, 1.105, accuracy: 0.001, "about 10% a click")
        XCTAssertEqual(click * ViewerZoom.factor(scroll: -1, precise: false), 1, accuracy: 1e-6)
        XCTAssertEqual(ViewerZoom.factor(scroll: 40, precise: false), ViewerZoom.factor(scroll: 3, precise: false),
                       "a hard spin is capped at three clicks an event")
    }

    func testATrackpadSwipeDoublesAndAPinchFollowsTheFingers() {
        // A long swipe arrives as many small events; together they about double it.
        let swipe = (0..<30).reduce(Float(1)) { z, _ in z * ViewerZoom.factor(scroll: 10, precise: true) }
        XCTAssertEqual(swipe, 2, accuracy: 0.05)
        XCTAssertEqual(ViewerZoom.factor(magnification: 0.02), 1.02, accuracy: 0.001)
        XCTAssertEqual(ViewerZoom.factor(magnification: 0.1) * ViewerZoom.factor(magnification: -0.1), 1, accuracy: 1e-6)
    }

    func testThePointUnderThePointerStaysUnderIt() {
        // Model point m is drawn at offset + scale × m (turning doesn't change the argument).
        let anchor = SIMD2<Float>(0.3, 0.2)
        let offset = SIMD2<Float>(0.1, -0.05), scale: Float = 2
        let m = (anchor - offset) / scale  // the point of the mini under the pointer
        let z = ViewerZoom.zoomed(scale: scale, offset: offset, by: 1.25, toward: anchor)
        XCTAssertEqual(z.scale, 2.5)
        XCTAssertLessThan(simd_distance(z.offset + z.scale * m, anchor), 1e-6, "still under the pointer")
    }

    func testZoomingAtTheMiddleOnlyScales() {
        let z = ViewerZoom.zoomed(scale: 1, offset: .zero, by: 3, toward: .zero)
        XCTAssertEqual(z.scale, 3)
        XCTAssertEqual(z.offset, .zero)
    }

    func testClampsTheZoomAndKeepsTheMiniInView() {
        XCTAssertEqual(ViewerZoom.zoomed(scale: 3.9, offset: .zero, by: 2, toward: .zero).scale, 4)
        XCTAssertEqual(ViewerZoom.zoomed(scale: 0.5, offset: .zero, by: 0.1, toward: .zero).scale, 0.4)
        // Zooming in at a far corner grows it away from that corner, but by at most half the extra size.
        let corner = ViewerZoom.zoomed(scale: 1, offset: .zero, by: 2, toward: [5, 5])
        XCTAssertEqual(corner.offset, [-0.5, -0.5])
        // Back at the default size (or smaller) it's in the middle again, wherever the pointer is.
        let back = ViewerZoom.zoomed(scale: 2, offset: [0.5, 0.5], by: 0.5, toward: [0.7, -0.3])
        XCTAssertEqual(back.scale, 1)
        XCTAssertEqual(back.offset, .zero)
    }

    func testThePointerMapsOntoTheMinisPlane() {
        let size = CGSize(width: 800, height: 400)
        XCTAssertEqual(ViewerZoom.anchor(at: CGPoint(x: 400, y: 200), in: size, distance: 1.7, fieldOfView: 45), .zero)
        let halfHeight = 1.7 * tan(Float.pi / 8)
        let top = ViewerZoom.anchor(at: CGPoint(x: 400, y: 0), in: size, distance: 1.7, fieldOfView: 45)
        XCTAssertEqual(top.y, halfHeight, accuracy: 1e-5, "the top edge is up, not down")
        let left = ViewerZoom.anchor(at: CGPoint(x: 0, y: 200), in: size, distance: 1.7, fieldOfView: 45)
        XCTAssertEqual(left.x, -2 * halfHeight, accuracy: 1e-5, "twice as wide as tall")
        XCTAssertEqual(ViewerZoom.anchor(at: .zero, in: .zero, distance: 1.7, fieldOfView: 45), .zero)
    }

    func testAGlideEasesFromStartToEndAndStaysThere() {
        XCTAssertEqual(Glide.progress(elapsed: 0, over: 0.45), 0)
        XCTAssertEqual(Glide.progress(elapsed: 0.225, over: 0.45), 0.5, accuracy: 1e-6)
        XCTAssertLessThan(Glide.progress(elapsed: 0.05, over: 0.45), 0.05 / 0.45, "starts softly")
        XCTAssertEqual(Glide.progress(elapsed: 0.45, over: 0.45), 1, "lands exactly")
        XCTAssertEqual(Glide.progress(elapsed: 3, over: 0.45), 1, "a late frame doesn't overshoot")
        XCTAssertEqual(Glide.progress(elapsed: -1, over: 0.45), 0)
        XCTAssertEqual(Glide.progress(elapsed: 0, over: 0), 1, "no glide: already there")
    }

    /// Every corner of the mini's box, however it's turned round, lands inside the seen band.
    func testTheMiniFitsTheSeenPartOfTheView() {
        let mini = SIMD3<Float>(0.76, 1, 0.74)
        for (view, top, bottom) in [(CGSize(width: 360, height: 730), 96.0, 56.0), (CGSize(width: 650, height: 680), 96, 56),
                                    (CGSize(width: 1200, height: 500), 96, 56)] {
            let camera = ViewerCamera.fitting(mini, in: view, top: top, bottom: bottom)
            var lo = CGPoint(x: CGFloat.infinity, y: .infinity), hi = CGPoint(x: -CGFloat.infinity, y: -.infinity)
            for x in [-1, 1] as [Float] { for y in [-1, 1] as [Float] { for z in [-1, 1] as [Float] {
                for turned in [false, true] {  // a quarter turn swaps width and depth
                    let half = turned ? SIMD3(mini.z, mini.y, mini.x) / 2 : mini / 2
                    let p = camera.project(SIMD3(x, y, z) * half, in: view)
                    lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y)); hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
                }
            } } }
            XCTAssertGreaterThanOrEqual(lo.y, top, "\(view): clear of the toolbar")
            XCTAssertLessThanOrEqual(hi.y, view.height - bottom, "\(view): clear of the hint")
            XCTAssertGreaterThanOrEqual(lo.x, 0); XCTAssertLessThanOrEqual(hi.x, view.width)
            // Its middle is in the middle of the band.
            XCTAssertEqual(camera.project(.zero, in: view).y, (top + view.height - bottom) / 2, accuracy: 0.5)
        }
        let narrow = ViewerCamera.fitting(mini, in: CGSize(width: 360, height: 730), top: 96, bottom: 56)
        let wide = ViewerCamera.fitting(mini, in: CGSize(width: 900, height: 730), top: 96, bottom: 56)
        XCTAssertGreaterThan(narrow.distance, wide.distance, "a narrow view stands further back, to fit its width")
        XCTAssertEqual(ViewerCamera().project(SIMD3(1, 1, 0), in: .zero), .zero, "not laid out yet: no NaN frames")
    }

    func testThePointerMapsOntoTheMinisPlaneWithTheCameraLifted() {
        let view = CGSize(width: 400, height: 600)
        let camera = ViewerCamera.fitting(SIMD3(0.8, 1, 0.8), in: view, top: 100, bottom: 50)
        let p = camera.project(SIMD3(0.2, -0.3, 0), in: view)
        let back = camera.anchor(at: p, in: view)
        XCTAssertEqual(back.x, 0.2, accuracy: 1e-4); XCTAssertEqual(back.y, -0.3, accuracy: 1e-4)
    }
}
