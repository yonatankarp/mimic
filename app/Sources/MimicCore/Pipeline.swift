import Foundation

/// The programs a job runs, as absolute paths, and the environment they run in. Resolved once:
/// launched from the Dock, the app's own PATH is launchd's bare one.
public struct Tools: Sendable {
    /// Mimic's own binary: print prep is its hidden `_prep` command, run as a separate program
    /// so Stop can end it like any other step.
    public var prep: String
    public var python: String
    public var pixal3dScript: String
    public var labDir: String
    public var environment: [String: String]

    public init(prep: String, python: String, pixal3dScript: String, labDir: String, environment: [String: String]) {
        self.prep = prep; self.python = python; self.pixal3dScript = pixal3dScript
        self.labDir = labDir; self.environment = environment
    }

    public static func resolve(_ install: Install) -> Tools {
        Tools(prep: ownExecutable(),
              python: install.labPython.path,
              pixal3dScript: install.lab.appendingPathComponent("scripts/pixal3d_generate.py").path,
              labDir: install.lab.path,
              environment: childEnvironment())
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
    case run(executable: String, arguments: [String], directory: String?, log: URL)
}

public enum JobKind: String, Sendable { case generate, prep }

public enum Pipeline {
    /// The steps that make (or resize) the mini in `folder`, from its saved settings. Built from
    /// settings.json alone, so Try Again rebuilds exactly the job that failed.
    public static func plan(_ kind: JobKind, folder: URL, settings: MiniSettings, tools: Tools) throws -> [(number: Int, step: Step)] {
        let name = folder.lastPathComponent
        let flags = try (settings.requested ?? Sizes()).flags()
        let prep: Step = .run(executable: tools.prep,
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
            picture = settings.restyle == true ? .sculptPicture(from: upload, seed: seed, to: source)
                                               : .copyPicture(from: upload, to: source)
        case .desc:
            guard let desc = settings.desc, !desc.isEmpty else { throw RequestError.nothingToRetry }
            picture = .drawCharacter(description: desc, seed: seed, to: source)
        case nil:
            throw RequestError.nothingToRetry
        }
        let mesh: Step = .run(executable: tools.python,
                              arguments: [tools.pixal3dScript, source.path, folder.appendingPathComponent("model.glb").path,
                                          "--seed", String(seed)],
                              directory: tools.labDir, log: folder.appendingPathComponent("pixal3d.log"))
        return [(1, picture), (2, mesh), (3, prep)]
    }
}
