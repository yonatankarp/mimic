import Foundation

/// What a request may contain. Every value here ends up as an argument to print prep or the 3D
/// engine, so this is the trust boundary: nothing unchecked gets past it.
public enum Rules {
    /// A mini's folder name: "dwarf-cleric". Shown to people as "Dwarf Cleric".
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

    public static let nozzles: Set<String> = ["0.2", "0.4", "0.6"]
}

public enum RequestError: Error, Equatable, CustomStringConvertible {
    case badName, badNumber(String), badNozzle, nameTaken(String), busy(String, JobKind = .generate), nothingToRetry, noModelYet, notFound, missing(String), modelNotDownloaded(String), unknownModel(String)
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
        case .modelNotDownloaded(let name): "The \(name) 3D model isn't downloaded. Open Settings → 3D model to download it."
        case .unknownModel(let id): "This Mimic doesn't know a 3D model called \(id). Update Mimic, or make it again with another model."
        }
    }
}
