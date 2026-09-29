import AppKit
import MimicCore
import SwiftUI

/// Checking for a newer Mimic and installing it (`MimicCore/Updates.swift` does the work).
/// At launch and then at most once a day, and from Mimic → Check for Updates…; a new version
/// shows as a quiet toolbar button, never a window of its own.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable { case idle, checking, downloading(Double), installing, waitingForQueue, failed(String) }
    static let automaticKey = "checkForUpdates", lastCheckedKey = "updatesLastChecked"
    static let lastTriedKey = "updatesLastTried", skippedKey = "updatesSkipped"

    weak var model: AppModel?
    var available: Release?
    var phase = Phase.idle
    /// The answer to a check asked for from the menu, shown as an alert.
    var notice: String?
    /// A disk image downloaded for a Mimic that can't replace itself where it is.
    var dmg: URL?
    private let defaults = UserDefaults.standard
    let app = Bundle.main.bundleURL

    init() {
        // An update's old app, left beside this one if Mimic stopped before removing it.
        let parent = app.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(".Mimic-update-") {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    var lastChecked: Date? { defaults.object(forKey: Self.lastCheckedKey) as? Date }
    var automatic: Bool { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
    var busy: Bool {
        guard let model else { return true }
        return Updates.busy(running: model.current != nil, waiting: model.queue.count, settingUp: model.setup.running)
    }
    var canReplace: Bool { Updates.canReplace(app) }

    /// Every few seconds (the queue's watch): an automatic check when one is due, and an update
    /// that was waiting for the queue once it's done.
    func tick() {
        if phase == .waitingForQueue && !busy { install() }
        if automatic, phase == .idle, AppVersion(BuildInfo.version) != nil,
           Updates.due(lastTried: defaults.object(forKey: Self.lastTriedKey) as? Date) {
            Task { await check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        if phase == .checking { return }
        // Already found (and maybe downloading or waiting): asked again, it shows what's there.
        if manual, available != nil { model?.sheet = model?.sheet ?? .update; return }
        if !manual && phase != .idle { return }
        phase = .checking
        defaults.set(Date(), forKey: Self.lastTriedKey)
        defer { if phase == .checking { phase = .idle } }
        do {
            let latest = try await Updates.latest(version: BuildInfo.version)
            defaults.set(Date(), forKey: Self.lastCheckedKey)
            guard AppVersion(BuildInfo.version) != nil else {
                if manual { notice = "This is a development build (\(BuildInfo.version)), so it doesn't update itself. The latest release is Mimic \(latest.version?.description ?? latest.tag)." }
                return
            }
            available = Updates.offer(current: BuildInfo.version, latest: latest,
                                      skipped: manual ? nil : defaults.string(forKey: Self.skippedKey))
            if manual {
                if available != nil { model?.sheet = model?.sheet ?? .update }
                else { notice = "You have the latest Mimic (\(BuildInfo.version))." }
            }
        } catch {
            if manual { notice = (error as? UpdateError)?.description ?? UpdateError.offline.description }
        }
    }

    func skip() {
        if let v = available?.version { defaults.set(v.description, forKey: Self.skippedKey) }
        available = nil
        if model?.sheet == .update { model?.sheet = nil }
    }

    /// Downloads, checks and installs the update, then opens the new Mimic and quits. While a
    /// mini is being made or waiting, it waits for the queue instead (`tick`).
    func install() {
        guard let release = available, let version = release.version else { return }
        if busy { phase = .waitingForQueue; return }
        phase = .downloading(0)
        Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Mimic-update-\(version)")
                let file = try await Updates.download(release, into: folder, version: BuildInfo.version) { f in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(f) } }
                }
                guard canReplace else {
                    dmg = file
                    NSWorkspace.shared.open(file)
                    phase = .idle
                    return
                }
                // A mini may have been asked for during the download.
                if busy { phase = .waitingForQueue; return }
                phase = .installing
                let app = app
                let staged = try await Task.detached { try Updates.stage(dmg: file, beside: app, version: version) }.value
                if busy { try? FileManager.default.removeItem(at: staged); phase = .waitingForQueue; return }
                try Updates.swap(staged, into: app)
                try? FileManager.default.removeItem(at: folder)
                relaunch(removing: staged)
            } catch {
                phase = .failed((error as? UpdateError)?.description ?? UpdateError.failed(error.localizedDescription).description)
            }
        }
    }

    /// Removes the old app (now at `old`) and quits; a small shell waits for this Mimic to be
    /// gone, then opens the new one, so the two never run at once. Mimic's own development
    /// variables (`MIMIC_HOME`, `MIMIC_FAKE_HOME`…) go with it, so a test copy stays a test copy.
    private func relaunch(removing old: URL) {
        try? FileManager.default.removeItem(at: old)
        let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("MIMIC_") }.sorted { $0.key < $1.key }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $1 the pid, $2 the app, then "--env" "K=V" pairs for open.
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; app=\"$2\"; shift 2; exec /usr/bin/open -n \"$@\" \"$app\"",
                       "sh", String(getpid()), app.path] + env.flatMap { ["--env", "\($0.key)=\($0.value)"] }
        do { try p.run() } catch { phase = .failed("Mimic is updated. Open it again to use the new version."); return }
        // A window with a sheet up refuses to quit (seen: the old Mimic stayed open), so the
        // sheet goes first, and so do alerts and questions, which SwiftUI shows as sheets too.
        notice = nil
        model?.sheet = nil; model?.problem = nil; model?.trashing = nil; model?.deletingProject = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }
}

