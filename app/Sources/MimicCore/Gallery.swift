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
    /// Its views, front first. A mini rendered before the left and right views has a side view
    /// instead, until a resize renders them (and removes it).
    public var renders: [(view: String, url: URL)] {
        ["front", "left", "right", "side", "back"].compactMap { v in existing("\(name)_\(v).png").map { (v, $0) } }
    }
    /// What its page shows in Previews, in the order ← and → go through them: the picture it
    /// was given, then its views. Only the ones it has.
    public var previews: [MiniPreview] {
        ((source ?? upload).map { [MiniPreview(caption: "Picture", url: $0)] } ?? [])
            + renders.map { MiniPreview(caption: $0.view.capitalized, url: $0.url) }
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

/// One of a mini's pictures: the one it was made from, or a view of it.
public struct MiniPreview: Hashable, Identifiable, Sendable {
    public let caption: String
    public let url: URL
    public var id: URL { url }
}

extension [MiniPreview] {
    /// The preview `by` places (-1 or +1) from `from`, or nil past either end: ← and → stop at
    /// the first and last rather than going round.
    public func step(from: MiniPreview, by: Int) -> MiniPreview? {
        guard let i = firstIndex(of: from), indices.contains(i + by) else { return nil }
        return self[i + by]
    }

    /// The preview above (-1) or below (+1) `from` on the page, where the first `wide` (0 or 1)
    /// sit full width over the views two by two: ↓ from the picture is the first view, ↑ from the
    /// top row of views is the picture. Nil past the top or bottom.
    public func step(from: MiniPreview, down by: Int, wide: Int) -> MiniPreview? {
        guard let i = firstIndex(of: from) else { return nil }
        let j = i < wide ? (by > 0 ? wide : -1)
            : i - wide < 2 && by < 0 ? wide - 1
            : i + 2 * by
        return indices.contains(j) ? self[j] : nil
    }
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

    /// Resize All on a project: which of its minis to resize, each to `sizes` but keeping its
    /// own base or none (a teapot in a party doesn't get the party's round base). Those already
    /// made at them are left out (`same`); those that can't be resized now (no 3D model yet, or
    /// `busy`: waiting or being made) are `skipped`.
    public static func toResize(_ minis: [Mini], to sizes: Sizes, busy: Set<String>) -> (resize: [(mini: Mini, sizes: Sizes)], same: Int, skipped: Int) {
        var resize: [(mini: Mini, sizes: Sizes)] = [], same = 0, skipped = 0
        for mini in minis {
            let settings = MiniSettings.load(mini.folder)
            var own = sizes
            own.noBase = (settings.made ?? settings.requested)?.noBase ?? (settings.kind == .object)
            if own.noBase { own.shape = .round; own.style = .plain }  // as it reads back: no base has no shape
            if !mini.hasModel || busy.contains(mini.name) { skipped += 1 }
            else if settings.made == own { same += 1 }
            else { resize.append((mini, own)) }
        }
        return (resize, same, skipped)
    }

    /// Move to Trash on several minis: all of them but the one being made, which stays (and is
    /// said, before anything goes).
    public static func toTrash(_ minis: [Mini], busyWith: String?) -> (trash: [Mini], staying: Mini?) {
        (minis.filter { $0.name != busyWith }, minis.first { $0.name == busyWith })
    }

    /// Several minis dragged together travel as one text, a name a line (a name has no line
    /// breaks); `dropped` reads it back, and a single name, as the names dropped.
    public static func dragged(_ names: [String]) -> String { names.joined(separator: "\n") }
    public static func dropped(_ items: [String]) -> [String] { items.flatMap { $0.split(separator: "\n").map(String.init) } }

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
    /// Renames a mini: its folder and every file named after it (the print file and the
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
        try renameFiles(in: dst, from: old, to: new)
        // Its other versions name it as their first: they follow it.
        for m in list(runs) where MiniSettings.load(m.folder).versionOf == old {
            try? MiniSettings.update(m.folder) { $0.versionOf = new }
        }
    }

    /// The files named after a mini (the print file and the previews), which is how the app
    /// finds them, renamed from `old` to `new`. Never over a file already there.
    static func renameFiles(in dir: URL, from old: String, to new: String) throws {
        guard old != new else { return }
        let fm = FileManager.default
        for suffix in [".stl", "_front.png", "_left.png", "_right.png", "_side.png", "_back.png"] {
            let f = dir.appendingPathComponent(old + suffix)
            if fm.fileExists(atPath: f.path) { try fm.moveItem(at: f, to: dir.appendingPathComponent(new + suffix)) }
        }
    }

    /// A mini renamed or copied in Finder ("Dwarf Cleric", "dwarf-cleric copy", iCloud's
    /// "dwarf-cleric 2"), or whose print file no longer matches its folder: the name its files
    /// have now, or nil when it's fine. That's its one print file's name (a `.part.stl` print
    /// prep left behind aside), else the folder's.
    static func oddFiles(_ mini: Mini) -> String? {
        let stls = ((try? FileManager.default.contentsOfDirectory(atPath: mini.folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".stl") && !$0.lowercased().hasSuffix(".part.stl") }
        let files = stls.count == 1 ? String(stls[0].dropLast(4)) : mini.name
        return !Rules.isValidName(mini.name) || (mini.stl == nil && files != mini.name) ? files : nil
    }

    /// Takes over the minis `oddFiles` finds, so the app can find, rename and resize them: the
    /// folder gets a valid name no mini or project has ("Dwarf Cleric" → "dwarf-cleric", or
    /// "dwarf-cleric-2" when that's taken) and its files follow. Nothing is ever moved over
    /// something already there, and a mini whose folder or files are named in `busy` (being
    /// made or waiting) is left alone. Returns the new names.
    @discardableResult
    public static func adopt(_ runs: URL, busy: Set<String>) -> [String] {
        let fm = FileManager.default
        var adopted: [String] = []
        for mini in list(runs) {
            guard let files = oddFiles(mini), !busy.contains(mini.name), !busy.contains(files) else { continue }
            let parent = mini.folder.deletingLastPathComponent()
            var dst = mini.folder
            do {
                if !Rules.isValidName(mini.name) {
                    var new = freeName(runs, mini.name)
                    // Free in the gallery, but a folder that isn't a mini may still be there.
                    while new != mini.name.lowercased() && fm.fileExists(atPath: parent.appendingPathComponent(new).path) {
                        new = nextVersionName(runs, new)
                    }
                    dst = parent.appendingPathComponent(new)
                    if new == mini.name.lowercased() {
                        // Only the capitals change: the disk sees one name, so it goes through a third.
                        let step = parent.appendingPathComponent("_rename-\(UUID().uuidString)")
                        try fm.moveItem(at: mini.folder, to: step)
                        try fm.moveItem(at: step, to: dst)
                    } else {
                        try fm.moveItem(at: mini.folder, to: dst)
                    }
                }
                try renameFiles(in: dst, from: files, to: dst.lastPathComponent)
                adopted.append(dst.lastPathComponent)
            } catch { continue }  // left as it is: Trash and Show in Finder still work on it
        }
        return adopted
    }

    /// Moves a mini to the Trash, where it can be put back. `folder` is where the gallery found
    /// it, so one it couldn't take over still goes. Returns its folder and where it went in the
    /// Trash, for Undo (`putBack`).
    @discardableResult
    public static func moveToTrash(_ runs: URL, name: String, folder: URL? = nil, busyWith: String? = nil,
                                   trash: (URL) throws -> URL? = Gallery.trash) throws -> (folder: URL, trashed: URL?) {
        guard busyWith != name else { throw RequestError.busy(name) }
        guard let folder = folder ?? Gallery.folder(runs, name) else { throw RequestError.notFound }
        return (folder, try trash(folder))
    }

    /// The Mac's Trash: where the item went there.
    public static func trash(_ url: URL) throws -> URL? {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    /// Undo for Move to Trash: puts a mini's folder back from the Trash where it was, making its
    /// project again if that has gone. Refused when a mini or project has taken its name since.
    public static func putBack(_ runs: URL, from trashed: URL, to folder: URL) throws {
        let name = folder.lastPathComponent
        guard !nameInUse(runs, name) else { throw RequestError.nameTaken(name) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: trashed, to: folder)
    }
}
