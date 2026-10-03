import AppKit
import MimicCore
import SwiftUI
import UniformTypeIdentifiers

/// File → Import Model… (#96): a 3D model made elsewhere, sized and given a base like any mini.
enum ImportModel {
    /// Asks for a GLB or STL file, then opens the import sheet for it.
    @MainActor static func choose(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose a 3D model to make print-ready: a GLB or STL file."
        panel.prompt = "Import"
        panel.allowedContentTypes = ModelImport.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.showWindow()
        model.sheet = .importModel(url)
    }
}

/// The import sheet: the name (from the file's), the project, character or object, and the
/// size card, as in New Mini and Resize. Only print prep runs, so it takes about a minute.
struct ImportSheet: View {
    let file: URL
    let room: CGSize
    @Environment(AppModel.self) private var model
    @State private var card = SizeCard.remembered()
    @State private var name = ""
    @State private var project = ""
    @State private var height: CGFloat
    @State private var forms = FormHeights(columns: 1)
    @State private var problem: (words: String, detail: String)?

    init(file: URL, room: CGSize) {
        self.file = file
        self.room = room
        _height = State(initialValue: room.sheetHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import a 3D Model").font(.title2.bold())
                Text("Mimic makes it print-ready at these sizes, \(takes). It has no picture, so it can be resized and duplicated, but not made again.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    Picker(selection: Binding(get: { card.kind }, set: { card.setKind($0) })) {
                        Text("A character (a mini)").tag(MiniKind.character)
                        Text("Anything else").tag(MiniKind.object)
                    } label: { Label("What is it?", systemImage: card.kind == .object ? "cube" : "person.fill") }
                    .pickerStyle(.segmented)
                    .help("A character stands on a base; anything else is sized by its longest side")
                    TextField("Name", text: $name)
                        .help("How it's listed, and what its print file is called")
                    Picker("Project", selection: $project) {
                        Text("Unsorted").tag("")
                        ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                    }
                    .help("The folder it's kept in, and where it's listed on the left.")
                    if let taken {
                        Text("You already have a mini called \(taken). Pick a new name.").font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Label("Model", systemImage: "cube.transparent")
                } footer: {
                    Text("It stands the way up its file has it. If it comes out lying down, turn it upright in the app it came from and import it again.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SizeSection(card: $card, seed: nil)
            }
            .formStyle(.grouped)
            .reportsHeight(0, into: $forms)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let reason = model.requiredProblem {
                    CantStart(reason: reason)
                } else if let problem {
                    Label(problem.words, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(problem.detail)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Import") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.requiredProblem != nil || slug.isEmpty || taken != nil)
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580, height: height)
        .fitsForms($height, $forms, room: room.height)
        .onAppear {
            name = ModelImport.names(for: file, in: model.install.runs).shown
            project = model.selected?.project ?? ""
        }
    }

    /// Its folder's name, or empty while no name is typed.
    private var slug: String { Rules.shownName(name) == nil ? "" : Rules.folderName(name) }

    private var taken: String? {
        guard !slug.isEmpty, model.nameInUse(slug) || model.waiting(slug) != nil || model.current?.name == slug else { return nil }
        return model.displayName(slug)
    }

    private var takes: String { JobProgress.about(model.estimate(slug, .prep, sizes: card.sizes).total) }

    private func start() {
        do {
            try model.importModel(file, name: slug, shown: name, sizes: card.sizes, kind: card.kind, project: project.isEmpty ? nil : project)
        } catch {
            problem = (model.plainWords(error), "\(error)")
        }
    }
}
