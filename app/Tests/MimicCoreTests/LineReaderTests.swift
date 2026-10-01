import Darwin
import XCTest
@testable import MimicCore

/// The 3D engine's output, read line by line as it comes.
final class LineReaderTests: XCTestCase {
    /// The lines `written` reads as, and whether every one was read; `stopAt` stops at that line.
    private func read(_ written: String, stopAt: String? = nil) -> (lines: [String], all: Bool) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        let bytes = Array(written.utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }, bytes.count)
        close(fds[1])
        var lines: [String] = []
        let all = LineReader(fd: fds[0]).lines { line in
            lines.append(line)
            return line != stopAt
        }
        return (lines, all)
    }

    func testANewlineOrACarriageReturnEndsALine() {
        let r = read("loading\n[flow] 10%\r[flow] 20%\r\ndone\n")
        XCTAssertEqual(r.lines, ["loading", "[flow] 10%", "[flow] 20%", "done"], "empty lines skipped")
        XCTAssertTrue(r.all)
    }

    func testTheLastLineNeedsNoEnd() {
        XCTAssertEqual(read("one\ntwo").lines, ["one", "two"])
        XCTAssertEqual(read("").lines, [])
    }

    func testStoppingReadsNothingMore() {
        let r = read("one\nstop\nthree\n", stopAt: "stop")
        XCTAssertEqual(r.lines, ["one", "stop"])
        XCTAssertFalse(r.all)
    }

    /// Only a line that ended can stop it: what's left when the pipe closes was the last word.
    func testTheUnendedLastLineCantStopIt() {
        let r = read("one\nstop", stopAt: "stop")
        XCTAssertEqual(r.lines, ["one", "stop"])
        XCTAssertTrue(r.all)
    }
}
