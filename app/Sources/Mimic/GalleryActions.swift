import AppKit
import MimicCore

/// Changing the gallery: projects, moving minis between them, and Rename, Duplicate, Move to
/// Trash and Keep This One, with their Edit → Undo.
extension AppModel {
    /// Why `mini` can't be moved to another project right now, or nil.
    func whyCantMove(_ mini: Mini) -> String? { miniMenu.whyCantMove(mini) }

    @discardableResult
    func createProject(_ text: String) throws -> String {
        let name = try jobs.createProject(text)
        reload()
        return name
    }

    /// Moves minis (one, or several dragged together) into `project`, nil being Unsorted. One
    /// waiting or being made stays, and says so.
    func move(_ names: [String], to project: String?) {
        for name in Gallery.dropped(names) where minis.first(where: { $0.name == name })?.project != project {
            do { try jobs.move(mini: name, toProject: project) }
            catch { problem = plainWords(error, else: "Couldn't move it. Is its folder open in another app?") }
        }
        reload()
    }

    /// Rename… and Keep This One's "Call it …?": renames `mini`'s folder to `new`, `shown` being
    /// the name as typed (nil carries its own over, see `Gallery.rename`). It stays selected if it
    /// was. Edit → Undo gives it back the name it was shown as, and Redo this one again (#343).
    func rename(_ mini: Mini, to new: String, shown: String? = nil) throws {
        try jobs.rename(mini.name, to: new, shown: shown)
        // Both in one go, so the window never shows another mini in between.
        if selection.remove(mini.id) != nil { selection.insert(new) }
        reload()
        let old = mini.name, oldShown = mini.displayName
        undo?.registerUndo(withTarget: self) { model in
            guard let renamed = model.minis.first(where: { $0.name == new }) else { return }
            do { try model.rename(renamed, to: old, shown: oldShown) }
            catch { model.problem = model.plainWords(error, else: "Couldn't rename it back. Is its folder open in another app?"); return }
            model.selection = [old]
        }
        undo?.setActionName("Rename")
    }

    /// Duplicate…: copies `mini` as `new`. Edit → Undo moves the copy to the Trash, as Move to
    /// Trash would (its Redo puts it back), so cancelling the Resize that follows doesn't leave
    /// an unwanted copy behind.
    func duplicate(_ mini: Mini, as new: String, shown: String) throws {
        try jobs.duplicate(mini.name, as: new, shown: shown)
        reload()
        let original = mini.name
        undo?.registerUndo(withTarget: self) { model in
            guard let copy = model.minis.first(where: { $0.name == new }) else { return }
            model.trash(copy)
            if model.minis.contains(where: { $0.name == original }) { model.selection = [original] }
            model.undo?.setActionName("Duplicate")
        }
        undo?.setActionName("Duplicate")
        selection = [new]
    }

    func renameProject(_ old: String, to text: String) throws {
        let new = try jobs.renameProject(old, to: text)
        // A collapsed project stays collapsed under its new name.
        if collapsed.remove(old) != nil { collapsed.insert(new) }
        reload()
    }

    func deleteProject(_ name: String, keepMinis: Bool) {
        do { try jobs.deleteProject(name, keepMinis: keepMinis) }
        catch { problem = plainWords(error, else: "Couldn't delete the project. Try Show in Finder and move it to the Trash there.") }
        reload()
    }

    func showInFinder(project: String) { NSWorkspace.shared.activateFileViewerSelecting([install.runs.appendingPathComponent(project)]) }

    /// Move to Trash from the sidebar or the Mini menu, for one mini or several: at once, as
    /// Edit → Undo puts them back; asked first only when one waits in the queue, which Undo
    /// can't put back in it.
    func askToTrash(_ group: [Mini]) {
        if group.contains(where: { waiting($0.name) != nil }) { trashing = group } else { trash(group) }
    }

    /// Moves minis to the Trash; one Undo puts them all back (grouped by event). The one being
    /// made stays, and says so.
    func trash(_ group: [Mini]) {
        let picked = Gallery.toTrash(group, busyWith: current?.name)
        trashEach(picked.trash)
        if let s = picked.staying { problem = "“\(s.displayName)” is being made, so it stayed. Move it to the Trash once it's done." }
    }

    func trash(_ mini: Mini) { trashEach([mini]) }

    /// Moves each to the Trash, then updates the queue and the list once for all of them.
    private func trashEach(_ group: [Mini]) {
        guard !group.isEmpty else { return }
        for mini in group {
            do {
                // Waiting to be made: out of the queue, and a new mini's folder goes to the Trash with it.
                if let moved = try jobs.moveToTrash(mini), let trashed = moved.trashed { undoable(moved.folder, trashed) }
            } catch {
                problem = plainWords(error, else: "Couldn't move it to the Trash. Try Show in Finder and delete it there.")
            }
        }
        if !refreshQueue() { reload() }  // picks the newest mini if one of these was selected
    }

    /// Undo puts it back from the Trash and shows it; Redo moves it there again. Several moved at
    /// once (Keep This One) come back with one Undo: the undo manager groups them by event.
    private func undoable(_ folder: URL, _ trashed: URL) {
        let name = folder.lastPathComponent
        undo?.registerUndo(withTarget: self) { model in
            do { try Gallery.putBack(model.install.runs, from: trashed, to: folder) }
            catch { model.problem = model.plainWords(error, else: "Couldn't put it back. Is it still in the Trash?"); return }
            model.reload()
            model.selection = [name]
            model.undo?.registerUndo(withTarget: model) { model in
                if let mini = model.minis.first(where: { $0.name == name }) { model.trash(mini) }
            }
            model.undo?.setActionName("Move to Trash")
        }
        undo?.setActionName("Move to Trash")
    }

    /// Keep This One: moves `mini`'s other versions to the Trash (waiting ones leave the queue).
    /// One being made stays, and says so. Returns whether they all went.
    @discardableResult
    func keep(_ mini: Mini) -> Bool {
        let picked = Gallery.toKeep(mini, in: minis, busyWith: current?.name)
        trashEach(picked.trash)
        if let v = picked.staying {
            problem = (problem.map { $0 + " " } ?? "") + "“\(v.displayName)” is being made, so it wasn't moved to the Trash. Move it there once it's done."
            return false
        }
        return problem == nil
    }
}
