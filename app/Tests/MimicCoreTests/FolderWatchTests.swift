import Foundation
import XCTest
@testable import MimicCore

/// The list refreshes when something else changes the minis folder (#81): a mini or project
/// added, renamed or removed, in the minis folder or a project. Not files written inside a mini,
/// which a running job does all the time.
final class FolderWatchTests: XCTestCase {
    @MainActor
    func testSaysWhenMinisOrProjectsChangeButNotWhenAMiniWritesItsFiles() throws {
        let fx = try Fixture(), runs = fx.install.runs, fm = FileManager.default
        let mini = try fx.mini("dwarf")
        try fm.createDirectory(at: runs.appendingPathComponent("Party"), withIntermediateDirectories: true)
        var calls = 0
        let watch = FolderWatch { calls += 1 }
        watch.follow(runs, projects: ["Party"])

        try "log".write(to: mini.appendingPathComponent("pixal3d.log"), atomically: false, encoding: .utf8)  // a job writing
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(calls, 0, "a file written inside a mini")

        try fm.createDirectory(at: runs.appendingPathComponent("Party/elf"), withIntermediateDirectories: true)  // mimic move, Finder
        try fm.createDirectory(at: runs.appendingPathComponent("Party/bard"), withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(calls, 1, "once for a burst of changes, in a project")

        try fm.moveItem(at: mini, to: runs.appendingPathComponent("dwarf-cleric"))  // renamed in Finder
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(calls, 2, "in the minis folder itself")
        withExtendedLifetime(watch) {}
    }
}
