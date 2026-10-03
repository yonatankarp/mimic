import AppKit
import MimicCore
import UserNotifications

/// Telling you a mini is done: a notification when one ends and Mimic isn't in front, and what
/// clicking it or its buttons does. Owned by the app's delegate; it is the notification center's
/// delegate too. Only an app bundle can use notifications: the bare binary from `swift build`
/// has none and would crash, so all of this is a no-op there.
@MainActor
final class Notifier: NSObject {
    weak var model: AppModel?

    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Before launching ends, so a click on a notification that opened Mimic reaches it.
    func start() {
        guard Self.available, let model else { return }
        UNUserNotificationCenter.current().delegate = self
        MiniNotification.register(slicer: model.slicerName)
    }

    /// The Mac asks once; after that this is a no-op.
    static func ask() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A notification when a mini ends and Mimic isn't in front (or its window was closed), with
    /// Open in the slicer on a ready one and Try Again on a failed one. Clicking it goes to the mini.
    func announce(_ s: JobStatus) {
        guard let model, !s.canceled, !(NSApp.isActive && NSApp.mainWindow != nil), Self.available else { return }
        let text = MiniNotification.text(s, who: model.displayName(s))
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = text.category
        content.userInfo = [MiniNotification.mini: s.name]
        // Again each time: the ready one names the slicer, which can change in Settings.
        MiniNotification.register(slicer: model.slicerName)
        content.sound = .default
        // One identifier per mini: a shared one made each notification replace the last, so of
        // three minis finishing from the queue only the last "ready" was left.
        let id = "job-\(s.name)-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A notification about `name` was clicked (`action` is the default action) or one of its
    /// buttons pressed.
    func answered(_ action: String, mini name: String) {
        guard let model else { return }
        switch action {
        case MiniNotification.retry:
            // In the background, as the job's popover's Try Again; only a refusal brings Mimic forward.
            do { try model.retry(name) } catch {
                model.problem = Problem(String(localized: "Couldn't try again"), model.plainWords(error, else: String(localized: "Open the mini and try again from there.")))
                model.go(to: name)
            }
        case MiniNotification.buildShape:
            do { try model.buildShape(name) } catch {
                model.problem = Problem(String(localized: "Couldn't build its shape"), model.plainWords(error, else: String(localized: "Open the mini and try from there.")))
                model.go(to: name)
            }
        case MiniNotification.open:
            model.reload()
            if let stl = model.minis.first(where: { $0.name == name })?.stl { model.openInSlicer(stl) } else { model.go(to: name) }
        default:
            model.go(to: name)
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// A finished mini's notification: clicked, Open in the slicer, or Try Again. The center may
    /// call from any thread, so only plain strings cross to the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let name = response.notification.request.content.userInfo[MiniNotification.mini] as? String else { return }
        await MainActor.run { answered(action, mini: name) }
    }

    /// Shown even with Mimic in front: it only posts one then when its window is closed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}

extension MiniNotification {
    static func register(slicer: String) {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: ready, actions: [UNNotificationAction(identifier: open, title: openTitle(slicer: slicer))],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: failed, actions: [UNNotificationAction(identifier: retry, title: retryTitle)],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: picture, actions: [UNNotificationAction(identifier: buildShape, title: buildShapeTitle)],
                                   intentIdentifiers: []),
        ])
    }
}
