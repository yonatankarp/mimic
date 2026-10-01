import Foundation

/// Why `mimic` refused what was typed, in the words it says.
public enum CommandRefusal: Error, Equatable, CustomStringConvertible {
    /// Shows the usage: a command that isn't there, or one typed wrong.
    case usage
    case noName, notSetUp
    /// A flag given without the value it needs, or with one it can't take.
    case badScale, badBaseShape, badBaseStyle, badMagnet, badSeed, noProjectName, badModel
    case noPicture(String)
    case unknownOption(String)
    case projectNotHere, importAsItIs, newShapeNotHere, sidesNeedImage, scaleForObject, improveImage
    case queueMoveUsage, queueRemoveUsage

    public var description: String {
        switch self {
        case .usage: Usage.text
        case .noName: "Give the mini a name."
        case .notSetUp: "Mimic needs to finish setting up. Open the Mimic app: it downloads what's missing."
        case .badScale: "--scale needs \(SizeCard.scaleChoices)"
        case .badBaseShape: "--base-shape needs round, square or hex"
        case .badBaseStyle: "--base-style needs plain, stone, wood or cobble"
        case .badMagnet: "--magnet needs 5x2, 6x2, 8x3 or none"
        case .badSeed: "--seed needs a number"
        case .noProjectName: "--project needs a project's name"
        case .badModel: "--model needs one of: \(EngineDownload.catalogue.map(\.id).joined(separator: ", ")) (see mimic models)"
        case .noPicture(let flag): "\(flag) needs a picture"
        case .unknownOption(let a): "unknown option: \(a)\n\(Usage.text)"
        case .projectNotHere: "--project is for mimic make, import and resize --project; mimic move moves a mini"
        case .importAsItIs: "mimic import takes the model as it is: only size options, --object, --add-base and --project"
        case .newShapeNotHere: "--new-shape is for mimic make-another"
        case .sidesNeedImage: "--back, --left and --right go with mimic make … --image <front picture>"
        case .scaleForObject: "--scale is for characters; give an object's longest side with --size"
        case .improveImage: "--improve works on a description, not --image"
        case .queueMoveUsage: "usage: mimic queue move <name> --to front|end|<place> | --up | --down"
        case .queueRemoveUsage: "usage: mimic queue remove <name>"
        }
    }
}

