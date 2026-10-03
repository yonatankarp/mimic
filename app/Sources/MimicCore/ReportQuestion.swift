import Foundation

/// What Report a Problem… asks before it makes the report (#100): about a failed mini, or
/// about Mimic as a whole from the Help menu.
public struct ReportQuestion: Equatable, Sendable {
    public let title: String
    public let text: String

    public static let make = "Make Report", cancel = "Cancel"
    /// Its own checkbox, shown only when the mini has a picture.
    public static let includePicture = "Include the picture (the issue is public)"
    /// Its own checkbox too, ticked to start, under a preview: the window can show minis' names and pictures.
    public static let includeWindow = "Include a picture of Mimic's window (the issue is public)"

    /// `mini` is the failed mini's name as shown, or nil from the Help menu.
    public init(mini: String?) {
        title = mini.map { "Report a problem with “\($0)”?" } ?? "Report a problem?"
        // Its settings hold the description you typed (#349), and the issue is public.
        let what = mini == nil ? "its notes on what happened"
            : "its notes on making this mini, its settings and your description of it"
        text = "Mimic puts \(what), and which Mac, version and setup this is, into one file, "
            + "with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to."
    }
}
