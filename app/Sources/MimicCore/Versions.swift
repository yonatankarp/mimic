import Foundation

/// Make Another Version: a sibling mini from the same source with a new seed.
extension JobRunner {
    /// Makes a sibling of `name` in the same project, from the same picture or description and
    /// settings, with a different seed: the seed is what the drawing (for a description or the
    /// grey sculpt) and the 3D shape start from, so a small detail that came out a blob may come
    /// out right. Named "<name>-2" (then -3…) unless `as` says. Returns the new name and, like
    /// `make`, its place in the queue.
    @discardableResult
    public func makeAnotherVersion(of name: String, as newName: String? = nil, seed: Int? = nil) throws -> (name: String, ahead: Int?) {
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        guard let (picture, restyle, settings) = try? Self.versionSource(folder) else { throw RequestError.noSource(name) }
        guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
        let new = newName ?? Gallery.nextVersionName(install.runs, name)
        let old = settings.seed ?? 42
        var s = seed ?? Int.random(in: 1...999_999)
        while seed == nil && s == old { s = Int.random(in: 1...999_999) }
        let project = folder.deletingLastPathComponent().standardizedFileURL == install.runs.standardizedFileURL
            ? nil : folder.deletingLastPathComponent().lastPathComponent
        let ahead = try make(name: new, picture: picture, restyle: restyle, seed: s, sizes: settings.requested ?? Sizes(),
                             kind: settings.kind ?? .character, model: model, project: project)
        return (new, ahead)
    }

    /// What a mini was made from, to make it again: nil-free or `nothingToRetry`. A picture mini
    /// from before upload.img was kept (the web version) has only source.png, which is exactly
    /// what its 3D step saw, so that's used without redrawing it.
    static func versionSource(_ folder: URL) throws -> (PictureSource, restyle: Bool, MiniSettings) {
        let settings = MiniSettings.load(folder)
        guard settings.requested != nil else { throw RequestError.nothingToRetry }
        switch settings.source {
        case .image:
            let upload = folder.appendingPathComponent("upload.img"), source = folder.appendingPathComponent("source.png")
            if FileManager.default.fileExists(atPath: upload.path) { return (.image(upload), settings.restyle == true, settings) }
            guard FileManager.default.fileExists(atPath: source.path) else { throw RequestError.nothingToRetry }
            return (.image(source), false, settings)
        case .desc:
            guard let desc = settings.desc, !desc.isEmpty else { throw RequestError.nothingToRetry }
            return (.description(desc, original: settings.descOriginal), false, settings)
        case nil:
            throw RequestError.nothingToRetry
        }
    }

    /// Whether Make Another Version can work for this mini (what it was made from was saved).
    public static func canMakeAnotherVersion(_ mini: Mini) -> Bool { (try? versionSource(mini.folder)) != nil }
}


extension Gallery {
    /// "tiefling-wizard" → "tiefling-wizard-2", or the next number free anywhere in the minis
    /// folder; "raven-2" → "raven-3".
    public static func nextVersionName(_ runs: URL, _ name: String) -> String {
        var base = name, n = 2
        if let dash = name.lastIndex(of: "-"), let k = Int(name[name.index(after: dash)...]), (1..<1000).contains(k), dash != name.startIndex {
            base = String(name[..<dash]); n = k + 1
        }
        while true {
            let suffix = "-\(n)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !nameInUse(runs, candidate) { return candidate }
            n += 1
        }
    }
}
