import AppKit
import ImageIO
import MimicCore
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The Make a Mini sheet (⌘N): a picture or a description, a name, and the size card. It starts
/// empty, or filled in from a mini (Edit & Make Again) or with the tour's sample.
struct MakeView: View {
    enum Start: String { case picture, description }

    @Environment(AppModel.self) private var model
    private let health = Health.shared
    @State private var start = Start.picture
    @State private var picture: Picture?
    @State private var dropTargeted = false
    /// Pictures of the back and sides besides `picture`, the front (#66), the place a picture
    /// is being chosen for, and the one dragged over.
    @State private var sides: [PictureSide: Picture] = [:]
    @State private var chooser = PictureChooser()
    @State private var sideTargeted: PictureSide?
    @State private var restyle = true
    @State private var cartoon = false
    @State private var description = ""
    /// The AI helper's version of `description`, used instead of it while shown.
    @State private var improved: String?
    @State private var name = ""
    @State private var seed = 42
    @State private var card = SizeCard.remembered()
    /// The main window's size under its toolbar: as big as the sheet can grow.
    let room: CGSize
    @State private var height: CGFloat
    /// What the two columns need, for `fitsForms`.
    @State private var forms = FormHeights(columns: 2)

    /// The mini it was filled in from, for Edit & Make Again.
    private let again: Mini?
    /// The 3D model `again` was made with, while it's used instead of this Mac's choice.
    @State private var madeWith: String?
    /// `again`'s own number for its 3D shape (New 3D Shape), while its variation number is kept.
    @State private var shapeSeed: Int?
    /// What to change in the picture (#156), and what was changed before in the mini it was
    /// filled in from, with the last as the AI helper put it.
    @State private var fix = ""
    @State private var earlierFixes: [String] = []
    @State private var earlierFixUsed: String?
    /// The pictures `again`'s step 1 made: a change starts from these, as Make Another
    /// Version's does. Forgotten once another picture is chosen.
    @State private var drawn: URL?
    @State private var drawnSides: [PictureSide: URL] = [:]
    /// The AI helper is rewriting the change, before it's made; Cancel stops it making it.
    @State private var writing = false
    @State private var writingTask: Task<Void, Never>?
    /// Improve Description's request, stopped when the sheet closes (#346). Here, not in the
    /// box: a row of a Form can disappear while it's scrolled out of sight.
    @State private var improving: Task<Void, Never>?
    /// Pictures pasted, written to the temporary folder: deleted when the sheet closes, by when
    /// any mini made from one has its own copy (`JobRunner.make` copies it as it's asked for).
    @State private var pasted: [URL] = []

    /// `start` was read and decoded when the sheet was asked for: this runs again on every frame
    /// of a window resize, so it reads nothing (#341).
    init(room: CGSize, start filled: MakeStart? = nil, again: Mini? = nil) {
        self.room = room
        self.again = again
        _height = State(initialValue: room.sheetHeight)
        // Filled in here rather than on appear, so no onChange takes it for a choice made in the
        // sheet (a kind changed forgets the improved description; the size card's are remembered).
        guard let filled else { return }
        let form = filled.form
        _start = State(initialValue: form.fromPicture ? .picture : .description)
        _picture = State(initialValue: filled.picture)
        _sides = State(initialValue: filled.sides)
        _restyle = State(initialValue: form.restyle)
        _cartoon = State(initialValue: form.cartoon)
        _description = State(initialValue: form.description)
        _improved = State(initialValue: form.improved)
        _name = State(initialValue: form.name)
        _seed = State(initialValue: form.seed)
        _card = State(initialValue: form.card)
        _project = State(initialValue: ProjectChoice(form.project))
        _madeWith = State(initialValue: form.model)
        _shapeSeed = State(initialValue: form.shapeSeed)
        _earlierFixes = State(initialValue: form.fixes)
        _earlierFixUsed = State(initialValue: form.fixUsed)
        _drawn = State(initialValue: form.drawn)
        _drawnSides = State(initialValue: form.drawnSides)
        // Open when the mini it's filled in from has any of them set, so none is hidden.
        _pictureOptions = State(initialValue: form.cartoon || !form.restyle || !filled.sides.isEmpty || !form.fixes.isEmpty)
    }
    @State private var message: String?
    @State private var messageIsError = false
    /// The raw error behind a message, for the tooltip only.
    @State private var messageDetail: String?
    @FocusState private var nameFocused: Bool
    /// The project it goes in; New Project… is one named in `newProjectName`.
    @State private var project = ProjectChoice.unsorted
    @State private var newProjectName = ""
    /// Picture Options is open: more pictures, the cartoon and grey sculpt switches, and a change.
    @State private var pictureOptions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Project menu's choice.
    private enum ProjectChoice: Hashable {
        case unsorted, existing(String), new

