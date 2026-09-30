import AppKit
import MimicCore
import SwiftUI

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
        let who = Mini.displayName(s.name)
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
                            .disabled(model.cantStart != nil || model.waiting(s.name) != nil)
                    }
                }
            }
        }
    }

    /// Another Mimic (the dev app, or `mimic` in Terminal) is running the job: shown, not controlled.
    private func elsewhere(_ s: JobStatus, now: Date) -> some View {
        let estimate = model.estimate(s)
        return VStack(alignment: .leading, spacing: 10) {
            Label("\(s.kind == .prep ? "Resizing" : "Making") \(Mini.displayName(s.name))", systemImage: Self.symbol(s.kind))
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
                    Text(s.succeeded ? "\(Mini.displayName(s.name)) is ready" : s.canceled ? "Stopped \(Mini.displayName(s.name))"
                                                                            : "\(Mini.displayName(s.name)) didn't finish")
                    Spacer()
                    if !s.succeeded && !s.canceled {
                        Button("Try Again") { tryAgain(s.name) }
                            .disabled(model.cantStart != nil || model.waiting(s.name) != nil)
                            .help(s.problem ?? "")
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
                Text(s.kind == .prep ? "It keeps its previous size." : "Nothing was kept. It's in the Trash if you want the pieces.")
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
        let prep = s.kind == .prep
        if s.running {
            Label(prep ? "Resizing \(who)" : "Making \(who)", systemImage: Self.symbol(s.kind))
        } else if s.canceled {
            Label(prep ? "Stopped resizing \(who)" : "Stopped making \(who)", systemImage: "stop.circle")
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
/// ways to move it up or take it out.
private struct QueueList: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        let rows = model.queueTimes(now: now)
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Waiting (\(rows.count))").font(.headline)
                Spacer()
                if let last = rows.last {
                    Text("All done in \(JobProgress.about(last.ready))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.element.entry.name) { i, row in
                        HStack(spacing: 8) {
                            Image(systemName: JobProgressView.symbol(row.entry.job)).foregroundStyle(.secondary)
                                .frame(width: 18).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Mini.displayName(row.entry.name))
                                Text("\(row.entry.job == .prep ? "Resize" : "Make") · takes \(JobProgress.about(row.estimate.total)) · ready in \(JobProgress.about(row.ready))")
                                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            Button { model.moveInQueue(row.entry.name, by: -1) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless)
                                .disabled(i == 0)
                                .help("Make this one sooner")
                                .accessibilityLabel("Move \(Mini.displayName(row.entry.name)) up")
                            Button { model.jobPopover = false; model.unqueueing = row.entry } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Take it out of the queue")
                                .accessibilityLabel("Take \(Mini.displayName(row.entry.name)) out of the queue")
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: rows.count <= 3)
        }
    }
}

/// The questions the job's popover asks, over the window: Stop, and taking a job out of the queue.
private struct JobQuestions: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(model.job.map(stopTitle) ?? "", isPresented: $model.confirmingStop) {
                Button("Keep Going", role: .cancel) {}
                Button("Stop", role: .destructive) { model.stop() }
            } message: {
                Text((model.job?.kind == .prep ? "It keeps its previous size." : "What's been made so far will be thrown away.")
                     + (model.queue.isEmpty ? "" : " The queue carries on with the next one."))
            }
            .confirmationDialog(model.unqueueing.map { "Take “\(Mini.displayName($0.name))” out of the queue?" } ?? "",
                                isPresented: unqueueing, presenting: model.unqueueing) { e in
                Button(e.job == .prep ? "Don't Resize" : "Take Out and Move to Trash", role: .destructive) { model.removeFromQueue(e.name) }
                Button("Keep It Waiting", role: .cancel) {}
            } message: { e in
                Text(e.job == .prep ? "It keeps its current size." : "It hasn't been made yet, so its picture and settings go to the Trash, where you can get them back.")
            }
    }

    private var unqueueing: Binding<Bool> {
        Binding(get: { model.unqueueing != nil }, set: { if !$0 { model.unqueueing = nil } })
    }

    private func stopTitle(_ s: JobStatus) -> String {
        s.kind == .prep ? "Stop resizing “\(Mini.displayName(s.name))”?" : "Stop making “\(Mini.displayName(s.name))”?"
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
            .glassEffect(.regular, in: .rect(cornerRadius: 12))  // as the mini's own previews: renders have no background
            // A soft glow while the long step runs, and the scan. Both sit outside the glass and
            // the glow is a still blur: glass or a shadow around the moving scan redrew with it
            // every frame.
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
        if let s = model.job.flatMap({ model.jobShown || $0.running ? $0 : nil }) ?? model.elsewhere {
            Button { model.jobPopover.toggle() } label: {
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
            }
            .help(s.running ? "Show progress, the queue and Stop" : "Show how it went")
            .popover(isPresented: $model.jobPopover, arrowEdge: .bottom) { JobProgressView().environment(model) }
        }
    }

    private func label(_ s: JobStatus, now: Date) -> String {
        let who = Mini.displayName(s.name)
        let waiting = model.queue.isEmpty ? "" : " · \(model.queue.count) waiting"
        if s.running { return "\(s.kind == .prep ? "Resizing" : "Making") \(who) · \(JobProgress.clock(now.timeIntervalSince(s.started)))\(waiting)" }
        if s.canceled { return "Stopped \(who)\(waiting)" }
        return (s.succeeded ? "\(who) is ready" : "\(who) didn't finish") + waiting
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
            tile.badgeLabel = nil
            model.updateBadge()  // the number waiting stays
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
    /// The window's size under its toolbar: New Mini and Resize grow up to it.
    @State private var room = CGSize(width: 960, height: 640)

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { room = $0 }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { UpdateToolbarItem() }
                ToolbarItem(placement: .primaryAction) { JobToolbarItem() }
                ToolbarItem(placement: .primaryAction) {
                    OpenSettingsButton(tab: Health.shared.needsAttention ? .general : nil) {
                        Label("Settings", systemImage: Health.shared.needsAttention ? "exclamationmark.triangle.fill" : "gearshape")
                    }
                    .foregroundStyle(Health.shared.needsAttention ? .orange : .primary)
                    .help(Health.shared.blocking ?? "Settings (⌘,)")
                    .tourStop(.settings)
                }
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
                case .resize(let mini): ResizeView(mini: mini, room: room)
                case .resizeAll(let p):
                    if let first = model.minis.first(where: { $0.project == p && $0.hasModel }) { ResizeView(mini: first, project: p, room: room) }
                case .rename(let mini): RenameSheet(mini: mini)
                case .newProject(let mini): ProjectNameSheet(renaming: nil, moving: mini)
                case .renameProject(let p): ProjectNameSheet(renaming: p)
                }
            }
            .modifier(JobQuestions())
            .confirmationDialog("Move “\(model.trashing?.displayName ?? "")” to the Trash?",
                                isPresented: Binding(get: { model.trashing != nil }, set: { if !$0 { model.trashing = nil } }),
                                presenting: model.trashing) { mini in
                Button("Move to Trash", role: .destructive) { model.trash(mini) }
                Button("Keep It", role: .cancel) {}
            } message: { _ in
                Text("You can put it back from the Trash if you change your mind.")
            }
            // Deleting a project never trashes its minis silently: keeping them is the default.
            .confirmationDialog("Delete the project “\(model.deletingProject ?? "")”?",
                                isPresented: Binding(get: { model.deletingProject != nil }, set: { if !$0 { model.deletingProject = nil } }),
                                presenting: model.deletingProject) { project in
                let count = model.minis.filter { $0.project == project }.count
                if count == 0 {
                    Button("Delete Project") { model.deleteProject(project, keepMinis: true) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Delete Project, Keep Its Minis") { model.deleteProject(project, keepMinis: true) }.keyboardShortcut(.defaultAction)
                    Button("Move Its Minis to the Trash Too", role: .destructive) { model.deleteProject(project, keepMinis: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { project in
                let count = model.minis.filter { $0.project == project }.count
                Text(count == 0 ? "The empty project goes to the Trash."
                     : "Its \(count == 1 ? "mini moves" : "\(count) minis move") to Unsorted, unless you choose to move \(count == 1 ? "it" : "them") to the Trash too. You can put anything back from the Trash.")
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

/// Quitting during a job asks first, and a confirmed quit stops the job before leaving.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = model.job, s.running else { return .terminateNow }
        let jobs = model.jobs
        let alert = NSAlert()
        let who = Mini.displayName(s.name)
        alert.messageText = s.kind == .prep ? "Mimic is still resizing “\(who)”" : "Mimic is still making “\(who)”"
        let waiting = model.queue.count
        alert.informativeText = (s.kind == .prep ? "Quitting stops it, and it keeps its previous size."
                                                 : "Quitting stops it, and what's been made so far will be thrown away.")
            + (waiting == 0 ? "" : " The \(waiting == 1 ? "mini" : "\(waiting) minis") waiting in the queue will start the next time you open Mimic.")
        alert.addButton(withTitle: "Keep Going")
        alert.addButton(withTitle: "Stop and Quit").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        jobs.keepGoing = { _ in false }  // the queue waits for the next launch
        jobs.cancel()
        // The job's own thread tidies up (the Trash, the lock) once its programs have ended;
        // waiting here on the main thread would block the updates it sends.
        DispatchQueue.global().async {
            jobs.waitUntilDone()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Closing the window quits Mimic, except while setup is downloading: that carries on, and
    /// the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.setup.running }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil  // seen it
        model.updateBadge()  // the number waiting stays
    }
}