/// "Mimic 0.5.1 is available" in the toolbar: the quiet note that opens the update sheet.
struct UpdateToolbarItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let v = model.updates.available?.version?.description {
            Button { model.sheet = .update } label: {
                Label(model.updates.phase == .waitingForQueue ? "Mimic \(v) installs when the queue is done" : "Mimic \(v) is available",
                      systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("See what's new and update")
        }
    }
}

/// What's new in the update, and Update / Later / Skip This Version.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let updates = model.updates
        let version = updates.available?.version.map(\.description) ?? ""
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mimic \(version) is available").font(.title2.bold())
                    Text("You have \(BuildInfo.version). Your minis and settings stay as they are.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                ReleaseNotes(text: updates.available?.notes ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .glassCard()
            status(updates)
            HStack {
                Button("Skip This Version") { updates.skip() }
                    .disabled(working(updates))
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updates.phase == .installing)
                Button(primary(updates)) { updates.install() }
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working(updates) || updates.phase == .waitingForQueue)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }

    private func working(_ u: Updater) -> Bool {
        switch u.phase { case .downloading, .installing: true; default: false }
    }

    private func primary(_ u: Updater) -> String {
        if !u.canReplace { return "Download Disk Image" }
        return u.busy ? "Update When the Queue Is Done" : "Update"
    }

    @ViewBuilder private func status(_ u: Updater) -> some View {
        switch u.phase {
        case .downloading(let f):
            ProgressView(value: f) { Text("Downloading…") }
        case .installing:
            ProgressView { Text("Installing. Mimic opens again in a moment.") }
        case .waitingForQueue:
            Text("Mimic updates itself when the last mini in the queue is made. You can keep working.").foregroundStyle(.secondary)
        case .failed(let why):
            Text(why).foregroundStyle(.red)
        case .idle, .checking:
            if u.dmg != nil {
                Text("The disk image is open: drag Mimic onto Applications, replacing the old one, then open it again.").foregroundStyle(.secondary)
            } else if !u.canReplace {
                Text("Mimic can't replace itself where it is: your account isn't allowed to change that folder. Download the disk image and drag Mimic onto Applications instead.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A release's notes (its CHANGELOG section): "### " headings, "- " bullets and inline
/// Markdown, which is all the changelog uses.
struct ReleaseNotes: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(.headline).padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.inline(String(line.dropFirst(2))))
                    }
                } else {
                    Text(Self.inline(line))
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString { (try? AttributedString(markdown: s)) ?? AttributedString(s) }
}

/// Settings → Updates.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Updater.automaticKey) private var automatic = true

    var body: some View {
        let updates = model.updates
        Section {
            Toggle("Check for updates automatically", isOn: $automatic)
            LabeledContent {
                Button(updates.phase == .checking ? "Checking…" : "Check Now") { Task { await updates.check(manual: true) } }
                    .disabled(updates.phase != .idle && !isFailed(updates.phase))
            } label: {
                Text("Last checked")
                Text(updates.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Mimic asks GitHub for its latest release once a day. Only public release information is read; nothing about your Mac or your minis is sent.")
                .foregroundStyle(.secondary)
        }
    }

    private func isFailed(_ p: Updater.Phase) -> Bool { if case .failed = p { true } else { false } }
}
