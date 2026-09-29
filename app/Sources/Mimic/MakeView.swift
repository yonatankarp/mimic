import AppKit
import ImageIO
import MimicCore
import SwiftUI
import UniformTypeIdentifiers

/// The Make a Mini sheet (⌘N): a picture or a description, a name, and the size card.
struct MakeView: View {
    enum Start: String { case picture, description }

    @Environment(AppModel.self) private var model
    private let health = Health.shared
    @State private var start = Start.picture
    @State private var picture: Picture?
    @State private var choosing = false
    @State private var dropTargeted = false
    @State private var restyle = true
    @State private var description = ""
    /// The AI helper's version of `description`, used instead of it while shown.
    @State private var improved: String?
    @State private var name = ""
    @State private var seed = 42
    @State private var card = SizeCard.remembered()
    @State private var message: String?
    @State private var messageIsError = false
    /// The raw error behind a message, for the tooltip only.
    @State private var messageDetail: String?
    @FocusState private var nameFocused: Bool
    /// The project it goes in: "" is Unsorted, `newProject` a project named in `newProjectName`.
    @State private var project = ""
    @State private var newProjectName = ""
    private static let newProject = "\u{1}new"

    var body: some View {
        VStack(spacing: 0) {
            // A sheet shows no window title, so it carries its own.
            Text("New Mini").font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            ScrollViewReader { scroller in
            Form {
                Section {
                    Picker("What are you making?", selection: Binding(get: { card.kind }, set: { card.setKind($0) })) {
                        Text("🧙 A character (a mini)").tag(MiniKind.character)
                        Text("🏺 Anything else").tag(MiniKind.object)
                    }
                    .pickerStyle(.segmented)
                    .help("A character is made as a tabletop mini: standing, on a round base, sized to match your other minis. Anything else (a teapot, a car, a chess piece) is sized by its longest side, with no base unless you add one.")
                }
                Section {
                    Picker("Start from", selection: $start) {
                        Text("🖼️ From a picture").tag(Start.picture)
                        Text("✍️ Describe it").tag(Start.description)
                    }
                    .pickerStyle(.segmented)
                    .tourStop(.start, arrow: .trailing)
                    .help("From a picture: art or a photo of your \(thing). Describe it: Draw Things draws the \(thing) from your words first.")
                    if start == .picture { picturePane } else { descriptionPane }
                    TextField("Name your mini", text: $name, prompt: Text(object ? "e.g. Teapot" : "e.g. Dwarf Cleric"))
                        .help("How it's listed in your minis. The print file is named after it too.")
                        .focused($nameFocused)
                        .onChange(of: name) { _, new in
                            if new != Mini.displayName(MakeAdvice.name(fromDescription: description)) { autoName = false }
                        }
                    Picker("Project", selection: $project) {
                        Text("Unsorted").tag("")
                        ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("New Project…").tag(Self.newProject)
                    }
                    .help("The folder it's kept in, and where it's listed on the left.")
                    if project == Self.newProject {
                        TextField("New project's name", text: $newProjectName, prompt: Text("e.g. Tiefling Party"))
                    }
                    if let taken = takenName {
                        Text(model.waiting(slug) != nil || model.current?.name == slug
                             ? "\(taken) is already being made or waiting in the queue. Pick a new name."
                             : "You already have a mini called \(taken). Pick a new name, or use Resize This Mini to change its size.")
                            .font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Text(object ? "🏺 Your object" : "🧙 Your character")
                } footer: {
                    Text(object ? "💡 Solid objects with bold shapes work best. Thin handles, wires and fine texture may come out soft."
                                : "💡 Chunky characters with bold shapes work best. Small details, like a pet on a shoulder, may come out soft.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                SizeSection(card: $card, seed: $seed)
            }
            .formStyle(.grouped)
            // The tour's stops in here can be below the fold (a popover on a control scrolled out
            // of sight doesn't show), so the form brings each one into view as the tour gets to it.
            .onChange(of: TourGuide.shared.step) { _, stop in
                guard let stop, stop.inNewMini else { return }
                withAnimation { scroller.scrollTo(stop, anchor: .center) }
            }
            }

            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let reason = model.cantStart {
                    CantStart(reason: reason)
                } else if let message, messageIsError {
                    Text(message).foregroundStyle(.red).help(messageDetail ?? "")
                } else if let missing {
                    Text(missing).foregroundStyle(.secondary)
                } else if let message {
                    Text(message).foregroundStyle(.secondary)
                } else {
                    Text(timing).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Make My Mini") { make() }
                    .help("Takes \(JobProgress.about(estimate.total))\(estimate.learned ? " on this Mac" : ""). You can keep using your Mac meanwhile.")
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.cantStart != nil || takenName != nil || missing != nil)
                    .tourCallout(.make, arrow: .top)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
        }
        // The tour's "Use the Sample": its picture and name, ready to make.
        .onAppear {
            if let url = TourGuide.shared.takeSample() { name = TourGuide.sampleName; take(url) }
            // The project you're looking at: the one New Mini was asked from, else the selected mini's.
            project = model.makeInProject ?? model.selected?.project ?? ""
            model.makeInProject = nil
        }
        .frame(width: 580, height: 640)  // fits under the toolbar of the smallest main window; the form scrolls
        .onChange(of: card.kind) { _, k in
            UserDefaults.standard.set(k.rawValue, forKey: "kind")
            improved = nil  // written for the other kind
        }
        .task {
            // Describe it and the grey sculpt need Draw Things, and Make needs every required
            // part: check them once if nothing has yet, then keep watching Draw Things.
            // Not during a job: the checks start the 3D engine themselves.
            if health.lastChecked == nil && !health.running && !model.running { health.check(model.install) }
            await health.watchDrawThings(model.install)
        }
        // ⌘V: a picture on the clipboard becomes the picture; anything else pastes as usual.
        .background { Button("") { paste() }.keyboardShortcut("v").hidden() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { take(url) }
        }
    }

    @State private var autoName = false
    private var object: Bool { card.kind == .object }
    private var thing: String { object ? "object" : "character" }

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
                        Text(object ? "The whole object, plain background" : "Full body, head to feet, plain background").font(.caption).foregroundStyle(.secondary)
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
                if urls.count > 1 { make(urls) } else { take(url) }
                return true
            } isTargeted: { dropTargeted = $0 }
            ForEach(picture.map { MakeAdvice.pictureWarnings(width: $0.width, height: $0.height, kind: card.kind) } ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            Toggle(isOn: $restyle) {
                Text("Turn it into a grey sculpt first (recommended)")
                Text("Best for drawings and photos. Turn it off only if your picture is already a grey 3D model.")
            }
            .disabled(!health.drawThingsReady)
            .help("Draw Things redraws your picture as a grey statue with the same pose and details. The 3D engine understands that far better than colourful art or photos.")
            if !health.drawThingsReady { needsDrawThings("The grey sculpt needs Draw Things.") } else { opensWhenNeeded }
        }
    }

    private var descriptionPane: some View {
        Group {
            TextEditor(text: $description)
                .frame(minHeight: 70)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
                .accessibilityLabel("Describe your \(thing)")
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text(object ? "e.g. a round teapot with a curved spout and a lid" : "e.g. dwarf cleric holding a warhammer against his chest, shield on his back")
                            .foregroundStyle(.tertiary).padding(.leading, 9).padding(.top, 4).allowsHitTesting(false)
                    }
                }
                .onChange(of: description) { _, text in
                    guard name.isEmpty || autoName else { return }
                    name = Mini.displayName(MakeAdvice.name(fromDescription: text))
                    autoName = true
                }
            ImproveBox(description: description, kind: card.kind.rawValue, improved: $improved)
            if !health.drawThingsReady { needsDrawThings("✍️ Describe it needs Draw Things.") } else { opensWhenNeeded }
        }
    }

    @ViewBuilder private var opensWhenNeeded: some View {
        if health.drawThingsOpensWhenNeeded { Text("Mimic opens Draw Things when it needs it.").font(.callout).foregroundStyle(.secondary) }
    }

    private func needsDrawThings(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            SettingsLink { Text("Open Settings") }
        }
        .font(.callout)
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
        let runs = model.install.runs
        // Any mini or project with the name, in any project, except a failed attempt's folder,
        // which Make My Mini makes again.
        let failedAttempt = Gallery.folder(runs, slug).map {
            !FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.glb").path)
                && $0.deletingLastPathComponent().standardizedFileURL
                    == (project.isEmpty || project == Self.newProject ? runs : runs.appendingPathComponent(project)).standardizedFileURL
        } ?? false
        guard !slug.isEmpty,
              Gallery.nameInUse(runs, slug) && !failedAttempt
                || model.waiting(slug) != nil || model.current?.name == slug
        else { return nil }
        return Mini.displayName(slug)
    }

    private var estimate: Estimate {
        model.estimateNew(drawn: start == .description || (restyle && health.drawThingsReady), sizes: card.sizes)
    }

    /// "⏱ About 8 minutes on this Mac", or when it would wait: how long until it's ready.
    private var timing: String {
        let e = estimate
        let own = "\(JobProgress.about(e.total).capitalizedFirst)\(e.learned ? " on this Mac" : "")"
        guard model.current != nil else { return "⏱ \(own)" }
        let ahead = model.queue.count + 1
        let ready = model.queueTimes().last?.ready ?? model.runningLeft()
        return "⏱ Joins the queue, \(ahead) ahead · ready in \(JobProgress.about(ready + e.total))"
    }

    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What Make My Mini is waiting for, said in the footer while the button is off.
    private var missing: String? {
        switch start {
        case .picture where picture == nil: return "Add a picture to start"
        case .description where trimmedDescription.isEmpty: return "Describe your \(thing) to start"
        default: break
        }
        if slug.isEmpty { return "Give your mini a name" }
        if project == Self.newProject && Rules.projectName(newProjectName) == nil { return "Name the new project" }
        if start == .description && !health.drawThingsReady { return "Describe it needs Draw Things first" }
        return nil
    }

    private func make() {
        guard missing == nil else { return }
        let source: PictureSource
        switch start {
        case .picture:
            guard let picture else { return }
            source = .image(picture.url)
        case .description:
            let better = improved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            source = better.isEmpty ? .description(trimmedDescription) : .description(better, original: trimmedDescription)
        }
        do {
            if project == Self.newProject { project = try model.createProject(newProjectName) }
            try model.make(name: slug, picture: source, restyle: start == .picture && restyle && health.drawThingsReady,
                           seed: seed, sizes: card.sizes, kind: card.kind, project: project.isEmpty ? nil : project)
        } catch {
            say(model.plainWords(error), error: true)
            messageDetail = "\(error)"
        }
    }

    /// Several pictures dropped at once: a mini each, with this card's settings, named after its
    /// file. Names can be changed afterwards.
    private func make(_ pictures: [URL]) {
        guard model.cantStart == nil else { return }
        if project == Self.newProject && Rules.projectName(newProjectName) == nil { return say("Name the new project, then drop the pictures again.", error: true) }
        do {
            if project == Self.newProject { project = try model.createProject(newProjectName) }
            if let why = model.make(pictures: pictures, restyle: restyle && health.drawThingsReady, seed: seed,
                                    sizes: card.sizes, kind: card.kind, project: project.isEmpty ? nil : project) { say(why, error: true) }
        } catch {
            say(model.plainWords(error), error: true)
            messageDetail = "\(error)"
        }
    }

    private func say(_ text: String, error: Bool = false) { message = text; messageIsError = error; messageDetail = nil }
}

