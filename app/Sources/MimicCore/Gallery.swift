import Foundation

/// One mini: a folder under runs/ whose print file and previews are named after it.
public struct Mini: Identifiable, Hashable, Sendable {
    public let name: String
    public let folder: URL
    public let madeAt: Date
    public var id: String { name }
    public var stl: URL? { existing("\(name).stl") }
    public var source: URL? { existing("source.png") }
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

    public static func == (a: Mini, b: Mini) -> Bool { a.name == b.name && a.madeAt == b.madeAt }
    public func hash(into h: inout Hasher) { h.combine(name) }
}

public enum Gallery {
    /// Every mini, newest first. Folders starting with "_" are Mimic's own scratch, not minis.
    public static func list(_ runs: URL) -> [Mini] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix("_") }
            .map { Mini(name: $0.lastPathComponent, folder: $0, madeAt: madeAt($0)) }
            .sorted { $0.madeAt > $1.madeAt }
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
        let src = runs.appendingPathComponent(old), dst = runs.appendingPathComponent(new)
        guard fm.fileExists(atPath: src.path) else { throw RequestError.notFound }
        guard !fm.fileExists(atPath: dst.path) else { throw RequestError.nameTaken(new) }
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
        let folder = runs.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw RequestError.notFound }
        try trash(folder)
    }
}
