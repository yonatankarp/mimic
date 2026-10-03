import Foundation

/// One mini: a folder under runs/ (or runs/<project>/) whose print file and previews are named
/// after it.
public struct Mini: Identifiable, Hashable, Sendable {
    public let name: String
    public let folder: URL
    /// Its print file's time, new on every resize: what the 3D view and thumbnails watch.
    public let madeAt: Date
    /// When it was asked for, which a resize leaves alone: the list's order.
    public let created: Date
    /// The project it's in (its parent folder's name), or nil when it's unsorted.
    public var project: String?
    /// Its settings.json as the gallery read it, once per reload: what the list and its page
    /// show, so a redraw never reads the file. What a job runs from is read afresh instead.
    public let settings: MiniSettings
    /// It has its print file, as the gallery found it on its reload: what the Unfinished
    /// filter goes by, so filtering never looks on disk.
    public let finished: Bool
    /// Its sidebar picture (its first view, else its picture) and whether its picture waits to be
    /// checked, found once here, as the gallery reads it: a row's redraw never looks on disk (#437).
    public let thumbnail: URL?
    public let pictureToCheck: Bool
    public var id: String { name }

    /// The 3D shape in a mini's folder: what step 2 (or an import) writes and print prep reads.
    public static let modelFile = "model.glb"
    private static let views = ["front", "left", "right", "side", "back"]

