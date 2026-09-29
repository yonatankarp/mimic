import CryptoKit
import Foundation

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

    /// Pixal3D's model files, from Hugging Face at a pinned revision (the big ones' sha256s are
    /// Hugging Face's own LFS hashes). The licences travel with the weights.
    static let modelsURL = URL(string: "https://huggingface.co/raven38/pixal3d-sv-q8_0-v1/resolve/46d399ac986f45a0d7f5b1ca5058614d8729a131")!

    public static let models: [EngineFile] = [
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
        ("MIT_LICENSE.md", 1_566, "8a37ac9d3587a7cec9bd64fe9043482de7ad53a461532faa3a9f4840cf3f7e59"),
        ("DINOV3_LICENSE.md", 7_503, "25d122eb8f5b880fd23c736fb6ea8018ee45c12237e00b8a86d14c653904999e"),
        ("README.md", 5_201, "d9cda1603b2828844623817d892ac20ee30c775c519798d8f60329fbd49ca4cf"),
    ].map { EngineFile(name: $0.0, url: modelsURL.appendingPathComponent($0.0), bytes: $0.1, sha256: $0.2) }

    /// Everything, as the setup screen counts it: 8.1 GB.
    public static var totalBytes: Int64 { engine.bytes + models.reduce(0) { $0 + $1.bytes } }

    /// The files trellis-cli loads. The health check wants every one at its full size: any
    /// missing file fails a run minutes in, and the size catches a download cut short.
    public static var weights: [EngineFile] { models.filter { $0.name.hasSuffix(".gguf") } }

    /// Quick (no hashing, no launching): whether the engine and its model files are there at all.
    /// The main window shows the setup screen until they are.
    public static func present(_ install: Install) -> Bool {
        FileManager.default.isExecutableFile(atPath: install.trellisCLI.path)
            && weights.allSatisfy { size(install.models.appendingPathComponent($0.name)) == $0.bytes }
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
    case couldntMove(String)

    public var description: String {
        switch self {
        case .offline:
            "Mimic couldn't reach the internet. Check your connection, then press Try Again. It carries on where it stopped."
        case .server(let code):
            "The download server had a problem (error \(code)). Wait a few minutes, then press Try Again."
        case .diskFull(let need, let have):
            "Mimic needs about \(need) GB of free space for its 3D engine, and this Mac has \(have) GB. Free up some space, then press Try Again."
        case .ranOutOfSpace:
            "Your Mac ran out of space during the download. Free up about 9 GB, then press Try Again."
        case .damaged(let name):
            "A file came down damaged (\(name)). Press Try Again to download it once more."
        case .engineWontStart:
            "The 3D engine downloaded but doesn't start on this Mac. Mimic needs a Mac with an Apple chip (M1 or newer)."
        case .couldntMove(let what):
            "Mimic couldn't move its 3D engine to its new place (\(what)). Press Try Again."
        }
    }
}

/// Where setup has got to, for the progress bar.
public struct SetupProgress: Sendable, Equatable {
    public enum Activity: Sendable, Equatable { case moving, checking, downloading }
    public var activity: Activity
    /// Bytes of `EngineDownload.totalBytes` that are in place and checked, or on their way.
    public var done: Int64
    public var total: Int64
}

/// First-launch setup: moves an old install's engine out of image-to-3dlab, then downloads
/// whatever of the engine and its model files is missing or damaged. Safe to run again at any
/// point: files already right are kept, and a cut-off download carries on from where it stopped.
public struct EngineSetup: Sendable {
    public var install: Install
    public var engineFile: EngineFile = EngineDownload.engine
    public var models: [EngineFile] = EngineDownload.models
    public var version: String = EngineDownload.version
    public var session: URLSession = .shared
    public var freeBytes: @Sendable (URL) -> Int64? = Checks.freeBytes

    public init(install: Install) { self.install = install }

    public func run(progress: @escaping @Sendable (SetupProgress) -> Void) async throws {
        let total = engineFile.bytes + models.reduce(0) { $0 + $1.bytes }
        let tally = Tally()
        @Sendable func report(_ a: SetupProgress.Activity, _ extra: Int64 = 0) {
            progress(SetupProgress(activity: a, done: tally.done + extra, total: total))
        }

        if let lab = install.legacyLab, FileManager.default.fileExists(atPath: lab.path) {
            report(.moving)
            try migrate(from: lab)
        }
        try FileManager.default.createDirectory(at: install.models, withIntermediateDirectories: true)

        // Room for what isn't here yet, and half a GB to spare, before anything starts.
        let engineOK = engineReady()
        let missing = (engineOK ? 0 : engineFile.bytes * 4)  // the tarball, then what it unpacks to
            + models.reduce(0) { $0 + (EngineDownload.size(install.models.appendingPathComponent($1.name)) == $1.bytes ? 0 : $1.bytes) }
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
        report(.checking)

        for file in models {
            try Task.checkCancellation()
            report(.checking)
            try await fetch(file, to: install.models.appendingPathComponent(file.name)) { report(.downloading, $0) }
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

    // MARK: Moving an old install

    /// Installs before the Swift engine kept it inside a clone of image-to-3dlab: move it rather
    /// than download 8 GB again. Its trellis-cli is kept only if it's the build this Mimic pins;
    /// the model files are checked by the download pass that follows, like any others. The rest
    /// of image-to-3dlab (a git clone and a Python setup) is no longer used, and is removed only
    /// once everything worth keeping has moved.
    func migrate(from lab: URL) throws {
        let fm = FileManager.default
        let old = lab.appendingPathComponent("vendor/pixal3d-cpp")
        let build = old.appendingPathComponent("build"), oldModels = old.appendingPathComponent("models/pixal3d-sv")
        func move(_ from: URL, _ to: URL) throws {
            do { try fm.moveItem(at: from, to: to) } catch { throw SetupError.couldntMove(from.lastPathComponent) }
        }
        do { try fm.createDirectory(at: install.models, withIntermediateDirectories: true) } catch {
            throw SetupError.couldntMove(install.models.path)
        }
        if fm.fileExists(atPath: old.path) {
            let oldVersion = (try? String(contentsOf: build.appendingPathComponent("VERSION"), encoding: .utf8)) ?? ""
            if !fm.isExecutableFile(atPath: install.trellisCLI.path), oldVersion.hasPrefix(version + " ") {
                let names = (try? fm.contentsOfDirectory(atPath: build.path)) ?? []
                for name in names where name == "trellis-cli" || name == "VERSION" || name.hasPrefix("LICENSE-")
                    || (name.hasPrefix("libggml") && name.hasSuffix(".dylib")) {
                    let to = install.engine.appendingPathComponent(name)
                    try? fm.removeItem(at: to)
                    try move(build.appendingPathComponent(name), to)
                }
            }
            for file in models {
                let from = oldModels.appendingPathComponent(file.name), to = install.models.appendingPathComponent(file.name)
                if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) { try move(from, to) }
            }
        }
        do { try fm.removeItem(at: lab) } catch { throw SetupError.couldntMove(lab.lastPathComponent) }
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

        var request = URLRequest(url: file.url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let transfer = try Transfer(part: part, have: have, progress: progress)
        try await transfer.run(request, session: session)

        guard EngineDownload.size(part) == file.bytes, EngineDownload.sha256(part) == file.sha256 else {
            try? fm.removeItem(at: part)
            throw SetupError.damaged(file.name)
        }
        try fm.moveItem(at: part, to: destination)
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
