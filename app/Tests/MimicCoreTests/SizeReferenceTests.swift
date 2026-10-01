import XCTest
import simd
@testable import MimicCore

final class SizeReferenceTests: XCTestCase {
    /// A 32 mm mini on a 25 mm base, as the 3D view has it: 1 tall, its base's middle under the box's.
    let dwarf = SIMD3<Float>(26, 32, 25) / 32
    func layout(_ kind: SizeReference, height: Float = 32, mini: SIMD3<Float>? = nil,
                origin: SIMD3<Float> = [0, -0.5, 0]) -> ReferenceLayout {
        ReferenceLayout(kind: kind, height: height, mini: mini ?? dwarf, origin: origin)
    }

    func testTheStoredChoicesKeepTheirNames() {
        // Renaming one would quietly put everyone's choice back to none.
        XCTAssertEqual(SizeReference.allCases.map(\.rawValue), ["none", "base", "person", "grid"])
        XCTAssertEqual(SizeReference.key, "sizeReference")
        XCTAssertEqual(SizeReference.allCases.map(\.title), ["None", "25 mm Base", "32 mm Person", "Millimetre Grid"])
    }

    func testAMillimetreIsOneOverThePrintsHeight() {
        let small = layout(.base)
        XCTAssertEqual(small.ringRadius, 12.5 / 32, accuracy: 1e-6, "a 25 mm base's radius, not its diameter")
        XCTAssertEqual(small.personHeight, 1, accuracy: 1e-6, "a 32 mm person is as tall as a 32 mm mini")
        XCTAssertEqual(small.gridSquare, 1)
        XCTAssertEqual(small.gridSpacing, 1 / 32, accuracy: 1e-6)
        let dragon = layout(.base, height: 100)
        XCTAssertEqual(dragon.ringRadius, 0.125, accuracy: 1e-6)
        XCTAssertEqual(dragon.personHeight, 0.32, accuracy: 1e-6, "a third of a 100 mm dragon")
        XCTAssertEqual(dragon.gridSquare, 5, "millimetres would be too fine to see on a big mini")
        XCTAssertEqual(dragon.gridSpacing, 0.05, accuracy: 1e-6)
        XCTAssertEqual(layout(.grid, height: 60).gridSquare, 2)
        XCTAssertEqual(layout(.grid, height: 400).gridSquare, 10)
        XCTAssertEqual(layout(.grid, height: 40).gridSquare, 1, "40 mm still has millimetre squares")
    }

    func testTheRingHugsA25mmBaseFromOutside() {
        let l = layout(.base, origin: [0.05, -0.5, -0.02])
        let ring = l.ring
        XCTAssertFalse(ring.indices.isEmpty)
        let radii = ring.positions.map { simd_length(SIMD2($0.x, $0.z) - SIMD2(0.05, -0.02)) }
        XCTAssertEqual(radii.min()!, l.ringRadius, accuracy: 1e-5, "centred on the base, its inside 25 mm across")
        XCTAssertLessThan(radii.max()!, l.ringRadius + 0.02)
        let heights = ring.positions.map(\.y)
        XCTAssertGreaterThan(heights.min()!, -0.5, "just above the floor, so it doesn't flicker against the base")
        XCTAssertLessThan(heights.max()!, -0.5 + 0.02)
    }

    func testThePersonStandsBesideTheMiniAt32mm() {
        for height: Float in [32, 28, 100] {
            let person = layout(.person, height: height).person
            let heights = person.positions.map(\.y)
            XCTAssertEqual(heights.min()!, -0.5, accuracy: 1e-6, "on the floor")
            XCTAssertEqual(heights.max()! + 0.5, 32 / height, accuracy: 1e-4, "\(height) mm mini: a 32 mm person")
            let left = person.positions.map(\.x).min()!
            XCTAssertGreaterThan(left, dwarf.x / 2, "clear of the mini however it's turned")
            XCTAssertGreaterThan(person.positions.map(\.z).max()! - person.positions.map(\.z).min()!, 0.1 * 32 / height,
                                 "has depth, so it doesn't vanish edge-on")
        }
    }

