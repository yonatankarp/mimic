import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where step 1's pictures are made (#247): Draw Things on this Mac, the default, or an online
/// service with the person's own key. Stored like the helper's provider, so `mimic make` through
/// the PATH symlink reads the app's choice.
public enum ImageService: String, CaseIterable, Sendable {
    case drawThings = "drawthings", bfl, openai
    public static let key = "imageService"
    public static func load(_ d: UserDefaults) -> ImageService { ImageService(rawValue: d.string(forKey: key) ?? "") ?? .drawThings }

    /// The one `maker` is: an online service's, else Draw Things.
    public init(_ maker: (any PictureMaker)?) {
        guard let online = (maker as? any OnlineImages)?.service else { self = .drawThings; return }
        self = Self.allCases.first { $0.online?.keyAccount == online.keyAccount } ?? .drawThings
    }

    /// The online service this is, nil for Draw Things. Each one's entry is in its own file.
    public var online: OnlineService? {
        switch self {
        case .drawThings: nil
        case .bfl: .bfl
        case .openai: .openai
        }
    }
}

/// Makes step 1's pictures: draws one from a description, or redraws one as a grey sculpt.
/// Draw Things and the online services all do; the job runner asks whichever was chosen.
public protocol PictureMaker: AnyObject, Sendable {
    func draw(description: String, seed: Int, kind: MiniKind) throws -> Data
    func sculpt(picture: URL, seed: Int, kind: MiniKind, change: String?) throws -> Data
    /// Stop: ends a request in flight, or the next one asked for.
    func cancel()
    /// Forgets an earlier Stop, when a job starts.
    func reset()
}

extension DrawThings: PictureMaker {}

/// An online picture service's client: a picture maker whose key can be checked for free.
public protocol OnlineImages: PictureMaker {
    var service: OnlineService { get }
    /// Settings' Test and the setup check: a request that costs nothing and proves the key.
    func check() throws
}

/// One online picture service, everything about it that isn't how its API is asked: what people
/// see, where its key is kept and may go, and how to check it. Settings, the checks, the report
/// and every message read the name from here, so none of them names a service itself.
public struct OnlineService: Sendable {
    /// The name people see.
    public let name: String
    /// The Keychain account its key is saved under (service "com.mimic.app", as the helper's keys).
    public let keyAccount: String
    /// Where to get a key: Settings' "Get a key".
    public let keyPage: URL
    public let base: URL
    /// The header the key goes in, and what goes before it there.
    let keyHeader: String
    let keyPrefix: String
    /// Hosts the key may go to over https, besides the address it was set up with; "*.example.com"
    /// is any host under it.
    let keyHosts: [String]
    /// A GET on this path checks the key for free.
    let checkPath: String
    /// Its client, asking `key` for the key only when a request goes out.
    let client: @Sendable (_ base: URL, _ key: @escaping @Sendable () -> String?) -> any OnlineImages

    public func client(base: URL? = nil, key: @escaping @Sendable () -> String?) -> any OnlineImages { client(base ?? self.base, key) }

    /// The service Settings chose, with the key saved for it; nil when pictures are made by Draw Things.
    public static func configured(defaults: UserDefaults, service: String = Keychain.service) -> (any OnlineImages)? {
        guard let s = ImageService.load(defaults).online else { return nil }
        return s.client { Keychain.read(account: s.keyAccount, service: service) }
    }

    func mayHaveKey(host: String) -> Bool {
        keyHosts.contains { $0.hasPrefix("*.") ? host.hasSuffix($0.dropFirst()) : host == $0 }
    }
}

/// What every online client shares: the key, Stop, and requests that only ever take the key
/// where it may go.
public class OnlineClient: @unchecked Sendable {
    public let service: OnlineService
    let base: URL
    private let key: @Sendable () -> String?
    /// How long a picture may take.
    var timeout: TimeInterval = 300
    /// How long to wait before each new try of a request the service turned away as busy, when it
    /// doesn't say: one try, then one more after each.
    var retryWaits: [TimeInterval] = [5, 15]

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var canceled = false
    /// The last reply's Retry-After, in seconds.
    private var retryAfter: TimeInterval?

    init(service: OnlineService, base: URL, key: @escaping @Sendable () -> String?) {
        self.service = service; self.base = base; self.key = key
    }

    public func cancel() { lock.withLock { canceled = true; task?.cancel() } }
    public func reset() { lock.withLock { canceled = false } }
    var isCanceled: Bool { lock.withLock { canceled } }

    /// Sends a new picture's request, and sends it again, twice at most, when the service turns it
    /// away as busy (429, 5xx): a request turned away isn't charged, and a busy moment shouldn't
    /// fail a queued mini nobody is watching (#320). Only the request that asks for the picture: once
    /// it's taken, the picture is paid for. Waits as long as the reply's Retry-After says (a number of
    /// seconds; the date form isn't read), up to a minute, else `retryWaits`. Stop ends the wait.
    func submit<T>(_ send: () throws -> T) throws -> T {
        for wait in retryWaits {
            do { return try send() } catch let e as OnlineImagesError where e.problem == .busy {
                pause(min(lock.withLock { retryAfter } ?? wait, 60))
            }
        }
        return try send()
    }

    /// Waits `seconds`, or until Stop.
    func pause(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !isCanceled { usleep(20_000) }
    }

    /// An error naming this service.
    func fail(_ problem: OnlineImagesError.Problem) -> OnlineImagesError { OnlineImagesError(problem, service: service.name) }

