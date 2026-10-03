import Foundation
import simd
import Synchronization

/// The size card of the Make and Resize sheets: what the mini is for, the nozzle, and the
/// sizes those suggest. Ported number for number from the web page's size card.
///
/// Choosing a purpose, scale, nozzle or real height means "size it for me again"; moving a
/// slider or typing a value means "I'll size it", and the suggestion leaves that value alone.
public struct SizeCard: Equatable, Sendable {
    /// The switch that gives an object a base, as New Mini and Resize name it.
    public static let addBase = String(localized: "Add a base", bundle: .mimicCore)
    public enum Purpose: String, CaseIterable, Sendable { case game, display }

    public static let heightRange = 15.0...200.0
    public static let baseRange = 20.0...80.0
    public static let inflateRange = 0.0...0.4
    public static let scales = [28, 32, 35, 54, 75]
    /// The smallest base a character gets at a scale: what minis of that scale usually stand on.
    /// Up to 35 mm it's 25 mm, one map square, as `baseFor` gives.
    public static let scaleBase: [Int: Double] = [54: 40, 75: 50]
    /// Best print sizes the figure so faces come out on the chosen nozzle: judged on a
    /// realistic-proportion character (a 2 m tiefling), faces read from about 64 mm on a 0.2
    /// nozzle and 100 mm on a 0.4; 0.6 is extrapolated.
    public static let bestPrint: [String: Double] = ["0.2": 64, "0.4": 100, "0.6": 150]
    /// An object's longest side, by the same rule scaled to objects: its finest details (a
    /// spout's lip, a handle) are coarser than a face, so it needs less size than Best print.
    // ponytail: judged, not measured on prints; measure when objects have been printed at these sizes.
    public static let objectSize: [String: Double] = ["0.2": 50, "0.4": 80, "0.6": 120]

    /// Nil when loaded sizes match neither choice: nothing is shown as chosen.
    public private(set) var purpose: Purpose?
    /// An object is sized by its longest side and has no round base unless asked for one.
    public private(set) var kind: MiniKind
    public private(set) var nozzle: String
    public private(set) var scale = 32
    /// As typed, in metres or feet (see `metres`). Blank, or what can't be read, counts as an
    /// average human, 1.8 m.
    public private(set) var realHeight = ""
    public private(set) var height = 32.0
    public private(set) var base = 25.0
    public private(set) var inflate: Double
    public var noBase = false
    public var shape = BaseShape.round
    public var style = BaseStyle.plain
    public var magnet: Magnet?
    public private(set) var heightTouched = false, baseTouched = false, inflateTouched = false
    /// The line under the size choices, and whether it's a warning.
    public private(set) var note = ""
    public private(set) var warns = false

    public init(purpose: Purpose = .game, nozzle: String = "0.4", kind: MiniKind = .character) {
        self.purpose = purpose
        self.kind = kind
        noBase = kind == .object
        self.nozzle = Rules.nozzles.contains(nozzle) ? nozzle : "0.4"
        inflate = Self.inflateFor(self.nozzle)
        suggest()
    }

    /// The kind, purpose, nozzle and base last chosen (`SettingsKey`): most people keep one printer.
    public static func remembered(defaults d: UserDefaults = .standard) -> SizeCard {
        var card = SizeCard(purpose: Purpose(rawValue: d.string(forKey: SettingsKey.purpose) ?? "") ?? .game,
                            nozzle: d.string(forKey: SettingsKey.nozzle) ?? "0.4",
                            kind: MiniKind(rawValue: d.string(forKey: SettingsKey.kind) ?? "") ?? .character)
        card.shape = BaseShape(rawValue: d.string(forKey: SettingsKey.baseShape) ?? "") ?? .round  // a hex-map player wants hex every time
        card.style = BaseStyle(rawValue: d.string(forKey: SettingsKey.baseStyle) ?? "") ?? .plain
        card.magnet = Magnet(rawValue: d.string(forKey: SettingsKey.magnet) ?? "")  // a player who magnetises does it every time
        return card
    }

