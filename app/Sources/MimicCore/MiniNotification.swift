import Foundation

/// What a finished mini's notification says and carries, and its buttons. The app posts it
/// (`Notifier`); the words are here, so they can be tested.
public enum MiniNotification {
    public static let ready = "mini-ready", failed = "mini-failed", picture = "picture-ready"
    public static let retry = "try-again", open = "open-in-slicer", buildShape = "build-shape"
    /// The userInfo key holding the mini's name.
    public static let mini = "mini"

    /// A notification's title, body and category (which picks its button).
    public struct Text: Equatable, Sendable {
        public let title: String
        public let body: String
        public let category: String
    }

    /// For `s` once it ended, `who` being the mini's name as shown: ready, or where it stopped.
    /// A make that stopped for its picture to be checked (#156) says so.
    public static func text(_ s: JobStatus, who: String) -> Text {
        s.outcome == .pictureReady
            ? Text(title: "Check the picture of \(who)", body: "Build its 3D shape when it looks right.", category: picture)
            : s.succeeded
            ? Text(title: "\(who) is ready", body: "Ready to print.", category: ready)
            : Text(title: "\(who) didn't finish", body: "Something went wrong while \(s.step.label.lowercased()).",
                   category: failed)
    }

    /// The ready one's button, which names the slicer.
    public static func openTitle(slicer: String) -> String { "Open in \(slicer)" }
    /// The failed one's button.
    public static let retryTitle = "Try Again"
    /// The picture-ready one's button.
    public static let buildShapeTitle = "Build Shape"
}
