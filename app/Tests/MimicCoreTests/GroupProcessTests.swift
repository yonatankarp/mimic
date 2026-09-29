import XCTest
@testable import MimicCore

/// Ported from tests/test_cancel.py: Stop has to end a job and everything it started.
final class GroupProcessTests: XCTestCase {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// A parent that starts a long-running child, like make_mini.sh starting the 3D engine.
    /// Returns the process and the child's pid.
    private func startParentWithChild(newSession: Bool) throws -> (GroupProcess, pid_t) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("child.pid").path
        let p = try GroupProcess(executable: "/bin/bash",
                                 arguments: ["-c", "sleep 60 & echo $! > \(pidFile); wait"],
                                 environment: ["PATH": "/usr/bin:/bin"], newSession: newSession)
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let child = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (p, child)
            }
            usleep(50_000)
        }
        XCTFail("the child never started")
        return (p, 0)
    }

    func testStopEndsTheJobAndEverythingItStarted() throws {
        let (p, child) = try startParentWithChild(newSession: true)
        p.terminateGroup()
        XCTAssertEqual(p.wait(), -15, "the job should end by SIGTERM")
        usleep(200_000)
        XCTAssertFalse(alive(child), "Stop left the job's child program running")
    }

    /// Why the session matters: without one, the same stop reaches nobody and the child lives
    /// on. If this ever starts passing, the test above no longer proves anything.
    func testWithoutItsOwnSessionTheChildWouldSurvive() throws {
        let (p, child) = try startParentWithChild(newSession: false)
        p.terminateGroup(grace: 0.5)
        XCTAssertTrue(alive(child), "expected the child to survive when the job shares a group")
        kill(child, SIGKILL)
        kill(p.pid, SIGKILL)
        p.wait()
    }

    func testExitCodes() throws {
        XCTAssertEqual(try GroupProcess(executable: "/usr/bin/true", arguments: [], environment: [:]).wait(), 0)
        XCTAssertEqual(try GroupProcess(executable: "/usr/bin/false", arguments: [], environment: [:]).wait(), 1)
    }

    func testOutputGoesToTheLog() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log").path
        try GroupProcess(executable: "/bin/echo", arguments: ["hello from the job"], environment: [:], log: log).wait()
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "hello from the job\n")
    }
}
