import Foundation

/// The programs a job runs, as absolute paths, and the environment they run in. Resolved once:
/// launched from the Dock, the app's own PATH is launchd's bare one, where Blender isn't.
public struct Tools: Sendable {
    public var blender: String?
    public var python: String
    public var pixal3dScript: String
    public var labDir: String
    public var miniPrep: String
    public var environment: [String: String]

    public init(blender: String?, python: String, pixal3dScript: String, labDir: String, miniPrep: String, environment: [String: String]) {
        self.blender = blender; self.python = python; self.pixal3dScript = pixal3dScript
        self.labDir = labDir; self.miniPrep = miniPrep; self.environment = environment
    }

    public static func resolve(_ install: Install) -> Tools {
        let env = childEnvironment()
        return Tools(blender: which("blender", path: env["PATH"]!),
                     python: install.labPython.path,
                     pixal3dScript: install.lab.appendingPathComponent("scripts/pixal3d_generate.py").path,
                     labDir: install.lab.path,
                     miniPrep: install.pipeline.appendingPathComponent("mini_prep.py").path,
                     environment: env)
    }

    /// What every job step runs with: Homebrew and Blender on the PATH, nothing else inherited.
    public static func childEnvironment(home: String = NSHomeDirectory()) -> [String: String] {
        ["PATH": "/opt/homebrew/bin:/Applications/Blender.app/Contents/MacOS:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": home, "USER": NSUserName(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }

    public static func which(_ name: String, path: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
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
        guard let blender = tools.blender else { throw RequestError.missing("Blender") }
        let prep: Step = .run(executable: blender,
                              arguments: ["-b", "-P", tools.miniPrep, "--",
                                          folder.appendingPathComponent("model.glb").path,
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
