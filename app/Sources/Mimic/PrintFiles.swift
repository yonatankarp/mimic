import AppKit
import MimicCore

/// A mini's print file out of Mimic: the slicer, Open Together, Export for Virtual Tabletop and
/// Finder.
extension AppModel {
    /// Opens a print file in the picked slicer, or the Mac's default app for STL files.
    func openInSlicer(_ stl: URL) { Slicer.open(stl, in: Slicer.preferred()) }

    var slicerName: String { Slicer.preferred()?.name ?? String(localized: "your slicer") }

    /// Open Together: one 3MF with every made mini of `group` laid out on the bed, each its own
    /// object named after it, opened in the slicer; with `copies`, that many of each. Named after
    /// the mini, or their project when they share one. Written off the main thread (a party's file
    /// is tens of MB), kept in the temporary folder: the slicer's own project is where it's saved.
    func openTogether(_ group: [Mini], copies: Int = 1) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Open Together")
        guard let together = ThreeMF.together(group, copies: copies, in: dir), !packing else { return }
        // One of one mini is its own print file.
        if together.parts.isEmpty { openInSlicer(together.url); return }
        packing = true
        Task {
            let failed: Error? = await Task.detached {
                do { try ThreeMF.pack(together.parts, copies: copies, to: together.url); return nil } catch { return error }
            }.value
            packing = false
            if let failed { problem = Problem(String(localized: "Couldn't put them in one print file"), plainWords(failed, else: String(localized: "Open them one at a time instead."))) }
            else { openInSlicer(together.url) }
        }
    }

    /// Export for Virtual Tabletop (#158) to `url`, picked in its save window (`MiniActionButton`):
    /// writes a low-poly .glb of the print file there, off the main thread (seconds), and shows
    /// it in Finder.
    func exportForTabletop(_ mini: Mini, to url: URL) {
        Task {
            let made: Result<String?, Error> = await Task.detached {
                Result { try Tabletop.export(mini, to: url).whyGrey }
            }.value
            switch made {
            case .failure(let failed): problem = Problem(String(localized: "Couldn't export \(mini.displayName)"), plainWords(failed, else: String(localized: "Try again, or save it somewhere else.")))
            case .success(let whyGrey):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                // The save window said it would be in its colours (#317).
                if let whyGrey { problem = Problem(String(localized: "Exported \(mini.displayName) in grey"), String(localized: "Not in its colours: \(whyGrey).")) }
            }
        }
    }

    /// The print file selected in Finder, or the folder when there's no print file yet.
    func showInFinder(_ minis: [Mini]) { NSWorkspace.shared.activateFileViewerSelecting(minis.map { $0.stl ?? $0.folder }) }
}
