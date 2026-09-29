// swift-tools-version: 6.0
// Mimic's native Mac app. `swift build` / `swift test` here; `./bundle.sh` assembles the .app.
import PackageDescription

let package = Package(
    name: "Mimic",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "mimic", targets: ["Mimic"]),
        .library(name: "MimicCore", targets: ["MimicCore"]),
    ],
    targets: [
        // Everything that isn't UI: jobs, the pipeline, Draw Things, checks, the gallery on disk.
        // Optimised in debug builds too: print prep's loops run ~30x slower unoptimised, which
        // made its tests take minutes.
        .target(name: "MimicCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // The app and the `mimic` command-line tool: one binary, same code.
        .executableTarget(name: "Mimic", dependencies: ["MimicCore"]),
        .testTarget(name: "MimicCoreTests", dependencies: ["MimicCore"]),
    ]
)
