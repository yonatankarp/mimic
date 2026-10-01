import MimicCore
import SwiftUI
import TipKit

extension SizeCard {
    /// The kind, purpose, nozzle and base last chosen: most people keep one printer.
    static func remembered() -> SizeCard {
        let d = UserDefaults.standard
        var card = SizeCard(purpose: Purpose(rawValue: d.string(forKey: "purpose") ?? "") ?? .game,
                            nozzle: d.string(forKey: "nozzle") ?? "0.4",
                            kind: MiniKind(rawValue: d.string(forKey: "kind") ?? "") ?? .character)
        card.shape = BaseShape(rawValue: d.string(forKey: "baseShape") ?? "") ?? .round  // a hex-map player wants hex every time
        card.style = BaseStyle(rawValue: d.string(forKey: "baseStyle") ?? "") ?? .plain
        card.magnet = Magnet(rawValue: d.string(forKey: "magnet") ?? "")  // a player who magnetises does it every time
        return card
    }
}

/// The size card, shared by Make and Resize. Sliders and typed values both go through the
/// card's setters, which keep them in range.
struct SizeSection: View {
    @Binding var card: SizeCard
    /// The variation number; nil for a resize, which doesn't draw anything.
    var seed: Binding<Int>?
    @State private var advanced = false

    var body: some View {
        Section {
            printerRows
            gameScaleRows
            heightRows
            baseRows
            advancedRows
        } header: {
            Label("Size & printer", systemImage: "ruler")
        }
        .onChange(of: card.purpose) { _, p in if let p { UserDefaults.standard.set(p.rawValue, forKey: "purpose") } }
        .onChange(of: card.nozzle) { _, n in UserDefaults.standard.set(n, forKey: "nozzle") }
        .onChange(of: card.shape) { _, s in UserDefaults.standard.set(s.rawValue, forKey: "baseShape") }
        .onChange(of: card.style) { _, s in UserDefaults.standard.set(s.rawValue, forKey: "baseStyle") }
        .onChange(of: card.magnet) { _, m in UserDefaults.standard.set(m?.rawValue ?? "", forKey: "magnet") }
    }

    /// What the size is for, and the nozzle it prints with.
    @ViewBuilder private var printerRows: some View {
        if !object {  // an object is sized by its longest side: no scale to match
            Picker(selection: bind(\.purpose, { if let p = $1 { $0.setPurpose(p) } })) {
                Text("Game scale").tag(SizeCard.Purpose.game as SizeCard.Purpose?)
                Text("Best print").tag(SizeCard.Purpose.display as SizeCard.Purpose?)
            } label: {
                // Each note is its control's subtitle, not a row of its own: the column fits unscrolled.
                Label {
                    Text("Size for")
                    if gameScale { Text("Matches the other minis on your table.") }  // Best print explains itself in its note below
                } icon: { Image(systemName: card.purpose == .display ? "sparkles" : "dice") }
            }
            .pickerStyle(.segmented)
            .help("Match your other minis, or go big enough for clear faces")
        }
        Picker(selection: bind(\.nozzle, { $0.setNozzle($1) })) {
            Text("0.2 mm · fine").tag("0.2")
            Text("0.4 mm · standard").tag("0.4")
            Text("0.6 mm · fast").tag("0.6")
        } label: {
            Label {
                Text("Nozzle")
                Text("Not sure? Most printers come with 0.4 mm. Choose the same nozzle in your slicer.")
            } icon: { Image(systemName: "printer") }
        }
        .pickerStyle(.segmented)
        .help("The tip your printer prints through; finer keeps more detail")
        .popoverTip(Tips.unlessTouring(SizeTip()), arrowEdge: .top)
    }

