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

    public init(mimic: String, engine: String, environment: [String: String]) {
        self.mimic = mimic; self.engine = engine; self.environment = environment
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

public enum JobKind: String, Codable, Sendable { case generate, prep }

public enum Pipeline {
    /// The steps that make (or resize) the mini in `folder`, from its saved settings. Built from
    /// settings.json alone, so Try Again rebuilds exactly the job that failed, from the step that
    /// failed: a picture already made (source.png) isn't drawn again, which with the same seed
    /// would draw the same one, and doesn't need Draw Things. Make clears a stale one first. A 3D
    /// shape already made (model.glb) isn't built again either: a make stopped by quitting in its
    /// last step carries on there (#82). Make refuses a folder that has one.
    public static func plan(_ kind: JobKind, folder: URL, settings: MiniSettings, tools: Tools) throws -> [(number: Int, step: Step)] {
        let name = folder.lastPathComponent
        guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
        // An object is sized by its longest side and stood on its whole bottom, not its feet;
        // a TRELLIS.2 model is turned round to face the front first (Prep turns before it levels).
        let flags = try (settings.requested ?? Sizes()).flags()
            + (settings.isObject ? ["--fit", "longest", "--ground", "bottom"] : [])
            + (model.turn == 0 ? [] : ["--turn", String(model.turn)])
            // The stones are laid out by the mini's own number: Try Again lays them the same way,
            // another version differently.
            + (settings.requested?.flags().contains("--base-style") == true ? ["--base-seed", String(settings.seed ?? 42)] : [])
        let prep: Step = .run(executable: tools.mimic,
                              arguments: ["_prep", folder.appendingPathComponent("model.glb").path,
                                          folder.appendingPathComponent("\(name).stl").path] + flags,
                              directory: nil, log: folder.appendingPathComponent("prep.log"))
        if kind == .prep { return [(3, prep)] }

        let seed = settings.seed ?? 42
        let source = folder.appendingPathComponent("source.png")
        let picture: Step
        switch settings.source {
        case .image:
            let upload = folder.appendingPathComponent("upload.img")
            picture = settings.restyle != true ? .copyPicture(from: upload, to: source)
                : settings.isObject ? .sculptObject(from: upload, seed: seed, to: source)
                : .sculptPicture(from: upload, seed: seed, to: source)
        case .desc:
            guard let desc = settings.desc, !desc.isEmpty else { throw RequestError.nothingToRetry }
            picture = settings.isObject ? .drawObject(description: desc, seed: seed, to: source)
                                        : .drawCharacter(description: desc, seed: seed, to: source)
        case nil:
            throw RequestError.nothingToRetry
        }
        let mesh: Step = .run(executable: tools.mimic,
                              arguments: ["_engine", source.path, folder.appendingPathComponent("model.glb").path,
                                          "--seed", String(settings.shapeSeed ?? seed), "--engine", tools.engine, "--model", model.id],
                              directory: nil, log: folder.appendingPathComponent("pixal3d.log"))
        let drawn = FileManager.default.fileExists(atPath: source.path)
        let shaped = drawn && FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.glb").path)
        return (drawn ? [] : [(1, picture)]) + (shaped ? [] : [(2, mesh)]) + [(3, prep)]
    }
}
