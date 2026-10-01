import Foundation

/// What the app does to minis from its menus, here so `mimic` in Terminal does exactly the same
/// (#129): Rename, Move to Trash, Keep This One, Resize All and Stop.
extension JobRunner {
    /// The minis waiting or being made, in any Mimic: what Rename, Trash and Resize All leave alone.
    public func busyNames() -> Set<String> {
        Set(queue.entries().map(\.name) + [running()?.name].compactMap { $0 })
    }

    // MARK: Rename

    /// Renames a mini to a name as people type it ("Dwarf Cleric", "Élodie"): its folder takes
    /// `Rules.folderName` of it, and the name is kept to show. Returns the folder's new name.
    @discardableResult
    public func rename(_ name: String, typed: String) throws -> String {
        guard let shown = Rules.shownName(typed) else { throw RequestError.noName }
        let new = Rules.folderName(shown)
        try rename(name, to: new, shown: shown)
        return new
    }

    /// Renames a mini's folder (see `Gallery.rename`). Refused while it waits in the queue or is
    /// being made: under the queue's lock, where a job finds its folder as it starts, so the two
    /// can't cross.
    public func rename(_ name: String, to new: String, shown: String? = nil) throws {
        let runs = install.runs
        try queue.locked { entries in
            if entries.contains(where: { $0.name == name }) { throw RequestError.renameWaiting(name) }
            try Gallery.rename(runs, from: name, to: new, shown: shown, busyWith: running()?.name)
        }
    }

    // MARK: Trash

    /// Move to Trash: one waiting in the queue leaves it first, and a new mini's folder goes to
    /// the Trash with that (nil is returned); otherwise its folder goes. Refused for the one being
    /// made. Returns its folder and where it went in the Trash, for Undo (`Gallery.putBack`).
    @discardableResult
    public func moveToTrash(_ mini: Mini, trash: (URL) throws -> URL? = Gallery.trash) throws -> (folder: URL, trashed: URL?)? {
        if let entry = queue.entries().first(where: { $0.name == mini.name }), try remove(mini.name), entry.job == .generate {
            return nil
        }
        return try Gallery.moveToTrash(install.runs, name: mini.name, folder: mini.folder, busyWith: running()?.name, trash: trash)
    }

    // MARK: Resize All

    /// Resize All on a project, or Resize on several minis: each one `Gallery.toResize` picks is
    /// asked for with `resize` (the app's shows its progress), and waits its turn.
    public func resizeAll(_ group: [Mini], to sizes: Sizes, resize: (Mini, Sizes) throws -> Void) -> ResizeAll {
        let picked = Gallery.toResize(group, to: sizes, busy: busyNames())
        var result = ResizeAll(same: picked.same, skipped: picked.skipped)
        for (mini, sizes) in picked.resize {
            do {
                try resize(mini, sizes)
                result.added.append(mini.name)
            } catch {
                result.skipped += 1
                result.failure = error
            }
        }
        return result
    }

    /// Resize All, each mini asked for with `resize(name:sizes:)`.
    public func resizeAll(_ group: [Mini], to sizes: Sizes) -> ResizeAll {
        resizeAll(group, to: sizes) { try self.resize(name: $0.name, sizes: $1) }
    }

    // MARK: Several pictures

    /// Several pictures dropped on New Mini: a mini each, named after its file (`name`, its
    /// folder's, and `shown`), each asked for with `make` and waiting its turn. A picture that
    /// can't be used is skipped.
    public func makeEach(_ pictures: [URL], make: (_ picture: URL, _ name: String, _ shown: String?) throws -> Void) -> MakeEach {
        var result = MakeEach()
        for url in pictures {
            // Named once those before it are made: "dwarf.png" and "dwarf.jpg" don't share a name.
            let name = Gallery.name(forPicture: url, in: install.runs)
            let shown = Rules.shownName(fromFile: url.deletingPathExtension().lastPathComponent).map { Rules.shownName($0, numberedAs: name) }
            do {
                try make(url, name, shown)
                result.added.append(name)
            } catch {
                result.skipped.append(url.lastPathComponent)
                if ![.noPicture, .unreadablePicture].contains(error as? RequestError) { result.failure = error }
            }
        }
        return result
    }

    // MARK: Stop

