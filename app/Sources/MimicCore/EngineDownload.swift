import CryptoKit
import Foundation
import OSLog

/// One file Mimic downloads, pinned: where from, how big, and its sha256.
public struct EngineFile: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let bytes: Int64
    public let sha256: String

    public init(name: String, url: URL, bytes: Int64, sha256: String) {
        self.name = name; self.url = url; self.bytes = bytes; self.sha256 = sha256
    }
}

/// One set of model files the 3D engine can run, and how it runs them.
public struct EngineModel: Sendable, Equatable, Identifiable {
    /// Which of trellis-cli's pipelines the files are for.
    public enum Family: Sendable, Equatable { case pixal3dSingleView, trellis2 }

    public let id: String
    /// Plain words, for the setup screen and Settings.
    public let name: String
    /// What it's like, without its time: `described` adds that.
    public let summary: String
    /// Whole minutes a mini takes, measured on an M2 Max (app/NOTES.md): what the time
    /// estimates start from until this Mac has made a few minis of its own.
    public let minutes: Int
    public let family: Family
    public var files: [EngineFile]
    /// Degrees print prep turns the engine's model so the figure faces the front render: the
    /// TRELLIS.2 pipeline writes it facing away (seen on every TRELLIS.2 run of the dwarf).
    public var turn: Int { family == .trellis2 ? 180 : 0 }
    /// It can make a mini from pictures of the back and sides too (#66): TRELLIS.2's
    /// multi-image mode takes 2–8. Pixal3D's single-view set takes one.
    public var multiView: Bool { family == .trellis2 }

    public init(id: String, name: String, summary: String, minutes: Int = 8, family: Family, files: [EngineFile]) {
        self.id = id; self.name = name; self.summary = summary; self.minutes = minutes; self.family = family; self.files = files
    }