/// A picture chosen for a new mini, with its warnings worked out from its real pixel size.
struct Picture {
    let url: URL
    let image: NSImage
    /// Pixels, upright.
    let width: Int, height: Int

    init?(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = NSImage(contentsOf: url) else { return nil }
        // Photos taken sideways say so in their orientation; the picture is shown turned upright.
        let turned = [5, 6, 7, 8].contains(props[kCGImagePropertyOrientation] as? Int ?? 1)
        self.url = url
        self.image = image
        (width, height) = turned ? (h, w) : (w, h)
    }
}

/// Resize This Mini: the size card, loaded with what the mini is now.
struct ResizeView: View {
    let mini: Mini
    @Environment(AppModel.self) private var model
    @State private var card: SizeCard
    /// A refused resize: in words for people, and the raw error for the tooltip.
    @State private var problem: (words: String, detail: String)?

    init(mini: Mini) {
        self.mini = mini
        var c = SizeCard.remembered()
        let saved = MiniSettings.load(mini.folder)
        c.setKind(saved.kind ?? .character)  // before the sizes: choosing a kind suggests sizes afresh
        if let sizes = saved.made ?? saved.requested { c.load(sizes) }
        _card = State(initialValue: c)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Resize \(mini.displayName)").font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    Text("Remakes the print file with these sizes. \(JobProgress.about(model.estimate(mini.name, .prep, sizes: card.sizes).total).capitalizedFirst)\(model.current == nil ? "" : ", once the jobs ahead of it are done"). The \(card.kind == .object ? "object" : "character") itself doesn't change.")
                        .foregroundStyle(.secondary)
                }
                SizeSection(card: $card, seed: nil)
            }
            .formStyle(.grouped)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let reason = model.cantStart {
                    CantStart(reason: reason)
                } else if let problem {
                    Label(problem.words, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(problem.detail)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    do { try model.resize(mini, sizes: card.sizes) } catch { problem = (model.plainWords(error), "\(error)") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.cantStart != nil || model.waiting(mini.name) != nil)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580, height: 600)
    }
}