    public init(name: String, folder: URL, madeAt: Date, created: Date? = nil, project: String? = nil, settings: MiniSettings = MiniSettings(),
                finished: Bool = true) {
        self.name = name; self.folder = folder; self.madeAt = madeAt; self.created = created ?? madeAt; self.project = project
        self.settings = settings; self.finished = finished
        thumbnail = Self.views.lazy.compactMap { Self.existing("\(name)_\($0).png", in: folder) }.first
            ?? Self.existing("source.png", in: folder) ?? Self.existing("upload.img", in: folder)
        pictureToCheck = !finished && Pipeline.pictureToCheck(folder, settings: settings)
    }
    public var stl: URL? { existing("\(name).stl") }
    /// Its print file as the gallery found it (`finished`), for what a view draws: `stl` looks on
    /// disk, which an action should, but a redraw shouldn't (#459).
    public var printFile: URL? { finished ? folder.appendingPathComponent("\(name).stl") : nil }
    public var source: URL? { existing("source.png") }
    /// The picture it was given, before step 1 made source.png from it.
    public var upload: URL? { existing("upload.img") }
    /// Its views, front first. A mini rendered before the left and right views has a side view
    /// instead, until a resize renders them (and removes it).
    public var renders: [(view: String, url: URL)] {
        Self.views.compactMap { v in existing("\(name)_\(v).png").map { (v, $0) } }
    }
    /// The pictures of the back and sides it was given besides the front one (#66): as step 1
    /// made them, else as given.
    public var sidePictures: [(side: PictureSide, url: URL)] {
        (settings.sides ?? []).compactMap { s in (existing(s.source) ?? existing(s.upload)).map { (s, $0) } }
    }
    /// What its page shows in Previews, in the order ← and → go through them: the picture it
    /// was given (and those of its back and sides), then its views. Only the ones it has.
    public var previews: [MiniPreview] {
        let sides = sidePictures
        return ((source ?? upload).map { [MiniPreview(caption: sides.isEmpty ? "Picture" : "Front picture", url: $0)] } ?? [])
            + sides.map { MiniPreview(caption: "\($0.side.title) picture", url: $0.url) }
            + renders.map { MiniPreview(caption: $0.view.capitalized, url: $0.url) }
    }
    /// Its print file faces +y, as print files did before 0.10.0 (#275), so the 3D view and
    /// Export for Virtual Tabletop turn it round. One made since says it faces front; those made
    /// with 0.10.0 before saying so was added are told by their date. An imported model was never
    /// turned, so it faces as its own file has it.
    public var facesAway: Bool { settings.facesFront != true && !settings.isImported && madeAt < Mini.facingFrontSince }
    /// When 0.10.0, the first Mimic to make print files face front, was published.
    public static let facingFrontSince = Date(timeIntervalSince1970: 1_790_928_043)  // 2 Oct 2026, 08:00:43 UTC
    /// The 3D model a resize starts from: without it only a full Make can finish the mini.
    public var hasModel: Bool { existing(Mini.modelFile) != nil }
    /// The name it was given ("Élodie"), from its settings as the gallery read them; a mini
    /// without one (older minis, one renamed or copied in Finder) goes by its folder's:
    /// "dwarf-cleric" is shown as "Dwarf Cleric".
    public var displayName: String { settings.shownName(folder: name) ?? Mini.displayName(name) }
    /// What it's shown as once renamed to `folder`, as `Gallery.rename` names it: so asking
    /// "Call it …?" shows the name it gets.
    public func displayName(renamedTo folder: String) -> String {
        settings.shownName(folder: name, renamedTo: folder) ?? Mini.displayName(folder)
    }
    public static func displayName(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    /// What the mini called `name` is shown as, found among `minis` (the gallery's list, so a
    /// redraw reads nothing), or its folder's name as shown when it isn't there.
    public static func displayName(_ name: String, in minis: [Mini]) -> String {
        minis.first { $0.name == name }?.displayName ?? displayName(name)
    }
    /// The same from its folder, for `mimic` in Terminal, which has no list to look in.
    public static func displayName(_ name: String, runs: URL) -> String {
        Gallery.folder(runs, name).flatMap { MiniSettings.load($0).shownName(folder: name) } ?? displayName(name)
    }

    /// "30 Sep, 18:23" in this Mac's time zone, for `mimic list`; a date from another year says
    /// which: "30 Sep 2025, 18:23". In English, like the rest of Mimic.
    public static func listDate(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM, HH:mm" : "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }

    private func existing(_ file: String) -> URL? { Self.existing(file, in: folder) }
    private static func existing(_ file: String, in folder: URL) -> URL? {
        let u = folder.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Settings, `finished` and what the row shows included, so a reload notices a run that
    /// failed or finished, or a rename that moved its versions.
    public static func == (a: Mini, b: Mini) -> Bool {
        a.name == b.name && a.madeAt == b.madeAt && a.project == b.project && a.settings == b.settings && a.finished == b.finished
            && a.thumbnail == b.thumbnail && a.pictureToCheck == b.pictureToCheck
    }
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
/// scratch, and files at the top are never minis.
///
/// A mini's name is unique across the whole minis folder, projects included, so everything
/// that names a mini (the queue, `mimic resize <name>`, rename, trash, timings) finds it with
/// `folder(_:_:)` wherever it is.
public enum Gallery {
    /// Every mini, in every project, the most recently asked for first.
    public static func list(_ runs: URL) -> [Mini] {
        var out: [Mini] = []
        func mini(_ dir: URL, project: String?) -> Mini {
            let settings = MiniSettings.load(dir), name = dir.lastPathComponent
            let finished = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).stl").path)
            return Mini(name: name, folder: dir, madeAt: madeAt(dir), created: created(dir, settings), project: project, settings: settings,
                        finished: finished)
        }
        for dir in subfolders(runs) {
            if isMini(dir) {
                out.append(mini(dir, project: nil))
            } else {
                out += subfolders(dir).filter(isMini).map { mini($0, project: dir.lastPathComponent) }
            }
        }
        return out.sorted { $0.created > $1.created }
    }

    /// The projects, alphabetical (as Finder sorts), empty ones included.
    public static func projects(_ runs: URL) -> [String] {
        subfolders(runs).filter { !isMini($0) }.map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Resize All on a project: which of its minis to resize, each to `sizes` but keeping its
    /// own base or none (a teapot in a party doesn't get the party's round base). At a `scale`
    /// (Game Scale), a character with its real height kept is sized from it, so a halfling stays
    /// shorter than an elf (#479); one without gets `sizes`' height. Those already made at them
    /// are left out (`same`); those that can't be resized now (no 3D model yet, or `busy`:
    /// waiting or being made) are `skipped`.
    public static func toResize(_ minis: [Mini], to sizes: Sizes, scale: Int? = nil, busy: Set<String>) -> (resize: [(mini: Mini, sizes: Sizes)], same: Int, skipped: Int) {
        var resize: [(mini: Mini, sizes: Sizes)] = [], same = 0, skipped = 0
        for mini in minis {
            let settings = mini.settings
            var own = sizes
            own.noBase = (settings.made ?? settings.requested)?.noBase ?? (settings.kind == .object)
            if own.noBase { own.shape = .round; own.style = .plain; own.magnet = nil }  // as it reads back: no base has no shape
            own.realHeight = settings.realHeight  // its own, never the card's
            if let scale, let real = own.realHeight {
                own.height = SizeCard.text(SizeCard.clamp(SizeCard.gameHeight(real: real, scale: scale), SizeCard.heightRange, step: 1))
            }
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
        return ["settings.json", Mini.modelFile, "\(folder.lastPathComponent).stl"]
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

    /// Whether a new mini can't be called `name` in `project`: any other mini (or a project) with
    /// the name, anywhere, keeps it. A failed attempt's folder in that same place doesn't: making
    /// it there makes it again. A failed attempt has no 3D model, no print file and no settings
    /// saying it was made; a finished mini whose model.glb is gone still keeps its name (#308).
    /// Nor is it waiting for its picture to be checked (#156): that one keeps its name too (#380).
    public static func nameTaken(_ runs: URL, _ name: String, project: String?) -> Bool {
        if let existing = folder(runs, name) {
            let fm = FileManager.default, settings = MiniSettings.load(existing)
            if existing.standardizedFileURL != newFolder(runs, name, project: project).standardizedFileURL
                || [Mini.modelFile, "\(existing.lastPathComponent).stl"].contains(where: { fm.fileExists(atPath: existing.appendingPathComponent($0).path) })
                || settings.made != nil || Pipeline.pictureToCheck(existing, settings: settings) {
                return true
            }
        }
        return projects(runs).contains { $0.lowercased() == name.lowercased() }
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

    /// When a mini's print file was last made: its time (a rename leaves that alone, where the
    /// folder's own time changes), else its picture's, else the folder's.
    public static func madeAt(_ folder: URL) -> Date {
        let name = folder.lastPathComponent
        for f in ["\(name).stl", "source.png"] {
            let u = folder.appendingPathComponent(f)
            if let d = try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date { return d }
        }
        return (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// When a mini was asked for: saved in its settings, else (older minis) its folder's creation
    /// date, which a rename, a move or a resize leaves alone.
    public static func created(_ folder: URL, _ settings: MiniSettings) -> Date {
        settings.created
            ?? (try? FileManager.default.attributesOfItem(atPath: folder.path)[.creationDate] as? Date) ?? .distantPast
    }
}

extension Gallery {
    /// Renames a mini: its folder and every file named after it (the print file and the
    /// previews), which is how the app finds them. It keeps its place in the gallery, which is
    /// by when it was asked for. `shown` is the name as typed, kept to show ("McGregor" for
    /// "mcgregor", which may be its folder's name already); without it, the name it had is
    /// carried over when it still fits (`Rules.shownName(carrying:to:)`).
    public static func rename(_ runs: URL, from old: String, to new: String, shown: String? = nil, busyWith: String? = nil) throws {
        guard Rules.isValidName(old), Rules.isValidName(new) else { throw RequestError.badName }
        let fm = FileManager.default
        guard let src = folder(runs, old) else { throw RequestError.notFound }
        let before = MiniSettings.load(src)
        let keep = shown ?? before.shownName(folder: old, renamedTo: new)
        guard old != new else {
            guard let shown, before.shownName(folder: old) != Rules.shownName(shown) else { return }
            guard busyWith != old else { throw RequestError.busy(old) }
            return try MiniSettings.update(src) { $0.name(shown, folder: new) }
        }
        let dst = src.deletingLastPathComponent().appendingPathComponent(new)  // stays in its project
        guard !nameInUse(runs, new), !fm.fileExists(atPath: dst.path) else { throw RequestError.nameTaken(new) }
        guard busyWith != old else { throw RequestError.busy(old) }
        try fm.moveItem(at: src, to: dst)
        try renameFiles(in: dst, from: old, to: new)
        // An older mini without a name of its own gets no settings for it.
        if keep != nil || before.name != nil { try? MiniSettings.update(dst) { $0.name(keep, folder: new) } }
        // Its other versions name it as their first: they follow it.
        for m in list(runs) where m.settings.versionOf == old {
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

    /// Moves a folder to a name that differs only in its capitals. The disk sees one name, so it
    /// goes through a third, a `_` folder the gallery never lists: when the second step fails, it
    /// goes back, so a mini or a whole project never looks deleted (#332).
    static func moveChangingCase(_ from: URL, to: URL,
                                 move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let step = from.deletingLastPathComponent().appendingPathComponent("_rename-\(UUID().uuidString)")
        try move(from, step)
        do { try move(step, to) } catch { try? move(step, from); throw error }
    }

    /// A mini renamed or copied in Finder ("Dwarf Cleric", "dwarf-cleric copy", iCloud's
    /// "dwarf-cleric 2"), or whose print file no longer matches its folder: the name its files
    /// have now, or nil when it's fine. That's its one print file's name (a `.part.stl` print
    /// prep left behind aside), else the folder's. Only one Mimic made, which has its previews
    /// beside it: one dropped in from elsewhere ("crow.stl") is left as it is (#336).
    static func oddFiles(_ mini: Mini) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mini.folder.path)) ?? []
        let stls = names.filter { $0.lowercased().hasSuffix(".stl") && !$0.lowercased().hasSuffix(".part.stl") }
        let stem = stls.count == 1 ? String(stls[0].dropLast(4)) : nil
        let files = stem.flatMap { s in
            ["front", "left", "right", "side", "back"].contains { names.contains("\(s)_\($0).png") } ? s : nil
        } ?? mini.name
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
                        try moveChangingCase(mini.folder, to: dst)
                    } else {
                        try fm.moveItem(at: mini.folder, to: dst)
                    }
                }
                try renameFiles(in: dst, from: files, to: dst.lastPathComponent)
                // A name typed in Finder ("Élodie la Druide", "McGregor") is kept to show, as a
                // name typed in Mimic is; a copy's ("dwarf-cleric copy") reads as before.
                if !Rules.isValidName(mini.name), mini.name != mini.name.lowercased() || !mini.name.allSatisfy(\.isASCII) {
                    try? MiniSettings.update(dst) { $0.name(Rules.shownName(mini.name, numberedAs: dst.lastPathComponent), folder: dst.lastPathComponent) }
                }
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
