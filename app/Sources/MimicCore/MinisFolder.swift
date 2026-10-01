import Foundation

/// Settings → General → Change… (#102): the minis can live in a folder of the person's choosing,
/// moved there, or found there when it already has minis. Kept in the app's settings, which
/// `mimic` in Terminal reads too (`Install.locate`), so both use the same folder and the same
/// queue.
public enum MinisFolder {
    /// The chosen folder's path.
    public static let key = "minisFolder"

    /// Whether `new` can be the minis folder instead of `old`: not the same folder, and neither
    /// inside the other (the old folder would become a project in the new one, or the new one a
    /// project in the old).
    public static func check(from old: URL, to new: URL) throws {
        let a = resolved(old), b = resolved(new)
        if a == b { throw RequestError.sameMinisFolder }
        if b.hasPrefix(a + "/") || a.hasPrefix(b + "/") { throw RequestError.minisFolderNested }
    }

    /// Moves every mini and project in `old` into `new`. A project already there by that name
    /// (compared without case, as the Mac's disk does) takes this one's minis; any other project
    /// moves whole, with files of the person's own in it. Names stay unique across the whole
    /// folder, so when a mini or project here has the name of one there, nothing moves and the
    /// error names them all: renaming them on the way would leave each folder disagreeing with
    /// its settings. Anything else in `old` (Mimic's own scratch, loose files) stays. A failed
    /// move puts back what had moved.
    public static func move(from old: URL, to new: URL) throws {
        let fm = FileManager.default
        let moves = try plan(from: old, to: new)
        var done: [(from: URL, to: URL)] = []
        do {
            for m in moves {
                try fm.createDirectory(at: m.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: m.from, to: m.to)
                done.append(m)
            }
        } catch {
            for m in done.reversed() { try? fm.moveItem(at: m.to, to: m.from) }
            throw error
        }
        // A project whose minis went into one of the same name, and the old folder, when that
        // left them empty.
        for p in Gallery.projects(old) { removeIfEmpty(old.appendingPathComponent(p)) }
        removeIfEmpty(old)
    }

    /// Where each mini and project goes, or the names that are taken there.
    static func plan(from old: URL, to new: URL) throws -> [(from: URL, to: URL)] {
        let minis = Gallery.list(old), there = Gallery.list(new).map { $0.name.lowercased() }
        let projectsThere = Gallery.projects(new)
        func taken(_ name: String) -> Bool {
            there.contains(name.lowercased()) || projectsThere.contains { $0.lowercased() == name.lowercased() }
        }
        var moves: [(from: URL, to: URL)] = [], clashes: [String] = []
        for m in minis where m.project == nil {
            if taken(m.name) { clashes.append(m.displayName) } else { moves.append((m.folder, new.appendingPathComponent(m.name))) }
        }
        for p in Gallery.projects(old) {
            let inside = minis.filter { $0.project == p }
            if there.contains(p.lowercased()) { clashes.append(p); continue }
            clashes += inside.filter { taken($0.name) }.map(\.displayName)
            if let same = projectsThere.first(where: { $0.lowercased() == p.lowercased() }) {
                moves += inside.map { ($0.folder, new.appendingPathComponent(same).appendingPathComponent($0.name)) }
            } else {
                moves.append((old.appendingPathComponent(p), new.appendingPathComponent(p)))
            }
        }
        guard clashes.isEmpty else { throw RequestError.minisFolderClash(clashes) }
        return moves
    }

    /// Removes a folder holding nothing but Finder's own .DS_Store.
    static func removeIfEmpty(_ folder: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              items.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}

extension JobRunner {
    /// Moves the minis into `new` (`moving`), or only checks they can go (they stay where they
    /// are), then calls `save`, which saves the setting. Refused while a mini is being made or
    /// waits, in any Mimic using this folder: a job finds its mini by name in this folder.
    ///
    /// The queue is marked as moving under its lock, and stays marked until `save` has run, so a
    /// Make asked for meanwhile, here or in another Mimic (`mimic make`), is refused rather than
    /// landing in the folder the minis are leaving; so are resizing, retrying, duplicating and
    /// moving minis. The lock itself isn't held while the files move, which can take minutes to
    /// another disk: a Make would wait that long for it, then write into the old folder.
    public func changeMinisFolder(to new: URL, moving: Bool, save: () -> Void = {}) throws {
        try MinisFolder.check(from: install.runs, to: new)
        try queue.locked { entries in
            guard entries.isEmpty, running() == nil, !queue.moving else { throw RequestError.minisFolderBusy }
            try queue.markMoving()
        }
        do {
            if moving { try MinisFolder.move(from: install.runs, to: new) }
        } catch {
            try? queue.locked { _ in queue.clearMoving() }
            throw error
        }
        try? queue.locked { _ in
            save()
            queue.clearMoving()
        }
        queue.clearMoving()  // even if the lock couldn't be had: this Mimic would refuse everything
    }

    /// Thrown inside the queue's lock by anything that changes the minis folder's contents.
    func refuseWhileMoving() throws {
        if queue.moving { throw RequestError.movingMinis }
    }
}
