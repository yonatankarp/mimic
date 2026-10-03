import Foundation
import XCTest
@testable import MimicCore

/// What the app's menus, alerts and save window say, decided from the queue and the job.
final class MenuWordsTests: XCTestCase {
    private func job(_ name: String, _ kind: JobKind = .generate, running: Bool = true) -> JobStatus {
        JobStatus(name: name, kind: kind, step: .print, started: Date(), running: running)
    }

    private func mini(_ name: String, project: String? = nil, _ change: (inout MiniSettings) -> Void = { _ in }) -> Mini {
        var s = MiniSettings()
        change(&s)
        return Mini(name: name, folder: URL(fileURLWithPath: "/runs/\(name)"), madeAt: Date(), project: project, settings: s)
    }

    func testStopSaysWhatThisMimicsJobIsDoing() {
        XCTAssertNil(JobProgress.stopCommand(nil))
        XCTAssertNil(JobProgress.stopCommand(job("dwarf", running: false)), "a job that ended can't be stopped")
        XCTAssertEqual(JobProgress.stopCommand(job("dwarf")), "Stop Making…")
        XCTAssertEqual(JobProgress.stopCommand(job("dwarf", .prep)), "Stop Resizing…")
    }

    func testPauseLetsTheMiniBeingMadeFinish() {
        XCTAssertEqual(JobProgress.pauseCommand(paused: true, making: true), "Resume Queue")
        XCTAssertEqual(JobProgress.pauseCommand(paused: false, making: true), "Pause After This One")
        XCTAssertEqual(JobProgress.pauseCommand(paused: false, making: false), "Pause Queue")
    }

    func testBusySaysWhatTheJobRunningIsDoing() {
        let fallback = "Couldn't start."
        XCTAssertEqual(plainWords(RequestError.busy("dwarf"), making: job("dwarf", .prep), else: fallback),
                       RequestError.busy("dwarf", .prep).description, "the gallery thought it was being made; it's being resized")
        XCTAssertEqual(plainWords(RequestError.busy("dwarf", .prep), making: job("dwarf"), else: fallback), RequestError.busy("dwarf").description)
        XCTAssertEqual(plainWords(RequestError.busy("dwarf", .prep), making: job("elf"), else: fallback),
                       RequestError.busy("dwarf", .prep).description, "another mini's job says nothing about this one")
        XCTAssertEqual(plainWords(RequestError.busy("dwarf", .prep), making: nil, else: fallback), RequestError.busy("dwarf", .prep).description)
        XCTAssertEqual(plainWords(CocoaError(.fileNoSuchFile), making: nil, else: fallback), fallback)
    }

    func testOpenTogetherNamesItsPrintFile() {
        XCTAssertEqual(ThreeMF.name([mini("dwarf-cleric")]), Mini.displayName("dwarf-cleric"))
        XCTAssertEqual(ThreeMF.name([mini("dwarf-cleric")], copies: 3), "\(Mini.displayName("dwarf-cleric")) ×3")
        XCTAssertEqual(ThreeMF.name([mini("a", project: "Party"), mini("b", project: "Party")]), "Party")
        XCTAssertEqual(ThreeMF.name([mini("a"), mini("b")], copies: 2), "Unsorted ×2")
        XCTAssertEqual(ThreeMF.name([mini("a", project: "Party"), mini("b"), mini("c")]), "3 Minis")
    }

    func testTheSaveWindowSaysWhetherItsInColour() {
        let colour = mini("dwarf") { $0.source = .image; $0.restyle = false }
        XCTAssertTrue(Tabletop.saveMessage(colour).contains("in its colours"))
        let sculpted = mini("dwarf") { $0.source = .image; $0.restyle = true }
        XCTAssertTrue(Tabletop.saveMessage(sculpted).contains("in grey"))
        XCTAssertTrue(Tabletop.saveMessage(sculpted).contains("grey sculpt first"), "says how to get colours")
        let changed = mini("dwarf") { $0.source = .image; $0.restyle = false; $0.fixes = ["a red cloak"] }
        XCTAssertTrue(Tabletop.saveMessage(changed).contains("change to its picture"), "says why a changed one can't be in colour")
    }
}
