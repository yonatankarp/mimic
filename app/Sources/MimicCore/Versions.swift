import Foundation

/// Make Another Version and New 3D Shape: a sibling mini from the same source with a new seed.
extension JobRunner {
    /// Makes a sibling of `name` in the same project, from the same picture or description and
    /// settings, with a different seed: the seed is what the drawing (for a description or the
    /// grey sculpt) and the 3D shape start from, so a small detail that came out a blob may come
    /// out right. Named "<name>-2" (then -3…) unless `as` says. Returns the new name and, like
    /// `make`, its place in the queue.
    @discardableResult
    public func makeAnotherVersion(of name: String, as newName: String? = nil, seed: Int? = nil) throws -> (name: String, ahead: Int?) {
        try version(of: name, as: newName) { settings in
            (seed: Self.newSeed(seed, not: settings.seed ?? 42), shapeSeed: nil, drawn: nil)
        }
    }

    /// New 3D Shape: a sibling like Make Another Version's, from the picture `name`'s step 1 made
    /// (source.png, copied now so a rename or trash of `name` can't take it away), with a new
    /// seed for the 3D engine alone. The picture isn't made again, so it's faster and a drawing
    /// you liked is kept; its own seed stays, so Try Again would draw the same one.
    @discardableResult
    public func makeNewShape(of name: String, as newName: String? = nil, seed: Int? = nil) throws -> (name: String, ahead: Int?) {
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        let drawn = folder.appendingPathComponent("source.png")
        guard FileManager.default.fileExists(atPath: drawn.path) else { throw RequestError.noDrawing(name) }
        return try version(of: name, as: newName) { settings in
            let old = settings.seed ?? 42
            return (seed: old, shapeSeed: Self.newSeed(seed, not: settings.shapeSeed ?? old), drawn: drawn)
        }
    }

    /// `given`, or a random seed (1-999,999) that isn't `old`.
    private static func newSeed(_ given: Int?, not old: Int) -> Int {
        if let given { return given }
        var s = Int.random(in: 1...999_999)
        while s == old { s = Int.random(in: 1...999_999) }
        return s
    }

    /// A sibling of `name` in its project, from its saved source and settings, with the seeds
    /// (and picture) `seeds` picks from them. Named "<name>-2" (then -3…) unless `as` says.
    private func version(of name: String, as newName: String?,
                         _ seeds: (MiniSettings) -> (seed: Int, shapeSeed: Int?, drawn: URL?)) throws -> (name: String, ahead: Int?) {
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        guard let (picture, restyle, settings) = try? Self.versionSource(folder) else { throw RequestError.noSource(name) }
        guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
        let new = newName ?? Gallery.nextVersionName(install.runs, name)
        let (seed, shapeSeed, drawn) = seeds(settings)
        let project = folder.deletingLastPathComponent().standardizedFileURL == install.runs.standardizedFileURL
            ? nil : folder.deletingLastPathComponent().lastPathComponent
        let ahead = try make(name: new, picture: picture, restyle: restyle, seed: seed, sizes: settings.requested ?? Sizes(),
                             kind: settings.kind ?? .character, model: model, project: project,
                             versionOf: settings.versionOf ?? name, cartoon: settings.cartoon == true,
                             shapeSeed: shapeSeed, drawn: drawn)
        return (new, ahead)
    }

    /// What a mini was made from, to make it again: nil-free or `nothingToRetry`. A picture mini
    /// from before upload.img was kept (the web version) has only source.png, which is exactly
    /// what its 3D step saw, so that's used without redrawing it.
    static func versionSource(_ folder: URL, _ settings: MiniSettings? = nil) throws -> (PictureSource, restyle: Bool, MiniSettings) {
        let settings = settings ?? MiniSettings.load(folder)
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
    public static func canMakeAnotherVersion(_ mini: Mini) -> Bool { (try? versionSource(mini.folder, mini.settings)) != nil }

    /// Whether New 3D Shape can work for this mini: Make Another Version can, and its picture is there.
    public static func canMakeNewShape(_ mini: Mini) -> Bool { mini.source != nil && canMakeAnotherVersion(mini) }
}


extension Gallery {
    /// The versions of `mini` among `minis`, itself included, by name: the first one and every
    /// mini in the same project that names it as `versionOf`. Just `mini` when it has none;
    /// minis made before versions were recorded have none.
    public static func versions(of mini: Mini, in minis: [Mini]) -> [Mini] {
        let root = mini.settings.versionOf ?? mini.name
        return minis.filter { $0.project == mini.project && ($0.name == root || $0.settings.versionOf == root) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

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

    /// A new mini's name from its picture's file: "Dwarf Cleric.png" → "dwarf-cleric", or
    /// "dwarf-cleric-2" when that's taken; "mini" when the file name has no letters or digits.
    public static func name(forPicture url: URL, in runs: URL) -> String {
        freeName(runs, url.deletingPathExtension().lastPathComponent)
    }

    /// "Dwarf Cleric" → "dwarf-cleric", or "dwarf-cleric-2" when that's taken; "mini" when it has
    /// no letters or digits.
    static func freeName(_ runs: URL, _ text: String) -> String {
        let slug = Rules.slug(text)
        let name = slug.isEmpty ? "mini" : slug
        return nameInUse(runs, name) ? nextVersionName(runs, name) : name
    }
}
