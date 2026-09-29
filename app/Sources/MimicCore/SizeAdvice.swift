import Foundation

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
    public static let scales = [28, 32, 54]
    /// Best print sizes the figure so faces come out on the chosen nozzle: judged on a
    /// realistic-proportion character (a 2 m tiefling), faces read from about 64 mm on a 0.2
    /// nozzle and 100 mm on a 0.4; 0.6 is extrapolated.
    public static let bestPrint: [String: Double] = ["0.2": 64, "0.4": 100, "0.6": 150]

    public private(set) var purpose: Purpose
    public private(set) var nozzle: String
    public private(set) var scale = 32
    /// Metres, as typed. Blank (or not a number) counts as an average human, 1.8 m.
    public private(set) var realHeight = ""
    public private(set) var height = 32.0
    public private(set) var base = 25.0
    public private(set) var inflate: Double
    public var noBase = false
    public private(set) var heightTouched = false, baseTouched = false, inflateTouched = false
    /// The line under the size choices, and whether it's a warning.
    public private(set) var note = ""
    public private(set) var warns = false

    public init(purpose: Purpose = .game, nozzle: String = "0.4") {
        self.purpose = purpose
        self.nozzle = Rules.nozzles.contains(nozzle) ? nozzle : "0.4"
        inflate = Self.inflateFor(self.nozzle)
        suggest()
    }

    public mutating func setPurpose(_ p: Purpose) { purpose = p; resuggest() }
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
        suggest()  // refreshes the note; touched values stay
    }

    /// What print prep is asked for. The extra thickness is sent only when chosen by hand:
    /// otherwise print prep picks it from the nozzle itself.
    public var sizes: Sizes {
        Sizes(height: Self.text(height), base: Self.text(base), nozzle: nozzle,
              inflate: inflateTouched ? Self.text(inflate) : nil, noBase: noBase)
    }

    private mutating func resuggest() { heightTouched = false; baseTouched = false; suggest() }

    private mutating func suggest() {
        let h: Double
        warns = false
        switch purpose {
        case .game:
            h = Self.gameHeight(real: realHeight, scale: scale)
            note = ""
            // The default (32 mm on a 0.4 nozzle) gets a tip, not a warning: it prints fine,
            // faces just come out a little soft. Only really small sizes, or a 0.6 nozzle under
            // its 54 mm sweet spot (see PrintTips), turn faces into bumps.
            if (nozzle == "0.4" && h < 28) || (nozzle == "0.6" && h < 50) {
                note = "⚠️ At \(Int(h)) mm, a \(nozzle) mm nozzle turns faces into bumps. Use a 0.2 mm nozzle, or choose ✨ Best print."
                warns = true
            } else if nozzle == "0.4" && h < 50 {
                note = "💡 At \(Int(h)) mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose ✨ Best print."
            }
        case .display:
            h = Self.bestPrint[nozzle] ?? 100
            note = "✨ Sized so faces come out clearly on a \(nozzle) mm nozzle: about \(Int(h)) mm tall. Chunky characters also look good a bit smaller."
        }
        // The note names the height as worked out; the slider can only hold its own range.
        if !heightTouched { height = Self.clamp(h, Self.heightRange, step: 1) }
        if !baseTouched { base = Self.baseFor(height) }
    }

    /// A real height at a table scale: an average human (1.8 m) is `scale` mm tall.
    public static func gameHeight(real: String, scale: Int) -> Double {
        let r = Double(real.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite && $0 != 0 ? $0 : nil } ?? 1.8
        return (r * Double(scale) / 1.8).rounded()
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
    /// Pixel sizes, not points: a 144 dpi picture is twice as big as it looks.
    public static func pictureWarnings(width: Int, height: Int) -> [String] {
        var notes: [String] = []
        if max(width, height) < 512 { notes.append("⚠️ This picture is small, so the mini may come out blobby. A bigger picture works better.") }
        if Double(width) > Double(height) * 1.15 { notes.append("⚠️ This picture is wider than it is tall, so it may not show the whole body. A full-body picture works best.") }
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

    public init(nozzle: String) {
        let t: (String, String, String) = switch nozzle {
        case "0.2": ("Layer height 0.06–0.08 mm", "3–4", "Sharp faces, beard braids and belt buckles. Slow, but the most detail.")
        case "0.6": ("Layer height 0.2 mm", "2–3", "Quick and sturdy; small details blur. Best at 54 mm scale or bigger.")
        default: ("Layer height 0.12 mm", "3", "Faces and weapons come out clearly; hair strands and cloth edges get softened. A good balance.")
        }
        self.nozzle = Rules.nozzles.contains(nozzle) ? nozzle : "0.4"
        (layer, walls, expect) = t
    }

    public var lines: [String] {
        ["\(layer). Supports: Tree (auto). Walls: \(walls).", "Stand the mini upright on its base. No brim needed.", expect]
    }
    public var copyText: String { "\(layer) · Supports: Tree (auto) · Walls: \(walls) · Upright on its base, no brim" }

    /// "Now: 32 mm character · 25 mm base · made for a 0.2 mm nozzle"
    public static func nowLine(_ made: Sizes) -> String {
        func mm(_ s: String?, _ fallback: Double) -> Int { Int((s.flatMap(Double.init).flatMap { $0 == 0 ? nil : $0 } ?? fallback).rounded()) }
        return "Now: \(mm(made.height, 32)) mm character · \(mm(made.base, 25)) mm base · made for a \(made.nozzle ?? "0.4") mm nozzle"
    }
}
