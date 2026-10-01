import AppKit
import Foundation

/// The slicers Mimic can hand a mini to, and which one the person picked.
public struct Slicer: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let app: URL

    /// Shown name and the bundle names each slicer ships under, ported from the web version.
    static let known: [(id: String, name: String, bundles: [String])] = [
        ("bambu", "Bambu Studio", ["BambuStudio.app", "Bambu Studio.app"]),
        ("orca", "OrcaSlicer", ["OrcaSlicer.app"]),
        ("prusa", "PrusaSlicer", ["PrusaSlicer.app", "Original Prusa Drivers/PrusaSlicer.app"]),
        ("cura", "UltiMaker Cura", ["UltiMaker Cura.app", "Ultimaker Cura.app", "Ultimaker-Cura.app"]),
        ("creality", "Creality Print", ["Creality Print.app", "CrealityPrint.app"]),
        ("elegoo", "ElegooSlicer", ["ElegooSlicer.app"]),
        ("anycubic", "Anycubic Slicer Next", ["AnycubicSlicerNext.app", "Anycubic Slicer Next.app"]),
        ("super", "SuperSlicer", ["SuperSlicer.app"]),
        ("ideamaker", "ideaMaker", ["ideaMaker.app"]),
        ("flashprint", "FlashPrint", ["FlashPrint 5.app", "FlashPrint.app"]),
        ("simplify", "Simplify3D", ["Simplify3D.app", "Simplify3D 5.app"]),
        ("lychee", "Lychee Slicer", ["Lychee Slicer.app", "LycheeSlicer.app"]),
        ("chitubox", "CHITUBOX", ["CHITUBOX Basic.app", "CHITUBOX.app"]),
    ]

    public static func appFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// Every known slicer present in an Applications folder, in the order above.
    public static func installed(in folders: [URL] = appFolders()) -> [Slicer] {
        known.compactMap { k in
            for d in folders {
                if let hit = k.bundles.map({ d.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    return Slicer(id: k.id, name: k.name, app: hit)
                }
            }
            return nil
        }
    }

    /// What the `slicer` default holds when the person picked the Mac's default app for 3D files.
    public static let macDefault = "default"

    /// The picked slicer (the `slicer` default), else the first installed, else nil, which means
    /// the Mac's default app for STL files. Picking that app explicitly also gives nil.
    public static func preferred(defaults: UserDefaults = .standard, in folders: [URL] = appFolders()) -> Slicer? {
        let picked = defaults.string(forKey: SettingsKey.slicer)
        if picked == macDefault { return nil }
        let all = installed(in: folders)
        return all.first { $0.id == picked } ?? all.first
    }

    /// Opens a print file in `slicer`, or in the Mac's default app for STL files when it's nil:
    /// the app's Open in, and `mimic open`. `done` hears back once macOS has answered.
    public static func open(_ file: URL, in slicer: Slicer?, done: (@Sendable (Error?) -> Void)? = nil) {
        if let slicer {
            NSWorkspace.shared.open([file], withApplicationAt: slicer.app, configuration: NSWorkspace.OpenConfiguration()) { _, error in done?(error) }
        } else {
            done?(NSWorkspace.shared.open(file) ? nil : CocoaError(.fileReadUnknown))
        }
    }
}