    /// The summary and how long a mini takes: `minutes` learned on this Mac when given.
    public func described(minutes learned: Int? = nil) -> String {
        "\(summary) About \(learned ?? minutes) minutes a mini\(learned == nil ? "" : " on this Mac")."
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The files trellis-cli loads. The health check wants every one at its full size: any
    /// missing file fails a run minutes in, and the size catches a download cut short.
    public var weights: [EngineFile] { files.filter { $0.name.hasSuffix(".gguf") } }

    public func folder(in install: Install) -> URL { install.engine.appendingPathComponent("models/\(id)") }

    /// Every weight file at its full size (setup checks their sha256 too).
    public func complete(in install: Install) -> Bool {
        let folder = folder(in: install)
        return weights.allSatisfy { EngineDownload.size(folder.appendingPathComponent($0.name)) == $0.bytes }
    }

    /// Whether any of its files, or a download of one, is on disk: something Remove can free.
    public func anyOnDisk(in install: Install) -> Bool {
        let folder = folder(in: install)
        return files.contains { f in
            [f.name, f.name + ".part"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
    }
}

/// Everything the 3D engine needs, pinned. The one place to change when a new engine build or
/// model revision is adopted.
public enum EngineDownload {
    /// How the engine's VERSION file starts. An engine that says anything else is replaced.
    public static let version = "pixal3d.cpp d1b4926"

    /// pixal3d.cpp d1b4926, built for macOS 14+ by tools/package_pixal3d.sh, so nobody needs Xcode.
    public static let engine = EngineFile(
        name: "pixal3d-metal-d1b4926-macos14.0.tar.gz",
        url: URL(string: "https://github.com/yonatankarp/mimic/releases/download/pixal3d-d1b4926/pixal3d-metal-d1b4926-macos14.0.tar.gz")!,
        bytes: 1_670_709,
        sha256: "58aa276c7605bddf250533c982ccd43c2e0791791b6cf2f5e2c777ff56c7dede")

    /// Draw Things' command line tool: pictures without the app open or its API server on.
    /// One arm64 file linking only system frameworks (macOS 13+).
    public static let drawThingsCLI = EngineFile(
        name: "draw-things-cli",
        url: URL(string: "https://github.com/drawthingsai/draw-things-community/releases/download/v1.20260430.0/draw-things-cli")!,
        bytes: 178_391_312,
        sha256: "7e5fb3af7dd99916d7671354a11fd40182bc6a0d16e7faf06fda7740c24915cd")

    /// The model sets Mimic can run, the default first. Each is downloaded into its own folder,
    /// `engine/models/<id>`, from Hugging Face at a pinned revision (the big files' sha256s are
    /// Hugging Face's own LFS hashes). The licences travel with the weights.
    /// TRELLIS.2 first, the default: in the comparison on issue #2 it kept what figures hold (a
    /// hammer, a bow, a raven on a shoulder) right 9 times out of 9, against 4 out of 10 for
    /// Pixal3D, which stays as the choice for the crispest surface.
    public static let catalogue: [EngineModel] = [trellis2Q8, pixal3d]

    /// What a new install makes minis with.
    public static var standard: EngineModel { catalogue[0] }

    /// A mini's model by the id it recorded. None recorded means Pixal3D, the only model before
    /// 0.4.0, not `standard`: since TRELLIS.2 became the standard, that turned an old mini round
    /// on Resize (TRELLIS.2's turn) and remade it with another model on Try Again.
    public static func model(_ id: String?) -> EngineModel? {
        catalogue.first { $0.id == (id ?? pixal3d.id) }
    }

    /// What a flat 2D cartoon is made with (#3): from the grey sculpt, TRELLIS.2 builds a
    /// cartoon out of flat panels while Pixal3D keeps it smooth (Piposh, 2026-09-30).
    public static let cartoon = pixal3d

    /// The model a new mini is made with: `chosen`, the one in use, unless it's a cartoon.
    public static func forMaking(cartoon isCartoon: Bool, chosen: EngineModel) -> EngineModel {
        isCartoon ? cartoon : chosen
    }

    /// The model this Mac makes minis with: the `model` default, or the standard one when it's
    /// unset or names a model this Mimic doesn't know.
    public static func selected(defaults: UserDefaults) -> EngineModel {
        defaults.string(forKey: SettingsKey.model).flatMap(model) ?? standard
    }

    static let pixal3dURL = URL(string: "https://huggingface.co/raven38/pixal3d-sv-q8_0-v1/resolve/46d399ac986f45a0d7f5b1ca5058614d8729a131")!
    static let trellis2URL = URL(string: "https://huggingface.co/ilintar/trellis2-gguf/resolve/a57397bd3d351599d9729fc144b3f87c3f87d65b")!

    static func files(_ base: URL, _ list: [(String, Int64, String)]) -> [EngineFile] {
        list.map { EngineFile(name: ($0.0 as NSString).lastPathComponent, url: base.appendingPathComponent($0.0), bytes: $0.1, sha256: $0.2) }
    }

    /// dinov3.gguf is Meta's DINOv3 and its licence says the licence must go wherever it goes;
    /// ilintar's repository ships none, so every set takes these two from raven38's.
    static let licences = files(pixal3dURL, [
        ("MIT_LICENSE.md", 1_566, "8a37ac9d3587a7cec9bd64fe9043482de7ad53a461532faa3a9f4840cf3f7e59"),
        ("DINOV3_LICENSE.md", 7_503, "25d122eb8f5b880fd23c736fb6ea8018ee45c12237e00b8a86d14c653904999e"),
    ])

    /// Pixal3D single view, 8-bit: the set Mimic was tuned on. Times in the summaries are whole
    /// minis (cutout, 3D, print prep) on an M2 Max, measured in app/NOTES.md.
    static let pixal3d = EngineModel(
        id: "pixal3d-sv", name: "Pixal3D",
        summary: "The crispest surface detail, and the fastest. Sometimes loses or misplaces something a figure holds; Make Another Version usually fixes it.", minutes: 8,
        family: .pixal3dSingleView,
        files: files(pixal3dURL, [
            ("dinov3.gguf", 323_657_920, "0dd4ffd4b46a248f5b7d49c35275d68461fbf73f57ddb4c1fa8afb4f7bb45a0d"),
            ("pixal3d_naf.gguf", 1_334_656, "c4f6cd80e94c8d120360ba50a3633322e6ecce0163966e3b7650b24f99c18569"),
            ("pixal3d_ss_flow_sv.gguf", 1_426_559_744, "75eeb538c5485e02f091d1fc8a55c8132035076a4e01b7e9607883deff3852c4"),
            ("ss_dec.gguf", 147_379_392, "2790b5eecb261cc877d9bf175ce2bd6dd48cd65be8c042c5f5bc023dfca01cf7"),
            ("pixal3d_shape_flow_512_sv.gguf", 1_476_761_760, "13f5df430ca49e6011827a3eeb208f047bdbad1fd4e52549809eaab63b83e19e"),
            ("shape_dec.gguf", 881_361_568, "0de7c7a675022dd8696d526a9279e5a50b2a35c8a79452f434a72dc53d40f169"),
            ("pixal3d_shape_flow_1024_sv.gguf", 1_476_761_760, "7cb1ecb189719edbbb991d16271ad0f8ab8bf54154df7795830aadba27f0efae"),
            ("pixal3d_tex_flow_1024_sv.gguf", 1_476_813_984, "06ef23d3badafc6f8ffcecebbc2bd0297461852b6c125dc4448f80d78040ee17"),
            ("tex_dec.gguf", 881_344_576, "88b4fced46455e02f316664d5c43584a311921dd9a1cdc1b7b7d981cca9214d4"),
            ("pixal3d-models.json", 2_522, "e127c0f70e6dc43c07b4c1afc896a7e14353e5c2e7aa6ce0fd82406a6a94c61e"),
            ("LICENSE.md", 2_129, "95774b0e9d74792a64ddbbd4c51388ea0df1c1a77f8fff0ebce7cb812822dbad"),
            ("README.md", 5_201, "d9cda1603b2828844623817d892ac20ee30c775c519798d8f60329fbd49ca4cf"),
        ]) + licences)

    /// Microsoft's TRELLIS.2, 8-bit, from one picture. Its dinov3, ss_dec, shape_dec and tex_dec
    /// are byte for byte Pixal3D's, so on a Mac that has Pixal3D those 2.2 GB are copied, not
    /// downloaded. birefnet.gguf is left out: Mimic always hands the engine a cutout.
    static let trellis2Q8 = EngineModel(
        id: "trellis2-q8", name: "TRELLIS.2",
        summary: "The most reliable with what a figure holds or carries: a weapon, a bow, a pet on a shoulder. A slightly softer surface, and slower on bulky figures.", minutes: 14,
        family: .trellis2,
        files: files(trellis2URL, [
            ("q8/dinov3.gguf", 323_657_920, "0dd4ffd4b46a248f5b7d49c35275d68461fbf73f57ddb4c1fa8afb4f7bb45a0d"),
            ("q8/ss_flow.gguf", 1_376_059_040, "ea6d8a42b20661a5c6a52e5ffbdc1df7aca9b212792193873b418c69f871422c"),
            ("q8/ss_dec.gguf", 147_379_392, "2790b5eecb261cc877d9bf175ce2bd6dd48cd65be8c042c5f5bc023dfca01cf7"),
            ("q8/shape_flow_512.gguf", 1_376_125_952, "29b639f4ff22ded8f91b619376a835f64b9874b0ebcadb9ac6c305195bf5d1f9"),
            ("q8/shape_flow_1024.gguf", 1_376_125_952, "997e9fc10ab95fda11c4cd1cbaf425101980ac36a2ef80e9c83e0b9c4bfc9680"),
            ("q8/shape_dec.gguf", 881_361_568, "0de7c7a675022dd8696d526a9279e5a50b2a35c8a79452f434a72dc53d40f169"),
            ("q8/tex_flow_512.gguf", 1_376_178_176, "389a2cbdda59d53b21e5989650d9d36b7ac603266eaef06712cd07a9fc377210"),
            ("q8/tex_flow_1024.gguf", 1_376_178_176, "cb2cb3aee74ba09c018f918ed8c146bc7e4f96335b61fa0d1fc1ff1a7811e6da"),
            ("q8/tex_dec.gguf", 881_344_576, "88b4fced46455e02f316664d5c43584a311921dd9a1cdc1b7b7d981cca9214d4"),
        ]) + licences)

    /// Everything a first launch with `model` downloads, as the setup screen counts it.
    public static func totalBytes(_ model: EngineModel) -> Int64 { engine.bytes + drawThingsCLI.bytes + model.bytes }

    /// Quick (no hashing, no launching): whether the engine and `model`'s files are there at all.
    /// The main window shows the setup screen until the chosen model's are.
    public static func present(_ install: Install, _ model: EngineModel) -> Bool {
        FileManager.default.isExecutableFile(atPath: install.trellisCLI.path)
            && FileManager.default.isExecutableFile(atPath: install.drawThingsCLI.path) && model.complete(in: install)
    }

    /// About how much space removing `model`'s folder gives back: its files on disk, half
    /// downloads included, less any another model on disk has byte for byte (setup clones
    /// those, and a clone's space is only freed when its twin goes too).
    public static func freed(by model: EngineModel, in install: Install, catalogue: [EngineModel] = catalogue) -> Int64 {
        let kept = Set(catalogue.filter { $0.id != model.id }.flatMap { other in
            other.files.filter { size(other.folder(in: install).appendingPathComponent($0.name)) == $0.bytes }.map(\.sha256)
        })
        let folder = model.folder(in: install)
        return model.files.reduce(0) { total, f in
            let whole = kept.contains(f.sha256) ? 0 : size(folder.appendingPathComponent(f.name)) ?? 0
            return total + whole + (size(folder.appendingPathComponent(f.name + ".part")) ?? 0)
        }
    }

    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? Int64
    }

    /// A file's sha256 in hex, read a few MB at a time (the big model files are 1.4 GB).
    public static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Why setup stopped, in words for people. Every one of them is fixed by Try Again once its
/// cause is gone: what's already downloaded is kept.
public enum SetupError: Error, Equatable, CustomStringConvertible {
    case offline
    case server(Int)
    case diskFull(needGB: Int, haveGB: Int)
    case ranOutOfSpace
    case damaged(String)
    case engineWontStart

    public var description: String {
        switch self {
        case .offline:
            "Mimic couldn't reach the internet. Check your connection, then press Try Again. It carries on where it stopped."
        case .server(let code):
            "The download server had a problem (error \(code)). Wait a few minutes, then press Try Again."
        case .diskFull(let need, let have):
            "Mimic needs about \(need) GB of free space for its 3D engine, and this Mac has \(have) GB. Free up some space, then press Try Again."
        case .ranOutOfSpace:
            "Your Mac ran out of space during the download. Free up some space (the setup screen shows how big the download is), then press Try Again."
        case .damaged(let name):
            "A file came down damaged (\(name)). Press Try Again to download it once more."
        case .engineWontStart:
            "The 3D engine downloaded but doesn't start on this Mac. Mimic needs a Mac with an Apple chip (M1 or newer)."
        }
    }
}

/// Where setup has got to, for the progress bar.
public struct SetupProgress: Sendable, Equatable {
    public enum Activity: Sendable, Equatable { case checking, downloading }
    public var activity: Activity
    /// Bytes of `EngineDownload.totalBytes` that are in place and checked, or on their way.
    public var done: Int64
    public var total: Int64

    public init(activity: Activity, done: Int64, total: Int64) {
        self.activity = activity; self.done = done; self.total = total
    }
}

/// First-launch setup: downloads whatever of the engine and its model files is missing or
/// damaged. Safe to run again at any point: files already right are kept, and a cut-off
/// download carries on from where it stopped.
public struct EngineSetup: Sendable {
    public var install: Install
    public var engineFile: EngineFile = EngineDownload.engine
    /// Draw Things' command line tool, downloaded beside the engine; nil leaves it out.
    public var drawThingsCLI: EngineFile? = EngineDownload.drawThingsCLI
    /// The model set to download.
    public var model: EngineModel = EngineDownload.standard
    /// Where identical files may already be on disk, so they're copied instead of downloaded.
    public var catalogue: [EngineModel] = EngineDownload.catalogue
    public var version: String = EngineDownload.version
    public var session: URLSession = .shared
    public var freeBytes: @Sendable (URL) -> Int64? = Checks.freeBytes

    public init(install: Install) { self.install = install }

    public func run(progress: @escaping @Sendable (SetupProgress) -> Void) async throws {
        let cli = drawThingsCLI
        let total = engineFile.bytes + (cli?.bytes ?? 0) + model.bytes
        let folder = model.folder(in: install)
        let tally = Tally()
        @Sendable func report(_ a: SetupProgress.Activity, _ extra: Int64 = 0) {
            progress(SetupProgress(activity: a, done: tally.done + extra, total: total))
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in model.files { reuse(file, in: folder) }

        // Room for what isn't here yet, and half a GB to spare, before anything starts.
        let engineOK = engineReady()
        let missing = (engineOK ? 0 : engineFile.bytes * 4)  // the tarball, then what it unpacks to
            + (cli.map { EngineDownload.size(install.drawThingsCLI) == $0.bytes ? 0 : $0.bytes } ?? 0)
            + model.files.reduce(0) { $0 + (EngineDownload.size(folder.appendingPathComponent($1.name)) == $1.bytes ? 0 : $1.bytes) }
        if missing > 0, let free = freeBytes(install.engine), free < missing + 500_000_000 {
            throw SetupError.diskFull(needGB: Int((Double(missing + 500_000_000) / 1e9).rounded(.up)), haveGB: Int(Double(free) / 1e9))
        }

        if engineOK {
            tally.done += engineFile.bytes
        } else {
            let tarball = install.engine.appendingPathComponent(engineFile.name)
            try await fetch(engineFile, to: tarball) { report(.downloading, $0) }
            try unpack(tarball)
            try? FileManager.default.removeItem(at: tarball)
            guard engineReady() else { throw SetupError.engineWontStart }
            tally.done += engineFile.bytes
        }
        if let cli {
            report(.checking)
            try await fetch(cli, to: install.drawThingsCLI) { report(.downloading, $0) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: install.drawThingsCLI.path)
            tally.done += cli.bytes
        }
        report(.checking)

        for file in model.files {
            try Task.checkCancellation()
            report(.checking)
            try await fetch(file, to: folder.appendingPathComponent(file.name)) { report(.downloading, $0) }
            tally.done += file.bytes
            report(.checking)
        }
    }

    /// The engine is the pinned build and actually starts (~10 ms).
    func engineReady() -> Bool {
        let versionFile = install.engine.appendingPathComponent("VERSION")
        guard let v = try? String(contentsOf: versionFile, encoding: .utf8), v.hasPrefix(version + " ") else { return false }
        return FileManager.default.isExecutableFile(atPath: install.trellisCLI.path)
            && Checks.execute(install.trellisCLI.path, ["--help"], 10)?.status == 0
    }

    private func unpack(_ tarball: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", tarball.path, "-C", install.engine.path, "--strip-components=1"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tarball)
            throw SetupError.damaged(engineFile.name)
        }
    }

    // MARK: Copying a file another model already has

    /// Some sets share files byte for byte (TRELLIS.2's dinov3.gguf is Pixal3D's). When another
    /// set's folder has one at the right size, it's cloned (APFS: instant, and no space until
    /// either copy changes), and the download pass checks its sha256 like any other file.
    func reuse(_ file: EngineFile, in folder: URL) {
        let to = folder.appendingPathComponent(file.name)
        guard !FileManager.default.fileExists(atPath: to.path) else { return }
        for other in catalogue where other.id != model.id {
            guard let same = other.files.first(where: { $0.sha256 == file.sha256 }) else { continue }
            let from = other.folder(in: install).appendingPathComponent(same.name)
            if EngineDownload.size(from) == file.bytes, clonefile(from.path, to.path, 0) == 0 { return }
        }
    }

    // MARK: Downloading one file

    /// Gets `file` to `destination`, or leaves it if it's already right. Downloads go to
    /// `<name>.part` first, so a half file is never taken for a whole one, and a `.part` left by a
    /// download that stopped is carried on with an HTTP Range request. A finished file whose
    /// sha256 is wrong is thrown away, so Try Again starts it afresh.
    func fetch(_ file: EngineFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        if EngineDownload.size(destination) == file.bytes, EngineDownload.sha256(destination) == file.sha256 { return }
        try? fm.removeItem(at: destination)
        let part = URL(fileURLWithPath: destination.path + ".part")
        var have = EngineDownload.size(part) ?? 0
        if have >= file.bytes {
            // Complete already (or too long, so wrong).
            if have == file.bytes, EngineDownload.sha256(part) == file.sha256 {
                try fm.moveItem(at: part, to: destination)
                return
            }
            try? fm.removeItem(at: part)
            have = 0
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        Log.download.notice("Downloading \(file.name, privacy: .public)\(have > 0 ? " from byte \(have)" : "", privacy: .public)")
        var request = URLRequest(url: file.url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let transfer = try Transfer(part: part, have: have, progress: progress)
        do { try await transfer.run(request, session: session) } catch {
            Log.download.error("\(file.name, privacy: .public) stopped: \(String(describing: error), privacy: .public)")
            throw error
        }

        guard EngineDownload.size(part) == file.bytes, EngineDownload.sha256(part) == file.sha256 else {
            try? fm.removeItem(at: part)
            Log.download.error("\(file.name, privacy: .public) arrived damaged")
            throw SetupError.damaged(file.name)
        }
        try fm.moveItem(at: part, to: destination)
        Log.download.notice("Downloaded \(file.name, privacy: .public)")
    }
}

/// Bytes done, shared by the progress closures of one run.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    var done: Int64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// One HTTP transfer streamed into a `.part` file. A server that honours the Range request (206)
/// is appended to; one that sends the whole file (200) starts the file over.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let have: Int64
    private let progress: @Sendable (Int64) -> Void
    // Touched only on the session's delegate queue, one callback at a time.
    private var written: Int64 = 0
    private var reported = Date.distantPast
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(part: URL, have: Int64, progress: @escaping @Sendable (Int64) -> Void) throws {
        handle = try FileHandle(forWritingTo: part)
        self.have = have
        self.progress = progress
    }

    func run(_ request: URLRequest, session: URLSession) async throws {
        defer { try? handle.close() }
        let task = session.dataTask(with: request)
        task.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock { continuation = c }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206 where have > 0:
                try handle.seek(toOffset: UInt64(have))
                written = have
            case 200:
                try handle.truncate(atOffset: 0)
                written = 0
            case 416:
                // The .part doesn't fit the file (it changed since); start again next time.
                try handle.truncate(atOffset: 0)
                failure = SetupError.server(status)
                return completionHandler(.cancel)
            default:
                failure = SetupError.server(status)
                return completionHandler(.cancel)
            }
        } catch {
            failure = error
            return completionHandler(.cancel)
        }
        progress(written)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            // A few times a second is plenty for a progress bar; every chunk would flood it.
            if Date().timeIntervalSince(reported) > 0.2 { reported = Date(); progress(written) }
        } catch {
            failure = (error as NSError).code == Int(ENOSPC) || (error as NSError).code == NSFileWriteOutOfSpaceError
                ? SetupError.ranOutOfSpace : error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in defer { continuation = nil }; return continuation }
        if let failure { return c?.resume(throwing: failure) ?? () }
        guard let error else { return c?.resume() ?? () }
        if (error as? URLError)?.code == .cancelled { return c?.resume(throwing: CancellationError()) ?? () }
        c?.resume(throwing: SetupError.offline)
    }
}
