import XCTest
@testable import MimicCore

/// Shell completions (#131): made from the usage text, so a command or option added there can't
/// be left out of them. Read here straight from the text, not through the scripts' own reading of it.
final class CompletionsTests: XCTestCase {
    private func matches(_ pattern: String, group: Int = 1) -> Set<String> {
        let re = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let text = Usage.text as NSString
        return Set(re.matches(in: Usage.text, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: group)) })
    }

    func testEveryCommandAndOptionInTheUsageIsCompleted() {
        let commands = matches(#"^\s+mimic ([a-z][a-z-]*)"#)
        let options = matches(#"(--[a-z][a-z-]*)"#)
        XCTAssertTrue(commands.isSuperset(of: ["make", "import", "stop", "queue", "project", "completions"]), "\(commands)")
        XCTAssertTrue(options.isSuperset(of: ["--height", "--json", "--wait", "--trash-minis", "--version"]), "\(options)")
        for shell in Completions.Shell.allCases {
            let script = Completions.script(shell)
            for c in commands { XCTAssertTrue(script.contains(c), "\(shell) leaves out \(c)") }
            for o in options {
                // fish names a long option without its dashes: -l height.
                let spelled = shell == .fish ? "-l \(o.dropFirst(2))" : o
                XCTAssertTrue(script.contains(spelled), "\(shell) leaves out \(o)")
            }
        }
    }

    func testWhatEachWordTakes() {
        let commands = Completions.parse().commands
        func command(_ name: String) -> Completions.Command? { commands.first { $0.name == name } }
        func option(_ c: String, _ o: String) -> Completions.Value? { command(c)?.options.first { $0.name == o }?.value }
        XCTAssertEqual(command("resize")?.argument, .mini)
        XCTAssertEqual(command("import")?.argument, .file)
        XCTAssertNil(command("make")?.argument, "a new mini's name is new")
        XCTAssertNil(command("project create")?.argument, "so is a new project's")
        XCTAssertEqual(command("project rename")?.argument, .project)
        XCTAssertEqual(command("queue remove")?.argument, .mini)
        XCTAssertEqual(command("queue")?.subcommands, ["remove", "move", "pause", "resume"])
        XCTAssertEqual(command("completions")?.argument, .choice(["zsh", "bash", "fish"]))
        XCTAssertEqual(option("resize", "--base-shape"), .choice(["round", "square", "hex"]))
        XCTAssertEqual(option("resize", "--project"), .project)
        XCTAssertEqual(option("make", "--image"), .file)
        for side in ["--back", "--left", "--right"] { XCTAssertEqual(option("make", side), .file, side) }
        XCTAssertEqual(option("make", "--project"), .project, "from the note under the commands")
        XCTAssertEqual(option("make", "--no-base"), .flag)
        XCTAssertEqual(option("make", "--height"), .text)
        XCTAssertEqual(option("make", "--wait"), .flag)
        XCTAssertEqual(option("queue move", "--to"), .choice(["front", "end"]))
        XCTAssertEqual(option("rename", "--to"), .text)
        XCTAssertEqual(option("make", "--model"), .choice(EngineDownload.catalogue.map(\.id)))
        for c in ["list", "projects", "queue", "models", "info"] { XCTAssertEqual(option(c, "--json"), .flag, c) }
        XCTAssertNil(option("make", "--json"), "only the listings print JSON")
        XCTAssertEqual(Completions.parse().top, ["--version", "--help"])
    }

    /// Mini and project names come from Mimic as you type, never from when the script was made.
    func testNamesAreAskedForAsYouType() {
        for shell in Completions.Shell.allCases {
            let script = Completions.script(shell)
            XCTAssertTrue(script.contains("mimic _names"), "\(shell)")
            XCTAssertTrue(script.contains("minis") && script.contains("projects"), "\(shell)")
        }
    }
}
