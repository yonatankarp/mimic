import AppKit
import MimicCore

/// A progress bar on the Dock icon while a job runs, so it can be followed from any app.
@MainActor
enum DockProgress {
    private static var task: Task<Void, Never>?

    static func follow(_ model: AppModel) {
        task?.cancel()
        task = Task { @MainActor in
            let tile = NSApp.dockTile, view = DockTileView()
            tile.contentView = view
            while !Task.isCancelled, let s = model.job, s.running {
                view.fraction = JobProgress.fraction(s, estimate: model.estimate(s))
                tile.display()
                // Every second, like the popover's clock: a 2-second step read as a stutter.
                try? await Task.sleep(for: .seconds(1))
            }
            tile.contentView = nil
            tile.display()
        }
    }
}

private final class DockTileView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let track = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.06, width: bounds.width * 0.8, height: bounds.height * 0.1)
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inset = track.insetBy(dx: 2, dy: 2)
        var fill = inset
        fill.size.width = max(inset.height, inset.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
