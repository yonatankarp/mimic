import AppKit
import Sparkle
import SwiftUI

/// Updates, through Sparkle: it reads the appcast each release publishes, at most once a day
/// and from Mimic → Check for Updates…, and shows, checks and installs the update. Mimic adds a
/// quiet toolbar note instead of a window at launch, and never installs while a mini is being
/// made or waiting. Release builds only: the dev build never updates itself.
@MainActor @Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    weak var model: AppModel?
    /// A new version a scheduled check found and nobody has looked at yet: the toolbar note.
    var available: String?
    /// The version that installs once the queue is done.
    var waiting: String?
    var automatic = true { didSet { controller?.updater.automaticallyChecksForUpdates = automatic } }
    var lastChecked: Date?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Sparkle's go-ahead to install and relaunch, held while the queue is busy.
    @ObservationIgnored private var relaunch: (() -> Void)?

    override init() {
        super.init()
        guard Bundle.main.bundleIdentifier == "com.mimic.app" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        automatic = controller.updater.automaticallyChecksForUpdates
        lastChecked = controller.updater.lastUpdateCheckDate
    }

    var enabled: Bool { controller != nil }

    /// Sparkle's own window: what's new, and Install Update.
    func check() { controller?.updater.checkForUpdates() }

    /// Never while a mini is being made (here or in another Mimic), waiting, or the engine
    /// downloading: replacing the app would end them.
    private var busy: Bool {
        guard let model else { return true }
        return model.current != nil || !model.queue.isEmpty || model.setup.running
    }

    /// Every few seconds (the queue's watch): an update that was waiting for the queue installs
    /// once it's done.
    func tick() {
        guard let relaunch, !busy else { return }
        self.relaunch = nil
        // A window with a sheet up refuses to quit (seen: the old Mimic stayed open), so the
        // sheet goes first, and so do alerts and questions, which SwiftUI shows as sheets too.
        model?.sheet = nil; model?.problem = nil; model?.trashing = nil; model?.deletingProject = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            relaunch()
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        waiting = item.displayVersionString
        relaunch = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastChecked = updater.lastUpdateCheckDate
    }
}

/// A scheduled check that finds an update shows the toolbar note, never Sparkle's window.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { available = nil }
    func standardUserDriverWillFinishUpdateSession() { available = nil }
}

/// "Mimic 0.6.1 is available" in the toolbar: the quiet note that opens Sparkle's update window.
struct UpdateToolbarItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        if let v = updates.waiting ?? updates.available {
            Button { updates.check() } label: {
                Label(updates.waiting != nil ? "Mimic \(v) installs when the queue is done" : "Mimic \(v) is available",
                      systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("See what's new and update")
        }
    }
}

/// Settings → Updates.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        if updates.enabled {
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automatic)
                LabeledContent {
                    Button("Check Now") { updates.check() }
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
    }
}
