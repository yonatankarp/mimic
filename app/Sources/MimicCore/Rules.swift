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

public enum RequestError: Error, Equatable, CustomStringConvertible {
    case badName, badNumber(String), badNozzle, nameTaken(String), busy(String, JobKind = .generate), nothingToRetry, noModelYet, notFound, missing(String), modelNotDownloaded(String), unknownModel(String), queued(String), noPicture, unreadablePicture,
         badProjectName, projectTaken(String), projectNotFound, cantMove(String), projectBusy(String, String), noSource(String), noDrawing(String), cantDuplicate(String),
         minisFolderBusy, sameMinisFolder, minisFolderNested, minisFolderClash([String]), movingMinis,
         imported(String), unreadableModel(String)
    public var description: String {
        switch self {
        case .badName: "Names can only use lowercase letters, numbers and dashes."
        case .badNumber(let k): "The \(k) must be a number of 0 or more."
        case .badNozzle: "The nozzle must be 0.2, 0.4 or 0.6 mm."
        case .nameTaken(let n): "You already have a mini called \(Mini.displayName(n))."
        // The lock held elsewhere comes with no mini's name: a second Mimic or `mimic` in Terminal.
        case .busy("another Mimic window", _): "Another Mimic is making a mini right now. Wait for it to finish."
        case .busy(let n, let kind): "Mimic is still \(kind == .prep ? "resizing" : "making") \(Mini.displayName(n)). Wait for it to finish."
        case .nothingToRetry: "This mini can't be retried: its picture or description wasn't saved."
        case .noModelYet: "This mini isn't made yet."
        case .notFound: "That mini doesn't exist."
        case .missing(let what): "\(what) is missing or won't start. Open Settings to see how to fix it."
        case .modelNotDownloaded(let name): "The \(name) 3D model isn't downloaded. Open Settings → 3D Model to download it."
        case .queued(let n): "\(Mini.displayName(n)) is already waiting in the queue."
        case .noPicture: "That picture can't be found any more. Choose it again."
        case .unreadablePicture: "Mimic can't read that picture. Try another one, or save it as a PNG or JPEG first."
        case .badProjectName: "Give the project a name, without a slash or colon, that doesn't start with a dot or an underscore."
        case .projectTaken(let n): "You already have a project or a mini called \(n)."
        case .projectNotFound: "That project doesn't exist."
        case .cantMove(let n): "\(Mini.displayName(n)) is being made or waiting in the queue. Move it once it's made."
        // With the mini's name as shown, read where it was found: an error has no folder to read it from.
        case .projectBusy(let p, let shown): "\(shown) in \(p) is being made or waiting in the queue. Wait for it, or take it out of the queue first."
        case .noSource(let n): "Mimic can't make another version of \(Mini.displayName(n)): the picture or description it was made from wasn't saved."
        case .noDrawing(let n): "Mimic can't make a new 3D shape of \(Mini.displayName(n)): its picture isn't made yet. Try Make Another Version instead."
        case .cantDuplicate(let n): "\(Mini.displayName(n)) is being made, resized or waiting in the queue. Duplicate it once that's done."
        case .imported(let n): "\(Mini.displayName(n)) was imported from a 3D model, so there's no picture or description to make it again from. Resize This Mini makes its print file again."
        case .unreadableModel(let why): "Mimic can't use that file: \(why). It needs a 3D model saved as GLB or STL."
        case .unknownModel(let id): "This Mimic doesn't know a 3D model called \(id). Update Mimic, or make it again with another model."
        case .minisFolderBusy: "A mini is being made or waiting in the queue. Change the folder once they're all done."
        case .movingMinis: "Mimic is moving your minis to another folder. Try again when it's done."
        case .sameMinisFolder: "Your minis are already in that folder."
        case .minisFolderNested: "Choose a folder that isn't inside the one your minis are in now, and doesn't hold it."
        case .minisFolderClash(let names):
            "That folder already has minis or projects called \(ListFormatter.localizedString(byJoining: names)). Rename yours first, or use the folder without moving your minis."
        }
    }
}
