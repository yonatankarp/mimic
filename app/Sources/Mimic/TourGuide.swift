import AppKit
import MimicCore
import Observation
import SwiftUI
import TipKit

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
        if step == .newMini {
            // The next stops are inside New Mini. The callout closes first and New Mini opens a
            // moment later: both at once left an empty glass panel of the callout on screen.
            visible = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                model.sheet = .make
            }
        }
        if step == .make, model.sheet == .make { model.sheet = nil; usingSample = false }
        after.map { go(to: $0, wait: step == .newMini ? 0.8 : step == .make ? 0.5 : 0.2) } ?? leave()
    }

    /// Cancel (or Esc, which presses it) in New Mini leaves the tour from its stops there.
    func newMiniCancelled() { if step?.inNewMini == true { leave() } }

    func useSample(_ model: AppModel) {
        sample = Self.samplePicture
        usingSample = true
        next(model)
    }

    /// New Mini asks once when it opens.
    func takeSample() -> URL? { defer { sample = nil }; return sample }

    /// New Mini opened or closed by hand: from New Mini's stop, pressing + goes inside. Inside,
    /// Make Mini closes it and carries on in the main window once the job's popover is closed
    /// (it opens a moment later, so the wait is longer than that). Cancel leaves the tour first.
    func sheetChanged(_ model: AppModel) {
        guard let step else { return }
        if step == .newMini, model.sheet == .make { go(to: .make, wait: 0.5) }
        if step.inNewMini, model.sheet != .make {
            usingSample = false
            Tour.next(after: .make, onScreen: onScreen).map { go(to: $0, wait: 1) } ?? leave()
        }
    }

    /// The popover was closed by something other than the tour (clicks outside don't close it;
    /// Esc inside it may). That leaves the tour, unless what closed it moved the tour on
    /// (pressing + or Make Mini), which is checked a moment later so the sheet change is seen first.
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

    /// The same, for a control that can be disabled: a disabled control disables everything
    /// attached to it, the callout's Next and Skip included (step 5 got stuck on a greyed-out
    /// Make Mini). The callout hangs on a clear layer behind it instead, outside `.disabled`.
    func tourCallout(_ stop: TourStep, arrow: Edge = .bottom) -> some View {
        background { Color.clear.tourStop(stop, arrow: arrow) }
    }
}

private struct TourStopModifier: ViewModifier {
    let stop: TourStep
    let arrow: Edge
    @Environment(AppModel.self) private var model
    private var guide: TourGuide { .shared }

    /// Only while its window is the one in front: New Mini's stops with New Mini open, the
    /// main window's with no sheet over it and the job's popover closed.
    private var shown: Bool {
        guide.step == stop && guide.visible && (stop.inNewMini ? model.sheet == .make : model.sheet == nil && !model.jobPopover)
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
            // A row of its own: beside Skip and Next it was squeezed to "Use the S…".
            if offersSample {
                Button { guide.useSample(model) } label: { Label("Use the Sample", systemImage: "photo").frame(maxWidth: .infinity) }
                    .help("Opens New Mini with a sample picture of a dwarf, ready to make.")
            }
            HStack {
                Text(guide.position).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("Step \(guide.position)")
                Spacer()
                Button("Skip Tour") { guide.leave() }
                // Learning by doing waits here for Make Mini: the tour carries on once it's pressed.
                if !(guide.step == .make && guide.usingSample) {
                    Button(last ? "Done" : "Next") { guide.next(model) }.keyboardShortcut(.defaultAction)
                }
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
        stop == .newMini && TourGuide.samplePicture != nil && !model.nameInUse(Rules.folderName(TourGuide.sampleName))
    }

    private var title: String { Self.title(stop) }

    static func title(_ stop: TourStep) -> String {
        switch stop {
        case .welcome: "Welcome to Mimic"
        case .newMini: "Start a new mini"
        case .make: "Make it"
        case .mini: "A finished mini"
        case .settings: "Settings"
        }
    }

    // One or two sentences each. The rest is in tips shown the first time it's used.
    private var text: String {
        switch stop {
        case .welcome:
            "Mimic turns a picture or a few words into a mini you can 3D print, right here on your Mac. Here's a quick look around."
        case .newMini:
            "Press + (or ⌘N) to start one from a picture or a description. To learn by doing, use the sample dwarf."
        case .make:
            guide.usingSample
                ? "Press Make Mini to make your dwarf; the time it takes is beside the button. Its progress opens in the toolbar, and the tour carries on when you close it."
                : "Make Mini starts it; the time it takes on this Mac is beside the button. Its progress is in the toolbar, and you can keep using Mimic meanwhile."
        case .mini:
            "Drag it to turn it around, and Open in \(model.slicerName) sends it to your slicer. The panel on the right has its size, previews and print tips."
        case .settings:
            "Settings (⌘,) is where you choose your slicer and set up Draw Things. If something needs you, Needs Setup appears in the toolbar."
        }
    }

}

/// Starts the tour once, puts the centred cards (the welcome, Settings) over the main window,
/// and follows New Mini opening and closing.
struct TourHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var guide: TourGuide { .shared }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let card {
                    TourCallout(stop: card)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .shadow(radius: reduceMotion ? 0 : 12)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: card)
            .onChange(of: model.sheet) { guide.sheetChanged(model) }
            // Esc leaves the tour when the main window, not a popover, has the keyboard (a card
            // has its own Esc).
            .background {
                if guide.step?.centred == false && model.sheet == nil {
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

    /// The centred stop being shown: not over a sheet or the job's popover, as the other stops.
    private var card: TourStep? {
        guard let step = guide.step, step.centred, guide.visible, model.sheet == nil, !model.jobPopover else { return nil }
        return step
    }
}

// MARK: Tips

// What the tour leaves out, shown in place the first time it's used. TipKit keeps each one
// dismissed once closed; Reset Mimic brings them back (`Tips.startUp`).

/// On the list, once there's a finished mini and one has been picked.
struct GalleryTip: Tip {
    var title: Text { Text("More in the list") }
    var message: Text? { Text("Right-click a mini for more, press Space to preview it, or drag it into a project (⇧⌘N makes one).") }
    var image: Image? { Image(systemName: "sidebar.left") }
}

/// On the nozzle, the first time New Mini or Resize opens outside the tour.
struct SizeTip: Tip {
    var title: Text { Text("Size and nozzle") }
    var message: Text? { Text("Game scale matches the other minis on your table; Best print goes for detail. Not sure of your nozzle? It's most likely 0.4 mm.") }
    var image: Image? { Image(systemName: "ruler") }
}

extension Tips {
    /// The UserDefaults key Reset Mimic sets: the tips' store can only be cleared before
    /// `configure`, so it's cleared at the next launch.
    static let resetKey = "resetTips"

    /// At launch. Only an app bundle has somewhere to keep them, as with notifications.
    @MainActor static func startUp() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if UserDefaults.standard.bool(forKey: resetKey) {
            try? resetDatastore()
            UserDefaults.standard.removeObject(forKey: resetKey)
        }
        try? configure()
    }

    /// `tip`, or none while the tour is showing: a tip's popover and the tour's would clash.
    @MainActor static func unlessTouring(_ tip: any Tip) -> (any Tip)? { TourGuide.shared.step == nil ? tip : nil }
}
