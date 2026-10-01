import Foundation

/// Projects: real folders in the minis folder, one level deep (`runs/<Project>/<mini>/`), so
/// Finder shows the same grouping. See `Gallery` for how a project is told from a mini.
extension Gallery {
    /// Makes an empty project. Returns its name as saved (trimmed).
    @discardableResult
    public static func createProject(_ runs: URL, _ text: String) throws -> String {
        guard let name = Rules.projectName(text) else { throw RequestError.badProjectName }
        guard !projectOrMiniExists(runs, name) else { throw RequestError.projectTaken(name) }
        try FileManager.default.createDirectory(at: runs.appendingPathComponent(name), withIntermediateDirectories: true)
        return name
    }

    /// The project named `text`, as it's spelled on disk: "tiefling party" finds "Tiefling Party".
    public static func project(_ runs: URL, named text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projects(runs).first { $0.lowercased() == t }
    }

    /// Whether a project, or a mini anywhere, already has this name (on a Mac's disk "Orcs" and
    /// "orcs" are one folder).
    static func projectOrMiniExists(_ runs: URL, _ name: String, except: String? = nil) -> Bool {
        let n = name.lowercased()
        return projects(runs).contains { $0.lowercased() == n && $0 != except }
            || list(runs).contains { $0.name == n }
    }
}

extension JobRunner {
    /// Moves a mini, with every file in its folder, into `project` (nil: Unsorted). Refused while
    /// it's being made or waiting: its job would write into a folder that has gone. Under the
    /// queue's lock, where a job resolves its folder as it starts, so the two can't cross.
    public func move(mini name: String, toProject project: String?) throws {
        let runs = install.runs
        try queue.locked { entries in
            try refuseWhileMoving()
            guard let from = Gallery.folder(runs, name) else { throw RequestError.notFound }
            if entries.contains(where: { $0.name == name }) || running()?.name == name { throw RequestError.cantMove(name) }
            if let project, !Gallery.projects(runs).contains(project) { throw RequestError.projectNotFound }
            let to = Gallery.newFolder(runs, name, project: project)
            guard from.standardizedFileURL != to.standardizedFileURL else { return }
            guard !FileManager.default.fileExists(atPath: to.path) else { throw RequestError.nameTaken(name) }
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// Takes over minis renamed or copied in Finder (`Gallery.adopt`), leaving alone any being
    /// made or waiting. Under the queue's lock, where a job finds its folder as it starts; only
    /// taken when there's one to take over. Returns the new names.
    @discardableResult
    public func adoptOddFolders() -> [String] {
        let runs = install.runs
        guard Gallery.list(runs).contains(where: { Gallery.oddFiles($0) != nil }) else { return [] }
        return (try? queue.locked { entries in
            try refuseWhileMoving()
            return Gallery.adopt(runs, busy: Set(entries.map(\.name) + [running()?.name].compactMap { $0 }))
        }) ?? []
    }

    /// Renames a project's folder. Refused while one of its minis is being made (that job's
    /// steps hold its folder's path); waiting ones are found by name when they start.
    @discardableResult
    public func renameProject(_ old: String, to text: String) throws -> String {
        let runs = install.runs
        guard let new = Rules.projectName(text) else { throw RequestError.badProjectName }
        return try queue.locked { _ in
            try refuseWhileMoving()
            guard Gallery.projects(runs).contains(old) else { throw RequestError.projectNotFound }
            guard old != new else { return new }
            guard !Gallery.projectOrMiniExists(runs, new, except: old) else { throw RequestError.projectTaken(new) }
            if let r = running(), Gallery.folder(runs, r.name)?.deletingLastPathComponent().lastPathComponent == old {
                throw RequestError.projectBusy(old, r.displayName(runs: runs))
            }
            let from = runs.appendingPathComponent(old), to = runs.appendingPathComponent(new)
            if old.lowercased() == new.lowercased() {
                // Only the capitals change: the disk sees one name, so it goes through a third.
                let step = runs.appendingPathComponent("_rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: from, to: step)
                try FileManager.default.moveItem(at: step, to: to)
            } else {
                try FileManager.default.moveItem(at: from, to: to)
            }
            return new
        }
    }

    /// Deletes a project. `keepMinis` (the default) moves its minis to Unsorted first; otherwise
    /// they go to the Trash with it. Either way the folder itself goes to the Trash, never
    /// removed outright: it may hold files of the person's own. Refused while one of its minis is
    /// being made or waiting.
    public func deleteProject(_ name: String, keepMinis: Bool = true) throws {
        let runs = install.runs
        try queue.locked { entries in
            try refuseWhileMoving()
            guard Gallery.projects(runs).contains(name) else { throw RequestError.projectNotFound }
            let minis = Gallery.list(runs).filter { $0.project == name }
            let busy = Set(entries.map(\.name) + [running()?.name].compactMap { $0 })
            if let m = minis.first(where: { busy.contains($0.name) }) { throw RequestError.projectBusy(name, m.displayName) }
            if keepMinis {
                for m in minis {
                    let to = runs.appendingPathComponent(m.name)
                    guard !FileManager.default.fileExists(atPath: to.path) else { throw RequestError.nameTaken(m.name) }
                }
                for m in minis { try FileManager.default.moveItem(at: m.folder, to: runs.appendingPathComponent(m.name)) }
            }
            try trash(runs.appendingPathComponent(name))
        }
    }
}
