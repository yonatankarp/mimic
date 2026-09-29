import AppKit
import MimicCore
import SwiftUI

/// One binary, two faces: `mimic <command> …` runs in the terminal, plain `mimic` (or a
/// double-click) opens the app. Both use the same MimicCore.
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // Finder may pass "-psn_…"; anything starting with "-" means "open the app".
        if let first = args.first, !first.hasPrefix("-") || ["--probe-notifications", "--version"].contains(first) {
            exit(CLI.run(args))
        }
        MimicApp.main()
    }
}
