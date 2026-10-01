import Foundation

/// What a finished mini's notification says and carries, and its buttons. The app posts it
/// (`Notifier`); the words are here, so they can be tested.
public enum MiniNotification {
    public static let ready = "mini-ready", failed = "mini-failed"
    public static let retry = "try-again", open = "open-in-slicer"
    /// The userInfo key holding the mini's name.
    public static let mini = "mini"

    /// A notification's title, body and category (which picks its button).
    public struct Text: Equatable, Sendable {
        public let title: String
        public let body: String
        public let category: String
    }

    /// For `s` once it ended, `who` being the mini's name as shown: ready, or where it stopped.
    public static func text(_ s: JobStatus, who: String) -> Text {
        s.succeeded
            ? Text(title: "\(who) is ready", body: "Ready to print.", category: ready)
            : Text(title: "\(who) didn't finish", body: "Something went wrong while \(s.step.label.lowercased()).",
                   category: failed)
    }

    /// The ready one's button, which names the slicer.
    public static func openTitle(slicer: String) -> String { "Open in \(slicer)" }
    /// The failed one's button.
    public static let retryTitle = "Try Again"
}
