import Foundation
import simd

/// Import Model (#96): print prep for a 3D model made elsewhere, a GLB from another generator or
/// an STL from HeroForge and the like. It becomes a mini with model.glb and no picture, so the
/// gallery, Resize and Duplicate treat it as any other; only print prep ever runs on it.
public enum ModelImport {
    /// The file types Import Model takes.
    public static let extensions = ["glb", "stl"]

    /// The new mini's name, as shown and as its folder, from the file's, as for pictures dropped
    /// on New Mini: "Ogre Chief.stl" is "Ogre Chief" in "ogre-chief", or "Ogre Chief 2" in
    /// "ogre-chief-2" when that's taken.
    public static func names(for file: URL, in runs: URL) -> (shown: String, folder: String) {
        let folder = Gallery.name(forPicture: file, in: runs)
        let shown = Rules.shownName(fromFile: file.deletingPathExtension().lastPathComponent).map { Rules.shownName($0, numberedAs: folder) }
        return (shown ?? Mini.displayName(folder), folder)
    }

    /// What goes in the new mini's folder as model.glb, and a line for its print prep log.
    public struct Read: Sendable {
        public let glb: Data
        public let note: String?
    }

    /// Reads `url` and checks there's a shape in it, before anything is written. A GLB is y up
    /// by glTF's spec; an STL is taken as z up, as slicers take it, and in millimetres. Either way
    /// its triangles are joined where their corners meet: an STL keeps no corner shared, and many
    /// GLBs split them at every seam or face. Print prep finds a model's main pieces (what an
    /// object is sized by and stands on) by shared corners, and of unjoined triangles finds none.
    public static func read(_ url: URL) throws -> Read { try read(url, most: GLB.most) }

