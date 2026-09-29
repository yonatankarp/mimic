import XCTest
@testable import MimicCore

final class TourTests: XCTestCase {
    func testStartsOnceAndOnlyWhenMimicCanMakeMinis() {
        XCTAssertTrue(Tour.shouldStart(seen: false, installed: true))
        XCTAssertFalse(Tour.shouldStart(seen: false, installed: false), "not over the setup screen")
        XCTAssertFalse(Tour.shouldStart(seen: true, installed: true), "only once")
    }

    func testEveryStopWhenEverythingIsOnScreen() {
        let all = Set(TourStep.allCases)
        XCTAssertEqual(Tour.steps(onScreen: all), TourStep.allCases)
        XCTAssertEqual(Tour.next(after: .welcome, onScreen: all), .newMini)
        XCTAssertEqual(Tour.next(after: .make, onScreen: all), .mini)
        XCTAssertNil(Tour.next(after: .settings, onScreen: all), "the last stop ends it")
    }

    func testSkipsMainWindowStopsThatArentThere() {
        // An empty gallery: no mini page, sidebar still there.
        let empty: Set<TourStep> = [.newMini, .gallery, .settings]
        XCTAssertEqual(Tour.next(after: .make, onScreen: empty), .gallery)
        XCTAssertEqual(Tour.steps(onScreen: empty).count, 7)
        // New Mini's stops are never skipped: the tour opens it itself.
        XCTAssertEqual(Tour.next(after: .newMini, onScreen: []), .start)
        XCTAssertEqual(Tour.next(after: .make, onScreen: []), nil)
    }
}
