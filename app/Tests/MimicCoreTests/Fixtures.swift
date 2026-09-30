import Foundation
@testable import MimicCore

/// A throwaway Mimic folder with fake tools: the job runner runs real processes, just not
/// print prep or the 3D engine.
struct Fixture {
    let root: URL
    let install: Install
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        install = Install(root: root)
    }

    /// A shell script to stand in for print prep or the 3D engine.
    func script(_ name: String, _ body: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// `mimic` stands in for Mimic's own binary, which steps 2 and 3 run as `mimic _engine …`
    /// and `mimic _prep …`.
    func tools(mimic: String = "/usr/bin/true") -> Tools {
        Tools(mimic: mimic, engine: install.engine.path,
              environment: ["PATH": "/usr/bin:/bin"])
    }

    /// Every weight file of `model` at its full size, sparse so gigabytes cost nothing; `short`
    /// is left a byte short, as an interrupted download would.
    func modelFiles(_ model: EngineModel = EngineDownload.standard, short: String? = nil) throws {
        let folder = model.folder(in: install)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for m in model.weights {
            let url = folder.appendingPathComponent(m.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(m.name == short ? m.bytes - 1 : m.bytes))
            try h.close()
        }
    }

    /// A mini folder with a 3D model, ready to resize.
    func mini(_ name: String) throws -> URL {
        let d = install.runs.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for f in ["model.glb", "\(name).stl", "\(name)_front.png", "\(name)_left.png", "\(name)_right.png", "\(name)_back.png", "source.png"] {
            FileManager.default.createFile(atPath: d.appendingPathComponent(f).path, contents: Data(f.utf8))
        }
        return d
    }
}

final class TrashSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    var trashed: [URL] { lock.withLock { items } }
    func callAsFunction(_ u: URL) { lock.withLock { items.append(u) } }
}
