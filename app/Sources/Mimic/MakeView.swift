import AppKit
import ImageIO
import MimicCore
import SwiftUI
import UniformTypeIdentifiers

/// The Make a Mini sheet (⌘N): a picture or a description, a name, and the size card.
struct MakeView: View {
    enum Start: String { case picture, description }

    @Environment(AppModel.self) private var model
    @State private var start = Start.picture
    @State private var picture: Picture?
    @State private var choosing = false
    @State private var dropTargeted = false
    @State private var restyle = true
    @State private var description = ""
    @State private var name = ""
    @State private var seed = 42
    @State private var card = SizeCard.remembered()
    @State private var message: String?
    @State private var messageIsError = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("🧙 Your character") {
                    Picker("Start from", selection: $start) {
                        Text("🖼️ From a picture").tag(Start.picture)
                        Text("✍️ Describe it").tag(Start.description)
                    }
                    .pickerStyle(.segmented)
                    if start == .picture { picturePane } else { descriptionPane }
                    TextField("Name your mini", text: $name, prompt: Text("e.g. Dwarf Cleric"))
                        .focused($nameFocused)
                        .onChange(of: name) { _, new in
                            if new != Mini.displayName(MakeAdvice.name(fromDescription: description)) { autoName = false }
                        }
                    if let taken = takenName {
                        Text("You already have a mini called \(taken). Pick a new name, or use Resize This Mini to change its size.")
                            .font(.callout).foregroundStyle(.red)
                    }
                }
                SizeSection(card: $card, seed: $seed)
            }
            .formStyle(.grouped)

            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let reason = model.cantStart {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let message {
                    Text(message).foregroundStyle(messageIsError ? .red : .secondary)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("✨ Make My Mini") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.cantStart != nil || takenName != nil)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580, height: 720)
        .task { await model.watchDrawThings() }
        // ⌘V: a picture on the clipboard becomes the picture; anything else pastes as usual.
        .background { Button("") { paste() }.keyboardShortcut("v").hidden() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { take(url) }
        }
    }

    @State private var autoName = false

    // MARK: Picture

    private var picturePane: some View {
        Group {
            Button { choosing = true } label: {
                VStack(spacing: 6) {
                    if let picture {
                        Image(nsImage: picture.image).resizable().scaledToFit().frame(maxHeight: 180)
                        Text(picture.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "photo.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Drop a picture, paste it (⌘V), or click to choose")
                        Text("Full body, head to feet, plain background").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .padding(10)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a picture")
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                take(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            ForEach(picture?.warnings ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            Toggle(isOn: $restyle) {
                Text("Turn it into a grey sculpt first (recommended)")
                Text("Best for drawings and photos. Turn it off only if your picture is already a grey 3D model.")
            }
            .disabled(!model.drawThingsReady)
            if !model.drawThingsReady { needsDrawThings }
        }
    }

    private var descriptionPane: some View {
        Group {
            TextEditor(text: $description)
                .frame(minHeight: 70)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("e.g. dwarf cleric holding a warhammer against his chest, shield on his back")
                            .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .onChange(of: description) { _, text in
                    guard name.isEmpty || autoName else { return }
                    name = Mini.displayName(MakeAdvice.name(fromDescription: text))
                    autoName = true
                }
            Button("🎲 Try a Different Version") {
                seed = Int.random(in: 0..<1_000_000)
                say("🎲 Next version picked. Press Make My Mini.")
            }
            if !model.drawThingsReady { needsDrawThings }
        }
    }

    private var needsDrawThings: some View {
        Text("Needs Draw Things. Open Settings to see how to set it up.").font(.callout).foregroundStyle(.secondary)
    }

    private func take(_ url: URL, pasted: Bool = false) {
        guard let p = Picture(url) else { return say("That picture can't be read.", error: true) }
        picture = p
        start = .picture
        message = nil
        if name.isEmpty {
            if pasted { say("📋 Picture pasted. Give your mini a name."); nameFocused = true }
            else { name = Mini.displayName(Rules.slug(url.deletingPathExtension().lastPathComponent)) }
        }
    }

    private func paste() {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first {
            return take(url)
        }
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted picture \(UUID().uuidString.prefix(8)).png")
            if (try? png.write(to: url)) != nil { return take(url, pasted: true) }
        }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }

    // MARK: Making

    private var slug: String { Rules.slug(name) }

    private var takenName: String? {
        guard let runs = model.install?.runs, !slug.isEmpty,
              FileManager.default.fileExists(atPath: runs.appendingPathComponent(slug).appendingPathComponent("model.glb").path)
        else { return nil }
        return Mini.displayName(slug)
    }

    private func make() {
        guard !slug.isEmpty else { return say("Give your mini a name first.", error: true) }
        let source: PictureSource
        switch start {
        case .picture:
            guard let picture else { return say("Choose a picture first.", error: true) }
            source = .image(picture.url)
        case .description:
            guard model.drawThingsReady else { return say("✍️ Describe it needs Draw Things. Open Settings to see how to set it up.", error: true) }
            let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty else { return say("Describe the character first.", error: true) }
            source = .description(d)
        }
        do {
            try model.make(name: slug, picture: source, restyle: start == .picture && restyle && model.drawThingsReady,
                           seed: seed, sizes: card.sizes)
        } catch {
            say("\(error)", error: true)
        }
    }

    private func say(_ text: String, error: Bool = false) { message = text; messageIsError = error }
}

/// A picture chosen for a new mini, with its warnings worked out from its real pixel size.
struct Picture {
    let url: URL
    let image: NSImage
    let warnings: [String]

    init?(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = NSImage(contentsOf: url) else { return nil }
        // Photos taken sideways say so in their orientation; the picture is shown turned upright.
        let turned = [5, 6, 7, 8].contains(props[kCGImagePropertyOrientation] as? Int ?? 1)
        self.url = url
        self.image = image
        warnings = MakeAdvice.pictureWarnings(width: turned ? h : w, height: turned ? w : h)
    }
}

/// Resize This Mini: the size card, loaded with what the mini is now.
struct ResizeView: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    @State private var card: SizeCard
    @State private var problem: String?

    init(mini: Mini) {
        self.mini = mini
        var c = SizeCard.remembered()
        let saved = MiniSettings.load(mini.folder)
        if let sizes = saved.made ?? saved.requested { c.load(sizes) }
        _card = State(initialValue: c)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Remakes the print file with these sizes. About 30 seconds. The character itself doesn't change.")
                        .foregroundStyle(.secondary)
                }
                SizeSection(card: $card, seed: nil)
            }
            .formStyle(.grouped)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let reason = model.cantStart ?? problem {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("🔁 Resize") {
                    do { try model.resize(mini, sizes: card.sizes) } catch { problem = "\(error)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.cantStart != nil)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle("Resize \(mini.displayName)")
        .frame(width: 580, height: 620)
    }
}

extension SizeCard {
    /// The purpose and nozzle last chosen: most people keep one printer.
    static func remembered() -> SizeCard {
        let d = UserDefaults.standard
        return SizeCard(purpose: Purpose(rawValue: d.string(forKey: "purpose") ?? "") ?? .game,
                        nozzle: d.string(forKey: "nozzle") ?? "0.4")
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
        Section("📏 Size & printer") {
            Picker("Size for", selection: bind(\.purpose, { $0.setPurpose($1) })) {
                Text("🎲 Game scale").tag(SizeCard.Purpose.game)
                Text("✨ Best print").tag(SizeCard.Purpose.display)
            }
            .pickerStyle(.segmented)
            Text(card.purpose == .game ? "Matches the other minis on your table." : "Sized so the details come out well.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("🖨️ Your printer's nozzle", selection: bind(\.nozzle, { $0.setNozzle($1) })) {
                Text("0.2 mm · fine").tag("0.2")
                Text("0.4 mm · standard").tag("0.4")
                Text("0.6 mm · fast").tag("0.6")
            }
            .pickerStyle(.segmented)
            Text("Not sure? Most printers come with 0.4 mm. Choose the same nozzle in your slicer.")
                .font(.callout).foregroundStyle(.secondary)
            if card.purpose == .game {
                LabeledContent("How tall is the character?") {
                    HStack(spacing: 4) {
                        TextField("", text: bind(\.realHeight, { $0.setRealHeight($1) }), prompt: Text("1.80"))
                            .labelsHidden().frame(width: 64).multilineTextAlignment(.trailing)
                        Text("m")
                    }
                }
                Picker("Scale", selection: bind(\.scale, { $0.setScale($1) })) {
                    Text("28 mm").tag(28)
                    Text("32 mm · most common").tag(32)
                    Text("54 mm").tag(54)
                }
                .pickerStyle(.segmented)
                Text("Use the scale of the other minis on your table. An average human (1.8 m) is 28, 32 or 54 mm tall.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !card.note.isEmpty {
                Text(card.note).font(.callout).foregroundStyle(card.warns ? .orange : .secondary)
            }
            slider("📏 Character height", \.height, { $0.setHeight($1) }, SizeCard.heightRange, unit: "mm",
                   hint: "Set for you by the choices above; type a value or drag to change it. The base adds about 2 mm.")
            slider("Base size", \.base, { $0.setBase($1) }, SizeCard.baseRange, unit: "mm", hint: nil)
            DisclosureGroup("⚙️ Advanced", isExpanded: $advanced) {
                slider("Extra thickness for thin parts", \.inflate, { $0.setInflate($1) }, SizeCard.inflateRange, unit: "mm",
                       hint: "Set by your nozzle. More keeps swords and capes in one piece, but softens faces.", decimals: 2)
                Toggle("Use the character's own base instead of a round one", isOn: $card.noBase)
                if let seed {
                    LabeledContent("Variation number") {
                        TextField("", value: seed, format: .number.grouping(.never)).labelsHidden().frame(width: 90)
                    }
                }
            }
        }
        .onChange(of: card.purpose) { _, p in UserDefaults.standard.set(p.rawValue, forKey: "purpose") }
        .onChange(of: card.nozzle) { _, n in UserDefaults.standard.set(n, forKey: "nozzle") }
    }

    private func bind<T>(_ get: KeyPath<SizeCard, T>, _ set: @escaping (inout SizeCard, T) -> Void) -> Binding<T> {
        Binding(get: { card[keyPath: get] }, set: { v in set(&card, v) })
    }

    private func slider(_ label: String, _ get: KeyPath<SizeCard, Double>, _ set: @escaping (inout SizeCard, Double) -> Void,
                        _ range: ClosedRange<Double>, unit: String, hint: String?, decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                HStack(spacing: 4) {
                    TextField("", value: bind(get, set), format: .number.precision(.fractionLength(0...decimals)).grouping(.never))
                        .labelsHidden().frame(width: 56).multilineTextAlignment(.trailing)
                    Text(unit)
                }
            }
            Slider(value: bind(get, set), in: range).labelsHidden()
            if let hint { Text(hint).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
