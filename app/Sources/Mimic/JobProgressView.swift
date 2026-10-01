import AppKit
import MimicCore
import SwiftUI
import TipKit
import UserNotifications

/// The job's popover under its toolbar item: three steps, a bar, the time so far, the queue,
/// and what to do when it ends. It never covers the window; a click outside closes it.
struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var retryProblem: String?
    /// The raw error behind retryProblem, for the tooltip only.
    @State private var retryDetail: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let steps = [(1, "Getting the picture ready"), (2, "Building the 3D shape (the long part)"),
                        (3, "Making the print-ready file")]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                if let note = model.queuedNote {
                    Label(note.text, systemImage: "tray.and.arrow.down.fill")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // This Mimic's job while it runs (or ended, when nothing else is running); else
                // what another Mimic is running.
                if let s = model.job, s.running || model.elsewhere == nil {
                    content(s, now: context.date)
                } else if let other = model.elsewhere {
                    elsewhere(other, now: context.date)
                }
                if !model.queue.isEmpty { QueueList(now: context.date) }
                if !model.ended.isEmpty { endedList }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { model.popoverShowing() }
        .onChange(of: model.running) { model.popoverShowing() }
    }

    private func content(_ s: JobStatus, now: Date) -> some View {
        let who = model.displayName(s.name)
        let estimate = model.estimate(s)
        return VStack(alignment: .leading, spacing: 14) {
            title(s, who: who).font(.title3.bold())
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.steps.filter { s.kind == .generate || $0.0 == 3 }, id: \.0) { n, label in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StepMark(state: state(of: n, in: s), number: n)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label).foregroundStyle(state(of: n, in: s) == .pending ? .secondary : .primary)
                                // Its time left, or how long it should take.
                                if let left = JobProgress.stepNote(n, of: s, estimate: estimate, now: now) {
                                    Text(left.capitalizedFirst).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                JobPicture(status: s, folder: Gallery.folder(model.install.runs, s.name) ?? model.install.runs.appendingPathComponent(s.name))
            }
            ProgressView(value: JobProgress.fraction(s, estimate: estimate, now: now))
                .progressViewStyle(GlidingBar(working: s.running))
            note(s, estimate: estimate, now: now)
            HStack {
                Spacer()
                if s.running {
                    // Asked over the window, not in here: a question inside a popover that closes
                    // on the next click is easy to lose.
                    Button("Stop…") { model.jobPopover = false; model.confirmingStop = true }
                } else {
                    if s.succeeded, let stl = model.minis.first(where: { $0.name == s.name })?.stl {
                        // A finished mini isn't selected by itself; this goes to it.
                        if model.selection != [s.name] {
                            Button("Show Mini") { model.jobPopover = false; model.go(to: s.name) }
                        }
                        Button("Open in \(model.slicerName)") { model.jobPopover = false; model.openInSlicer(stl) }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                    } else if !s.succeeded && !s.canceled {
                        if JobProgress.drawThingsCaused(s) {
                            Button("Open Setup") { model.jobPopover = false; SettingsTab.drawThings.select(); openSettings() }
                        }
                        Button("Try Again") { tryAgain(s.name) }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.cantStart != nil || model.waiting(s.name) != nil || model.isImported(s.name))
                            .help(model.isImported(s.name) ? RequestError.imported(s.name).description : "")
                    }
                }
            }
        }
    }

    /// Another Mimic (the dev app, or `mimic` in Terminal) is running the job: shown, not controlled.
    private func elsewhere(_ s: JobStatus, now: Date) -> some View {
        let estimate = model.estimate(s)
        return VStack(alignment: .leading, spacing: 10) {
            Label("\(model.doing(s)) \(model.displayName(s.name))", systemImage: Self.symbol(s.kind))
                .font(.title3.bold())
            Text("Another Mimic is doing this one (another copy of the app, or Terminal): stop it there. Step \(s.step) of 3 · \(JobProgress.about(estimate.left(s, now: now))) left.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: JobProgress.fraction(s, estimate: estimate, now: now)).progressViewStyle(GlidingBar(working: true))
        }
    }

    /// Jobs that ended while the next one went on: how each went, and Try Again for a failure.
    private var endedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Finished while you waited").font(.headline)
            ForEach(Array(model.ended.enumerated().reversed()), id: \.offset) { _, s in
                HStack {
                    Image(systemName: s.succeeded ? "checkmark.circle.fill" : s.canceled ? "stop.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.succeeded ? .green : s.canceled ? .secondary : .orange)
                    Text(s.succeeded ? "\(model.displayName(s.name)) is ready" : s.canceled ? "Stopped \(model.displayName(s.name))"
                                                                            : "\(model.displayName(s.name)) didn't finish")
                    Spacer()
                    if !s.succeeded && !s.canceled {
                        Button("Try Again") { tryAgain(s.name) }
                            .disabled(model.cantStart != nil || model.waiting(s.name) != nil || model.isImported(s.name))
                            .help(model.isImported(s.name) ? RequestError.imported(s.name).description : s.problem ?? "")
                    }
                }
            }
        }
    }

    @ViewBuilder private func note(_ s: JobStatus, estimate: Estimate, now: Date) -> some View {
        Group {
            if s.running {
                Text(JobProgress.note(s, estimate: estimate, now: now))
                    .foregroundStyle(JobProgress.pace(s, estimate: estimate, now: now) == .usual ? Color.secondary : .orange)
                    // The time so far rolls from one second to the next.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .default, value: Int(now.timeIntervalSince(s.started)))
            } else if s.canceled {
                Text(s.kind == .prep && !s.importing ? "It keeps its previous size." : "Nothing was kept. It's in the Trash if you want the pieces.")
                    .foregroundStyle(.secondary)
            } else if s.succeeded {
                ForEach(s.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if s.fragile {
                    Label("Your mini is ready, but some thin parts may be fragile. Check it in your slicer before printing.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(JobProgress.drawThingsCaused(s) ? "Draw Things didn't answer. Check the setup steps, then try again."
                         : model.isImported(s.name) ? "Try Resize This Mini with other sizes, or check the model in the app it came from."
                         : "Try again, or use a clearer, full-body picture.")
                    if let why = retryProblem ?? model.cantStart ?? s.problem {
                        Text(why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .help(retryProblem != nil ? retryDetail ?? "" : "")
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tryAgain(_ name: String) {
        retryProblem = nil
        do { try model.retry(name) } catch { retryProblem = model.plainWords(error); retryDetail = "\(error)" }
    }

    @ViewBuilder private func title(_ s: JobStatus, who: String) -> some View {
        if s.running {
            Label("\(model.doing(s)) \(who)", systemImage: Self.symbol(s.kind))
        } else if s.canceled {
            Label("Stopped \(model.doing(s).lowercased()) \(who)", systemImage: "stop.circle")
        } else if s.succeeded {
            Label { Text("\(who) is ready") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        } else {
            Label { Text("Something went wrong while \(JobRunner.label(s.step).lowercased())").fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    /// Making or resizing, as the menus show them.
    static func symbol(_ kind: JobKind) -> String { kind == .prep ? "arrow.up.left.and.arrow.down.right" : "cube" }

    private func state(of n: Int, in s: JobStatus) -> StepMark.State {
        if s.running { return n < s.step ? .done : n == s.step ? .active : .pending }
        if s.succeeded { return .done }
        if s.canceled { return .pending }
        return n < s.step ? .done : n == s.step ? .failed : .pending
    }
}

/// The jobs waiting their turn: each with how long it takes and when it should be ready, and
/// ways to move it or take it out.
private struct QueueList: View {
    @Environment(AppModel.self) private var model
    let now: Date
    /// The row a dragged mini is over.
    @State private var target: String?

    var body: some View {
        let rows = model.queueTimes(now: now)
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Waiting (\(rows.count))").font(.headline)
                Spacer()
                if model.hold == nil, let last = rows.last {
                    Text("All done in \(JobProgress.about(last.ready))").foregroundStyle(.secondary).monospacedDigit()
                }
                Button(model.pauseCommand) { model.togglePause() }
                    .help(model.paused ? "Carry on with the queue" : "Let the mini being made finish, and start no more until you resume")
            }
            if let hold = model.hold {
                Label(hold.sentence, systemImage: hold == .paused ? "pause.circle" : "battery.50percent")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.element.entry.name) { i, row in
                        QueueRow(entry: row.entry, estimate: row.estimate, ready: row.ready, index: i, count: rows.count, target: $target)
                    }
                }
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: rows.count <= 3)
        }
    }
}

/// One waiting mini (#72). Drag it onto another to take that one's place; right-click to move
/// it to the front, up, down or to the end, or to take it out. One mini at a time, and never
/// the one being made: the front is the next to start.
private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let entry: QueueEntry
    let estimate: Estimate
    let ready: TimeInterval
    let index: Int
    let count: Int
    @Binding var target: String?

    var body: some View {
        let who = model.displayName(entry.name)
        HStack(spacing: 8) {
            Image(systemName: JobProgressView.symbol(entry.job)).foregroundStyle(.secondary)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(who)
                Text(times)
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button { model.moveInQueue(entry.name, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Make this one sooner. Drag it, or right-click, to move it further")
                .accessibilityLabel("Move \(who) up")
            Button { unqueue() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Take it out of the queue")
                .accessibilityLabel("Take \(who) out of the queue")
        }
        .contentShape(Rectangle())
        .background(target == entry.name ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .draggable(entry.name)
        .dropDestination(for: String.self) { names, _ in
            guard let name = names.first, name != entry.name, model.waiting(name) != nil else { return false }
            model.moveInQueue(name, to: .position(index + 1))
            return true
        } isTargeted: { over in
            if over { target = entry.name } else if target == entry.name { target = nil }
        }
        .contextMenu {
            Button("Move to Front") { model.moveInQueue(entry.name, to: .front) }.disabled(index == 0)
            Button("Move Up") { model.moveInQueue(entry.name, by: -1) }.disabled(index == 0)
            Button("Move Down") { model.moveInQueue(entry.name, by: 1) }.disabled(index == count - 1)
            Button("Move to End") { model.moveInQueue(entry.name, to: .end) }.disabled(index == count - 1)
            Divider()
            Button("Take Out of Queue…") { unqueue() }
        }
    }

    private func unqueue() { model.jobPopover = false; model.unqueueing = entry }

    /// "Make · takes about 9 minutes · ready in about 20 minutes", without when it's ready while
    /// the queue is held.
    private var times: String {
        let takes = "\(entry.job == .generate ? "Make" : model.importing(entry.name) ? "Import" : "Resize") · takes \(JobProgress.about(estimate.total))"
        return model.hold == nil ? "\(takes) · ready in \(JobProgress.about(ready))" : takes
    }
}

/// The questions the job's popover asks, over the window: Stop, and taking a job out of the queue.
private struct JobQuestions: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(model.job.map(stopTitle) ?? "", isPresented: $model.confirmingStop) {
                Button("Cancel", role: .cancel) {}
                Button("Stop", role: .destructive) { model.stop() }
            } message: {
                Text((model.job.map { $0.kind == .prep && !$0.importing } == true ? "It keeps its previous size." : "What's been made so far will be thrown away.")
                     + (model.queue.isEmpty ? "" : " The queue carries on with the next one."))
            }
            .confirmationDialog(model.unqueueing.map { "Take “\(model.displayName($0.name))” out of the queue?" } ?? "",
                                isPresented: unqueueing, presenting: model.unqueueing) { e in
                Button(e.job == .prep && !model.importing(e.name) ? "Don't Resize" : "Take Out", role: .destructive) { model.removeFromQueue(e.name) }
                Button("Cancel", role: .cancel) {}
            } message: { e in
                Text(e.job == .generate ? "It hasn't been made yet, so its picture and settings go to the Trash, where you can get them back."
                     : model.importing(e.name) ? "It hasn't been made yet, so it goes to the Trash, where you can get it back."
                     : "It keeps its current size.")
            }
    }

    private var unqueueing: Binding<Bool> {
        Binding(get: { model.unqueueing != nil }, set: { if !$0 { model.unqueueing = nil } })
    }

    private func stopTitle(_ s: JobStatus) -> String {
        "Stop \(model.doing(s).lowercased()) “\(model.displayName(s.name))”?"
    }
}

/// A step's number, breathing while it's the one being worked on; it turns into a checkmark
/// (or a cross) in place, and a checkmark gives a small bounce.
private struct StepMark: View {
    enum State { case pending, active, done, failed }
    let state: State
    let number: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .symbolEffect(.breathe, options: .repeat(.periodic(delay: 1.5)), isActive: state == .active && !reduceMotion)
            .symbolEffect(.bounce, value: state == .done && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .default, value: state)
            .frame(width: 18, height: 18)
    }

    private var symbol: String {
        switch state {
        case .pending: "\(number).circle"
        case .active: "\(number).circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .pending: .secondary
        case .active: .accentColor
        case .done: .green
        case .failed: .red
        }
    }
}

/// The character, as soon as there's a picture of it: the picture while it's being made, with
/// a slow scan across it while the 3D shape is built; the finished mini's front view once it's
/// ready. Success gets a checkmark badge; failure a warning badge and a small shake, no fuss.
private struct JobPicture: View {
    let status: JobStatus
    /// runs/<name>, where the job writes source.png and the renders.
    let folder: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read every second with the popover's clock: cheap (a stat), and the picture appears the
        // moment step 1 writes it.
        let file = shownFile
        let version = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        let building = status.running && status.kind == .generate && status.step == 2
        let failed = !status.running && !status.succeeded && !status.canceled
        let shape = RoundedRectangle(cornerRadius: 12)
        Thumbnail(url: version == nil ? nil : file, version: version ?? .distantPast)
            .frame(width: 84, height: 84)
            .clipShape(shape)
            .background(Color.primary.opacity(0.05), in: shape)  // as the mini's own previews: renders have no background
            // A soft glow while the long step runs, and the scan. The glow is a still blur: a
            // shadow around the moving scan redrew with it every frame.
            .background { shape.fill(Color.accentColor.opacity(building ? 0.45 : 0)).blur(radius: 8) }
            .overlay { if building && !reduceMotion { LightSweep(vertical: true, crossing: 2.6, rest: 1.6, strength: 0.35).clipShape(shape) } }
            .overlay(alignment: .bottomTrailing) {
                if status.succeeded {
                    badge("checkmark.circle.fill", .green)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                } else if failed {
                    badge("exclamationmark.triangle.fill", .orange).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .bouncy, value: status.running)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: building)
            .keyframeAnimator(initialValue: 0.0, trigger: failed && !reduceMotion) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    for x in [-5.0, 4, -2.5, 1, 0] { CubicKeyframe(x, duration: 0.09) }
                }
            }
            .accessibilityHidden(true)
    }

    private var shownFile: URL {
        let front = folder.appendingPathComponent("\(status.name)_front.png")
        let resized = status.kind == .prep || status.succeeded
        return resized && FileManager.default.fileExists(atPath: front.path) ? front : folder.appendingPathComponent("source.png")
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .background(Circle().fill(.background).padding(2))
            .offset(x: 6, y: 6)
    }
}

/// The job in the toolbar: its progress while it runs, how it went once it ends (until seen).
/// Clicking it opens the job's popover.
struct JobToolbarItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        @Bindable var model = model
        // One button either way, so its popover stays open when Resume starts the next mini.
        if model.toolbarJob != nil || model.queueHeld != nil {
            Button { model.jobPopover.toggle() } label: {
                if let s = model.toolbarJob {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            if s.running {
                                ProgressRing(fraction: JobProgress.fraction(s, estimate: model.estimate(s), now: context.date))
                                    .transition(.opacity)
                            } else {
                                Image(systemName: s.succeeded ? "checkmark.circle.fill" : s.canceled ? "stop.circle" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(s.succeeded ? .green : s.canceled ? .secondary : .orange)
                                    .transition(reduceMotion || !s.succeeded ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                            }
                            Text(label(s, now: context.date)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .animation(reduceMotion ? nil : .bouncy, value: s.running)
                        .animation(reduceMotion ? nil : .default, value: Int(context.date.timeIntervalSince(s.started)))
                    }
                } else if let hold = model.queueHeld {
                    // Nothing running and the queue held: what it waits for, and Resume in the popover.
                    Label("\(hold == .paused ? "Paused" : "On battery") · \(model.queue.count) waiting",
                          systemImage: hold == .paused ? "pause.circle" : "battery.50percent")
                        .labelStyle(.titleAndIcon)
                }
            }
            .help(tip)
            .background { DetachablePopover(isPresented: $model.jobPopover) { JobProgressView().environment(model) } }
        }
    }

    private var tip: String {
        if let s = model.toolbarJob { return s.running ? "Show progress, the queue and Stop" : "Show how it went" }
        return model.queueHeld?.sentence ?? ""
    }

    private func label(_ s: JobStatus, now: Date) -> String {
        let who = model.displayName(s.name)
        let waiting = model.queue.isEmpty ? "" : " · \(model.queue.count) waiting" + (model.paused ? ", paused" : "")
        if s.running { return "\(model.doing(s)) \(who) · \(JobProgress.clock(now.timeIntervalSince(s.started)))\(waiting)" }
        if s.canceled { return "Stopped \(who)\(waiting)" }
        return (s.succeeded ? "\(who) is ready" : "\(who) didn't finish") + waiting
    }
}

/// `.popover(isPresented:)` that can be dragged off into a small window of its own, to keep an eye
/// on a job: SwiftUI's popover can't detach, AppKit's can. Opens under the view it's behind,
/// closes on a click outside, Esc, or switching apps (unless detached), and sets `isPresented`
/// back to false when it closes, as SwiftUI's does. A new hosting controller each time, so its
/// content appears afresh.
private struct DetachablePopover<Content: View>: NSViewRepresentable {
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

/// The toolbar's progress: a ring around a dot that pulses now and then to say it's still
/// working. It shows for the whole job, so it rests between pulses.
private struct ProgressRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle().trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeat(.periodic(delay: 1.5)), isActive: !reduceMotion)
        }
        .frame(width: 14, height: 14)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

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

/// What the main window adds around the gallery: the sheets and questions, and the toolbar's
/// New Mini button and job progress. Kept here so the window's own layout stays about the gallery.
struct MainWindowChrome: ViewModifier {
    // Named, not written inline: inside the long modifier chain below it made one expression
    // too slow for CI's Swift to type-check.
    private var showsProblem: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    /// The window's size under its toolbar: New Mini and Resize grow up to it.
    @State private var room = CGSize(width: 960, height: 640)

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
            .toolbar {
                // What's going on, then New Mini apart from it; the mini's page adds its own group.
                ToolbarItem(placement: .primaryAction) { UpdateToolbarItem() }
                ToolbarItem(placement: .primaryAction) { JobToolbarItem() }
                ToolbarItem(placement: .primaryAction) { NeedsSetupItem() }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button { model.sheet = .make } label: { Label("New Mini", systemImage: "plus") }
                        .help("Make a new mini (⌘N)")
                        .disabled(!model.setup.installed)
                        .tourCallout(.newMini)
                }
            }
            // [room]: read here, so a new window size reaches the sheets (read only inside the
            // closure, the sheet kept getting the starting 640).
            .sheet(item: $model.sheet) { [room] sheet in
                switch sheet {
                case .make: MakeView(room: room)
                case .makeAgain(let mini): MakeView(room: room, form: MakeForm.again(mini, install: model.install, card: .remembered()), again: mini)
                case .resize(let mini): ResizeView(mini: mini, room: room)
                case .resizeAll(let p):
                    let group = model.minis.filter { $0.project == p }
                    if let first = group.first(where: \.hasModel) { ResizeView(mini: first, group: group, project: p, room: room) }
                case .resizeSeveral(let group):
                    if let first = group.first(where: \.hasModel) { ResizeView(mini: first, group: group, room: room) }
                case .rename(let mini): RenameSheet(mini: mini)
                case .newProject(let group): ProjectNameSheet(renaming: nil, moving: group)
                case .renameProject(let p): ProjectNameSheet(renaming: p)
                case .copies(let group): CopiesSheet(minis: group)
                case .duplicate(let mini): DuplicateSheet(mini: mini)
                case .importModel(let file): ImportSheet(file: file, room: room)
                }
            }
            .modifier(JobQuestions())
            .confirmationDialog(model.trashing.count == 1 ? "Move “\(model.trashing[0].displayName)” to the Trash?" : "Move \(model.trashing.count) minis to the Trash?",
                                isPresented: Binding(get: { !model.trashing.isEmpty }, set: { if !$0 { model.trashing = [] } }),
                                presenting: model.trashing) { group in
                Button("Move to Trash", role: .destructive) { model.trash(group) }
                Button("Cancel", role: .cancel) {}
            } message: { group in
                Text(group.count == 1 ? "It leaves the queue. You can put it back from the Trash, but not in the queue."
                     : "Those waiting leave the queue. You can put them back from the Trash, but not in the queue.")
            }
            // Move to Trash registers its Undo with the window's undo manager (Edit → Undo).
            .onChange(of: undoManager, initial: true) { model.undo = undoManager }
            // Kept by the model, so a notification or the Dock menu can bring the window back
            // after it's been closed while a mini is made.
            .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
            // Deleting a project never trashes its minis silently: keeping them is the default.
            .confirmationDialog("Delete the project “\(model.deletingProject ?? "")”?",
                                isPresented: Binding(get: { model.deletingProject != nil }, set: { if !$0 { model.deletingProject = nil } }),
                                presenting: model.deletingProject) { project in
                let count = model.minis.filter { $0.project == project }.count
                if count == 0 {
                    Button("Delete Project") { model.deleteProject(project, keepMinis: true) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Keep Minis") { model.deleteProject(project, keepMinis: true) }.keyboardShortcut(.defaultAction)
                    Button("Delete All", role: .destructive) { model.deleteProject(project, keepMinis: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { project in
                let count = model.minis.filter { $0.project == project }.count
                let minis = count == 1 ? "its mini" : "its \(count) minis"
                Text(count == 0 ? "The empty project goes to the Trash."
                     : "Keep Minis moves \(minis) to Unsorted. Delete All moves \(minis) to the Trash with the project. You can put anything back from the Trash.")
            }
            .alert(model.problem ?? "", isPresented: showsProblem) {
                Button("OK") {}
            }
            // Minis made from the terminal appear when you come back to the app.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reload()
            }
    }
}

/// Settings lives in the Mimic menu (⌘,); the toolbar only says so when something needs you,
/// and goes straight to what's missing.
private struct NeedsSetupItem: View {
    private var health: Health { .shared }

    var body: some View {
        if let why = health.blocking {
            OpenSettingsButton(tab: .general) {
                Label {
                    Text("Needs Setup")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .labelStyle(.titleAndIcon)
            }
            .help(why)
        }
    }
}

/// Quitting during a job asks first; a confirmed quit stops the job before leaving and puts it
/// back at the front of the queue, to carry on from its last finished step at the next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = model.job, s.running else { return .terminateNow }
        let jobs = model.jobs
        // Logging out, restarting or shutting down: a question would hold the Mac up, and
        // nothing is lost by not asking.
        if !Self.systemQuit {
            let alert = NSAlert()
            let who = model.displayName(s.name)
            alert.messageText = s.kind == .prep ? "Mimic is still resizing “\(who)”" : "Mimic is still making “\(who)”"
            let waiting = model.queue.count
            alert.informativeText = "Quitting stops it for now. The next time you open Mimic, it carries on from the last step it finished."
                + (waiting == 0 ? "" : " The \(waiting == 1 ? "mini" : "\(waiting) minis") waiting in the queue will follow.")
            // First, so Esc presses it.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        jobs.keepGoing = { _ in false }  // the queue waits for the next launch
        jobs.cancel(keepingWork: true)
        // The job's own thread tidies up (the queue, the lock) once its programs have ended;
        // waiting here on the main thread would block the updates it sends.
        DispatchQueue.global().async {
            jobs.waitUntilDone()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// The quit is the Mac logging out, restarting or shutting down, as its quit event says.
    private static var systemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(why.enumCodeValue)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Tips.startUp()
        // Before launching ends, so a click on a notification that opened Mimic reaches it.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            MiniNotification.register(slicer: model.slicerName)
        }
    }

    /// Closing the window quits Mimic, except while a mini is being made or waiting, or setup is
    /// downloading: that carries on, with its progress on the Dock icon, and the Dock icon (or
    /// the Window menu) brings the window back. ⌘Q still asks first.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.setup.running && !model.running && model.queue.isEmpty
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.becameActive() }

    /// New Mini, and the job's progress and Stop while one runs, from the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let free = model.sheet == nil
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if model.setup.installed && free { add("New Mini…", #selector(newMini)) }
        if model.toolbarJob != nil && free { add("Show Progress", #selector(showProgress)) }
        if let title = model.stopCommand, free { add(title, #selector(stopJob)) }
        return menu
    }

    // Mimic and its window come to the front first (the window may have been closed while a
    // mini is made), then act: the job's popover keeps track of whether it is.
    @objc private func newMini() { model.showWindow(); Task { model.sheet = .make } }
    @objc private func showProgress() { model.showWindow(); Task { model.jobPopover = true } }
    @objc private func stopJob() { model.showWindow(); Task { model.confirmingStop = true } }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A finished mini's notification: clicked, Open in the slicer, or Try Again. The center may
    /// call from any thread, so only plain strings cross to the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let name = response.notification.request.content.userInfo[MiniNotification.mini] as? String else { return }
        await MainActor.run { model.notificationAnswered(action, mini: name) }
    }

    /// Shown even with Mimic in front: it only posts one then when its window is closed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}