    public mutating func setPurpose(_ p: Purpose) { purpose = p; resuggest() }
    public mutating func setKind(_ k: MiniKind) { kind = k; noBase = k == .object; resuggest() }
    public mutating func setScale(_ s: Int) { scale = s; resuggest() }
    public mutating func setRealHeight(_ text: String) { realHeight = text; resuggest() }
    /// A nozzle sets the extra thickness too, unless that was chosen by hand.
    public mutating func setNozzle(_ n: String) {
        guard Rules.nozzles.contains(n) else { return }
        nozzle = n
        if !inflateTouched { inflate = Self.inflateFor(n) }
        resuggest()
    }

    public mutating func setHeight(_ v: Double) { height = Self.clamp(v, Self.heightRange, step: 1); heightTouched = true; suggest() }
    public mutating func setBase(_ v: Double) { base = Self.clamp(v, Self.baseRange, step: 1); baseTouched = true }
    public mutating func setInflate(_ v: Double) { inflate = Self.clamp(v, Self.inflateRange, step: 0.01); inflateTouched = true }

    /// Puts the sizes a mini was made with into the card, so Resize starts from what it is now.
    public mutating func load(_ made: Sizes) {
        if let n = made.nozzle, n != nozzle { setNozzle(n) }
        if let h = made.height.flatMap(Double.init) { height = Self.clamp(h, Self.heightRange, step: 1) }
        if let b = made.base.flatMap(Double.init) { base = Self.clamp(b, Self.baseRange, step: 1) }
        heightTouched = true; baseTouched = true
        let madeInflate = made.inflate.flatMap(Double.init)
        inflateTouched = madeInflate != nil
        inflate = madeInflate.map { Self.clamp($0, Self.inflateRange, step: 0.01) } ?? Self.inflateFor(nozzle)
        noBase = made.noBase
        if !made.noBase { shape = made.shape; style = made.style; magnet = made.magnet }  // no base keeps the last ones chosen, for if one is added
        // Its own real height, even when it isn't at a scale now: choosing Game Scale starts from it.
        if kind != .object { realHeight = made.realHeight ?? "" }
        // The choice shown is the one these sizes match, not the last New Mini's: Game Scale when
        // its real height (an average human without one) is this tall at a scale (#479).
        // An object's one choice is its suggested size.
        if kind == .object { purpose = height == Self.objectSize[nozzle] ? .display : nil }
        else if height == Self.bestPrint[nozzle] { purpose = .display }
        else if let s = Self.scales.first(where: { Self.gameHeight(real: realHeight, scale: $0) == height }) { purpose = .game; scale = s }
        else { purpose = nil }
        suggest()  // refreshes the note; touched values stay
    }

    /// Resize All: each character is sized from its own real height (`Gallery.toResize`), so the
    /// card's is left blank, not the first mini's, and at Game Scale its height, which minis
    /// without one get, is an average human's. The base loaded stays.
    public mutating func forSeveral() {
        guard kind != .object else { return }
        realHeight = ""
        if purpose == .game { heightTouched = false; suggest() }
    }

    /// The scale chosen, when it's a character at Game Scale: what Resize All sizes each
    /// character for from its own real height.
    public var chosenScale: Int? { kind != .object && purpose == .game ? scale : nil }

    /// Resize All at Game Scale, which doesn't ask the real height: what the minis are sized
    /// from, when `without` of `count` have none kept (made before it was, or not at a scale).
    public static func severalNote(without: Int, of count: Int) -> String {
        if without == 0 { return String(localized: "Each character keeps its own real height, so a halfling stays shorter than an elf.", bundle: .mimicCore) }
        if without == count { return String(localized: "Every mini gets the same height, the Character height below: none of them has its real height saved.", bundle: .mimicCore) }
        return String(localized: "Each character keeps its own real height. \(without) minis have no real height saved, so they get the Character height below.",
                      bundle: .mimicCore)
    }