    /// At game scale: the character's real height and the table's scale.
    @ViewBuilder private var gameScaleRows: some View {
        if gameScale {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("", text: bind(\.realHeight, { $0.setRealHeight($1) }), prompt: Text("1.80"))
                        .labelsHidden().accessibilityLabel("How tall is the character?")
                        .frame(width: 64).multilineTextAlignment(.trailing)
                        .help("How tall the character would be in real life, in metres or feet.")
                    Text("m")
                }
                .fixedSize()  // the label's long hint wraps instead of squeezing "1.80" (#167)
            } label: {
                Text("How tall is the character?")
                // SizeCard.gameHeight: blank, or what can't be read, counts as 1.8 m; the problem says so.
                if let problem = card.realHeightProblem {
                    Text(problem).foregroundStyle(.orange)
                } else {
                    Text("In metres or feet: 1.75, or 5'9\". A halfling ≈ 1 m. Leave blank for an average human (1.8 m).")
                }
            }
            Picker(selection: bind(\.scale, { $0.setScale($1) })) {
                Text("28 mm").tag(28)
                Text("32 mm · most common").tag(32)
                Text("35 mm · heroic").tag(35)
                Text("54 mm").tag(54)
                Text("75 mm").tag(75)
            } label: {
                Text("Scale")
                Text("Pick the scale your other minis use. At 32 mm, an average 1.8 m human stands 32 mm tall.")
            }
            .pickerStyle(.menu)  // five choices don't fit a segmented row in the smallest column
            .help("How tall an average human is on the table")
        }
    }

    /// The card's note, and how tall it is.
    @ViewBuilder private var heightRows: some View {
        if !card.note.isEmpty {
            Label(card.note, systemImage: card.warns ? "exclamationmark.triangle.fill" : "lightbulb")
                .font(.callout).foregroundStyle(card.warns ? .orange : .secondary)
        }
        if object {
            slider("Longest side", \.height, { $0.setHeight($1) }, SizeCard.heightRange, unit: "mm",
                   hint: "Its biggest size, whichever way that is: height, width or depth. Set for your nozzle; type a value or drag to change it.")
            Toggle("Add a base", isOn: Binding(get: { !card.noBase }, set: { card.noBase = !$0 }))
                .help("Off: it stands on its own flat bottom")
        } else {
            slider("Character height", \.height, { $0.setHeight($1) }, SizeCard.heightRange, unit: "mm",
                   hint: "Set for you by the choices above; type a value or drag to change it. The base adds about 2 mm.")
        }
    }

    /// The base's shape, top and size, when it has one.
    @ViewBuilder private var baseRows: some View {
        if !object || !card.noBase {
            // Shape and top on one row, so the column still fits unscrolled.
            LabeledContent("Base") {
                HStack {
                    Picker("Shape", selection: $card.shape) {
                        Text("Round").tag(BaseShape.round)
                        Text("Square").tag(BaseShape.square)
                        Text("Hex").tag(BaseShape.hex)
                    }
                    .pickerStyle(.segmented).fixedSize()
                    .help("Square and hex bases fit grid and hex maps; the figure faces a flat side")
                    Picker("Base style", selection: $card.style) {
                        ForEach(BaseStyle.allCases, id: \.self) { Text($0.words.capitalizedFirst).tag($0) }
                    }
                    .fixedSize()
                    .help("Plain, or a floor pressed into the top of the base: flagstones, planks or cobblestones")
                }
                .labelsHidden()
            }
            slider("Base size", \.base, { $0.setBase($1) }, SizeCard.baseRange, unit: "mm",
                   hint: card.shape == .hex ? "Across the flat sides." : nil, ticks: [25, 32, 40, 50])
                .help(baseHelp)
        }
    }

    /// Advanced: thin parts, a magnet hole, the own base and the variation number.
    @ViewBuilder private var advancedRows: some View {
        // A plain button as the label, so a click or VoiceOver's press on the words opens it too.
        DisclosureGroup(isExpanded: $advanced) {
            slider("Extra thickness for thin parts", \.inflate, { $0.setInflate($1) }, SizeCard.inflateRange, unit: "mm",
                   hint: "Set by your nozzle. More keeps swords and capes in one piece, but softens faces.", decimals: 2)
            if !card.noBase {
                Picker(selection: $card.magnet) {
                    Text("None").tag(Magnet?.none)
                    ForEach(Magnet.allCases, id: \.self) { Text($0.words).tag(Magnet?.some($0)) }
                } label: {
                    Text("Magnet hole")
                    Text("A hole under the base to glue a magnet into, with a little room to spare. The base gets a little taller to fit it.")
                }
                .help("For round magnets, sized across by tall")
            }
            if !object {
                Toggle("Use the character's own base instead of adding one", isOn: $card.noBase)
                    .help("For a character already on a base or a rock: Mimic flattens that")
            }
            if let seed {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Variation number") {
                        TextField("", value: seed, format: .number.grouping(.never)).labelsHidden().frame(width: 90)
                            .accessibilityLabel("Variation number")
                    }
                    Text("Same description + same number = same drawing. Change it for a different take.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } label: {
            Button("Advanced") { withAnimation { advanced.toggle() } }.buttonStyle(.plain)
        }
    }

    private var object: Bool { card.kind == .object }
    private var baseHelp: String {
        switch card.shape {
        case .round: object ? "How wide the round base is" : "How wide the round base is; 25 mm fits one map square"
        case .square: object ? "How long each side of the square base is" : "How long each side of the square base is; 25 mm fits one map square"
        case .hex: "How wide the hex base is, flat side to flat side; 25 mm fits one hex on a 1-inch hex map"
        }
    }
    private var gameScale: Bool { !object && card.purpose == .game }

    private func bind<T>(_ get: KeyPath<SizeCard, T>, _ set: @escaping (inout SizeCard, T) -> Void) -> Binding<T> {
        Binding(get: { card[keyPath: get] }, set: { v in set(&card, v) })
    }

    private func slider(_ label: String, _ get: KeyPath<SizeCard, Double>, _ set: @escaping (inout SizeCard, Double) -> Void,
                        _ range: ClosedRange<Double>, unit: String, hint: String?, decimals: Int = 0, ticks: [Double] = []) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("", value: bind(get, set), format: .number.precision(.fractionLength(0...decimals)).grouping(.never))
                        .labelsHidden().accessibilityLabel(label).frame(width: 56).multilineTextAlignment(.trailing)
                    Text(unit)
                }
                .fixedSize()  // as the real height's field: the hint wraps, the number stays whole
            } label: {
                Text(label)
                if let hint { Text(hint) }
            }
            Group {
                if ticks.isEmpty { Slider(value: bind(get, set), in: range) } else { TickedSlider(value: bind(get, set), range: range, ticks: ticks) }
            }
            .labelsHidden().accessibilityLabel(label)
        }
    }
}

/// A slider with tick marks at common sizes (the base's 25, 32, 40 and 50 mm). The value still
/// goes through the card's setter, so typing any size in the field beside it keeps working.
private struct TickedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let ticks: [Double]

    var body: some View {
        Slider(value: $value, in: range) {
            EmptyView()
        } ticks: {
            SliderTickContentForEach(ticks, id: \.self) { SliderTick($0) }
        }
    }
}
