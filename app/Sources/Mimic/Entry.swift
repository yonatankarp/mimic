import AppKit
import MimicCore
import SwiftUI

/// One binary, two faces: `mimic <command> …` runs in the terminal, plain `mimic` (or a
/// double-click) opens the app. Both use the same MimicCore.
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // macOS may launch the app with its own "-" arguments ("-psn_…", "-NSDocumentRevisionsDebugMode"),
        // so any other "-" argument opens the app; these few are the command line's own.
        let commandLineFlags = ["--probe-notifications", "--version", "-v", "--help", "-h"]
        if let first = args.first, !first.hasPrefix("-") || commandLineFlags.contains(first) {
            exit(CLI.run(args))
        }
        MimicApp.main()
    }
}
