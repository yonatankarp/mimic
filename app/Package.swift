// swift-tools-version: 6.2
// Mimic's native Mac app. `swift build` / `swift test` here; `./bundle.sh` assembles the .app.
import PackageDescription

let package = Package(
    name: "Mimic",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "mimic", targets: ["Mimic"]),
        .library(name: "MimicCore", targets: ["MimicCore"]),
    ],
    dependencies: [
        // Updates. Its framework goes in the app's Contents/Frameworks (bundle.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.10.0")),
    ],
    targets: [
        // Everything that isn't UI: jobs, the pipeline, Draw Things, checks, the gallery on disk.
        // Optimised in debug builds too: print prep's loops run ~30x slower unoptimised, which
        // made its tests take minutes.
        .target(name: "MimicCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug)), slowCode]),
        // The app and the `mimic` command-line tool: one binary, same code.
        .executableTarget(name: "Mimic", dependencies: ["MimicCore", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Resources/sample-dwarf.png")], swiftSettings: [slowCode],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MimicCoreTests", dependencies: ["MimicCore"]),
    ]
)

/// Warns about any expression that takes long to type-check. CI builds with an older Swift that
/// gives up on some expressions this Mac's compiler handles in time (three failed CI runs), so a
/// slow one is flagged here, before it's pushed.
var slowCode: SwiftSetting { .unsafeFlags(["-Xfrontend", "-warn-long-expression-type-checking=300"]) }
