import AppKit
import MimicCore
import Sparkle
import SwiftUI

/// Updates, through Sparkle: it reads the appcast each release publishes, when Mimic opens and
/// from Mimic → Check for Updates…, and shows, checks and installs the update. A newer version
/// found when Mimic opens shows Sparkle's window; after Remind Me Later, a quiet toolbar note.
/// Never installs while a mini is being made or waiting. Release builds only: the dev build
/// never updates itself.
@MainActor @Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    weak var model: AppModel?
    /// A new version found and not looked at yet, or put off with Remind Me Later: the toolbar note.
    var available: String?
    /// The version that installs once the queue is done.
    var waiting: String?
    /// Settings' Check for updates when Mimic opens. Never Sparkle's own automatic checks: those
    /// are its daily schedule, off in Info.plist, whose window would land in the middle of a queue.
    var automatic = true { didSet { UserDefaults.standard.set(automatic, forKey: UpdateCheck.key) } }
    var lastChecked: Date?
    /// Sparkle's, so Check Now and Check for Updates… are dimmed while a check is under way
    /// (the one when Mimic opens) instead of doing nothing.
    var canCheck = true
    @ObservationIgnored private var canCheckWatch: NSKeyValueObservation?
    /// An update found while another app was in front: its window waits until Mimic is.
    @ObservationIgnored private var showWhenActive = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Sparkle's go-ahead to install and relaunch, held while the queue is busy.
    @ObservationIgnored private var relaunch: (() -> Void)?

    override init() {
        super.init()
        guard Bundle.main.bundleIdentifier == "com.mimic.app" else { return }
        automatic = UpdateCheck.atLaunch()  // before Sparkle starts: it takes Sparkle's old switch away
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        lastChecked = controller.updater.lastUpdateCheckDate
        canCheckWatch = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
        guard automatic else { return }
        // A few seconds after the window opens, so the window doesn't land on a mini being started.
        // Nothing shows when there's nothing new or Mimic is offline.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !controller.updater.sessionInProgress { controller.updater.checkForUpdatesInBackground() }
        }
    }

    var enabled: Bool { controller != nil }

    /// Sparkle's own window: what's new, and Install Update.
    func check() { controller?.updater.checkForUpdates() }

    /// Mimic came to the front (`AppModel.becameActive`).
    func becameActive() {
        guard showWhenActive else { return }
        showWhenActive = false
        check()
    }

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
        model?.sheet = nil; model?.problem = nil; model?.trashing = []; model?.deletingProject = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            if busy { self.relaunch = relaunch; return }  // a mini started meanwhile, maybe in another Mimic
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

    /// Remind Me Later leaves the toolbar note until Mimic next opens; Install Update and Skip This
    /// Version take it away.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        available = choice == .dismiss ? updateItem.displayVersionString : nil
    }
}

/// The check when Mimic opens finds an update: Sparkle's window, in front. Sparkle on its own would
/// hold it back until Mimic is next switched to, this long after launch, so Mimic shows it the way
/// the toolbar note does.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // The note too, in case the window doesn't come forward; it goes once the window is looked at.
        // Never in front of another app: Sparkle's "show in focus" brings Mimic to the front.
        guard !handleShowingUpdate else { return }
        available = update.displayVersionString
        if NSApp.isActive { check() } else { showWhenActive = true }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { available = nil }
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
                Toggle("Check for updates when Mimic opens", isOn: $updates.automatic)
                LabeledContent {
                    Button("Check Now") { updates.check() }.disabled(!updates.canCheck)
                } label: {
                    Text("Last checked")
                    Text(updates.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Mimic asks GitHub for its latest release \(updates.automatic ? "each time it opens" : "only when you check"). Only public release information is read; nothing about your Mac or your minis is sent.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
