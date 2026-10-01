import AppKit
import SwiftUI

/// `.popover(isPresented:)` that can be dragged off into a small window of its own, to keep an eye
/// on a job: SwiftUI's popover can't detach, AppKit's can. Opens under the view it's behind,
/// closes on a click outside, Esc, or switching apps (unless detached), and sets `isPresented`
/// back to false when it closes, as SwiftUI's does. A new hosting controller each time, so its
/// content appears afresh.
struct DetachablePopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.closed = { isPresented = false }
        guard isPresented != (c.popover != nil) else { return }
        guard isPresented else {
            if c.popover?.isShown == true { c.popover?.close() } else { c.popover = nil }
            return
        }
        // The click outside that closed it also presses the toolbar button, which asks to open it
        // again: SwiftUI's popover ignores that, and so does this.
        if Date().timeIntervalSince(c.lastClosed) < 0.3 {
            DispatchQueue.main.async { isPresented = false }
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = c
        let host = NSHostingController(rootView: content())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        c.popover = popover
        // After this update; or, when the window is still opening (Show Progress from the Dock
        // with the window closed), once the anchor is in it.
        DispatchQueue.main.async { c.show(from: anchor) }
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: Coordinator) { coordinator.popover?.close() }

    final class Anchor: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.show(from: self)
        }
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var closed: () -> Void = {}
        var lastClosed = Date.distantPast

        func show(from anchor: NSView) {
            guard let popover, !popover.isShown, anchor.window != nil else { return }
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }

        func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
        func popoverDidClose(_ notification: Notification) {
            popover = nil
            lastClosed = Date()
            closed()
        }
    }
}
