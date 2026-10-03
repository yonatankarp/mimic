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
            ? Text(title: String(localized: "Check the picture of \(who)", bundle: .mimicCore), body: String(localized: "Build its 3D shape when it looks right.", bundle: .mimicCore), category: picture)
            : s.succeeded
            ? Text(title: String(localized: "\(who) is ready", bundle: .mimicCore), body: String(localized: "Ready to print.", bundle: .mimicCore), category: ready)
            : Text(title: String(localized: "\(who) didn't finish", bundle: .mimicCore),
                   body: String(localized: "Something went wrong while \(s.step.during).", bundle: .mimicCore),
                   category: failed)
    }

    /// The ready one's button, which names the slicer.
    public static func openTitle(slicer: String) -> String { String(localized: "Open in \(slicer)", bundle: .mimicCore) }
    /// The failed one's button.
    public static let retryTitle = String(localized: "Try Again", bundle: .mimicCore)
    /// The picture-ready one's button.
    public static let buildShapeTitle = String(localized: "Build Shape", bundle: .mimicCore)
}
