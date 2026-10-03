import Foundation

/// What a request may contain. Every value here ends up as an argument to print prep or the 3D
/// engine, so this is the trust boundary: nothing unchecked gets past it.
public enum Rules {
    /// A mini's folder name: "dwarf-cleric". Shown to people as the name they typed, or else
    /// as "Dwarf Cleric" (see `folderName`).
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// "Dwarf Cleric!" → "dwarf-cleric". What the app turns typed names into.
    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-" }
        let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Names people type (#87)
    //
    // A mini has two names: the one typed ("Élodie", "D&D Bard"), kept in its settings and shown
    // everywhere, and its folder's ("elodie", "d-d-bard"), which its files, the queue and
    // `mimic` commands go by. Everything that names a new mini, renames one or copies one gets
    // both from here.

    /// The folder name for a typed name: other alphabets and accents written in plain letters,
    /// then `slug`. "Élodie" → "elodie", "Дракон" → "drakon", "Straße" → "strasse". Never empty:
    /// a name with nothing to write that way (only emoji, say) is "mini".
    public static func folderName(_ typed: String) -> String {
        let latin = (typed.applyingTransform(.toLatin, reverse: false) ?? typed)
            .applyingTransform(.stripDiacritics, reverse: false) ?? typed
        let plain = latin.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? latin
        let s = slug(plain)
        return s.isEmpty ? "mini" : s
    }

    /// A mini named on the command line: its folder's name, as `mimic list` shows it, or its name
    /// as typed in Mimic ("Élodie" is elodie).
    public static func miniName(_ text: String) -> String { isValidName(text) ? text : folderName(text) }

    /// A typed name as it's kept: trimmed, one line, at most 64 characters; nil when nothing is left.
    public static func shownName(_ typed: String) -> String? {
        let one = typed.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.isEmpty ? nil : String(one.prefix(64))
    }

    /// A name given to `mimic make` or `mimic duplicate`, taken as the app takes a typed one:
    /// "Élodie" is the folder "elodie", shown as "Élodie". A folder-style name ("dwarf-cleric")
    /// keeps no typed name, so it's shown as before ("Dwarf Cleric"). Nil when nothing is left.
    public static func typedName(_ typed: String) -> (folder: String, shown: String?)? {
        guard let shown = shownName(typed) else { return nil }
        return (folderName(shown), isValidName(typed) ? nil : shown)
    }

    /// The name to show for a picture's file: its own, as it's spelled ("Élodie" stays "Élodie"),
    /// dashes and underscores as spaces, and words capitalised when it has no capitals at all
    /// ("dwarf-cleric" → "Dwarf Cleric", as before).
    public static func shownName(fromFile base: String) -> String? {
        let words = base.split { $0 == "-" || $0 == "_" || $0.isWhitespace }.map(String.init)
        let spaced = words.joined(separator: " ")
        let text = spaced == spaced.lowercased() ? words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") : spaced
        return shownName(text)
    }

    /// The name shown for a mini whose typed name `typed` got the folder `folder`: the name
    /// itself, or with the folder's number when it had to take one ("Élodie" in "elodie-2" is
    /// "Élodie 2", and "Raven 2" in "raven-3" is "Raven 3"). Make Another Version and pictures
    /// named alike take a number that way.
    public static func shownName(_ typed: String, numberedAs folder: String) -> String {
        func numbered(_ s: String) -> (base: String, n: Int)? {
            guard let dash = s.lastIndex(of: "-"), let n = Int(s[s.index(after: dash)...]),
                  String(n) == s[s.index(after: dash)...] else { return nil }
            return (String(s[..<dash]), n)
        }
        let base = folderName(typed)
        guard folder != base, let m = numbered(folder) else { return typed }
        let (b, n) = m
        if b == base { return "\(typed) \(n)" }
        if numbered(base)?.base == b, let r = typed.range(of: #"\s*[0-9]+$"#, options: .regularExpression) {
            return "\(typed[..<r.lowerBound]) \(n)"
        }
        return typed
    }

    /// A typed name carried to a mini that goes by `folder` now, when it still fits: a version
    /// renamed to the plain name, or the other way, or a new version of it. "Élodie 2" to
    /// "elodie" is "Élodie"; "Élodie" to "elodie-3" is "Élodie 3". Nil when it doesn't fit.
    public static func shownName(carrying typed: String, to folder: String) -> String? {
        let root = typed.replacingOccurrences(of: #"\s+[0-9]+$"#, with: "", options: .regularExpression)
        for t in [typed, root] where !t.isEmpty {
            let shown = shownName(t, numberedAs: folder)
            if folderName(shown) == folder { return shown }
        }
        return nil
    }

    /// The file name for a print file named after shown names: "AC/DC Roadie ×2" is
    /// "AC-DC Roadie ×2.3mf", since "/" and ":" can't be in a file name and a leading "." would
    /// hide it. "minis.3mf" when nothing in it could be a folder name (only emoji, say).
    public static func printFileName(_ name: String) -> String {
        let plain = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let shown = plain.drop { $0 == "." }
        return slug(String(shown)).isEmpty ? "minis.3mf" : "\(shown).3mf"
    }

    /// A project's folder name, as typed ("Tiefling Party"), trimmed; nil when it can't be one.
    /// "_" and "." folders are Mimic's own scratch and hidden, so a project can't start with either.
    public static func projectName(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(t.count), !t.hasPrefix("."), !t.hasPrefix("_"),
              !t.contains("/"), !t.contains(":"), !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return t
    }

    public static let nozzles: Set<String> = ["0.2", "0.4", "0.6"]
}

/// An error in words for people (#324): Mimic's own already are. Anything else, a Cocoa error
/// say, is nil: the caller says what it was doing instead, and keeps the raw text for the log.
public func plainWords(_ error: Error) -> String? {
    switch error {
    case let e as RequestError: e.description
    case let e as Refusal: e.description
    case let e as DrawThingsError: e.description
    case let e as OnlineImagesError: e.description
    case let e as HelperError: e.description
    default: nil
    }
}

/// `plainWords` as the app says it, with `fallback` for an error that isn't in words: the
/// gallery doesn't know what the job is doing, but `making`, the job running, does.
public func plainWords(_ error: Error, making: JobStatus?, else fallback: String) -> String {
    switch error {
    case RequestError.busy(let n, _) where n == making?.name: RequestError.busy(n, making?.kind ?? .generate).description
    default: plainWords(error) ?? fallback
    }
}

/// A refusal of the app's or the command line's own, already in words for people: a job
/// refused before it started, a project that isn't there.
public struct Refusal: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum RequestError: Error, Equatable, CustomStringConvertible {
    case badName, badNumber(String), badNozzle, nameTaken(String), busy(String, JobKind = .generate), nothingToRetry, noModelYet, notFound, missing(String), modelNotDownloaded(String), unknownModel(String), queued(String), noPicture, unreadablePicture,
         badProjectName, projectTaken(String), projectNotFound, cantMove(String), projectBusy(String, String), noSource(String), noDrawing(String), cantDuplicate(String),
         minisFolderBusy, sameMinisFolder, minisFolderNested, minisFolderClash([String]), movingMinis,
         imported(String), unreadableModel(String),
         noName, renameWaiting(String), sidesNeedAPicture, oneSideOnly(String), unreadableSettings(String), fixNeedsAPicture,
         noPictureToFix(String), noPictureToCheck(String)
    public var description: String {
        switch self {
        case .badName: String(localized: "Names can only use lowercase letters, numbers and dashes.", bundle: .mimicCore)
        case .badNumber(let k):
            String(localized: "The \(Self.sizeName(k)) must be a number from \(SizeCard.text(Sizes.ranges[k]!.lowerBound)) to \(SizeCard.text(Sizes.ranges[k]!.upperBound)) mm.", bundle: .mimicCore)
        case .badNozzle: String(localized: "The nozzle must be 0.2, 0.4 or 0.6 mm.", bundle: .mimicCore)
        case .nameTaken(let n): String(localized: "You already have a mini called \(Mini.displayName(n)).", bundle: .mimicCore)
        // The lock held elsewhere comes with no mini's name: a second Mimic or `mimic` in Terminal.
        case .busy("another Mimic window", _): String(localized: "Another Mimic is making a mini right now. Wait for it to finish.", bundle: .mimicCore)
        case .busy(let n, .prep): String(localized: "Mimic is still resizing \(Mini.displayName(n)). Wait for it to finish.", bundle: .mimicCore)
        case .busy(let n, _): String(localized: "Mimic is still making \(Mini.displayName(n)). Wait for it to finish.", bundle: .mimicCore)
        case .nothingToRetry: String(localized: "This mini can't be retried: its picture or description wasn't saved.", bundle: .mimicCore)
        case .noModelYet: String(localized: "This mini isn't made yet.", bundle: .mimicCore)
        case .notFound: String(localized: "That mini doesn't exist.", bundle: .mimicCore)
        case .missing(let what): String(localized: "\(what) is missing or won't start. Open Settings to see how to fix it.", bundle: .mimicCore)
        case .modelNotDownloaded(let name): String(localized: "The \(name) 3D model isn't downloaded. Open Settings → 3D Model to download it.", bundle: .mimicCore)
        case .queued(let n): String(localized: "\(Mini.displayName(n)) is already waiting in the queue.", bundle: .mimicCore)
        case .noPicture: String(localized: "That picture can't be found any more. Choose it again.", bundle: .mimicCore)
        case .unreadablePicture: String(localized: "Mimic can't read that picture. Try another one, or save it as a PNG or JPEG first.", bundle: .mimicCore)
        case .badProjectName: String(localized: "Give the project a name, without a slash or colon, that doesn't start with a dot or an underscore.", bundle: .mimicCore)
        case .projectTaken(let n): String(localized: "You already have a project or a mini called \(n).", bundle: .mimicCore)
        case .projectNotFound: String(localized: "That project doesn't exist.", bundle: .mimicCore)
        case .cantMove(let n): String(localized: "\(Mini.displayName(n)) is being made or waiting in the queue. Move it once it's made.", bundle: .mimicCore)
        // With the mini's name as shown, read where it was found: an error has no folder to read it from.
        case .projectBusy(let p, let shown): String(localized: "\(shown) in \(p) is being made or waiting in the queue. Wait for it, or remove it from the queue first.", bundle: .mimicCore)
        case .noSource(let n): String(localized: "Mimic can't make another version of \(Mini.displayName(n)): the picture or description it was made from wasn't saved.", bundle: .mimicCore)
        case .noDrawing(let n): String(localized: "Mimic can't make a new 3D shape of \(Mini.displayName(n)): its picture isn't made yet. Try Make Another Version instead.", bundle: .mimicCore)
        case .cantDuplicate(let n): String(localized: "\(Mini.displayName(n)) is being made, resized or waiting in the queue. Duplicate it once that's done.", bundle: .mimicCore)
        case .noName: String(localized: "Give it a name.", bundle: .mimicCore)
        case .renameWaiting(let n): String(localized: "\(Mini.displayName(n)) is waiting in the queue. Rename it once it's made.", bundle: .mimicCore)
        case .imported(let n): String(localized: "\(Mini.displayName(n)) was imported from a 3D model, so there's no picture or description to make it again from. Resize This Mini makes its print file again.", bundle: .mimicCore)
        case .unreadableModel(GLB.tooBig): String(localized: "That model is too big for Mimic to read. Try a simpler one, with fewer triangles.", bundle: .mimicCore)
        case .unreadableModel(let why):String(localized: "Mimic can't use that file: \(why). It needs a 3D model saved as GLB or STL.", bundle: .mimicCore)
        case .unknownModel(let id): String(localized: "This Mimic doesn't know a 3D model called \(id). Update Mimic, or make it again with another model.", bundle: .mimicCore)
        case .minisFolderBusy: String(localized: "A mini is being made or waiting in the queue. Change the folder once they're all done.", bundle: .mimicCore)
        case .movingMinis: String(localized: "Mimic is moving your minis to another folder. Try again when it's done.", bundle: .mimicCore)
        case .sameMinisFolder: String(localized: "Your minis are already in that folder.", bundle: .mimicCore)
        case .minisFolderNested: String(localized: "Choose a folder that isn't inside the one your minis are in now, and doesn't hold it.", bundle: .mimicCore)
        case .minisFolderClash(let names):
            String(localized: "That folder already has minis or projects called \(ListFormatter.localizedString(byJoining: names)). Rename yours first, or use the folder without moving your minis.", bundle: .mimicCore)
        case .sidesNeedAPicture: String(localized: "Pictures of the back and sides go with a picture of the front, not a description.", bundle: .mimicCore)
        case .oneSideOnly(let model): String(localized: "\(model) makes a mini from one picture. Choose TRELLIS.2 in Settings → 3D Model to use pictures of the back and sides too.", bundle: .mimicCore)
        case .noPictureToFix(let n): String(localized: "Mimic can't change the picture of \(Mini.displayName(n)): its picture isn't made yet. Make another version without a change instead.", bundle: .mimicCore)
        case .noPictureToCheck(let n): String(localized: "\(Mini.displayName(n)) has no picture waiting to be checked.", bundle: .mimicCore)
        case .fixNeedsAPicture: String(localized: "What to change goes with a picture. For a description, change the description instead.", bundle: .mimicCore)
        case .unreadableSettings(let n):String(localized: "Mimic can't read the settings.json of \(Mini.displayName(n)), so it left it as it is. Fix or remove that file, then try again.", bundle: .mimicCore)
        }
    }

    /// The size in “The height must be a number from…”.
    private static func sizeName(_ k: String) -> String {
        switch k {
        case "inflate": String(localized: "extra thickness", bundle: .mimicCore, comment: "The size in “The %@ must be a number from 1 to 5 mm.”")
        case "base": String(localized: "base", bundle: .mimicCore, comment: "The size in “The %@ must be a number from 1 to 5 mm.”")
        default: String(localized: "height", bundle: .mimicCore, comment: "The size in “The %@ must be a number from 1 to 5 mm.”")
        }
    }
}