    static func read(_ url: URL, most: Int) throws -> Read {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw RequestError.unreadableModel(String(localized: "it's another kind of file", bundle: .mimicCore)) }
        guard let data = try? Data(contentsOf: url) else { throw RequestError.unreadableModel(String(localized: "it can't be opened", bundle: .mimicCore)) }
        let corners: [SIMD3<Float>]
        if ext == "glb" {
            let mesh: Mesh
            do { mesh = try GLB.parse(data, painted: false, most: most).mesh }
            // The reader's own reason, such as "the .glb is too big" (#438); JSON's raw text isn't one.
            catch let e as PrepError { throw RequestError.unreadableModel(e.description) }
            catch { throw RequestError.unreadableModel(String(localized: "its shape is stored in a way Mimic can't read", bundle: .mimicCore)) }
            corners = mesh.triangles.flatMap { [mesh.positions[Int($0.x)], mesh.positions[Int($0.y)], mesh.positions[Int($0.z)]] }
        } else {
            corners = try stlCorners(data)
        }
        let mesh = try weld(corners)
        guard !mesh.triangles.isEmpty else { throw RequestError.unreadableModel(String(localized: "it has no shape in it", bundle: .mimicCore)) }
        // A GLB's units are metres by its spec, and generators' sizes vary: only an STL's are a hint.
        return Read(glb: GLB.encode(mesh), note: ext == "stl" ? unitsNote(mesh) : nil)
    }

    /// Every triangle's three corners, in order, from a binary STL or a text one. Binary when its
    /// size is exactly what its triangle count says: some binary files start with "solid" too.
    static func stlCorners(_ data: Data) throws -> [SIMD3<Float>] {
        if data.count >= 84 {
            let n = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) }
            if data.count == 84 + 50 * n {
                return data.withUnsafeBytes { b in
                    var out: [SIMD3<Float>] = []
                    out.reserveCapacity(3 * n)
                    for t in 0..<n {
                        for v in 1...3 {
                            let o = 84 + t * 50 + v * 12
                            func f(_ at: Int) -> Float { Float(bitPattern: UInt32(littleEndian: b.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
                            out.append(SIMD3(f(o), f(o + 4), f(o + 8)))
                        }
                    }
                    return out
                }
            }
        }
        // Text: "vertex x y z" lines, three to a facet.
        let text = String(decoding: data, as: UTF8.self)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("solid") else {
            throw RequestError.unreadableModel(String(localized: "it's cut short or isn't a 3D model", bundle: .mimicCore))
        }
        var out: [SIMD3<Float>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first?.lowercased() == "vertex" else { continue }
            guard words.count == 4, let x = Float(words[1]), let y = Float(words[2]), let z = Float(words[3]) else {
                throw RequestError.unreadableModel(String(localized: "it's cut short or isn't a 3D model", bundle: .mimicCore))
            }
            out.append(SIMD3(x, y, z))
        }
        guard out.count % 3 == 0 else { throw RequestError.unreadableModel(String(localized: "it's cut short or isn't a 3D model", bundle: .mimicCore)) }
        return out
    }

    /// Triangles given as separate corners (an STL's) joined into one mesh: corners in the same
    /// place, to a millionth of the model's size, become one, and a triangle left with two
    /// corners in one place (a sliver) is dropped. Corners that aren't numbers are dropped too.
    /// Corners further apart than any model's are refused: past Float's range the grid's cells
    /// would be infinite and its places not numbers (#334).
    public static func weld(_ corners: [SIMD3<Float>]) throws -> Mesh {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in corners where p.x.isFinite && p.y.isFinite && p.z.isFinite { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        var mesh = Mesh()
        guard lo.x <= hi.x else { return mesh }
        let span = simd_length(hi - lo)
        guard span.isFinite, span <= 1e7 else { throw RequestError.unreadableModel(String(localized: "its corners are too far apart to be one model", bundle: .mimicCore)) }
        let cell = max(span * 1e-6, .leastNormalMagnitude)
        var index: [SIMD3<Int32>: UInt32] = [:]
        index.reserveCapacity(corners.count / 2)
        func vertex(_ p: SIMD3<Float>) -> UInt32 {
            let key = SIMD3<Int32>(((p - lo) / cell).rounded(.toNearestOrAwayFromZero))
            if let i = index[key] { return i }
            let i = UInt32(mesh.positions.count)
            mesh.positions.append(p)
            index[key] = i
            return i
        }
        for t in stride(from: 0, to: corners.count - 2, by: 3) {
            let c = corners[t..<t + 3]
            guard c.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { continue }
            let tri = SIMD3(vertex(c[t]), vertex(c[t + 1]), vertex(c[t + 2]))
            if tri.x != tri.y && tri.y != tri.z && tri.x != tri.z { mesh.triangles.append(tri) }
        }
        return mesh
    }

    /// What to tell the prep log when an STL's size doesn't look like millimetres: by its longest
    /// side, so it doesn't depend on which way is up. Print prep sizes it to what was asked for
    /// either way, so this only explains a model that looked tiny or huge before.
    public static func unitsNote(_ mesh: Mesh) -> String? {
        let b = mesh.bounds, longest = Double((b.hi - b.lo).max())
        let size = String(format: "%g", (longest * 1000).rounded() / 1000)
        if longest < 0.5 {
            return "import: the model is \(size) mm across, so it's probably in metres; it's sized to what you asked for anyway"
        }
        if longest < 5 {
            return "import: the model is \(size) mm across, so it's probably in inches; it's sized to what you asked for anyway"
        }
        if longest > 500 {
            return "import: the model is \(size) mm across, so it's probably in a unit smaller than millimetres; it's sized to what you asked for anyway"
        }
        return nil
    }
}

extension JobRunner {
    /// An imported mini whose print file isn't made yet: its print prep is its import, not a resize.
    public static func importing(_ folder: URL) -> Bool {
        MiniSettings.load(folder).isImported
            && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(folder.lastPathComponent).stl").path)
    }

    /// What a job of `kind` is doing, for the progress window and the list: "Making", "Resizing",
    /// or "Importing" for an import's first print prep.
    public static func doing(_ kind: JobKind, importing: Bool) -> String {
        kind == .generate ? String(localized: "Making", bundle: .mimicCore)
            : importing ? String(localized: "Importing", bundle: .mimicCore) : String(localized: "Resizing", bundle: .mimicCore)
    }

    /// Imports the 3D model at `file` as a new mini called `name` (`shown` as typed), of `kind`,
    /// in `project`, and queues its print prep at `sizes`. Like `make`, everything is checked and
    /// the file read before anything is written; then its folder, settings and model.glb are
    /// written and it joins the queue. Needs no 3D engine. Returns nil when it started at once,
    /// else how many jobs are ahead of it.
    @discardableResult
    public func importModel(_ file: URL, name: String, shown: String? = nil, sizes: Sizes, kind: MiniKind = .character,
                            project: String? = nil) throws -> Int? {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        if let project, !Gallery.projects(install.runs).contains(project) { throw RequestError.projectNotFound }
        _ = try sizes.flags()
        let read = try ModelImport.read(file)
        var settings = MiniSettings()
        settings.imported = file.lastPathComponent
        settings.requested = sizes
        settings.kind = kind == .object ? .object : nil
        let fm = FileManager.default
        let folder = Gallery.newFolder(install.runs, name, project: project)
        _ = try Pipeline.plan(.prep, folder: folder, settings: settings, tools: tools)
        return try queue.locked { entries in
            try checkFree(name, entries)
            guard !Gallery.nameInUse(install.runs, name), !fm.fileExists(atPath: folder.path) else { throw RequestError.nameTaken(name) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                // settings.json first: it's what makes the folder a mini.
                try MiniSettings.update(folder) { s in
                    s = settings
                    s.name(shown, folder: name)
                    s.created = Date()
                }
                try read.glb.write(to: folder.appendingPathComponent(Mini.modelFile), options: .atomic)
                if let note = read.note { try Data("\(note)\n".utf8).write(to: folder.appendingPathComponent("prep.log")) }
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
            return enqueue(QueueEntry(name: name, job: .prep, sizes: sizes), &entries)
        }
    }
}
