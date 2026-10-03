import Foundation

/// What Report a Problem… asks before it makes the report (#100): about a failed mini, or
/// about Mimic as a whole from the Help menu.
public struct ReportQuestion: Equatable, Sendable {
    public let title: String
    public let text: String

    public static let make = String(localized: "Make Report", bundle: .mimicCore), cancel = String(localized: "Cancel", bundle: .mimicCore)
    /// Its own checkbox, shown only when the mini has a picture.
    public static let includePicture = String(localized: "Include the picture (the issue is public)", bundle: .mimicCore)
    /// Its own checkbox too, unticked to start (#350): the window can show minis' names and pictures.
    public static let includeWindow = String(localized: "Include a picture of Mimic's window (the issue is public)", bundle: .mimicCore)

    /// `mini` is the failed mini's name as shown, or nil from the Help menu.
    public init(mini: String?) {
        title = mini.map { String(localized: "Report a problem with “\($0)”?", bundle: .mimicCore) }
            ?? String(localized: "Report a problem?", bundle: .mimicCore)
        // Its settings hold the description you typed (#349), and the issue is public.
        text = mini == nil
            ? String(localized: "Mimic puts its notes on what happened, and which Mac, version and setup this is, into one file, with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to.", bundle: .mimicCore)
            : String(localized: "Mimic puts its notes on making this mini, its settings and your description of it, and which Mac, version and setup this is, into one file, with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to.", bundle: .mimicCore)
    }
}
