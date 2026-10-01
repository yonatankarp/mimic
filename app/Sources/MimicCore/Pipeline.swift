import Foundation

/// The programs a job runs, as absolute paths, and the environment they run in. Resolved once:
/// launched from the Dock, the app's own PATH is launchd's bare one.
public struct Tools: Sendable {
    /// Mimic's own binary: the 3D engine and print prep are its hidden `_engine` and `_prep`
    /// commands, each run as a separate program so Stop can end it like any other step.
    public var mimic: String
    /// The 3D engine's folder (trellis-cli, its libraries, `models/`).
    public var engine: String
    public var environment: [String: String]
    /// Step 1's Draw Things; nil is the real one. Tests give theirs here, so none reaches the real one.
    public var drawThings: DrawThings?

    public init(mimic: String, engine: String, environment: [String: String], drawThings: DrawThings? = nil) {
        self.mimic = mimic; self.engine = engine; self.environment = environment; self.drawThings = drawThings
    }

    public static func resolve(_ install: Install) -> Tools {
        Tools(mimic: ownExecutable(), engine: install.engine.path, environment: childEnvironment())
    }

    /// The running binary's real path: through the installer's symlink on the PATH,
    /// CommandLine.arguments[0] is just "mimic".
    public static func ownExecutable() -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// What every job step runs with: Homebrew on the PATH, nothing else inherited.
    public static func childEnvironment(home: String = NSHomeDirectory()) -> [String: String] {
        ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": home, "USER": NSUserName(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }
}

/// One step of a job. The first step works in Swift (copy a picture, or ask Draw Things); the
/// other two run a program.
public enum Step: Equatable, Sendable {
    case copyPicture(from: URL, to: URL)
    case drawCharacter(description: String, seed: Int, to: URL)
    case sculptPicture(from: URL, seed: Int, to: URL)
    /// The same two for anything that isn't a character (see `MiniKind`).
    case drawObject(description: String, seed: Int, to: URL)
    case sculptObject(from: URL, seed: Int, to: URL)
    case run(executable: String, arguments: [String], directory: String?, log: URL)
}

extension Step {
    /// The picture step 1 writes.
    var makes: URL? {
        switch self {
        case let .copyPicture(_, to), let .drawCharacter(_, _, to), let .sculptPicture(_, _, to),
             let .drawObject(_, _, to), let .sculptObject(_, _, to): to
        case .run: nil
        }
    }
}

public enum JobKind: String, Codable, Sendable { case generate, prep }

public enum Pipeline {
    /// The steps that make (or resize) the mini in `folder`, from its saved settings. Built from
    /// settings.json alone, so Try Again rebuilds exactly the job that failed, from the step that
    /// failed: a picture already made (source.png) isn't drawn again, which with the same seed
    /// would draw the same one, and doesn't need Draw Things. Make clears a stale one first. A 3D
    /// shape already made (model.glb) isn't built again either: a make stopped by quitting in its
    /// last step carries on there (#82). Make refuses a folder that has one.
    public static func plan(_ kind: JobKind, folder: URL, settings: MiniSettings, tools: Tools) throws -> [(number: JobStep, step: Step)] {
        let name = folder.lastPathComponent
        // An imported model (#96) wasn't made by any 3D model here, so it's never turned: it
        // faces whichever way its own file has it.
        let turn: Int
        if settings.isImported {
            turn = 0
        } else {
            guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
            turn = model.turn
        }
        // An object is sized by its longest side and stood on its whole bottom, not its feet;
        // a TRELLIS.2 model is turned round to face the front first (Prep turns before it levels).
        let flags = try (settings.requested ?? Sizes()).flags()
            + (settings.isObject ? ["--fit", "longest", "--ground", "bottom"] : [])
            + (turn == 0 ? [] : ["--turn", String(turn)])
            // The stones are laid out by the mini's own number: Try Again lays them the same way,
            // another version differently.
            + (settings.requested?.flags().contains("--base-style") == true ? ["--base-seed", String(settings.seed ?? 42)] : [])
        let prep: Step = .run(executable: tools.mimic,
                              arguments: ["_prep", folder.appendingPathComponent(Mini.modelFile).path,
                                          folder.appendingPathComponent("\(name).stl").path] + flags,
                              directory: nil, log: folder.appendingPathComponent("prep.log"))
        if kind == .prep { return [(.print, prep)] }
        if settings.isImported { throw RequestError.imported(name) }
        guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }

        let seed = settings.seed ?? 42
        let source = folder.appendingPathComponent("source.png")
        // Each picture is made its own way, the extra ones exactly as the front one (#66), so
        // all of them look alike to the 3D engine.
        let pictures: [Step]
        switch settings.source {
        case .image:
            func made(_ upload: String, _ to: URL) -> Step {
                let from = folder.appendingPathComponent(upload)
                return settings.restyle != true ? .copyPicture(from: from, to: to)
                    : settings.isObject ? .sculptObject(from: from, seed: seed, to: to)
                    : .sculptPicture(from: from, seed: seed, to: to)
            }
            pictures = [made("upload.img", source)]
                + (settings.sides ?? []).map { made($0.upload, folder.appendingPathComponent($0.source)) }
        case .desc:
            guard let desc = settings.desc, !desc.isEmpty else { throw RequestError.nothingToRetry }
            pictures = [settings.isObject ? .drawObject(description: desc, seed: seed, to: source)
                                          : .drawCharacter(description: desc, seed: seed, to: source)]
        case nil:
            throw RequestError.nothingToRetry
        }
        let sides = settings.source == .image ? settings.sides ?? [] : []
        let mesh: Step = .run(executable: tools.mimic,
                              arguments: ["_engine", source.path, folder.appendingPathComponent(Mini.modelFile).path,
                                          "--seed", String(settings.shapeSeed ?? seed), "--engine", tools.engine, "--model", model.id]
                                  + sides.flatMap { ["--\($0.rawValue)", folder.appendingPathComponent($0.source).path] },
                              directory: nil, log: folder.appendingPathComponent("pixal3d.log"))
        let skip = skipped(folder, sides: sides)
        // A picture already made isn't made again, each on its own: a make stopped while
        // sculpting the back keeps the front.
        let fm = FileManager.default
        return pictures.filter { !fm.fileExists(atPath: $0.makes?.path ?? "") }.map { (.picture, $0) }
            + (skip.contains(.shape) ? [] : [(.shape, mesh)]) + [(.print, prep)]
    }

    /// The steps a make of the mini in `folder` skips because what they make is there already:
    /// the picture (source.png and one for each of its `sides`: Try Again, a new 3D shape), and
    /// the 3D shape too when it has model.glb as well (a make stopped in its last step).
    public static func skipped(_ folder: URL, sides: [PictureSide] = []) -> Set<JobStep> {
        let fm = FileManager.default
        guard (["source.png"] + sides.map(\.source)).allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) else { return [] }
        return fm.fileExists(atPath: folder.appendingPathComponent(Mini.modelFile).path) ? [.picture, .shape] : [.picture]
    }
}

/// The pictures a mini can have besides its front one (#66), each of the character seen from
/// that side. Only TRELLIS.2 can use them (`EngineModel.multiView`). Kept in the mini's folder
/// as given (`upload`) and as step 1 made it (`source`), like the front's upload.img and
/// source.png; the order here is the order the 3D engine is given them, after the front.
public enum PictureSide: String, Codable, CaseIterable, Sendable {
    case back, left, right
    /// "Back", as New Mini labels its place.
    public var title: String { rawValue.capitalized }
    public var upload: String { "upload-\(rawValue).img" }
    public var source: String { "source-\(rawValue).png" }
}
