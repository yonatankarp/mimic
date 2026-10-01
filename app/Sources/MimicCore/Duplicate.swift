import Foundation

/// Duplicate (#85): a copy of a made mini under a new name, to resize without losing the first.
extension JobRunner {
    /// Copies the mini called `name`, with its 3D model, print file, pictures and settings, to a
    /// new mini called `new` next to it (same project). `shown` is the name as typed. The copy is
    /// asked for now, so it sorts as new, and isn't one of the original's versions: Keep This One
    /// on a version would otherwise trash it. Its logs stay behind, since they tell how the
    /// original was made (and the estimates would count it twice). Refused while the mini is
    /// being made, resized or waiting, under the queue's lock where a job finds its folder.
    public func duplicate(_ name: String, as new: String, shown: String? = nil) throws {
        guard Rules.isValidName(name), Rules.isValidName(new) else { throw RequestError.badName }
        let runs = install.runs, fm = FileManager.default
        try queue.locked { entries in
            try refuseWhileMoving()
            guard let src = Gallery.folder(runs, name) else { throw RequestError.notFound }
            guard fm.fileExists(atPath: src.appendingPathComponent("model.glb").path) else { throw RequestError.noModelYet }
            if entries.contains(where: { $0.name == name }) || running()?.name == name { throw RequestError.cantDuplicate(name) }
            let dst = src.deletingLastPathComponent().appendingPathComponent(new)
            guard !Gallery.nameInUse(runs, new), !fm.fileExists(atPath: dst.path) else { throw RequestError.nameTaken(new) }
            // Made in a "_" folder, which the gallery never lists, so a half-made copy is never
            // seen and never taken over as a folder copied in Finder.
            let step = src.deletingLastPathComponent().appendingPathComponent("_duplicate-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: src, to: step)
                for f in try fm.contentsOfDirectory(atPath: step.path) where Self.staysBehind(f) {
                    try fm.removeItem(at: step.appendingPathComponent(f))
                }
                try Gallery.renameFiles(in: step, from: name, to: new)
                try MiniSettings.update(step) { s in
                    s.name(shown, folder: new)
                    s.versionOf = nil
                    s.created = Date()
                }
                try fm.moveItem(at: step, to: dst)
            } catch {
                try? fm.removeItem(at: step)
                throw error
            }
        }
    }

    /// What a duplicate leaves behind: the logs of how the original was made, and a print file
    /// print prep hadn't finished.
    static func staysBehind(_ file: String) -> Bool {
        file.hasSuffix(".log") || file.hasSuffix(".part.stl")
    }
}

extension Gallery {
    /// The name Duplicate offers for a copy of `mini`, as typed and as its folder: its own name
    /// with the next number free ("Raven" → "Raven 2" in "raven-2", "Raven 2" → "Raven 3"), as
    /// Make Another Version and pictures named alike are numbered. Always a number, even when the
    /// name as shown has a folder of its own free, so two minis never show the same name. Not a
    /// size: that's chosen after, in Resize.
    public static func duplicateName(_ runs: URL, _ mini: Mini) -> (shown: String, folder: String) {
        let typed = mini.displayName
        let folder = nextVersionName(runs, Rules.folderName(typed))
        return (Rules.shownName(typed, numberedAs: folder), folder)
    }
}