    /// What print prep is asked for. The extra thickness is sent only when chosen by hand:
    /// otherwise print prep picks it from the nozzle itself.
    public var sizes: Sizes {
        Sizes(height: Self.text(height), base: Self.text(base), nozzle: nozzle,
              inflate: inflateTouched ? Self.text(inflate) : nil, noBase: noBase, shape: shape, style: style, magnet: magnet,
              realHeight: realHeightKept)
    }

    /// The real height kept with the sizes, in metres: what's typed, or at Game Scale the 1.8 m
    /// it counts as. None for an object, or over 20 m, which the field would read back as
    /// centimetres (no height that tall fits the slider anyway).
    private var realHeightKept: String? {
        guard kind != .object, let m = Self.metres(realHeight) ?? (purpose == .game ? 1.8 : nil), m <= 20 else { return nil }
        return Self.text((m * 1000).rounded() / 1000)
    }

    private mutating func resuggest() { heightTouched = false; baseTouched = false; suggest() }

    private mutating func suggest() {
        let h: Double
        warns = false
        switch (kind, purpose) {
        case (.object, nil):  // loaded at another size than the suggestion: the note is about the size it is
            h = height
            let best = Self.objectHeight(nozzle: nozzle)
            note = h < best ? String(localized: "At \(Int(h)) mm, a \(nozzle) mm nozzle softens fine details a little. For the clearest details, make it about \(Int(best)) mm on its longest side.", bundle: .mimicCore) : ""
        case (.object, _):
            h = Self.objectHeight(nozzle: nozzle)
            note = String(localized: "Sized so details come out clearly on a \(nozzle) mm nozzle: about \(Int(h)) mm on its longest side. Change it to the size you want.", bundle: .mimicCore)
        case (_, .game), (_, nil):  // nil: loaded sizes that match neither, so the note is about their height
            h = purpose == .game ? Self.gameHeight(real: realHeight, scale: scale) : height
            note = ""
            // The default (32 mm on a 0.4 nozzle) gets a tip, not a warning: it prints fine,
            // faces just come out a little soft. Only really small sizes, or a 0.6 nozzle under
            // its 54 mm sweet spot (see PrintTips), turn faces into bumps.
            if (nozzle == "0.4" && h < 28) || (nozzle == "0.6" && h < 50) {
                note = String(localized: "At \(Int(h)) mm, a \(nozzle) mm nozzle turns faces into bumps. Use a 0.2 mm nozzle, or choose Best Print.", bundle: .mimicCore)
                warns = true
            } else if nozzle == "0.4" && h < 50 {
                note = String(localized: "At \(Int(h)) mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose Best Print.", bundle: .mimicCore)
            }
        case (_, .display):
            h = Self.bestPrint[nozzle] ?? 100
            note = String(localized: "Sized so faces come out clearly on a \(nozzle) mm nozzle: about \(Int(h)) mm tall. Chunky characters also look good a bit smaller.", bundle: .mimicCore)
        }
        // The note names the height as worked out; the slider can only hold its own range.
        if !heightTouched { height = Self.clamp(h, Self.heightRange, step: 1) }
        // An object's base goes under its whole shadow, which is about its longest side.
        if !baseTouched {
            base = kind == .object ? Self.objectBase(height)
                : max(purpose == .game ? Self.scaleBase[scale] ?? 25 : 25, Self.baseFor(height))
        }
    }

    /// "28, 32, 35, 54 or 75", for Terminal's --scale.
    public static var scaleChoices: String {
        scales.dropLast().map(String.init).joined(separator: ", ") + " or \(scales.last!)"
    }

