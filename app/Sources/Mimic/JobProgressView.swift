import AppKit
import MimicCore
import SwiftUI
import TipKit

/// The job's popover under its toolbar item: three steps, a bar, the time so far, the queue,
/// and what to do when it ends. It never covers the window; a click outside closes it.
struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var retryProblem: String?
    /// The raw error behind retryProblem, for the tooltip only.
    @State private var retryDetail: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let steps: [(JobStep, String)] = [(.picture, "Getting the picture ready"), (.shape, "Building the 3D shape (the long part)"),
                                             (.print, "Making the print-ready file")]

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
        let who = model.displayName(s)
        let estimate = model.estimate(s)
        return VStack(alignment: .leading, spacing: 14) {
            title(s, who: who).font(.title3.bold())
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.steps.filter { s.kind == .generate || $0.0 == .print }, id: \.0) { n, label in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StepMark(state: state(of: n, in: s), number: n.rawValue)
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
                // The gallery's own record of where it is, not a search of the minis folder every second.
                JobPicture(status: s, folder: model.minis.first { $0.name == s.name }?.folder ?? Gallery.folder(model.install.runs, s.name)
                           ?? model.install.runs.appendingPathComponent(s.name))
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
                    } else if s.outcome == .failed {
                        if JobProgress.drawThingsCaused(s) {
                            Button("Open Setup") { model.jobPopover = false; SettingsTab.drawThings.select(); openSettings() }
                        }
                        Button("Try Again") { tryAgain(s.name) }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.requiredProblem != nil || model.waiting(s.name) != nil || model.isImported(s.name))
                            .help(model.isImported(s.name) ? RequestError.imported(s.name).description : "")
                    } else if s.outcome == .pictureReady {
                        checkButtons(s.name)
                    }
                }
            }
        }
    }

    /// For a make that stopped once its picture was made (#156): draw it again, or carry on.
    @ViewBuilder private func checkButtons(_ name: String) -> some View {
        let off = model.requiredProblem != nil || model.waiting(name) != nil || model.current?.name == name
        Button("Try Again") { redraw(name) }
            .disabled(off)
            .help("Draws the picture again with a new variation number")
        Button("Build Shape") { buildShape(name) }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(off)
            .help("Makes the 3D shape from this picture")
    }

    /// Another Mimic (the dev app, or `mimic` in Terminal) is running the job: shown, not controlled.
    private func elsewhere(_ s: JobStatus, now: Date) -> some View {
        let estimate = model.estimate(s)
        return VStack(alignment: .leading, spacing: 10) {
            Label("\(model.doing(s)) \(model.displayName(s))", systemImage: Self.symbol(s.kind))
                .font(.title3.bold())
            Text("Another Mimic is doing this one (another copy of the app, or Terminal): stop it there. Step \(s.step.rawValue) of 3 · \(JobProgress.about(estimate.left(s, now: now))) left.")
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
                    Image(systemName: s.outcome.symbol).foregroundStyle(s.outcome.color)
                    Text(s.succeeded ? "\(model.displayName(s)) is ready" : s.canceled ? "Stopped \(model.displayName(s))"
                         : s.outcome == .pictureReady ? "Check the picture of \(model.displayName(s))"
                         : "\(model.displayName(s)) didn't finish")
                    Spacer()
                    if s.outcome == .pictureReady {
                        Button("Show Picture") { model.jobPopover = false; model.go(to: s.name) }
                    } else if s.outcome == .failed {
                        Button("Try Again") { tryAgain(s.name) }
                            .disabled(model.requiredProblem != nil || model.waiting(s.name) != nil || model.isImported(s.name))
                            .help(model.isImported(s.name) ? RequestError.imported(s.name).description : s.problem ?? "")
                    }
                }
            }
        }
    }

    @ViewBuilder private func note(_ s: JobStatus, estimate: Estimate, now: Date) -> some View {
        Group {
            switch s.outcome {
            case .running:
                Text(JobProgress.note(s, estimate: estimate, now: now))
                    .foregroundStyle(JobProgress.pace(s, estimate: estimate, now: now) == .usual ? Color.secondary : .orange)
                    // The time so far rolls from one second to the next.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .default, value: Int(now.timeIntervalSince(s.started)))
            case .stopped:
                Text(s.stopSays).foregroundStyle(.secondary)
            case .finished:
                ForEach(s.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if s.fragile {
                    Label(PrepReport.footprintNote, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            case .pictureReady:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check it before the 3D shape is built. Try Again draws it again.")
                        .foregroundStyle(.secondary)
                    if let why = retryProblem { Text(why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            case .failed:
                VStack(alignment: .leading, spacing: 4) {
                    let headline = JobProgress.failedHeadline(s, imported: model.isImported(s.name))
                    Text(headline)
                    // Not said twice when the reason is the headline.
                    if let why = retryProblem ?? model.requiredProblem ?? s.problem, why != headline {
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

    private func buildShape(_ name: String) {
        retryProblem = nil
        do { try model.buildShape(name) } catch { retryProblem = model.plainWords(error); retryDetail = "\(error)" }
    }

    private func redraw(_ name: String) {
        retryProblem = nil
        do { try model.redrawPicture(name) } catch { retryProblem = model.plainWords(error); retryDetail = "\(error)" }
    }

    @ViewBuilder private func title(_ s: JobStatus, who: String) -> some View {
        switch s.outcome {
        case .running:
            Label("\(model.doing(s)) \(who)", systemImage: Self.symbol(s.kind))
        case .stopped:
            Label("Stopped \(model.doing(s).lowercased()) \(who)", systemImage: "stop.circle")
        case .finished:
            Label { Text("\(who) is ready") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .pictureReady:
            Label { Text("The picture of \(who) is ready") } icon: { Image(systemName: s.outcome.symbol).foregroundStyle(s.outcome.color) }
        case .failed:
            Label { Text("Something went wrong while \(s.step.during)").fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    /// Making or resizing, as the menus show them.
    static func symbol(_ kind: JobKind) -> String { kind == .prep ? "arrow.up.left.and.arrow.down.right" : "cube" }

    private func state(of n: JobStep, in s: JobStatus) -> StepMark.State {
        switch s.outcome {
        case .running: n < s.step ? .done : n == s.step ? .active : .pending
        case .finished: .done
        case .pictureReady: n == .picture ? .done : .pending
        case .stopped: .pending
        case .failed: n < s.step ? .done : n == s.step ? .failed : .pending
        }
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
            // Not on the first, which can't move up; its room is kept so the ✕ buttons line up.
            Button { model.moveInQueue(entry.name, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .opacity(index == 0 ? 0 : 1)
                .accessibilityHidden(index == 0)
                .help(index == 0 ? "" : "Make this one sooner. Drag it, or right-click, to move it further")
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
struct JobQuestions: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(model.job.map(stopTitle) ?? "", isPresented: $model.confirmingStop) {
                Button("Cancel", role: .cancel) {}
                Button("Stop", role: .destructive) { model.stop() }
            } message: {
                Text((model.job?.stopAsks ?? "") + (model.queue.isEmpty ? "" : " The queue carries on with the next one."))
            }
            .confirmationDialog(model.unqueueing.map { "Take “\(model.displayName($0.name))” out of the queue?" } ?? "",
                                isPresented: unqueueing, presenting: model.unqueueing) { e in
                Button(e.job == .prep && !model.importing(e.name) ? "Don't Resize" : "Take Out", role: .destructive) { model.removeFromQueue(e.name) }
                Button("Cancel", role: .cancel) {}
            } message: { e in
                Text(e.takeOutSays(importing: model.importing(e.name)))
            }
    }

    private var unqueueing: Binding<Bool> {
        Binding(get: { model.unqueueing != nil }, set: { if !$0 { model.unqueueing = nil } })
    }

    private func stopTitle(_ s: JobStatus) -> String {
        "Stop \(model.doing(s).lowercased()) “\(model.displayName(s))”?"
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
    /// The picture shown and its file's time, once there is one.
    @State private var shown: Shown?
    struct Shown: Equatable { let url: URL, version: Date }

    var body: some View {
        let building = status.running && status.kind == .generate && status.step == .shape
        let failed = status.outcome == .failed
        let shape = RoundedRectangle(cornerRadius: 12)
        Thumbnail(url: shown?.url, version: shown?.version ?? .distantPast)
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
            // Looked for every second, as the popover's clock goes, so the picture appears the
            // moment step 1 writes it; off the main thread, not while the popover is drawn (#340).
            .task(id: "\(folder.path) \(status.name) \(status.kind == .prep || status.succeeded)") {
                let (folder, name, resized) = (folder, status.name, status.kind == .prep || status.succeeded)
                while !Task.isCancelled {
                    let found = await Task.detached { Self.find(folder, name, resized: resized) }.value
                    if found != shown { shown = found }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    /// The finished front view once resized, else the picture; nil while neither is there.
    private nonisolated static func find(_ folder: URL, _ name: String, resized: Bool) -> Shown? {
        let front = folder.appendingPathComponent("\(name)_front.png")
        let file = resized && FileManager.default.fileExists(atPath: front.path) ? front : folder.appendingPathComponent("source.png")
        return ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date).map { Shown(url: file, version: $0) }
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
                                Image(systemName: s.outcome.symbol)
                                    .foregroundStyle(s.outcome.color)
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
        let who = model.displayName(s)
        let waiting = model.queue.isEmpty ? "" : " · \(model.queue.count) waiting" + (model.paused ? ", paused" : "")
        switch s.outcome {
        case .running: return "\(model.doing(s)) \(who) · \(JobProgress.clock(now.timeIntervalSince(s.started)))\(waiting)"
        case .stopped: return "Stopped \(who)\(waiting)"
        case .finished: return "\(who) is ready" + waiting
        case .pictureReady: return "Check the picture of \(who)" + waiting
        case .failed: return "\(who) didn't finish" + waiting
        }
    }
}

/// How an ended job is marked beside its name: in the toolbar, and in the jobs that ended
/// while the next one went on.
private extension JobOutcome {
    var symbol: String {
        switch self {
        case .finished: "checkmark.circle.fill"
        case .pictureReady: "photo.circle.fill"
        case .stopped: "stop.circle"
        case .running, .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .finished: .green
        case .pictureReady: .accentColor
        case .stopped: .secondary
        case .running, .failed: .orange
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
