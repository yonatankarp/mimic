import Darwin
import Foundation

/// Reads what a program writes into a pipe as lines, as they come: the 3D engine's output.
struct LineReader {
    /// The pipe's reading end. Not closed here.
    let fd: Int32

    /// Gives `line` each line until the pipe closes, or until `line` says to stop (false): then
    /// false, and nothing more is read. A line ends at a newline or a carriage return (progress
    /// bars redraw with \r); empty ones are skipped. What's left without an end when the pipe
    /// closes is given too, though it can't stop anything by then.
    func lines(_ line: (String) -> Bool) -> Bool {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let text = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                if text.isEmpty { continue }
                if !line(text) { return false }
            }
        }
        if !pending.isEmpty { _ = line(String(decoding: pending, as: UTF8.self)) }
        return true
    }
}