    /// `--scale` in Terminal: Game scale's height and base, for what wasn't typed, so Terminal
    /// sizes a mini as the app does. The height is the real height's in `sizes` (a resize keeps
    /// the mini's own), else an average 1.8 m human's. Nil for a scale not in `scales`.
    public static func gameSizes(scale: Int, filling sizes: Sizes) -> Sizes? {
        guard scales.contains(scale) else { return nil }
        var card = SizeCard(purpose: .game, nozzle: sizes.nozzle ?? "0.4")
        card.setScale(scale)
        card.setRealHeight(sizes.realHeight ?? "")
        if let h = sizes.height.flatMap(Double.init) { card.setHeight(h) }  // the base suits the height typed
        var out = sizes
        if out.height == nil { out.height = card.sizes.height }
        if out.base == nil && !out.noBase { out.base = card.sizes.base }
        out.realHeight = card.sizes.realHeight
        return out
    }

    /// A real height at a table scale: an average human (1.8 m) is `scale` mm tall.
    public static func gameHeight(real: String, scale: Int) -> Double {
        ((metres(real) ?? 1.8) * Double(scale) / 1.8).rounded()
    }

    /// A typed real height in metres: "1.8", "1,80", or feet and inches: 6'2", 6 ft 2, 5 feet 9 in.
    /// Curly quotes too, which a Mac may type for ' and ". A plain number over 20 is centimetres
    /// (#335): no height over 13 m fits the slider even at 28 mm, while a giant of 8 m does.
    /// Nil when it can't be read, or isn't above 0.
    public static func metres(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        var m = Double(t).map { $0 > 20 ? $0 / 100 : $0 }
        if m == nil, let f = t.wholeMatch(of: #/(\d+(?:\.\d+)?)\s*(?:'|’|′|ft|feet|foot)\s*(?:(\d+(?:\.\d+)?)\s*(?:"|”|″|''|’’|in|inch|inches)?)?/#) {
            m = ((Double(f.1) ?? 0) * 12 + (f.2.flatMap { Double($0) } ?? 0)) * 0.0254
        }
        return m.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The line under the real height when what's typed can't be read, so 1.8 m isn't used unnoticed.
    public var realHeightProblem: String? {
        realHeight.trimmingCharacters(in: .whitespaces).isEmpty || Self.metres(realHeight) != nil ? nil
            : String(localized: "Couldn't read that, so it's using 1.8 m. Try 1.75 or 5'9\".", bundle: .mimicCore)
    }

    /// The round base for a character height: 40% of it, in steps of 5, 25 to 80 mm.
    public static func baseFor(_ height: Double) -> Double {
        min(80, max(25, (height * 0.4 / 5).rounded() * 5))
    }

    /// An object's suggested longest side on `nozzle` (nil is the 0.4 mm one).
    public static func objectHeight(nozzle: String?) -> Double { objectSize[nozzle ?? "0.4"] ?? 80 }

    /// The round base for an object, under its whole shadow: 80% of its longest side, in steps
    /// of 5, 25 to 80 mm.
    public static func objectBase(_ height: Double) -> Double {
        min(80, max(25, (height * 0.8 / 5).rounded() * 5))
    }

    /// An object's sizes in Terminal, as the card sizes one: its longest side as typed, else the
    /// suggested one, and no base unless `addBase`, then one under its whole shadow unless typed.
    public static func objectSizes(_ typed: Sizes, addBase: Bool) -> Sizes {
        var sizes = typed
        if !addBase { sizes.noBase = true }
        else if sizes.base == nil { sizes.base = text(objectBase(typed.height.flatMap(Double.init) ?? objectHeight(nozzle: typed.nozzle))) }
        if sizes.height == nil { sizes.height = text(objectHeight(nozzle: typed.nozzle)) }
        return sizes
    }

    public static func inflateFor(_ nozzle: String) -> Double {
        ((Double(nozzle) ?? 0.4) * 0.4 * 100).rounded() / 100
    }

    /// Keeps a typed or suggested value inside the slider's range, on its steps.
    public static func clamp(_ v: Double, _ range: ClosedRange<Double>, step: Double) -> Double {
        guard v.isFinite else { return range.lowerBound }
        let snapped = range.lowerBound + ((min(range.upperBound, max(range.lowerBound, v)) - range.lowerBound) / step).rounded() * step
        return (min(range.upperBound, snapped) * 100).rounded() / 100
    }

    /// "32", "0.16": how settings.json has always stored sizes.
    public static func text(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

/// Advice about the picture and the name, given before a 10-minute wait rather than after it.
public enum MakeAdvice {
    /// ⌘V in New Mini: a picture on the clipboard becomes the mini's picture, unless a text field
    /// is being typed in and there's text to paste too (a copied web page carries both).
    public static func pastesPicture(typing: Bool, hasText: Bool, hasPicture: Bool) -> Bool {
        hasPicture && !(typing && hasText)
    }

    /// What Make Mini is waiting for, said in the footer while the button is off, or nil. From a
    /// picture (`hasPicture`) or a typed `description`; `folder` is the name's (`Rules.folderName`),
    /// `newProject` the name typed for New Project… (nil for an existing one), `fix` the change
    /// typed for the picture, and `pictureNeed` what pictures still need, nil once they're ready.
    public static func missing(fromPicture: Bool, hasPicture: Bool, description: String, kind: MiniKind,
                               folder: String, newProject: String?, fix: String, pictureNeed: String?) -> String? {
        if fromPicture && !hasPicture { return String(localized: "Add a picture to start", bundle: .mimicCore) }
        if !fromPicture && description.isEmpty {
            return kind == .object ? String(localized: "Describe your object to start", bundle: .mimicCore)
                : String(localized: "Describe your character to start", bundle: .mimicCore)
        }
        if folder.isEmpty { return String(localized: "Give your mini a name", bundle: .mimicCore) }
        if let newProject, Rules.projectName(newProject) == nil { return String(localized: "Name the new project", bundle: .mimicCore) }
        guard let pictureNeed else { return nil }
        if !fromPicture { return String(localized: "A description needs \(pictureNeed) first", bundle: .mimicCore) }
        if !fix.isEmpty { return String(localized: "A change needs \(pictureNeed) first", bundle: .mimicCore) }
        return nil
    }

    /// The changes asked for in a new mini's picture (#156): the `earlier` ones of the mini it
    /// was filled in from, then `fix`, typed now (empty for none). From the picture it was given
    /// instead of the one it was drawn as (not `drawn`), the new change takes the place of the
    /// last. A description has none.
    public static func fixes(fromPicture: Bool, earlier: [String], fix: String, drawn: Bool) -> [String] {
        guard fromPicture else { return [] }
        guard !fix.isEmpty else { return earlier }
        return (drawn ? earlier : Array(earlier.dropLast())) + [fix]
    }

    /// Pixel sizes, not points: a 144 dpi picture is twice as big as it looks.
    public static func pictureWarnings(width: Int, height: Int, kind: MiniKind = .character) -> [String] {
        var notes: [String] = []
        if max(width, height) < 512 { notes.append(String(localized: "This picture is small, so the mini may come out blobby. A bigger picture works better.", bundle: .mimicCore)) }
        if kind == .character, Double(width) > Double(height) * 1.15 { notes.append(String(localized: "This picture is wider than it is tall, so it may not show the whole body. A full-body picture works best.", bundle: .mimicCore)) }
        return notes
    }

    /// "A dwarf cleric holding a warhammer" → "Dwarf Cleric": the name New Mini fills in, in the
    /// description's own letters ("élodie the druid" → "Élodie Druid"), each word capitalised.
    /// Its folder comes from it as a typed name's does (`Rules.folderName`).
    public static func name(fromDescription text: String) -> String {
        // The character is what comes before its gear: "a dwarf cleric holding a warhammer" is a
        // dwarf-cleric. Articles go wherever they are, and a name never ends on a joining word.
        let all = text.split(whereSeparator: \.isWhitespace)
        let kept = all.filter { !["a", "an", "the"].contains($0.lowercased()) }
        var words = Array(kept.isEmpty ? all : kept)
        let joining: Set = ["with", "and", "of", "in", "on", "at", "holding", "wearing", "carrying", "riding"]
        if let cut = words.firstIndex(where: { joining.contains($0.lowercased()) }), cut >= 2 { words = Array(words[..<cut]) }
        words = Array(words.prefix(4))
        while words.count > 1, let last = words.last, joining.contains(last.lowercased()) { words.removeLast() }
        let parts = words.joined(separator: " ").split { !$0.isLetter && !$0.isNumber }
        return Rules.shownName(parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")) ?? ""
    }
}

/// Slicer settings for each nozzle, shown under a mini and copied with one click.
public struct PrintTips: Sendable {
    public let nozzle: String
    public let layer: String
    public let walls: String
    public let expect: String
    public let kind: MiniKind

    public init(nozzle: String, kind: MiniKind = .character) {
        let object = kind == .object
        let t: (String, String, String) = switch nozzle {
        case "0.2": (String(localized: "Layer height 0.06–0.08 mm", bundle: .mimicCore), "3–4", object ? String(localized: "Crisp edges, small lettering and fine texture. Slow, but the most detail.", bundle: .mimicCore)
                                                                : String(localized: "Sharp faces, beard braids and belt buckles. Slow, but the most detail.", bundle: .mimicCore))
        case "0.6": (String(localized: "Layer height 0.2 mm", bundle: .mimicCore), "2–3", object ? String(localized: "Quick and sturdy; small details blur. Best for big, simple shapes.", bundle: .mimicCore)
                                                          : String(localized: "Quick and sturdy; small details blur. Best at 54 mm scale or bigger.", bundle: .mimicCore))
        default: (String(localized: "Layer height 0.12 mm", bundle: .mimicCore), "3", object ? String(localized: "Shapes and edges come out clearly; fine texture gets softened. A good balance.", bundle: .mimicCore)
                                                      : String(localized: "Faces and weapons come out clearly; hair strands and cloth edges get softened. A good balance.", bundle: .mimicCore))
        }
        self.nozzle = Rules.nozzles.contains(nozzle) ? nozzle : "0.4"
        self.kind = kind
        (layer, walls, expect) = t
    }

    private var placing: (line: String, short: String) {
        kind == .object ? (String(localized: "Print it as it sits: its bottom is already flat. Add a brim if it's tall and narrow.", bundle: .mimicCore), String(localized: "Flat side down", bundle: .mimicCore))
                        : (String(localized: "Stand the mini upright on its base. No brim needed.", bundle: .mimicCore), String(localized: "Upright on its base, no brim", bundle: .mimicCore))
    }
    public var lines: [String] {
        [String(localized: "\(layer). Supports: Tree (auto). Walls: \(walls).", bundle: .mimicCore), placing.line, expect]
    }
    public var copyText: String { String(localized: "\(layer) · Supports: Tree (auto) · Walls: \(walls) · \(placing.short)", bundle: .mimicCore) }

    /// What a mini was made at, as its page lists it: Character 32 mm, Base 25 mm, Nozzle 0.4 mm.
    /// An object's first row is its longest side, and its base may be None. A base that isn't
    /// round says so, and so does a floor on it: Base 25 mm hex, stone floor.
    public static func made(_ made: Sizes, kind: MiniKind = .character) -> [(label: String, value: String)] {
        [(kind == .object ? String(localized: "Longest side", bundle: .mimicCore) : String(localized: "Character", bundle: .mimicCore),
          String(localized: "\(mm(made.height, 32)) mm", bundle: .mimicCore)),
         (String(localized: "Base", bundle: .mimicCore), kind == .object && made.noBase ? String(localized: "None", bundle: .mimicCore)
            : String(localized: "\(mm(made.base, 25)) mm", bundle: .mimicCore) + (made.shape == .round ? "" : " \(made.shape.words)")
            + (made.style == .plain ? "" : ", \(made.style.words)")
            + (made.magnet.map { String(localized: ", \($0.words) magnet hole", bundle: .mimicCore) } ?? "")),
         (String(localized: "Nozzle", bundle: .mimicCore), String(localized: "\(made.nozzle ?? "0.4") mm", bundle: .mimicCore))]
    }

    /// "32 mm · 0.4 mm nozzle": under a finished mini's name in the gallery.
    public static func shortLine(_ made: Sizes) -> String { String(localized: "\(mm(made.height, 32)) mm · \(made.nozzle ?? "0.4") mm nozzle", bundle: .mimicCore) }

    /// A size in whole millimetres; missing, 0 or not a number of millimetres ("inf", 1e20 from a
    /// hand edit, #307) is the default.
    private static func mm(_ s: String?, _ fallback: Double) -> Int {
        s.flatMap(Double.init).flatMap { $0 == 0 ? nil : Int(exactly: $0.rounded()) } ?? Int(fallback.rounded())
    }
}

/// How much filament a print file takes: its volume printed solid, in PLA on 1.75 mm filament.
/// Small minis print nearly solid (their walls meet in the middle); infill makes a big one take
/// less, and supports a little more. So it's "up to", a rough figure for a spool running low.
public enum Filament {
    /// PLA, g/cm³.
    static let density = 1.24
    /// 1.75 mm filament's cross-section, mm².
    static let area = Double.pi * 0.875 * 0.875

    /// mm³ inside a closed surface given as separate triangles, three corners each (an STL).
    public static func volume(_ corners: [SIMD3<Float>]) -> Double {
        var six = 0.0
        for t in stride(from: 0, to: corners.count - 2, by: 3) {
            six += Double(simd_dot(corners[t], simd_cross(corners[t + 1], corners[t + 2])))
        }
        return abs(six) / 6
    }

    /// A print file's volume, read again only when its time changes: a project's total is added
    /// up whenever any of its minis changes, and each print file is tens of megabytes (#340).
    public static func volume(stl: URL) -> Double? {
        let time = (try? FileManager.default.attributesOfItem(atPath: stl.path))?[.modificationDate] as? Date
        if let time, let kept = known.withLock({ $0[stl.path] }), kept.time == time { return kept.volume }
        guard let v = (try? STL.read(stl)).map(volume) else { return nil }
        if let time { known.withLock { $0[stl.path] = (time, v) } }
        return v
    }
    /// Never emptied: one entry per print file looked at, a few bytes each.
    private static let known = Mutex<[String: (time: Date, volume: Double)]>([:])

    public static func grams(_ mm3: Double) -> Double { mm3 / 1000 * density }

    /// Metres of 1.75 mm filament.
    public static func metres(_ mm3: Double) -> Double { mm3 / area / 1000 }

    /// Whole grams, 1 for less: never 0 g.
    static func wholeGrams(_ mm3: Double) -> Int { max(1, Int(grams(mm3).rounded())) }

    /// "≈ 4 g filament", beside a project's name.
    public static func short(_ mm3: Double) -> String { String(localized: "≈ \(String(wholeGrams(mm3))) g filament", bundle: .mimicCore) }

    /// "Up to 4 g · 1.3 m": grams of PLA, metres of 1.75 mm filament.
    public static func words(_ mm3: Double) -> String {
        let metres = max(0.1, metres(mm3))
        return String(localized: "Up to \(String(wholeGrams(mm3))) g · \(String(format: "%.1f", metres)) m", bundle: .mimicCore)
    }
}
