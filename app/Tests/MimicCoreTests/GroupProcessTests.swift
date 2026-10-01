import XCTest
@testable import MimicCore

/// Ported from tests/test_cancel.py: Stop has to end a job and everything it started.
final class GroupProcessTests: XCTestCase {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// A parent that starts a long-running child, like the 3D engine running under its wrapper.
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

    /// A job gets only its own input and output, not every file the app has open: one holding
    /// a Settings check's pipe kept that check from finishing until the job ended.
    func testAJobDoesNotGetTheAppsOpenFiles() throws {
        let fd = open("/etc/hosts", O_RDONLY)
        XCTAssertGreaterThan(fd, 2)
        defer { close(fd) }
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "the file must be one a child would inherit")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log").path
        try GroupProcess(executable: "/bin/sh",
                         arguments: ["-c", "if (: <&\(fd)) 2>/dev/null; then echo open; else echo closed; fi"],
                         environment: [:], log: log).wait()
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "closed\n")
    }

    /// The 3D engine's output still reaches the pipe it's given.
    func testOutputGoesToThePipe() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        let p = try GroupProcess(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2"], environment: [:],
                                 output: (fds[1], fds[0]), newSession: false)
        close(fds[1])
        let output = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false).readDataToEndOfFile()
        XCTAssertEqual(p.wait(), 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "out\nerr\n")
    }
}