    func validKey() throws -> String {
        let k = key()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !k.isEmpty else { throw fail(.noKey) }
        return k
    }

    /// A request to `path` on the service, carrying the key.
    func request(_ path: String, key: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        authorize(&req, key: key)
        return req
    }

    func authorize(_ req: inout URLRequest, key: String) {
        req.setValue(service.keyPrefix + key, forHTTPHeaderField: service.keyHeader)
    }

    /// The free key check's request.
    func checkRequest(timeout: TimeInterval) throws -> URLRequest {
        var req = request(service.checkPath, key: try validKey())
        req.timeoutInterval = timeout
        return req
    }

    /// The key goes to the service's own hosts over https, or to the address it was set up with
    /// (this Mac in tests): never to whatever address a reply names.
    func sendsKey(to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == base.host?.lowercased() && url.scheme == base.scheme && url.port == base.port { return true }
        return url.scheme == "https" && service.mayHaveKey(host: host)
    }

    /// Error text a service sent, for a message: the key taken out before it's cut short, or a
    /// cut key would stay.
    func masked(_ text: String) -> String {
        var why = text
        if let k = key(), !k.isEmpty { why = why.replacingOccurrences(of: k, with: "…") }
        return String(why.prefix(200))
    }

    func fetch(_ req: URLRequest) throws -> (status: Int, data: Data) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Int, Data), Error> = .failure(fail(.unreachable))
        let name = service.name
        let t = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            if let err = err as? URLError { result = .failure(OnlineImagesError(.from(err), service: name)); return }
            guard let data, let http = resp as? HTTPURLResponse else { return }
            self.lock.withLock { self.retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } }
            result = .success((http.statusCode, data))
        }
        t.delegate = KeepKey(header: service.keyHeader) { [self] url in self.sendsKey(to: url) }
        let stopNow = lock.withLock { () -> Bool in
            if !canceled { task = t; t.resume() }
            return canceled
        }
        if stopNow { throw fail(.cancelled) }
        done.wait()
        lock.withLock { task = nil }
        return try result.get()
    }

    /// A PNG of the size asked for, as Draw Things gives and step 1 writes `source.png`. PNG and the
    /// size are asked for, but anything else that comes back is converted and scaled to them.
    func png(_ data: Data, width: Int, height: Int) throws -> Data {
        let unreadable = fail(.failed(String(localized: "the picture it sent can't be read", bundle: .mimicCore)))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw unreadable
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) && image.width == width && image.height == height { return data }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw unreadable }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        guard let sized = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw unreadable
        }
        CGImageDestinationAddImage(dest, sized, nil)
        guard CGImageDestinationFinalize(dest) else { throw unreadable }
        return out as Data
    }
}

/// URLSession follows a redirect with every header, the key too: a redirect to an address the key
/// mustn't go to is followed without it.
final class KeepKey: NSObject, URLSessionTaskDelegate, Sendable {
    let header: String
    let allowed: @Sendable (URL) -> Bool
    init(header: String, _ allowed: @escaping @Sendable (URL) -> Bool) { self.header = header; self.allowed = allowed }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, !allowed(url) else { return request }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: header)
        return stripped
    }
}

/// In plain words, naming the service, since a job keeps `String(describing:)` as why it failed.
public struct OnlineImagesError: Error, CustomStringConvertible, Equatable {
    public enum Problem: Equatable, Sendable {
        case noKey, badKey, noCredits, busy, refused([String]), timedOut, noInternet, unreachable, failed(String), cancelled

        static func from(_ e: URLError) -> Problem {
            switch e.code {
            case .cancelled: .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed: .noInternet
            case .timedOut: .timedOut
            default: .unreachable
            }
        }
    }

    public let problem: Problem
    /// The service's name, as people see it.
    public let service: String

    public init(_ problem: Problem, service: String) { self.problem = problem; self.service = service }

    public var description: String {
        switch problem {
        case .noKey: String(localized: "No \(service) key is saved. Paste yours in Settings, under Pictures.", bundle: .mimicCore)
        case .badKey: String(localized: "\(service) turned the key down. Copy it again from your account and save it in Settings, under Pictures.", bundle: .mimicCore)
        case .noCredits: String(localized: "Your \(service) account is out of credits, or has reached its spending limit. Add credits or raise your limit on their website, then try again.", bundle: .mimicCore)
        case .busy: String(localized: "\(service) is busy, or you've reached your account's limit. Try again in a minute.", bundle: .mimicCore)
        case .refused(let why) where why.isEmpty: String(localized: "\(service) wouldn't make this picture. Try different words or another picture.", bundle: .mimicCore)
        case .refused(let why): String(localized: "\(service) wouldn't make this picture (\(why.joined(separator: ", ").lowercased())). Try different words or another picture.", bundle: .mimicCore)
        case .timedOut: String(localized: "\(service) took too long to make the picture. Try again.", bundle: .mimicCore)
        case .noInternet: String(localized: "No internet connection. Connect, then try again.", bundle: .mimicCore)
        case .unreachable: String(localized: "Couldn't reach \(service). Try again in a minute.", bundle: .mimicCore)
        case .failed(let why) where why.isEmpty: String(localized: "\(service) couldn't make the picture. Try again.", bundle: .mimicCore)
        case .failed(let why): String(localized: "\(service) couldn't make the picture: \(why)", bundle: .mimicCore)
        case .cancelled: String(localized: "Stopped.", bundle: .mimicCore)
        }
    }
}
