import Foundation

/// A release version, "X.Y.Z" and nothing else: a development build ("0.4.2-3-gabc", "dev",
/// "…-dirty", a bare commit) is none, so it never offers or takes an update.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        // Int() refuses a number too big to hold, so a silly tag from the network can't crash this.
        let numbers = parts.filter { $0.allSatisfy { $0.isASCII && $0.isNumber } }.compactMap { Int($0) }
        guard parts.count == 3, numbers.count == 3 else { return nil }
        self.parts = numbers
    }

    /// A release tag: "v0.4.2". The engine's pre-release ("pixal3d-d1b4926") is none.
    public init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// A GitHub release, as `releases/latest` sends it: only the fields Mimic reads.
public struct Release: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let size: Int64
        public let url: URL
        enum CodingKeys: String, CodingKey { case name, size, url = "browser_download_url" }
    }
    public let tag: String
    public let notes: String
    public let prerelease: Bool
    public let draft: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tag = "tag_name", notes = "body", prerelease, draft, assets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        prerelease = try c.decode(Bool.self, forKey: .prerelease)
        draft = try c.decode(Bool.self, forKey: .draft)
        assets = try c.decode([Asset].self, forKey: .assets)
    }

    public var version: AppVersion? { AppVersion(tag: tag) }
    /// The disk image and its checksums, as the release workflow names them.
    public var dmg: Asset? { version.flatMap { v in assets.first { $0.name == "Mimic-\(v).dmg" } } }
    public var sums: Asset? { assets.first { $0.name == "SHA256SUMS" } }
}

/// Why an update didn't go ahead, in words for people.
public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case offline
    case server(Int)
    case notListed(String)
    case wrongApp(String)
    case notWritable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .offline: "Mimic couldn't reach GitHub. Check your connection, then try again."
        case .server(let code): "GitHub had a problem (error \(code)). Try again in a few minutes."
        case .notListed: "This update came without the information Mimic needs to check it, so Mimic won't install it. Try again later."
        case .wrongApp(let why): "The downloaded Mimic doesn't look right (\(why)), so it wasn't installed. Your Mimic is unchanged."
        case .notWritable: "Mimic can't replace itself where it is: your account isn't allowed to change that folder. Open the disk image and drag Mimic onto Applications instead."
        case .failed(let what): "The update stopped (\(what)). Your Mimic is unchanged."
        }
    }
}

/// Checking GitHub for a newer Mimic, and installing it. Only the public release information is
/// read; nothing about the Mac or its minis is sent.
public enum Updates {
    public static let latestURL = URL(string: "https://api.github.com/repos/yonatankarp/mimic/releases/latest")!
    /// What every release ships as: a new app has to be this, so it keeps the same settings.
    public static let bundleID = "com.mimic.app"
    /// Automatic checks: at most this often. Counted from the last attempt, so a Mac that's
    /// offline doesn't try every few seconds.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// The release to offer, or nil: a release build older than a real, finished `vX.Y.Z`
    /// release that has its disk image and checksums. A skipped version is offered again only
    /// when asked for.
    public static func offer(current: String, latest: Release, skipped: String? = nil) -> Release? {
        guard let mine = AppVersion(current), !latest.prerelease, !latest.draft,
              let theirs = latest.version, theirs > mine,
              latest.dmg != nil, latest.sums != nil,
              theirs.description != skipped else { return nil }
        return latest
    }

    /// Whether an automatic check is due.
    public static func due(lastTried: Date?, now: Date = Date()) -> Bool {
        guard let lastTried else { return true }
        return now.timeIntervalSince(lastTried) >= interval || now < lastTried
    }

    /// Never while a mini is being made (here or in another Mimic), waiting, or the engine
    /// downloading: replacing the app would end them.
    public static func busy(running: Bool, waiting: Int, settingUp: Bool) -> Bool { running || waiting > 0 || settingUp }

