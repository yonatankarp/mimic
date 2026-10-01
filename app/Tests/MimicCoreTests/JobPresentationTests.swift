import XCTest
@testable import MimicCore

final class JobPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func job(_ name: String, running: Bool = true, exit: Int32? = nil, canceled: Bool = false, at offset: TimeInterval = 0) -> JobStatus {
        var s = JobStatus(name: name, kind: .generate, step: 1, started: start.addingTimeInterval(offset))
        s.running = running
        s.exit = exit
        s.canceled = canceled
        return s
    }

    private func ready(_ name: String, at offset: TimeInterval = 0) -> JobStatus { job(name, running: false, exit: 0, at: offset) }

    /// A job started, ran and finished with the popover never opened.
    private func finishedUnseen(_ name: String) -> JobPresentation {
        var p = JobPresentation()
        p.jobAdded(note: nil)
        _ = p.jobChanged(from: job(name), to: ready(name))
        p.jobFinished(ready(name), onScreen: false)
        return p
    }

    func testAStartedJobStaysInTheToolbarUntilItsEndIsSeen() {
        var p = finishedUnseen("dwarf")
        XCTAssertTrue(p.keptShown)
        XCTAssertEqual(p.unseen, ["dwarf"])
        p.popoverShowing(active: true, open: true, idle: true)
        XCTAssertTrue(p.popoverClosed(active: true, busy: false))
        XCTAssertFalse(p.keptShown)
        XCTAssertEqual(p.unseen, [])
        XCTAssertFalse(p.shownEnd)
    }

    func testSwitchingAwayClosesThePopoverWithoutSeeingIt() {
        var p = finishedUnseen("dwarf")
        p.noteQueued(.init(name: "elf", text: "Added to the queue."))
        p.popoverShowing(active: true, open: true, idle: true)
        XCTAssertFalse(p.popoverClosed(active: false, busy: false), "the ready item is still there when you come back")
        XCTAssertTrue(p.keptShown)
        XCTAssertEqual(p.unseen, ["dwarf"])
        XCTAssertEqual(p.queuedNote?.name, "elf", "not read, so kept (#141)")
        XCTAssertFalse(p.shownEnd, "shown again before the next close counts")
        XCTAssertFalse(p.popoverClosed(active: true, busy: false))
    }

    func testClosingInFrontWhileBusyDropsOnlyTheQueuedNote() {
        var p = JobPresentation()
        p.jobAdded(note: .init(name: "elf", text: "Added to the queue. 1 ahead of it."))
        _ = p.jobChanged(from: nil, to: job("dwarf"))
        p.popoverShowing(active: true, open: true, idle: false)
        XCTAssertFalse(p.shownEnd, "still running")
        XCTAssertFalse(p.popoverClosed(active: true, busy: true))
        XCTAssertNil(p.queuedNote, "seen once is enough (#141)")
        XCTAssertTrue(p.keptShown)
    }

    func testThePopoverShowsTheEndOnlyOpenInFrontWithNothingRunning() {
        var p = JobPresentation()
        p.popoverShowing(active: false, open: true, idle: true)
        XCTAssertFalse(p.shownEnd)
        p.popoverShowing(active: true, open: false, idle: true)
        XCTAssertFalse(p.shownEnd)
        p.popoverShowing(active: true, open: true, idle: false)
        XCTAssertFalse(p.shownEnd, "running here or in another Mimic")
        p.popoverShowing(active: true, open: true, idle: true)
        XCTAssertTrue(p.shownEnd)
    }

    func testAWaitingQueueKeepsTheToolbarItemAfterTheEndWasShown() {
        var p = finishedUnseen("dwarf")
        p.popoverShowing(active: true, open: true, idle: true)
        XCTAssertFalse(p.popoverClosed(active: true, busy: true), "the next one waits")
        XCTAssertTrue(p.keptShown)
        XCTAssertFalse(p.shownEnd)
    }

    func testAJobThatEndedIsListedUnderTheNextOne() {
        var p = JobPresentation()
        _ = p.jobChanged(from: nil, to: job("dwarf"))
        _ = p.jobChanged(from: job("dwarf"), to: ready("dwarf"))
        XCTAssertEqual(p.ended, [], "still the one the popover shows")
        _ = p.jobChanged(from: ready("dwarf"), to: ready("dwarf"))
        XCTAssertEqual(p.ended, [], "the same status again")
        _ = p.jobChanged(from: ready("dwarf"), to: job("elf", at: 60))
        XCTAssertEqual(p.ended.map(\.name), ["dwarf"])
        // Tried again under the same name: a new start time, so the failed one is listed.
        let failed = job("elf", running: false, exit: 1, at: 60)
        _ = p.jobChanged(from: failed, to: job("elf", at: 120))
        XCTAssertEqual(p.ended.map(\.name), ["dwarf", "elf"])
        p.retried("elf")
        XCTAssertEqual(p.ended.map(\.name), ["dwarf"])
        p.popoverShowing(active: true, open: true, idle: true)
        XCTAssertTrue(p.popoverClosed(active: true, busy: false))
        XCTAssertEqual(p.ended, [])
    }

    func testStartedAndFinished() {
        var p = JobPresentation()
        XCTAssertEqual(p.jobChanged(from: nil, to: job("dwarf")), .init(started: true, finished: false))
        XCTAssertEqual(p.jobChanged(from: job("dwarf"), to: job("dwarf")), .init(started: false, finished: false), "started at once by Make")
        XCTAssertEqual(p.jobChanged(from: job("dwarf"), to: job("elf")), .init(started: true, finished: false))
        XCTAssertEqual(p.jobChanged(from: job("elf"), to: ready("elf")), .init(started: false, finished: true))
        XCTAssertEqual(p.jobChanged(from: ready("elf"), to: ready("elf")), .init(started: false, finished: false))
        XCTAssertEqual(p.jobChanged(from: nil, to: ready("orc")), .init(started: false, finished: true), "the first status ever")
        XCTAssertEqual(p.jobChanged(from: ready("orc"), to: ready("orc", at: 60)), .init(started: false, finished: true), "another run of it")
    }

    func testANewJobStartingForgetsTheEndShownAndItsOwnNote() {
        var p = finishedUnseen("dwarf")
        p.popoverShowing(active: true, open: true, idle: true)
        p.noteQueued(.init(name: "orc", text: "2 minis added to the queue."))
        _ = p.jobChanged(from: ready("dwarf"), to: job("elf", at: 60))
        XCTAssertFalse(p.shownEnd)
        XCTAssertEqual(p.queuedNote?.name, "orc", "another mini's note stays")
        _ = p.jobChanged(from: job("elf", at: 60), to: job("orc", at: 120))
        XCTAssertNil(p.queuedNote, "that mini started")
    }

    func testOnlyAReadyMiniOffScreenIsUnseen() {
        var p = JobPresentation()
        p.jobFinished(ready("dwarf"), onScreen: true)
        p.jobFinished(job("elf", running: false, exit: 1), onScreen: false)
        p.jobFinished(job("orc", running: false, canceled: true), onScreen: false)
        XCTAssertEqual(p.unseen, [])
        p.jobFinished(ready("goblin"), onScreen: false)
        XCTAssertEqual(p.unseen, ["goblin"])
    }

    func testPickingAMiniSeesIt() {
        var p = finishedUnseen("dwarf")
        XCTAssertFalse(p.seen(["elf"]))
        XCTAssertTrue(p.seen(["dwarf", "elf"]))
        XCTAssertEqual(p.unseen, [])
        XCTAssertTrue(p.keptShown, "the toolbar item waits for the popover")
    }

    func testAddingAJobShowsItWithItsNote() {
        var p = JobPresentation()
        p.jobAdded(note: .init(name: "dwarf", text: "Added to the queue."))
        XCTAssertTrue(p.keptShown)
        XCTAssertEqual(p.queuedNote?.text, "Added to the queue.")
        p.jobAdded(note: nil)
        XCTAssertNil(p.queuedNote, "started at once")
    }
}