        /// A project's name, nil or empty for Unsorted.
        init(_ project: String?) {
            if let project, !project.isEmpty { self = .existing(project) } else { self = .unsorted }
        }

        /// The project to make it in: nil for Unsorted, and for New Project… until it's made.
        var name: String? {
            if case .existing(let p) = self { return p }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // A sheet shows no window title, so it carries its own.
            Text(again == nil ? "New Mini" : "Edit & Make Again").font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            // Two columns, so the size choices are in sight before Make Mini without scrolling.
            // Each column scrolls on its own if it outgrows the sheet (Advanced open, say).
            HStack(spacing: 0) {
            Form {
                kindSection
                characterSection
                if start == .picture { pictureOptionsSection }
            }
            .formStyle(.grouped)
            .reportsHeight(0, into: $forms)
            Form { SizeSection(card: $card, seed: $seed) }
                .formStyle(.grouped)
                .reportsHeight(1, into: $forms)
            }

            Divider()
            makeBar
        }
        .onDisappear {
            writingTask?.cancel()  // closed while the helper writes: nothing is made
            improving?.cancel()
            for url in pasted { try? FileManager.default.removeItem(at: url) }
        }
        .onAppear {
            // The project you're looking at: the one New Mini was asked from, else the selected
            // mini's. Edit & Make Again keeps the mini's own.
            if again == nil { project = ProjectChoice(model.makeInProject ?? model.selected?.project) }
            model.makeInProject = nil
        }
        // Two equal columns: 540 each from the default window up (the size column's hints mostly
        // on one line, so Game Scale fits unscrolled), 460 each in the smallest.
        .frame(width: room.sheetWidth, height: height)
        .fitsForms($height, $forms, room: room.height)
        .onChange(of: card.kind) { _, k in
            UserDefaults.standard.set(k.rawValue, forKey: SettingsKey.kind)
            improved = nil  // written for the other kind
        }
        .onChange(of: seed) { shapeSeed = nil }  // a new variation number is a new shape too
        .task(id: nameLookup) { await lookUpName() }
        .task(id: "\(model.setup.removals) \(model.setup.running)") {
            let install = model.install
            let here = await Task.detached { EngineDownload.cartoon.complete(in: install) }.value
            if !Task.isCancelled { pixal3dHere = here }
        }
        .task {
            // A description and the grey sculpt need Draw Things, and Make needs every required
            // part: check them once if nothing has yet, then keep watching Draw Things.
            // Not during a job: the checks start the 3D engine themselves.
            if health.lastChecked == nil && !health.running && !model.running { health.check(model.install) }
            await health.watchDrawThings(model.install)
        }
        // ⌘V: a picture on the clipboard becomes the picture; anything else pastes as usual, and
        // so does text while a field is being typed in (see paste()).
        .background { Button("") { paste() }.keyboardShortcut("v").hidden() }
        // One importer for every place: a second one on the same sheet would never open.
        .fileImporter(isPresented: Binding(get: { chooser.isOpen }, set: { if !$0 { chooser.close() } }),
                      allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            if let side = chooser.side { takeSide(side, url) } else { take(url) }
        }
        // File → Import from iPhone (Continuity Camera): a photo taken for it, or a scan.
        .importsItemProviders([.image]) { receive($0); return true }
    }

