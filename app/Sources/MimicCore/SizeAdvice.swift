import Foundation
import simd

/// The size card of the Make and Resize sheets: what the mini is for, the nozzle, and the
/// sizes those suggest. Ported number for number from the web page's size card.
///
/// Choosing a purpose, scale, nozzle or real height means "size it for me again"; moving a
/// slider or typing a value means "I'll size it", and the suggestion leaves that value alone.
public struct SizeCard: Equatable, Sendable {
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
        // The choice shown is the one these sizes match, not the last New Mini's.
        // An object's one choice is its suggested size.
        if kind == .object { purpose = height == Self.objectSize[nozzle] ? .display : nil }
        else if height == Self.bestPrint[nozzle] { purpose = .display }
        else if let s = Self.scales.first(where: { Double($0) == height }) { purpose = .game; scale = s; realHeight = "" }
        else { purpose = nil }
        suggest()  // refreshes the note; touched values stay
    }

    /// What print prep is asked for. The extra thickness is sent only when chosen by hand:
    /// otherwise print prep picks it from the nozzle itself.
    public var sizes: Sizes {
        Sizes(height: Self.text(height), base: Self.text(base), nozzle: nozzle,
              inflate: inflateTouched ? Self.text(inflate) : nil, noBase: noBase, shape: shape, style: style, magnet: magnet)
    }

    private mutating func resuggest() { heightTouched = false; baseTouched = false; suggest() }

    private mutating func suggest() {
        let h: Double
        warns = false
        switch (kind, purpose) {
        case (.object, nil):  // loaded at another size than the suggestion: the note is about the size it is
            h = height
            let best = Self.objectSize[nozzle] ?? 80
            note = h < best ? "At \(Int(h)) mm, a \(nozzle) mm nozzle softens fine details a little. For the clearest details, make it about \(Int(best)) mm on its longest side." : ""
        case (.object, _):
            h = Self.objectSize[nozzle] ?? 80
            note = "Sized so details come out clearly on a \(nozzle) mm nozzle: about \(Int(h)) mm on its longest side. Change it to the size you want."
        case (_, .game), (_, nil):  // nil: loaded sizes that match neither, so the note is about their height
            h = purpose == .game ? Self.gameHeight(real: realHeight, scale: scale) : height
            note = ""
            // The default (32 mm on a 0.4 nozzle) gets a tip, not a warning: it prints fine,
            // faces just come out a little soft. Only really small sizes, or a 0.6 nozzle under
            // its 54 mm sweet spot (see PrintTips), turn faces into bumps.
            if (nozzle == "0.4" && h < 28) || (nozzle == "0.6" && h < 50) {
                note = "At \(Int(h)) mm, a \(nozzle) mm nozzle turns faces into bumps. Use a 0.2 mm nozzle, or choose Best print."
                warns = true
            } else if nozzle == "0.4" && h < 50 {
                note = "At \(Int(h)) mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose Best print."
            }
        case (_, .display):
            h = Self.bestPrint[nozzle] ?? 100
            note = "Sized so faces come out clearly on a \(nozzle) mm nozzle: about \(Int(h)) mm tall. Chunky characters also look good a bit smaller."
        }
        // The note names the height as worked out; the slider can only hold its own range.
        if !heightTouched { height = Self.clamp(h, Self.heightRange, step: 1) }
        // An object's base goes under its whole shadow, which is about its longest side.
        if !baseTouched {
            base = kind == .object ? min(80, max(25, (height * 0.8 / 5).rounded() * 5))
                : max(purpose == .game ? Self.scaleBase[scale] ?? 25 : 25, Self.baseFor(height))
        }
    }

    /// "28, 32, 35, 54 or 75", for Terminal's --scale.
    public static var scaleChoices: String {
        scales.dropLast().map(String.init).joined(separator: ", ") + " or \(scales.last!)"
    }

    /// `--scale` in Terminal: Game scale's height (an average 1.8 m human) and base, for what
    /// wasn't typed, so Terminal sizes a mini as the app does. Nil for a scale not in `scales`.
    public static func gameSizes(scale: Int, filling sizes: Sizes) -> Sizes? {
        guard scales.contains(scale) else { return nil }
        var card = SizeCard(purpose: .game, nozzle: sizes.nozzle ?? "0.4")
        card.setScale(scale)
        if let h = sizes.height.flatMap(Double.init) { card.setHeight(h) }  // the base suits the height typed
        var out = sizes
        if out.height == nil { out.height = card.sizes.height }
        if out.base == nil && !out.noBase { out.base = card.sizes.base }
        return out
    }

    /// A real height at a table scale: an average human (1.8 m) is `scale` mm tall.
    public static func gameHeight(real: String, scale: Int) -> Double {
        ((metres(real) ?? 1.8) * Double(scale) / 1.8).rounded()
    }

    /// A typed real height in metres: "1.8", "1,80", or feet and inches: 6'2", 6 ft 2, 5 feet 9 in.
    /// Curly quotes too, which a Mac may type for ' and ". Nil when it can't be read, or isn't above 0.
    public static func metres(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        var m = Double(t)
        if m == nil, let f = t.wholeMatch(of: #/(\d+(?:\.\d+)?)\s*(?:'|’|′|ft|feet|foot)\s*(?:(\d+(?:\.\d+)?)\s*(?:"|”|″|''|’’|in|inch|inches)?)?/#) {
            m = ((Double(f.1) ?? 0) * 12 + (f.2.flatMap { Double($0) } ?? 0)) * 0.0254
        }
        return m.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The line under the real height when what's typed can't be read, so 1.8 m isn't used unnoticed.
    public var realHeightProblem: String? {
        realHeight.trimmingCharacters(in: .whitespaces).isEmpty || Self.metres(realHeight) != nil ? nil
            : "Couldn't read that, so it's using 1.8 m. Try 1.75 or 5'9\"."
    }

    /// The round base for a character height: 40% of it, in steps of 5, 25 to 80 mm.
    public static func baseFor(_ height: Double) -> Double {
        min(80, max(25, (height * 0.4 / 5).rounded() * 5))
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

    /// Pixel sizes, not points: a 144 dpi picture is twice as big as it looks.
    public static func pictureWarnings(width: Int, height: Int, kind: MiniKind = .character) -> [String] {
        var notes: [String] = []
        if max(width, height) < 512 { notes.append("This picture is small, so the mini may come out blobby. A bigger picture works better.") }
        if kind == .character, Double(width) > Double(height) * 1.15 { notes.append("This picture is wider than it is tall, so it may not show the whole body. A full-body picture works best.") }
        return notes
    }

    /// "A dwarf cleric holding a warhammer" → "dwarf-cleric-holding-a": the first four words,
    /// skipping a leading a, an or the.
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
        return Rules.slug(words.joined(separator: " "))
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
        case "0.2": ("Layer height 0.06–0.08 mm", "3–4", object ? "Crisp edges, small lettering and fine texture. Slow, but the most detail."
                                                                : "Sharp faces, beard braids and belt buckles. Slow, but the most detail.")
        case "0.6": ("Layer height 0.2 mm", "2–3", object ? "Quick and sturdy; small details blur. Best for big, simple shapes."
                                                          : "Quick and sturdy; small details blur. Best at 54 mm scale or bigger.")
        default: ("Layer height 0.12 mm", "3", object ? "Shapes and edges come out clearly; fine texture gets softened. A good balance."
                                                      : "Faces and weapons come out clearly; hair strands and cloth edges get softened. A good balance.")
        }
        self.nozzle = Rules.nozzles.contains(nozzle) ? nozzle : "0.4"
        self.kind = kind
        (layer, walls, expect) = t
    }

    private var placing: (line: String, short: String) {
        kind == .object ? ("Print it as it sits: its bottom is already flat. Add a brim if it's tall and narrow.", "Flat side down")
                        : ("Stand the mini upright on its base. No brim needed.", "Upright on its base, no brim")
    }
    public var lines: [String] {
        ["\(layer). Supports: Tree (auto). Walls: \(walls).", placing.line, expect]
    }
    public var copyText: String { "\(layer) · Supports: Tree (auto) · Walls: \(walls) · \(placing.short)" }

    /// What a mini was made at, as its page lists it: Character 32 mm, Base 25 mm, Nozzle 0.4 mm.
    /// An object's first row is its longest side, and its base may be None. A base that isn't
    /// round says so, and so does a floor on it: Base 25 mm hex, stone floor.
    public static func made(_ made: Sizes, kind: MiniKind = .character) -> [(label: String, value: String)] {
        [(kind == .object ? "Longest side" : "Character", "\(mm(made.height, 32)) mm"),
         ("Base", kind == .object && made.noBase ? "None" : "\(mm(made.base, 25)) mm" + (made.shape == .round ? "" : " \(made.shape.rawValue)")
            + (made.style == .plain ? "" : ", \(made.style.words)") + (made.magnet.map { ", \($0.words) magnet hole" } ?? "")),
         ("Nozzle", "\(made.nozzle ?? "0.4") mm")]
    }

    /// "32 mm · 0.4 mm nozzle": under a finished mini's name in the gallery.
    public static func shortLine(_ made: Sizes) -> String { "\(mm(made.height, 32)) mm · \(made.nozzle ?? "0.4") mm nozzle" }

    /// A size in whole millimetres; missing or 0 is the default.
    private static func mm(_ s: String?, _ fallback: Double) -> Int {
        Int((s.flatMap(Double.init).flatMap { $0 == 0 ? nil : $0 } ?? fallback).rounded())
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

    public static func volume(stl: URL) -> Double? { (try? STL.read(stl)).map(volume) }

    public static func grams(_ mm3: Double) -> Double { mm3 / 1000 * density }

    /// "up to 4 g", "up to 1 g" for less: whole grams.
    public static func short(_ mm3: Double) -> String { "up to \(max(1, Int(grams(mm3).rounded()))) g" }

    /// "Up to 4 g · 1.3 m": grams of PLA, metres of 1.75 mm filament.
    public static func words(_ mm3: Double) -> String {
        let metres = max(0.1, mm3 / area / 1000)
        return short(mm3).capitalizedFirst + String(format: " · %.1f m", metres)
    }
}