    /// Whether Mimic can replace itself at `app`: its folder and the app are this account's to
    /// change, and it isn't running from the disk image or from where macOS moved it to check it.
    public static func canReplace(_ app: URL) -> Bool {
        let fm = FileManager.default
        return !app.path.contains("/AppTranslocation/") && !app.path.hasPrefix("/Volumes/")
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    /// SHA256SUMS as `shasum -a 256` writes it: "<hex>  <name>", or "<hex> *<name>".
    public static func parseSums(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[0].count == 64, fields[0].allSatisfy(\.isHexDigit) else { continue }
            var name = fields[1].drop { $0 == " " }
            if name.first == "*" { name = name.dropFirst() }
            sums[String(name)] = fields[0].lowercased()
        }
        return sums
    }

    static func request(_ url: URL, version: String) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Mimic/\(version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// The latest release. `releases/latest` never lists pre-releases or drafts; `offer` checks anyway.
    public static func latest(version: String, url: URL = latestURL, session: URLSession = .shared) async throws -> Release {
        var r = request(url, version: version)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: r) } catch { throw UpdateError.offline }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.server(code) }
        do { return try JSONDecoder().decode(Release.self, from: data) } catch { throw UpdateError.server(code) }
    }

    /// Downloads the release's disk image into `folder` and checks it against its SHA256SUMS
    /// line: a file that doesn't match is deleted, never used.
    public static func download(_ release: Release, into folder: URL, version: String, session: URLSession = .shared,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let dmg = release.dmg, let sums = release.sums else { throw UpdateError.notListed("Mimic-\(release.tag).dmg") }
        let text: String
        do {
            let (data, response) = try await session.data(for: request(sums.url, version: version))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.server(code) }
            text = String(decoding: data, as: UTF8.self)
        } catch let e as UpdateError { throw e } catch { throw UpdateError.offline }
        guard let sha = parseSums(text)[dmg.name] else { throw UpdateError.notListed(dmg.name) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(dmg.name)
        var setup = EngineSetup(install: Install(root: folder))
        setup.session = session
        let total = Double(max(dmg.size, 1))
        do {
            try await setup.fetch(EngineFile(name: dmg.name, url: dmg.url, bytes: dmg.size, sha256: sha), to: dest) { progress(Double($0) / total) }
        } catch let e as SetupError {
            throw e == .damaged(dmg.name) ? UpdateError.wrongApp("it came down damaged") : UpdateError.failed(e.description)
        }
        return dest
    }

    /// Takes the new app out of the disk image and checks it: a Mimic of `version`, with the
    /// release bundle id and an intact signature. Staged as a hidden folder beside `app`, so the
    /// swap is a rename on one disk. Returns the staged app.
    public static func stage(dmg: URL, beside app: URL, version: AppVersion) throws -> URL {
        let fm = FileManager.default
        let parent = app.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".Mimic-update-\(UUID().uuidString).app")
        let mount = fm.temporaryDirectory.appendingPathComponent("mimic-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        // Its own mount point: a disk image already open would push this one to "Mimic 1".
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        do {
            try run("/usr/bin/ditto", [mount.appendingPathComponent("Mimic.app").path, staged.path])
        } catch {
            try? fm.removeItem(at: staged)
            if !fm.isWritableFile(atPath: parent.path) { throw UpdateError.notWritable(parent.path) }
            throw error
        }
        do {
            try check(staged, version: version)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// The new app is what it says: the release's version and bundle id, signature intact.
    public static func check(_ app: URL, version: AppVersion) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let found = info["CFBundleShortVersionString"] as? String ?? "none"
        guard found == version.description else { throw UpdateError.wrongApp("it's version \(found), not \(version)") }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.wrongApp("it isn't Mimic") }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) } catch { throw UpdateError.wrongApp("it has been changed since it was made") }
    }

    /// Swaps the staged app into `app`'s place in one step (the old app ends up at `staged`),
    /// so there's never a moment without a Mimic there.
    public static func swap(_ staged: URL, into app: URL) throws {
        if renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 { return }
        let err = errno
        if err == EACCES || err == EPERM { throw UpdateError.notWritable(app.deletingLastPathComponent().path) }
        throw UpdateError.failed(String(cString: strerror(err)))
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError.failed("\((tool as NSString).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return text
    }
}