    /// What it is: a character or an object.
    private var kindSection: some View {
        Section {
            // A segmented control shows words only (SwiftUI drops a segment's symbol on
            // the Mac), so the symbol for the choice sits on the row's label.
            Picker(selection: Binding(get: { card.kind }, set: { card.setKind($0) })) {
                Text("Character").tag(MiniKind.character)
                Text("Object").tag(MiniKind.object)
            } label: { Label("What are you making?", systemImage: object ? "cube" : "person.fill") }
            .pickerStyle(.segmented)
            // One help for the whole control: a segment of a Mac segmented picker takes no help of its own.
            .help("A character is a mini that stands on a base; an object is sized by its longest side")
        }
    }

    /// Where it starts from, what it's called and where it's kept: what everyone fills in.
    private var characterSection: some View {
        Section {
            startRows
            nameRows
        } footer: {
            Label(object ? "Solid objects with bold shapes work best. Thin handles, wires and fine texture may come out soft."
                         : "Chunky characters with bold shapes work best. Small details, like a pet on a shoulder, may come out soft.",
                  systemImage: "lightbulb")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A picture or a description, and the 3D model a remade mini keeps.
    @ViewBuilder private var startRows: some View {
        Picker(selection: $start) {
            Text("Picture").tag(Start.picture)
            Text("Description").tag(Start.description)
        } label: { Label("Start from", systemImage: start == .picture ? "photo" : "text.cursor") }
        .pickerStyle(.segmented)
        .help("Start from a picture of your \(thing), or from a description")
        if start == .picture { picturePane } else { descriptionPane }
        if let again, let used = madeWith.flatMap({ EngineDownload.model($0) }), used != model.setup.engineModel, !cartoonOn {
            HStack(alignment: .firstTextBaseline) {
                Text("Made with \(used.name), as \(again.displayName) was.").foregroundStyle(.secondary)
                Spacer()
                Button("Use \(model.setup.engineModel.name)") { madeWith = nil }
                    .help("Make it with the 3D model chosen in Settings instead")
            }
            .font(.callout)
        }
    }

    /// Its name and project, and why the name can't be used.
    @ViewBuilder private var nameRows: some View {
        TextField("Name", text: $name, prompt: Text(object ? "e.g. Teapot" : "e.g. Dwarf Cleric"))
            .help("How it's listed, and what its print file is called")
            .focused($nameFocused)
            .onChange(of: name) { _, new in
                if new != MakeAdvice.name(fromDescription: description) { autoName = false }
            }
        Picker("Project", selection: $project) {
            Text("Unsorted").tag(ProjectChoice.unsorted)
            ForEach(model.projects, id: \.self) { Text($0).tag(ProjectChoice.existing($0)) }
            Divider()
            Text("New Project…").tag(ProjectChoice.new)
        }
        .help("The folder it's kept in, and where it's listed on the left.")
        if project == .new {
            TextField("New project's name", text: $newProjectName, prompt: Text("e.g. Tiefling Party"))
        }
        if let taken = takenName {
            Text(model.waiting(slug) != nil || model.current?.name == slug
                 ? "\(taken) is already being made or waiting in the queue. Pick a new name."
                 : "You already have a mini called \(taken). Pick a new name, or use Resize This Mini to change its size.")
                .font(.callout).foregroundStyle(.red)
        }
    }

    /// Why it can't be made yet, or how long it takes, and Cancel and Make Mini.
    private var makeBar: some View {
        HStack(alignment: .firstTextBaseline) {
            if let reason = model.requiredProblem {
                CantStart(reason: reason)
            } else if writing {
                ProgressView().controlSize(.small)
                Text("Writing the change…").foregroundStyle(.secondary)
            } else if let message, messageIsError {
                Text(message).foregroundStyle(.red).help(messageDetail ?? "")
            } else if let missing {
                Text(missing).foregroundStyle(.secondary)
            } else if let message {
                Text(message).foregroundStyle(.secondary)
            } else {
                Label(timing, systemImage: "timer").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { writingTask?.cancel(); TourGuide.shared.newMiniCancelled(); model.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Make Mini") { make() }
                .help(estimate.learned ? String(localized: "Takes \(JobProgress.about(estimate.total)) on this Mac; keep using your Mac meanwhile")
                      : String(localized: "Takes \(JobProgress.about(estimate.total)); keep using your Mac meanwhile"))
                .keyboardShortcut(.defaultAction)
                .disabled(model.requiredProblem != nil || takenName != nil || missing != nil || writing)
                .tourCallout(.make, arrow: .top)
        }
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
    }

    @State private var autoName = false
    private var object: Bool { card.kind == .object }
    /// Pixal3D is downloaded: looked up off the main thread when the sheet opens and after a
    /// download or removal (#340), as it checks the size of every file. Nil until then, taken
    /// as here: Make Mini refuses a model that isn't, and the sheet doesn't flicker.
    @State private var pixal3dHere: Bool?
    /// A cartoon character from a picture, and everything it needs is here.
    private var cartoonOn: Bool { cartoon && !object && start == .picture && health.picturesReady && pixal3dHere != false }
    /// The grey sculpt, which a cartoon always gets.
    private var sculpt: Bool { (restyle || cartoonOn) && health.picturesReady }
    private var thing: String { object ? String(localized: "object") : String(localized: "character") }

    // MARK: Picture

    private var picturePane: some View {
        Group {
            Button { chooser.open(nil) } label: {
                VStack(spacing: 6) {
                    if let picture {
                        Image(nsImage: picture.image).resizable().scaledToFit().frame(maxHeight: 180)
                        Text(picture.caption).font(.caption).foregroundStyle(.secondary)
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
            .accessibilityLabel(picture.map { "Change the picture, \($0.caption)" } ?? "Choose a picture")
            .onDrop(of: PictureDrop.types, isTargeted: $dropTargeted) { receive($0); return true }
            ForEach(picture.map { MakeAdvice.pictureWarnings(width: $0.width, height: $0.height, kind: card.kind) } ?? [], id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
    }

    /// What most pictures need left as they are, folded away: more pictures, a cartoon, the grey
    /// sculpt and a change. Closed, each keeps its default.
    private var pictureOptionsSection: some View {
        Section {
            // A plain button as the label, as Advanced's, so a click on the words opens it too.
            DisclosureGroup(isExpanded: $pictureOptions) {
                pictureOptionRows
            } label: {
                Button("Picture Options") { withAnimation(reduceMotion ? nil : .default) { pictureOptions.toggle() } }.buttonStyle(.plain)
            }
            // In sight with it closed: without them, the picture is made without the grey sculpt.
            if !health.picturesReady { needsPictures(String(localized: "The grey sculpt needs \(health.pictureNeed).")) }
        }
    }

    @ViewBuilder private var pictureOptionRows: some View {
        sidesRow
        if !object {
            Toggle(isOn: $cartoon) {
                Text("It's a cartoon")
                Text("For flat drawings with outlines and flat colours. Made from the grey sculpt with Pixal3D, which keeps cartoon shapes smooth.")
            }
            .disabled(!health.picturesReady || pixal3dHere == false)
            .help("Flat 2D cartoon art comes out smoother this way")
            if health.picturesReady && pixal3dHere == false {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cartoons need the Pixal3D model.").foregroundStyle(.secondary)
                    Spacer()
                    OpenSettingsButton(tab: .model) { Text("Open Settings") }
                }
                .font(.callout)
            }
        }
        Toggle(isOn: Binding(get: { restyle || cartoonOn }, set: { restyle = $0 })) {
            Text("Turn it into a grey sculpt first (recommended)")
            Text(cartoonOn ? "A cartoon always gets the grey sculpt: without it, it comes out flat."
                           : "Mimic redraws it as a grey statue, which the 3D engine understands far better. Turn it off if your picture is already a grey 3D model, or to keep its colours for Export for Virtual Tabletop: the shape may come out less clean.")
        }
        .disabled(!health.picturesReady || cartoonOn)
        .help("Redraws your picture as a grey statue with the same pose")
        FixBox(text: $fix, earlier: earlierFixes, kind: card.kind, turnsSculptOn: !(restyle || cartoonOn))
            .disabled(!health.picturesReady)
        if let again, drawn != nil, !trimmedFix.isEmpty {
            Text("Starts from the picture \(again.displayName) was drawn as.").font(.callout).foregroundStyle(.secondary)
        }
        if health.picturesReady { opensWhenNeeded }
    }

    // MARK: Pictures of the back and sides (#66)

    /// The 3D model it would be made with, which decides whether it can use them.
    private var makingWith: EngineModel {
        EngineDownload.forMaking(cartoon: cartoonOn, chosen: madeWith.flatMap { EngineDownload.model($0) } ?? model.setup.engineModel)
    }

    /// What Make Mini sends of them: nothing when the model uses one picture.
    private var sidesUsed: [PictureSide: URL] {
        start == .picture && makingWith.multiView ? sides.mapValues(\.url) : [:]
    }

    /// Only when the model can use them (#254); pictures already added stay in `sides` while
    /// it's hidden, and `sidesUsed` sends none of them.
    @ViewBuilder private var sidesRow: some View {
        if makingWith.multiView {
            VStack(alignment: .leading, spacing: 6) {
                Text("More pictures of the same \(thing) (optional)")
                Text("Its back and sides, so the 3D model doesn't have to guess them. Drop each on its place, or click to choose.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) { ForEach(PictureSide.allCases, id: \.self) { sideSlot($0) } }
            }
        } else if !cartoonOn {
            HStack(alignment: .firstTextBaseline) {
                Text("TRELLIS.2 can also use pictures of the back and sides.").foregroundStyle(.secondary)
                Spacer()
                if madeWith == nil { OpenSettingsButton(tab: .model) { Text("Open Settings") } }
            }
            .font(.callout)
        }
    }

    private func sideSlot(_ side: PictureSide) -> some View {
        let words = side == .back ? side.words : String(localized: "\(side.words) side", comment: "“left side”: in “Add a picture of the %@”")
        return Button { chooser.open(side) } label: {
            VStack(spacing: 4) {
                if let p = sides[side] {
                    Image(nsImage: p.image).resizable().scaledToFit().frame(height: 60)
                } else {
                    Image(systemName: "plus").font(.title3).foregroundStyle(.secondary).frame(height: 60)
                }
                Text(side.title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .foregroundStyle(sideTargeted == side ? Color.accentColor : .secondary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sides[side] == nil ? "Add a picture of the \(words)" : "Change the picture of the \(words)")
        .help("A picture of the \(words) of the same \(thing). Drop it here or click to choose.")
        .overlay(alignment: .topTrailing) {
            if sides[side] != nil {
                Button { sides[side] = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(4)
                    .accessibilityLabel("Remove the picture of the \(words)")
                    .help("Remove this picture")
            }
        }
        .onDrop(of: PictureDrop.types, isTargeted: Binding(get: { sideTargeted == side },
                                                           set: { sideTargeted = $0 ? side : sideTargeted == side ? nil : sideTargeted })) { providers in
            Task {
                if let item = await PictureDrop.pictures(Array(providers.prefix(1))).first { takeSide(side, item.url) }
                else { say(String(localized: "That picture can't be read."), error: true) }
            }
            return true
        }
    }

    private func takeSide(_ side: PictureSide, _ url: URL) {
        guard let p = Picture(url) else { return say(String(localized: "That picture can't be read."), error: true) }
        sides[side] = p
        drawn = nil  // a change starts from the pictures chosen now
        message = nil
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
                            // As grey as the Name field's own placeholder: .tertiary measured 1.9:1 (#483).
                            .foregroundStyle(.secondary).padding(.leading, 9).padding(.top, 4).allowsHitTesting(false)
                    }
                }
                .onChange(of: description) { _, text in
                    guard name.isEmpty || autoName else { return }
                    name = MakeAdvice.name(fromDescription: text)
                    autoName = true
                }
            ImproveBox(description: description, kind: card.kind.rawValue, improved: $improved, request: $improving)
            if !health.picturesReady { needsPictures(String(localized: "A description needs \(health.pictureNeed).")) } else { opensWhenNeeded }
        }
    }

    @ViewBuilder private var opensWhenNeeded: some View {
        if health.drawThingsOpensWhenNeeded { Text("Mimic opens Draw Things when it needs it.").font(.callout).foregroundStyle(.secondary) }
    }

    private func needsPictures(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            OpenSettingsButton(tab: .drawThings) { Text("Open Settings") }
        }
        .font(.callout)
    }

    /// `unnamed`: what to say when the picture came without a name to give the mini.
    private func take(_ url: URL, unnamed: String? = nil) {
        guard let p = Picture(url) else { return say(String(localized: "That picture can't be read."), error: true) }
        picture = p
        start = .picture
        // Another picture has none of the changes the mini it was filled in from had.
        earlierFixes = []; earlierFixUsed = nil; drawn = nil
        message = nil
        if name.isEmpty {
            if let unnamed { say(String(localized: "\(unnamed) Give your mini a name.")); nameFocused = true }
            else { name = Rules.shownName(fromFile: url.deletingPathExtension().lastPathComponent) ?? "" }
        }
    }

    /// Pictures dropped or imported: several make a mini each, as several files dropped do.
    private func receive(_ providers: [NSItemProvider]) {
        Task {
            let items = await PictureDrop.pictures(providers)
            if items.count > 1 { make(items.map(\.url)) }
            else if let item = items.first { take(item.url, unnamed: item.named ? nil : String(localized: "Picture added.")) }
            else { say(String(localized: "That picture can't be read."), error: true) }
        }
    }

    private func paste() {
        let pb = NSPasteboard.general
        // Typing in a field (its editor is an NSText) with text to paste: the text, as anywhere.
        let typing = NSApp.keyWindow?.firstResponder is NSText
        let hasText = pb.availableType(from: [.string]) != nil
        let hasPicture = NSImage.canInit(with: pb) || pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]])
        guard MakeAdvice.pastesPicture(typing: typing, hasText: hasText, hasPicture: hasPicture) else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first {
            return take(url)
        }
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted picture \(UUID().uuidString.prefix(8)).png")
            if (try? png.write(to: url)) != nil { pasted.append(url); return take(url, unnamed: String(localized: "Picture pasted.")) }
        }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }

    // MARK: Making

    /// Its folder's name ("elodie" for "Élodie"), or empty while no name is typed.
    private var slug: String { Rules.shownName(name) == nil ? "" : Rules.folderName(name) }

    private var takenName: String? {
        // As Make Mini refuses it: a failed attempt's folder in the same place is made again.
        guard !slug.isEmpty, takenOnDisk == nameLookup || model.waiting(slug) != nil || model.current?.name == slug
        else { return nil }
        return model.displayName(slug)
    }

    /// The name and project `Gallery.nameTaken` was asked about, and the gallery then: it reads
    /// the minis folder, so it's asked off the main thread when one of these changes, not on
    /// every redraw (every key typed in Name), #340.
    private struct NameLookup: Equatable {
        let slug: String, project: String?, minis: [Mini]
    }
    private var nameLookup: NameLookup { NameLookup(slug: slug, project: project.name, minis: model.minis) }
    /// The last lookup that found the name taken.
    @State private var takenOnDisk: NameLookup?

    private func lookUpName() async {
        let lookup = nameLookup, runs = model.install.runs
        guard !lookup.slug.isEmpty else { takenOnDisk = nil; return }
        let taken = await Task.detached { Gallery.nameTaken(runs, lookup.slug, project: lookup.project) }.value
        if !Task.isCancelled { takenOnDisk = taken ? lookup : nil }
    }

    private var estimate: Estimate {
        model.estimateNew(drawn: start == .description || sculpt || changing, sizes: card.sizes, cartoon: cartoonOn, pictures: 1 + sidesUsed.count)
    }

    private var trimmedFix: String { fix.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A picture with a change typed: it's redrawn with it (#156).
    private var changing: Bool { start == .picture && !trimmedFix.isEmpty }

    /// "About 8 minutes on this Mac", or when it would wait: how long until it's ready.
    private var timing: String {
        let e = estimate
        let about = JobProgress.about(e.total).capitalizedFirst
        let own = e.learned ? String(localized: "\(about) on this Mac") : about
        guard model.current != nil else { return own }
        let ahead = model.queue.count + 1
        let ready = model.queueTimes().last?.ready ?? model.runningLeft()
        return String(localized: "Joins the queue, \(ahead) ahead · ready in \(JobProgress.about(ready + e.total))")
    }

    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What Make Mini is waiting for, said in the footer while the button is off.
    private var missing: String? {
        MakeAdvice.missing(fromPicture: start == .picture, hasPicture: picture != nil, description: trimmedDescription, kind: card.kind,
                           folder: slug, newProject: project == .new ? newProjectName : nil, fix: trimmedFix,
                           pictureNeed: health.picturesReady ? nil : health.pictureNeed)
    }

    /// Make Mini: with a change and the AI helper set up, once the helper has rewritten it.
    private func make() {
        guard missing == nil, !writing else { return }
        guard changing, FixWriter.helperOn else { return make(fixUsed: nil) }
        writing = true
        writingTask = Task {
            let used = await FixWriter.rewrite(trimmedFix, kind: card.kind)
            writing = false
            if !Task.isCancelled { make(fixUsed: used) }
        }
    }

    /// `fixUsed`: the AI helper's rewrite of the change typed, or nil to use it as typed.
    private func make(fixUsed used: String?) {
        let source: PictureSource
        var pictureSides = sidesUsed
        switch start {
        case .picture:
            guard let picture else { return }
            // A change starts from the picture the mini it was filled in from was drawn as.
            if changing, let drawn {
                source = .image(drawn)
                pictureSides = makingWith.multiView ? drawnSides : [:]
            } else {
                source = .image(picture.url)
            }
        case .description:
            let better = improved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            source = better.isEmpty ? .description(trimmedDescription) : .description(better, original: trimmedDescription)
        }
        let fixes = MakeAdvice.fixes(fromPicture: start == .picture, earlier: earlierFixes, fix: trimmedFix, drawn: drawn != nil)
        do {
            if project == .new { project = .existing(try model.createProject(newProjectName)) }
            try model.make(name: slug, picture: source, restyle: start == .picture && sculpt,
                           seed: seed, sizes: card.sizes, kind: card.kind, project: project.name, cartoon: cartoonOn, shown: name,
                           model: madeWith.flatMap { EngineDownload.model($0) }, shapeSeed: shapeSeed, sides: pictureSides,
                           fixes: fixes, fixUsed: changing ? used : earlierFixUsed, checkPicture: changing)
        } catch {
            say(model.plainWords(error), error: true)
            messageDetail = "\(error)"
        }
    }

    /// Several pictures dropped at once: a mini each, with this card's settings, named after its
    /// file. Names can be changed afterwards.
    private func make(_ pictures: [URL]) {
        guard model.requiredProblem == nil else { return }
        if project == .new && Rules.projectName(newProjectName) == nil { return say(String(localized: "Name the new project, then drop the pictures again."), error: true) }
        let typed = trimmedFix
        if !typed.isEmpty && !health.picturesReady { return say(String(localized: "A change needs \(health.pictureNeed) first."), error: true) }
        writing = !typed.isEmpty && FixWriter.helperOn
        writingTask = Task {
            let used = writing ? await FixWriter.rewrite(typed, kind: card.kind) : nil
            writing = false
            guard !Task.isCancelled else { return }
            do {
                if project == .new { project = .existing(try model.createProject(newProjectName)) }
                if let why = model.make(pictures: pictures, restyle: sculpt, seed: seed, sizes: card.sizes, kind: card.kind,
                                        project: project.name, cartoon: cartoonOn, fix: typed, fixUsed: used) { say(why, error: true) }
            } catch {
                say(model.plainWords(error), error: true)
                messageDetail = "\(error)"
            }
        }
    }

    private func say(_ text: String, error: Bool = false) { message = text; messageIsError = error; messageDetail = nil }
}