    /// `mimic stop`: asks whichever Mimic is running a job (the app, or `mimic` in another
    /// Terminal) to stop it, as its Stop does, and waits up to `timeout` seconds for it to.
    /// A Mimic from before 0.9.0 doesn't hear it.
    public func stopElsewhere(timeout: TimeInterval = 10) -> StopRequest {
        guard let job = running() else { return .nothing }
        let file = queue.stopFile
        let ask = Self.stopAsk(job)
        guard (try? Data(ask.utf8).write(to: file, options: .atomic)) != nil else { return .noAnswer(job) }
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if let now = running(), now.name == job.name, now.started == job.started {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            // Stopped only when the Mimic making it said so: it may have ended on its own first
            // (#173). Either way the request goes, so it can't stop a later job.
            let answer = try? String(contentsOf: file, encoding: .utf8)
            try? FileManager.default.removeItem(at: file)
            return answer == ask + Self.stopAnswer ? .stopped(job) : .ended(job)
        }
        // Not heard: taken back, so it can't stop a later job of the same name.
        try? FileManager.default.removeItem(at: file)
        return .noAnswer(job)
    }

    /// What `mimic stop` writes in job.stop: the job's name and when it started, so a request
    /// left behind can't stop a later job of the same name (#173).
    static func stopAsk(_ job: JobStatus) -> String { job.name + "\n" + stopTime(job.started) }
    /// Added to the request by the Mimic that stopped the job.
    static let stopAnswer = "\nstopped"
    /// Written as job.json writes it, so the time `mimic stop` read there matches this Mimic's
    /// own to the second (a formatter of its own may round where job.json's drops the rest).
    static func stopTime(_ date: Date) -> String {
        (try? JobQueue.encoder.encode([date])).map { String(decoding: $0, as: UTF8.self).filter { !$0.isWhitespace } } ?? ""
    }

    /// Run while this runner holds the job lock: stops its job when `mimic stop` asks for it,
    /// and answers. Any other request is from before it and is dropped. A request with only a
    /// name is from a Mimic before 0.10.0.
    func answerStopRequest() {
        let file = queue.stopFile
        guard let asked = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = asked.components(separatedBy: "\n")
        if lines.count > 2 { return }  // answered: `mimic stop` takes it away
        if let s = status, s.running, lines[0] == s.name, lines.count == 1 || lines[1] == Self.stopTime(s.started), cancel() {
            try? Data((asked + Self.stopAnswer).utf8).write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// What `mimic stop` did.
public enum StopRequest: Equatable, Sendable {
    /// Nothing was being made.
    case nothing
    case stopped(JobStatus)
    /// It ended on its own, finished or failed, before it could be stopped.
    case ended(JobStatus)
    /// The Mimic making it didn't stop it in time (or is from before `mimic stop`).
    case noAnswer(JobStatus)
}

/// How Resize All went: the minis added to the queue, those already at those sizes, and those
/// skipped (not made yet, waiting, being made, or refused, the last refusal kept as `failure`).
public struct ResizeAll {
    public var added: [String] = []
    public var same = 0
    public var skipped = 0
    public var failure: Error?

    /// " 2 were already that size."
    public var sameNote: String { same == 0 ? "" : " \(same) \(same == 1 ? "was" : "were") already that size." }
    /// " Skipped 1: not made yet, or already waiting or being made."
    public var skippedNote: String { skipped == 0 ? "" : " Skipped \(skipped): not made yet, or already waiting or being made." }
    /// Why none was added, in words, given the last refusal's (`failure`) in words; nil when some were.
    public func nothingAdded(_ why: String?) -> String? {
        guard added.isEmpty else { return nil }
        if same > 0 && skipped == 0 { return "They're all already that size." }
        return (why ?? "None of these minis can be resized right now.") + sameNote + skippedNote
    }
}

/// How several dropped pictures went: the minis added to the queue, the files skipped, and the
/// last refusal that wasn't about the picture itself (`failure`).
public struct MakeEach {
    public var added: [String] = []
    public var skipped: [String] = []
    public var failure: Error?

    /// " Skipped a.png, b.png: Mimic can't use them."
    public var skippedNote: String {
        skipped.isEmpty ? "" : " Skipped \(skipped.joined(separator: ", ")): Mimic can't use \(skipped.count == 1 ? "it" : "them")."
    }
}

extension Gallery {
    /// Keep This One: `mini`'s other versions, to move to the Trash, and the one of them being
    /// made, which stays.
    public static func toKeep(_ mini: Mini, in minis: [Mini], busyWith: String?) -> (trash: [Mini], staying: Mini?) {
        toTrash(versions(of: mini, in: minis).filter { $0.name != mini.name }, busyWith: busyWith)
    }
}