/// `mimic make`, `resize`, `retry`, `make-another` and `import`, as typed. Reading it touches
/// nothing on disk: what needs the minis folder (Resize All's project, what a resize keeps, the
/// next version's name) is the command line's, and `checkedSizes(_:object:)` finishes the checks after it.
public struct MakeRequest: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case make, resize, retry, makeAnother, `import`
        /// `mimic resize --project <project>`: every mini in it.
        case resizeAll(project: String)
    }

    public var command: Command
    /// The mini it's about, as `mimic list` names it: make's new folder, import's file as typed,
    /// and empty for Resize All.
    public var of = ""
    /// The name as make was given it ("Élodie"), shown instead of the folder's.
    public var shown: String?
    public var sizes = Sizes()
    public var shapeGiven = false, styleGiven = false, magnetGiven = false
    public var scale: Int?
    public var object = false, addBase = false
    public var image: String?
    public var sides: [PictureSide: URL] = [:]
    public var description: String?
    public var restyle = false, improve = false, wait = false, newShape = false
    /// Nil unless given: make starts from 42, make-another from the mini's own.
    public var seed: Int?
    /// Nil unless given: the app's choice.
    public var model: EngineModel?
    /// Make and import's project, as typed.
    public var project: String?

    public init(_ command: Command) { self.command = command }

    /// `args` from the command's own name on: `["make", "Élodie", "a dwarf", "--height", "40"]`.
    /// `engineReady` is whether the 3D engine is there: make, retry and make-another need it,
    /// and say so before reading their options.
    public static func parse(_ args: [String], engineReady: Bool = true) throws -> MakeRequest {
        guard let verb = args.first else { throw CommandRefusal.usage }
        var rest = Array(args.dropFirst())
        let all = verb == "resize" && rest.first == "--project"
        guard all || rest.first.map({ !$0.hasPrefix("-") }) == true else { throw CommandRefusal.usage }
        var r: MakeRequest
        switch verb {
        case "make": r = MakeRequest(.make)
        case "resize": r = MakeRequest(all ? .resizeAll(project: "") : .resize)
        case "retry": r = MakeRequest(.retry)
        case "make-another": r = MakeRequest(.makeAnother)
        case "import": r = MakeRequest(.import)
        default: throw CommandRefusal.usage
        }
        if !all {
            // make takes a name as the app does: "Élodie" is the folder elodie, shown as typed.
            if verb == "make" {
                guard let given = Rules.typedName(rest[0]) else { throw CommandRefusal.noName }
                r.of = given.folder; r.shown = given.shown
            } else {
                r.of = verb == "import" ? rest[0] : Rules.miniName(rest[0])
            }
        }
        // Setup downloads the engine in the app, where it can show its progress. Resize and
        // import only run print prep.
        guard verb == "resize" || verb == "import" || engineReady else { throw CommandRefusal.notSetUp }
        if !all { rest.removeFirst() }
        while let a = rest.first {
            rest.removeFirst()
            func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
            switch a {
            case "--height", "--size": r.sizes.height = value()
            case "--scale":
                guard let v = value().flatMap(Int.init), SizeCard.scales.contains(v) else { throw CommandRefusal.badScale }
                r.scale = v
            case "--object": r.object = true
            case "--add-base": r.addBase = true
            case "--base": r.sizes.base = value()
            case "--nozzle": r.sizes.nozzle = value()
            case "--inflate": r.sizes.inflate = value()
            case "--no-base": r.sizes.noBase = true
            case "--base-shape":
                guard let v = value().flatMap(BaseShape.init) else { throw CommandRefusal.badBaseShape }
                r.sizes.shape = v; r.shapeGiven = true
            case "--base-style":
                guard let v = value().flatMap(BaseStyle.init) else { throw CommandRefusal.badBaseStyle }
                r.sizes.style = v; r.styleGiven = true
            case "--magnet":
                let v = value()
                guard v == "none" || v.flatMap(Magnet.init) != nil else { throw CommandRefusal.badMagnet }
                r.sizes.magnet = v.flatMap(Magnet.init); r.magnetGiven = true
            case "--image": r.image = value()
            case "--back", "--left", "--right":
                guard let v = value() else { throw CommandRefusal.noPicture(a) }
                r.sides[PictureSide(rawValue: String(a.dropFirst(2)))!] = URL(fileURLWithPath: v)
            case "--restyle": r.restyle = true
            case "--improve": r.improve = true
            case "--wait": r.wait = true
            case "--new-shape": r.newShape = true
            case "--seed": guard let v = value().flatMap(Int.init) else { throw CommandRefusal.badSeed }; r.seed = v
            case "--project": guard let v = value() else { throw CommandRefusal.noProjectName }; r.project = v
            case "--model":
                guard let v = value().flatMap(EngineDownload.model) else { throw CommandRefusal.badModel }
                r.model = v
            default:
                guard r.description == nil, !a.hasPrefix("-") else { throw CommandRefusal.unknownOption(a) }
                r.description = a
            }
        }
        // Resize All's --project is the project it resizes, not one to put a mini in.
        if all { r.command = .resizeAll(project: r.project ?? ""); r.project = nil }
        return r
    }

    /// The options that don't go with this command, in the order they're refused, then the sizes
    /// to make it at: `sizes` and `object` as typed, or as a resize keeps them.
    public func checkedSizes(_ sizes: Sizes, object: Bool) throws -> Sizes {
        if project != nil && command != .make && command != .import { throw CommandRefusal.projectNotHere }
        if command == .import && (image != nil || restyle || improve || seed != nil || model != nil || newShape || description != nil) {
            throw CommandRefusal.importAsItIs
        }
        if newShape && command != .makeAnother { throw CommandRefusal.newShapeNotHere }
        if !sides.isEmpty && (command != .make || image == nil) { throw CommandRefusal.sidesNeedImage }
        var sizes = sizes
        if let scale {
            if object { throw CommandRefusal.scaleForObject }
            sizes = SizeCard.gameSizes(scale: scale, filling: sizes) ?? sizes
        }
        if object {
            if !addBase { sizes.noBase = true }
            // An object's base goes under its whole shadow, as in the app (SizeCard).
            else if sizes.base == nil, let h = sizes.height.flatMap(Double.init) ?? SizeCard.objectSize[sizes.nozzle ?? "0.4"] {
                sizes.base = SizeCard.text(min(80, max(25, (h * 0.8 / 5).rounded() * 5)))
            }
            if sizes.height == nil { sizes.height = SizeCard.text(SizeCard.objectSize[sizes.nozzle ?? "0.4"] ?? 80) }
        }
        if command == .make && improve && image != nil { throw CommandRefusal.improveImage }
        return sizes
    }
}

/// `mimic queue …`, as typed (without `--json`, which the listing takes).
public enum QueueCommand: Equatable, Sendable {
    case list, pause, resume
    /// `name` as `mimic list` names it.
    case move(name: String, Move)
    /// `name` as `mimic list` names it, and as it was typed, which the refusal repeats.
    case remove(name: String, typed: String)

    public enum Move: Equatable, Sendable {
        /// --up is -1, --down 1.
        case by(Int)
        case to(QueuePlace)
    }

    public static func parse(_ rest: [String]) throws -> QueueCommand {
        if rest == ["pause"] { return .pause }
        if rest == ["resume"] { return .resume }
        if rest.first == "move" {
            guard rest.count >= 3 else { throw CommandRefusal.queueMoveUsage }
            let name = Rules.miniName(rest[1])
            switch Array(rest.dropFirst(2)) {
            case ["--up"]: return .move(name: name, .by(-1))
            case ["--down"]: return .move(name: name, .by(1))
            case let a where a.count == 2 && a[0] == "--to":
                guard let place = QueuePlace(a[1]) else { throw CommandRefusal.queueMoveUsage }
                return .move(name: name, .to(place))
            default: throw CommandRefusal.queueMoveUsage
            }
        }
        if rest.first == "remove" {
            guard rest.count == 2 else { throw CommandRefusal.queueRemoveUsage }
            return .remove(name: Rules.miniName(rest[1]), typed: rest[1])
        }
        guard rest.isEmpty else { throw CommandRefusal.usage }
        return .list
    }
}
