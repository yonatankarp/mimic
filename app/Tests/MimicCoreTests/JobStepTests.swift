import XCTest
@testable import MimicCore

/// A job's steps and how it ended, as the progress window, notifications and `mimic make` read them.
final class JobStepTests: XCTestCase {
    func testTheStepsAreNumberedAndNamedInOrder() {
        XCTAssertEqual(JobStep.allCases.map(\.rawValue), [1, 2, 3])
        XCTAssertEqual(JobStep.allCases.map(\.label), ["Getting the picture ready", "Building the 3D shape", "Making the print-ready file"])
        XCTAssertTrue(JobStep.picture < .shape && JobStep.shape < .print)
        XCTAssertNil(JobStep(rawValue: 0))
        XCTAssertNil(JobStep(rawValue: 4))
    }

    /// job.json, which another Mimic reads, keeps the step as its number.
    func testTheRunningJobIsSharedWithItsStepAsANumber() throws {
        let shared = SharedJob(name: "dwarf", kind: .generate, step: .shape, started: Date(timeIntervalSince1970: 0),
                               stepStarted: Date(timeIntervalSince1970: 0), pid: 1, pidStart: 2, shown: nil)
        let json = try XCTUnwrap(String(data: JobQueue.encoder.encode(shared), encoding: .utf8))
        XCTAssertTrue(json.contains(#""step" : 2"#), json)
        XCTAssertEqual(try JobQueue.decoder.decode(SharedJob.self, from: Data(json.utf8)).step, .shape)
    }

    func testTheOutcomeFollowsRunningThenStoppedThenTheExitCode() {
        var s = JobStatus(name: "dwarf", kind: .generate, step: .shape, started: Date())
        XCTAssertEqual(s.outcome, .running)
        s.canceled = true
        XCTAssertEqual(s.outcome, .running, "still stopping")
        s.running = false
        s.exit = 0
        XCTAssertEqual(s.outcome, .stopped, "stopped, whatever its exit")
        s.canceled = false
        XCTAssertEqual(s.outcome, .finished)
        XCTAssertTrue(s.succeeded)
        s.exit = 1
        XCTAssertEqual(s.outcome, .failed)
        s.exit = nil
        XCTAssertEqual(s.outcome, .failed, "ended without an exit code")
        XCTAssertFalse(s.succeeded)
    }
}