    func testTheGridIsSquaresOnTheFloorBolderEveryCentimetre() {
        let l = layout(.grid)
        let meshes = l.grid
        XCTAssertEqual(meshes.map(\.bold), [false, true])
        for p in meshes.flatMap(\.positions) { XCTAssertEqual(p.y, -0.5 + ReferenceLayout.lift, accuracy: 1e-6) }
        // Each line is a thin strip: its middles along x are a square apart, a bold one every 10.
        func middles(_ mesh: ReferenceMesh) -> Set<Int> {
            Set(stride(from: 0, to: mesh.positions.count, by: 4).compactMap { k in
                let quad = mesh.positions[k..<k + 4]
                let xs = quad.map(\.x)
                guard xs.max()! - xs.min()! < 0.01 else { return nil }  // runs along z
                return Int((xs.reduce(0, +) / 4 / l.gridSpacing).rounded())
            })
        }
        let thin = middles(meshes[0]), bold = middles(meshes[1])
        XCTAssertTrue(bold.allSatisfy { $0 % 10 == 0 }, "bold lines are whole centimetres")
        XCTAssertTrue(bold.contains(0) && bold.contains(10))
        XCTAssertTrue(thin.contains(1) && thin.contains(9) && !thin.contains(10))
        // It reaches past the footprint.
        let reach = meshes.flatMap(\.positions).map { abs($0.x) }.max()!
        XCTAssertGreaterThan(reach, dwarf.x / 2)
        // On a big mini a square is 5 mm, and a bold line every second one.
        let dragon = layout(.grid, height: 100, mini: [0.8, 1, 0.7])
        XCTAssertEqual(dragon.gridSquare, 5)
        XCTAssertFalse(dragon.grid[1].positions.isEmpty)
    }

    func testAPrintFileFromElsewhereIsCentredOnItsBox() {
        // Print prep puts the base's middle at the origin; another file may have it anywhere.
        XCTAssertEqual(layout(.base, origin: [0.1, -0.5, 0.1]).centre, [0.1, 0.1])
        XCTAssertEqual(layout(.base, origin: [3, -0.5, 0]).centre, .zero)
        XCTAssertEqual(layout(.base, origin: [0, -0.5, -0.9]).centre, .zero)
    }

    func testTheCameraFitsTheMiniAndTheReference() {
        XCTAssertEqual(layout(.none).fit, dwarf, "nothing drawn: the mini alone")
        XCTAssertTrue(layout(.none).meshes.isEmpty)
        for kind in SizeReference.allCases where kind != .none {
            for height: Float in [10, 28, 32, 100] {
                let l = layout(kind, height: height)
                let fit = l.fit
                XCTAssertGreaterThanOrEqual(fit.y, 1); XCTAssertGreaterThanOrEqual(fit.x, dwarf.x)
                XCTAssertEqual(fit.x, fit.z, "it turns, so as deep as it is wide")
                for p in l.meshes.flatMap(\.positions) {
                    XCTAssertLessThanOrEqual(abs(p.y), fit.y / 2 + 1e-5, "\(kind) at \(height) mm")
                    XCTAssertLessThanOrEqual(simd_length(SIMD2(p.x, p.z)), fit.x / 2 + 1e-5, "\(kind) at \(height) mm, turned")
                }
            }
        }
        // A 32 mm person beside a 10 mm thing: the view fits the person, so the thing is small.
        XCTAssertEqual(layout(.person, height: 10).fit.y, 2 * (3.2 - 0.5), accuracy: 1e-4)
        // Every point lands in the seen part of the view (as for the mini alone in ViewerZoomTests).
        let l = layout(.person, height: 28)
        let view = CGSize(width: 650, height: 680)
        let camera = ViewerCamera.fitting(l.fit, in: view, top: 96, bottom: 56)
        for p in l.person.positions {
            let at = camera.project(p, in: view)
            XCTAssertGreaterThanOrEqual(at.y, 96); XCTAssertLessThanOrEqual(at.y, view.height - 56)
            XCTAssertGreaterThanOrEqual(at.x, 0); XCTAssertLessThanOrEqual(at.x, view.width)
        }
    }

    func testVoiceOverHearsWhatIsShown() {
        XCTAssertNil(SizeReference.none.spoken(gridSquare: 1))
        XCTAssertEqual(SizeReference.base.spoken(gridSquare: 1), "on a 25 mm base ring")
        XCTAssertEqual(SizeReference.person.spoken(gridSquare: 1), "beside a 32 mm person")
        XCTAssertEqual(SizeReference.grid.spoken(gridSquare: 5), "on a grid of 5 mm squares")
    }

    func testEveryTriangleIsSeenFromBothSides() {
        for kind in SizeReference.allCases {
            for mesh in layout(kind).meshes {
                XCTAssertEqual(mesh.indices.count % 6, 0)
                for k in stride(from: 0, to: mesh.indices.count, by: 6) {
                    let i = mesh.indices
                    XCTAssertEqual([i[k], i[k + 1], i[k + 2]], [i[k + 3], i[k + 5], i[k + 4]])
                }
                XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.positions.count })
            }
        }
    }
}
