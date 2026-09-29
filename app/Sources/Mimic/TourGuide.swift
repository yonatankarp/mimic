import AppKit
import MimicCore
import Observation
import SwiftUI

// The first-run tour: a welcome, then popovers on the real controls, one at a time. A popover
// sits beside the view it's attached to, so it never covers the control it points at, and it
// works in the toolbar and in the New Mini sheet, which live in windows of their own (anchor
// preferences can't reach either). On macOS 26 a popover is already Liquid Glass.

/// Where the tour is. One per app, like Health, so AppModel doesn't need to know about it.
@MainActor @Observable
final class TourGuide {
    static let shared = TourGuide()

    private(set) var step: TourStep?
    /// False for a moment between stops, so one popover closes before the next opens (both in
    /// one update can drop the second), and the window or sheet has settled first.
    private(set) var visible = false
    /// Main-window stops whose control is on screen right now; the others are skipped.
    private(set) var onScreen: Set<TourStep> = []
    /// The sample picture, handed to New Mini once when "Use the Sample" is pressed.
    private var sample: URL?
    /// "Use the Sample" was pressed and New Mini is still open with it.
    private(set) var usingSample = false

    /// The bundled sample picture, from the app's resource bundle (Contents/Resources in the
    /// app, beside the binary for `swift run`). nil if it's missing: the offer isn't made.
    /// Not Bundle.module, whose accessor stops the app when it can't find the bundle.
    static let samplePicture: URL? = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        .compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent("Mimic_Mimic.bundle")) } }
        .lazy.compactMap { $0.url(forResource: "sample-dwarf", withExtension: "png") }.first
    static let sampleName = "Sample Dwarf"

    func begin() {
        UserDefaults.standard.set(true, forKey: Tour.seenKey)
        go(to: .welcome)
    }

    func leave() { step = nil; visible = false; usingSample = false }

    func next(_ model: AppModel) {
        guard let step else { return }
        let after = Tour.next(after: step, onScreen: onScreen)
        if step == .newMini { model.sheet = .make }                    // the next stops are inside it
        if step == .make, model.sheet == .make { model.sheet = nil; usingSample = false }
        after.map { go(to: $0, wait: step == .newMini || step == .make ? 0.5 : 0.2) } ?? leave()
    }

    func useSample(_ model: AppModel) {
        sample = Self.samplePicture
        usingSample = true
        next(model)
    }

    /// New Mini asks once when it opens.
    func takeSample() -> URL? { defer { sample = nil }; return sample }

    /// New Mini opened or closed by hand: from New Mini's stop, pressing + goes inside. Inside,
    /// Make My Mini carries on in the main window once the progress is out of the way; Cancel
    /// (and Esc, which presses it) leaves the tour.
    func sheetChanged(_ model: AppModel) {
        guard let step else { return }
        if step == .newMini, model.sheet == .make { go(to: .start, wait: 0.5) }
        if step.inNewMini, model.sheet == nil { return leave() }
        if step.inNewMini, model.sheet != .make {
            usingSample = false
            Tour.next(after: .make, onScreen: onScreen).map { go(to: $0, wait: 0.5) } ?? leave()
        }
    }

    /// The popover was closed by something other than the tour (clicks outside don't close it;
    /// Esc inside it may). That leaves the tour, unless what closed it moved the tour on
    /// (pressing + or Make My Mini), which is checked a moment later so the sheet change is seen first.
    func dismissed(_ stop: TourStep) {
        guard step == stop, visible else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.15))
            if step == stop && visible { leave() }
        }
    }

    func appeared(_ stop: TourStep) { onScreen.insert(stop) }
    func disappeared(_ stop: TourStep) { onScreen.remove(stop) }

    /// "3 of 8", counting only the stops that will be shown.
    var position: String {
        let all = Tour.steps(onScreen: onScreen)
        guard let step, let i = all.firstIndex(of: step) else { return "" }
        return "\(i + 1) of \(all.count)"
    }

    private func go(to next: TourStep, wait: Double = 0.2) {
        visible = false
        step = next
        Task {
            try? await Task.sleep(for: .seconds(wait))
            guard step == next else { return }
            visible = true
            // VoiceOver doesn't notice a popover opening by itself.
            AccessibilityNotification.Announcement("Tour: \(TourCallout.title(next))").post()
        }
    }
}

extension View {
    /// Attaches the tour's callout for `stop` to this control.
    func tourStop(_ stop: TourStep, arrow: Edge = .bottom) -> some View { modifier(TourStopModifier(stop: stop, arrow: arrow)) }
}

private struct TourStopModifier: ViewModifier {
    let stop: TourStep
    let arrow: Edge
    @Environment(AppModel.self) private var model
    private var guide: TourGuide { .shared }

