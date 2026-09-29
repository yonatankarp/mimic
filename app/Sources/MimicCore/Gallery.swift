import Foundation

/// One mini: a folder under runs/ (or runs/<project>/) whose print file and previews are named
/// after it.
public struct Mini: Identifiable, Hashable, Sendable {
    public let name: String
    public let folder: URL
    public let madeAt: Date
    /// The project it's in (its parent folder's name), or nil when it's unsorted.
    public var project: String?
    public var id: String { name }

    public init(name: String, folder: URL, madeAt: Date, project: String? = nil) {
        self.name = name; self.folder = folder; self.madeAt = madeAt; self.project = project
    }
    public var stl: URL? { existing("\(name).stl") }
    public var source: URL? { existing("source.png") }
    /// The picture it was given, before step 1 made source.png from it.
    public var upload: URL? { existing("upload.img") }
    public var renders: [(view: String, url: URL)] {
        ["front", "side", "back"].compactMap { v in existing("\(name)_\(v).png").map { (v, $0) } }
    }
    /// The 3D model a resize starts from: without it only a full Make can finish the mini.
    public var hasModel: Bool { existing("model.glb") != nil }
    /// "dwarf-cleric" is shown as "Dwarf Cleric".
    public var displayName: String { Mini.displayName(name) }
    public static func displayName(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func existing(_ file: String) -> URL? {
        let u = folder.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static func == (a: Mini, b: Mini) -> Bool { a.name == b.name && a.madeAt == b.madeAt && a.project == b.project }
    public func hash(into h: inout Hasher) { h.combine(name) }
}

/// The minis folder on disk. A mini is a folder Mimic made (see `isMini`); any other folder at
/// the top is a project, holding minis one level down. Projects don't nest: a folder inside a
/// project that isn't a mini is ignored. Folders starting with "_" or "." are Mimic's own
/// scratch, and files at the top (.queue.json, .job.*) are never minis.
///
/// A mini's name is unique across the whole minis folder, projects included, so everything
/// that names a mini (the queue, `mimic resize <name>`, rename, trash, timings) finds it with
/// `folder(_:_:)` wherever it is.
public enum Gallery {
    /// Every mini, in every project, newest first.
    public static func list(_ runs: URL) -> [Mini] {
        var out: [Mini] = []
        for dir in subfolders(runs) {
            if isMini(dir) {
                out.append(Mini(name: dir.lastPathComponent, folder: dir, madeAt: madeAt(dir)))
            } else {
                out += subfolders(dir).filter(isMini).map {
                    Mini(name: $0.lastPathComponent, folder: $0, madeAt: madeAt($0), project: dir.lastPathComponent)
                }
            }
        }
        return out.sorted { $0.madeAt > $1.madeAt }
    }

    /// The projects, alphabetical (as Finder sorts), empty ones included.
    public static func projects(_ runs: URL) -> [String] {
        subfolders(runs).filter { !isMini($0) }.map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A folder is a mini when it holds a file only Mimic writes there: settings.json (every
    /// mini since the web version, written the moment it's asked for), model.glb (older ones
    /// had no settings) or a print file named after the folder. Not any .stl: one dragged into
    /// a project in Finder would make the project look like a mini.
    public static func isMini(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return ["settings.json", "model.glb", "\(folder.lastPathComponent).stl"]
            .contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Where the mini called `name` is, in whichever project, or nil when there's none.
    public static func folder(_ runs: URL, _ name: String) -> URL? {
        guard Rules.isValidName(name) else { return nil }
        // Checked by marker, not existence: on a Mac's disk "dwarf" also finds a project "Dwarf".
        let top = runs.appendingPathComponent(name)
        if isMini(top), exactName(top, name) { return top }
        for p in subfolders(runs) where !isMini(p) {
            let f = p.appendingPathComponent(name)
            if isMini(f), exactName(f, name) { return f }
        }
        return nil
    }

    /// Where a new mini called `name` goes: in `project`, or at the top.
    public static func newFolder(_ runs: URL, _ name: String, project: String?) -> URL {
        (project.map { runs.appendingPathComponent($0) } ?? runs).appendingPathComponent(name)
    }

    /// Whether `name` is used by a mini anywhere or by a project (on a Mac's disk "Dwarf" and
    /// "dwarf" are one folder).
    public static func nameInUse(_ runs: URL, _ name: String) -> Bool {
        folder(runs, name) != nil || projects(runs).contains { $0.lowercased() == name.lowercased() }
    }

    /// The folder's name as it is on disk, which on a case-insensitive disk may differ from the
    /// one asked for.
    static func exactName(_ folder: URL, _ name: String) -> Bool {
        let parent = folder.deletingLastPathComponent().path
        return ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).contains(name)
    }

    static func subfolders(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix("_") && !$0.lastPathComponent.hasPrefix(".") }
            // Built on `dir` as given: the listing's own URLs spell /var as /private/var.
            .map { dir.appendingPathComponent($0.lastPathComponent) }
    }

    /// When a mini was made: its print file's time (a rename leaves that alone, where the
    /// folder's own time changes), else its picture's, else the folder's.
    public static func madeAt(_ folder: URL) -> Date {
        let name = folder.lastPathComponent
        for f in ["\(name).stl", "source.png"] {
            let u = folder.appendingPathComponent(f)
            if let d = try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date { return d }
        }
        return (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date) ?? .distantPast
    }
}

extension Gallery {
    /// Renames a mini: its folder and every file named after it (the print file and the three
    /// previews), which is how the app finds them. Its date is the print file's, so it keeps its
    /// place in the gallery.
    public static func rename(_ runs: URL, from old: String, to new: String, busyWith: String? = nil) throws {
        guard Rules.isValidName(old), Rules.isValidName(new) else { throw RequestError.badName }
        guard old != new else { return }
        let fm = FileManager.default
        guard let src = folder(runs, old) else { throw RequestError.notFound }
        let dst = src.deletingLastPathComponent().appendingPathComponent(new)  // stays in its project
        guard !nameInUse(runs, new), !fm.fileExists(atPath: dst.path) else { throw RequestError.nameTaken(new) }
        guard busyWith != old else { throw RequestError.busy(old) }
        try fm.moveItem(at: src, to: dst)
        for suffix in [".stl", "_front.png", "_side.png", "_back.png"] {
            let f = dst.appendingPathComponent(old + suffix)
            if fm.fileExists(atPath: f.path) { try fm.moveItem(at: f, to: dst.appendingPathComponent(new + suffix)) }
        }
    }

    /// Moves a mini to the Trash, where it can be put back.
    public static func moveToTrash(_ runs: URL, name: String, busyWith: String? = nil,
                                   trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        guard busyWith != name else { throw RequestError.busy(name) }
        guard let folder = folder(runs, name) else { throw RequestError.notFound }
        try trash(folder)
    }
}
