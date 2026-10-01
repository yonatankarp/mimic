import XCTest
@testable import MimicCore

final class TourTests: XCTestCase {
    func testAFinishedJobIsSeenOnlyInFrontAndOnceItsEndWasShown() {
        XCTAssertTrue(JobProgress.seenEnd(active: true, busy: false, shownEnd: true))
        XCTAssertFalse(JobProgress.seenEnd(active: false, busy: false, shownEnd: true), "closed by switching to another app")
        XCTAssertFalse(JobProgress.seenEnd(active: true, busy: true, shownEnd: true), "the next one runs or waits")
        XCTAssertFalse(JobProgress.seenEnd(active: true, busy: false, shownEnd: false), "closed while it ran, or never shown in front")
    }

    func testTheDockCountsReadyMinisNotYetSeen() {
        XCTAssertNil(JobProgress.badge(unseen: [], minis: ["dwarf"]), "nothing, not 0")
        XCTAssertEqual(JobProgress.badge(unseen: ["dwarf", "elf"], minis: ["dwarf", "elf", "orc"]), "2")
        XCTAssertEqual(JobProgress.badge(unseen: ["dwarf", "elf"], minis: ["dwarf"]), "1", "one trashed since")
    }

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
        // An empty gallery: no mini page.
        let empty: Set<TourStep> = [.newMini]
        XCTAssertEqual(Tour.next(after: .make, onScreen: empty), .settings)
        XCTAssertEqual(Tour.steps(onScreen: empty), [.welcome, .newMini, .make, .settings])
        // New Mini's stop is never skipped: the tour opens it itself.
        XCTAssertEqual(Tour.next(after: .newMini, onScreen: []), .make)
    }

    func testFiveShortStops() {
        XCTAssertEqual(TourStep.allCases, [.welcome, .newMini, .make, .mini, .settings])
    }

    func testSettingsIsAlwaysTheLastStop() {
        // It points at nothing (Settings is in the Mimic menu), so nothing on screen can skip it.
        XCTAssertEqual(Tour.steps(onScreen: []), [.welcome, .make, .settings])
        XCTAssertEqual(Tour.next(after: .mini, onScreen: [.mini]), .settings)
        XCTAssertNil(Tour.next(after: .settings, onScreen: []))
    }

    func testTheToolbarShowsThisMimicsJobUntilSeenElseAnothers() {
        var mine = JobStatus(name: "dwarf", kind: .generate, step: .shape, started: Date())
        let other = JobStatus(name: "elf", kind: .generate, step: .picture, started: Date())
        XCTAssertEqual(JobProgress.inToolbar(mine, keptShown: false, elsewhere: other)?.name, "dwarf", "running")
        mine.running = false
        XCTAssertEqual(JobProgress.inToolbar(mine, keptShown: true, elsewhere: other)?.name, "dwarf", "ended, not seen yet")
        XCTAssertEqual(JobProgress.inToolbar(mine, keptShown: false, elsewhere: other)?.name, "elf", "seen: another Mimic's")
        XCTAssertNil(JobProgress.inToolbar(mine, keptShown: false, elsewhere: nil), "nothing to show")
    }

    func testPastingAPictureLeavesTextToTextFields() {
        XCTAssertTrue(MakeAdvice.pastesPicture(typing: false, hasText: true, hasPicture: true))
        XCTAssertTrue(MakeAdvice.pastesPicture(typing: true, hasText: false, hasPicture: true), "only a picture to paste")
        XCTAssertFalse(MakeAdvice.pastesPicture(typing: true, hasText: true, hasPicture: true), "typing: the text")
        XCTAssertFalse(MakeAdvice.pastesPicture(typing: false, hasText: true, hasPicture: false))
    }
}