    /// Only while its window is the one in front: New Mini's stops with New Mini open, the
    /// main window's with no sheet over it.
    private var shown: Bool {
        guide.step == stop && guide.visible && (stop.inNewMini ? model.sheet == .make : model.sheet == nil)
    }

    func body(content: Content) -> some View {
        content
            .id(stop)  // so a scroll view can bring it into view (New Mini's form)
            .onAppear { guide.appeared(stop) }
            .onDisappear { guide.disappeared(stop) }
            .popover(isPresented: Binding(get: { shown }, set: { if !$0 { guide.dismissed(stop) } }),
                     arrowEdge: arrow) {
                // Stays up while you try the control it points at; Skip or Esc closes it.
                TourCallout(stop: stop).environment(model).interactiveDismissDisabled()
            }
    }
}

/// What one stop says.
struct TourCallout: View {
    let stop: TourStep
    @Environment(AppModel.self) private var model
    private var guide: TourGuide { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(guide.position).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("Step \(guide.position)")
                Spacer()
                Button("Skip Tour") { guide.leave() }
                if offersSample {
                    Button("Use the Sample 🧙") { guide.useSample(model) }
                        .help("Opens New Mini with a sample picture of a dwarf, ready to make.")
                }
                Button(last ? "Done" : "Next") { guide.next(model) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        // Esc leaves the tour, as a click outside does.
        .background { Button("") { guide.leave() }.keyboardShortcut(.cancelAction).hidden() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mimic tour")
    }

    private var last: Bool { Tour.next(after: stop, onScreen: guide.onScreen) == nil }

    /// Only on New Mini's stop, and not if a Sample Dwarf is already in the gallery.
    private var offersSample: Bool {
        stop == .newMini && TourGuide.samplePicture != nil
            && !FileManager.default.fileExists(atPath: model.install.runs.appendingPathComponent(Rules.slug(TourGuide.sampleName)).path)
    }

    private var title: String { Self.title(stop) }

    static func title(_ stop: TourStep) -> String {
        switch stop {
        case .welcome: "Welcome to Mimic 👋"
        case .newMini: "Start a new mini"
        case .start: "Two ways to start"
        case .size: "Size and nozzle"
        case .make: "Make it"
        case .mini: "Your finished mini"
        case .gallery: "All your minis"
        case .settings: "Settings"
        }
    }

    private var text: String {
        switch stop {
        case .welcome:
            "Mimic turns a picture or a few words into a miniature you can 3D print, right here on your Mac. Here's a quick look around."
        case .newMini:
            "Press + (or ⌘N) whenever you want to make one. Want to learn by doing? Use the sample and you'll have a dwarf of your own in a few minutes."
        case .start:
            "🖼️ From a picture: your own art or a photo, head to feet.\n✍️ Describe it: Draw Things draws the character from your words.\nWith Draw Things set up, Mimic first redraws either one as a grey sculpt, which the 3D engine understands best."
        case .size:
            "Game scale matches the other minis on your table; Best print goes for detail. Pick the nozzle your printer uses. Not sure? It's most likely 0.4 mm."
        case .make:
            "Make My Mini takes about 7–10 minutes. Press Run in Background to keep using your Mac: the toolbar and the Dock icon show how far along it is."
                + (guide.usingSample ? " Go ahead and press it when you're ready! 🎉" : "")
        case .mini:
            "Drag it to turn it around. Open in \(model.slicerName) sends it to your slicer to print, and the print tips below are for your nozzle."
        case .gallery:
            "Everything you make lands here. Right-click a mini for more, or press space to preview it."
        case .settings:
            "Checks that everything works, and where you choose your slicer and set up Draw Things. It turns orange if something needs you. Happy printing! 🎲"
        }
    }

}

/// Starts the tour once, puts the welcome over the main window, and follows New Mini opening
/// and closing.
struct TourHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var guide: TourGuide { .shared }

    func body(content: Content) -> some View {
        content
            .overlay {
                if guide.step == .welcome && guide.visible && model.sheet == nil {
                    TourCallout(stop: .welcome)
                        .glassCard(cornerRadius: 18)
                        .shadow(radius: reduceMotion ? 0 : 12)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: guide.step == .welcome && guide.visible)
            .onChange(of: model.sheet) { guide.sheetChanged(model) }
            // Esc leaves the tour when the main window, not the popover, has the keyboard.
            .background {
                if guide.step != nil && guide.step != .welcome && model.sheet == nil {
                    Button("") { guide.leave() }.keyboardShortcut(.cancelAction).hidden()
                }
            }
            // After setup's "done" and its crossfade to the gallery (or the first frame at launch).
            .task(id: model.setup.installed) {
                guard Tour.shouldStart(seen: UserDefaults.standard.bool(forKey: Tour.seenKey), installed: model.setup.installed)
                else { return }
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled && model.sheet == nil { guide.begin() }
            }
    }
}