/// Why Make or Resize can't start, with a way to Settings when the reason is the setup
/// rather than a job already running.
struct CantStart: View {
    @Environment(AppModel.self) private var model
    let reason: String
    var body: some View {
        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        if model.requiredProblem != nil { SettingsLink { Text("Open Settings") } }
    }
}

extension SizeCard {
    /// The kind, purpose and nozzle last chosen: most people keep one printer.
    static func remembered() -> SizeCard {
        let d = UserDefaults.standard
        return SizeCard(purpose: Purpose(rawValue: d.string(forKey: "purpose") ?? "") ?? .game,
                        nozzle: d.string(forKey: "nozzle") ?? "0.4",
                        kind: MiniKind(rawValue: d.string(forKey: "kind") ?? "") ?? .character)
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
            if !object {  // an object is sized by its longest side: no scale to match
                Picker("Size for", selection: bind(\.purpose, { $0.setPurpose($1) })) {
                    Text("🎲 Game scale").tag(SizeCard.Purpose.game)
                    Text("✨ Best print").tag(SizeCard.Purpose.display)
                }
                .pickerStyle(.segmented)
                .help("Game scale: the same size as the other minis on your table. Best print: as big as your nozzle needs for faces to come out clearly.")
            }
            if gameScale {  // Best print explains itself in its note below
                Text("Matches the other minis on your table.").font(.callout).foregroundStyle(.secondary)
            }
            Picker("🖨️ Your printer's nozzle", selection: bind(\.nozzle, { $0.setNozzle($1) })) {
                Text("0.2 mm · fine").tag("0.2")
                Text("0.4 mm · standard").tag("0.4")
                Text("0.6 mm · fast").tag("0.6")
            }
            .pickerStyle(.segmented)
            .tourStop(.size, arrow: .top)  // on the nozzle, which characters and objects both show
            .help("The tip your printer prints through. Its size is usually marked on it, or listed in your printer's settings. Mimic thickens thin parts to suit it: finer nozzles keep more detail.")
            Text("Not sure? Most printers come with 0.4 mm. Choose the same nozzle in your slicer.")
                .font(.callout).foregroundStyle(.secondary)
            if gameScale {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("How tall is the character?") {
                        HStack(spacing: 4) {
                            TextField("", text: bind(\.realHeight, { $0.setRealHeight($1) }), prompt: Text("1.80"))
                                .labelsHidden().frame(width: 64).multilineTextAlignment(.trailing)
                                .help("How tall the character would be in real life, in metres.")
                            Text("m")
                        }
                    }
                    // SizeCard.gameHeight: blank (or not a number) counts as 1.8 m.
                    Text("In metres. 6 ft ≈ 1.83 m, a halfling ≈ 1 m. Leave blank for an average human (1.8 m).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Scale", selection: bind(\.scale, { $0.setScale($1) })) {
                    Text("28 mm").tag(28)
                    Text("32 mm · most common").tag(32)
                    Text("54 mm").tag(54)
                }
                .pickerStyle(.segmented)
                .help("The scale your other minis are made at: how tall an average human is on the table. 32 mm is the most common today.")
                Text("Pick the scale your other minis use. At 32 mm scale, an average 1.8 m human stands 32 mm tall.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !card.note.isEmpty {
                Text(card.note).font(.callout).foregroundStyle(card.warns ? .orange : .secondary)
            }
            if object {
                slider("Longest side", \.height, { $0.setHeight($1) }, SizeCard.heightRange, unit: "mm",
                       hint: "Its biggest size, whichever way that is: height, width or depth. Set for your nozzle; type a value or drag to change it.")
                Toggle("Add a round base", isOn: Binding(get: { !card.noBase }, set: { card.noBase = !$0 }))
                    .help("Off: it prints standing on its own flat bottom. On: it's fused to a round base, like a display piece.")
            } else {
                slider("Character height", \.height, { $0.setHeight($1) }, SizeCard.heightRange, unit: "mm",
                       hint: "Set for you by the choices above; type a value or drag to change it. The base adds about 2 mm.")
            }
            if !object || !card.noBase {
                slider("Base size", \.base, { $0.setBase($1) }, SizeCard.baseRange, unit: "mm", hint: nil)
                    .help(object ? "How wide the round base is." : "How wide the round base is. 25 mm fits one square on a battle map.")
            }
            // A plain button as the label, so a click or VoiceOver's press on the words opens it too.
            DisclosureGroup(isExpanded: $advanced) {
                slider("Extra thickness for thin parts", \.inflate, { $0.setInflate($1) }, SizeCard.inflateRange, unit: "mm",
                       hint: "Set by your nozzle. More keeps swords and capes in one piece, but softens faces.", decimals: 2)
                if !object {
                    Toggle("Use the character's own base instead of a round one", isOn: $card.noBase)
                        .help("For characters already standing on a base or a rock: Mimic flattens that instead of adding a round one.")
                }
                if let seed {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Variation number") {
                            TextField("", value: seed, format: .number.grouping(.never)).labelsHidden().frame(width: 90)
                        }
                        Text("Same description + same number = same drawing. Change it for a different take.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } label: {
                Button("Advanced") { withAnimation { advanced.toggle() } }.buttonStyle(.plain)
            }
        }
        .onChange(of: card.purpose) { _, p in UserDefaults.standard.set(p.rawValue, forKey: "purpose") }
        .onChange(of: card.nozzle) { _, n in UserDefaults.standard.set(n, forKey: "nozzle") }
    }

    private var object: Bool { card.kind == .object }
    private var gameScale: Bool { !object && card.purpose == .game }

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
