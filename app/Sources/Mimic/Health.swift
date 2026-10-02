import Foundation
import MimicCore
import Observation

/// The latest health check results, shared by the Settings window, the Make button and the
/// toolbar's Needs Setup. One instance for the whole app (`Health.shared`), so there's only ever one
/// check run and one Draw Things watch going.
@MainActor @Observable
final class Health {
    static let shared = Health()

    /// The checks of the latest run, in order; a row with no result yet shows a spinner.
    private(set) var checks: [Check] = []
    private(set) var results: [String: CheckResult] = [:]
    private(set) var running = false
    private(set) var lastChecked: Date?
    /// Bumped by every full run, so a run that "Check Again" replaced drops its late results.
    private var generation = 0

    /// Passive: nothing runs until `check` is called.
    private init() {}

    /// Runs every check, one at a time, each off the main thread.
    func check(_ install: Install?) {
        guard let install else { return }
        generation += 1
        let run = generation
        checks = Checks(install: install, model: EngineDownload.selected(defaults: .standard)).all
        results = [:]
        running = true
        Task {
            for c in checks {
                let r = await Task.detached { c.run() }.value
                guard run == generation else { return }
                results[c.id] = r
            }
            running = false
            lastChecked = Date()
        }
    }

    /// While the window that calls this is open: re-checks Draw Things every few seconds while
    /// any of its checks fails, so the setup steps tick off as they're done. Once ready it keeps
    /// asking, less often: Draw Things can be quit at any moment, and the web page once stopped
    /// asking after it had seen it ready.
    func watchDrawThings(_ install: Install?) async {
        guard let install else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(picturesReady ? 15 : 4))
            guard !running else { continue }
            let run = generation
            for c in Checks(install: install, model: EngineDownload.selected(defaults: .standard)).all where Checks.drawThingsIDs.contains(c.id) {
                let r = await Task.detached { c.run() }.value
                guard run == generation, !Task.isCancelled else { break }
                results[c.id] = r
            }
        }
    }

    func ok(_ id: String) -> Bool { results[id]?.ok == true }

    /// Pictures are made online (Settings → Pictures), so Draw Things isn't needed. Its key is
    /// checked with the others, never by the Draw Things watch: that would ask every few seconds.
    var online: Bool { checks.contains { $0.id == Checks.onlineID } }

    /// False until whatever makes the pictures has come back green: the online service's key, or
    /// every Draw Things check. Closed counts as green when Mimic opens it (Settings → Open Draw
    /// Things when needed).
    var picturesReady: Bool { online ? ok(Checks.onlineID) : Checks.drawThingsIDs.allSatisfy(ok) }
    /// What a picture needs, as "A description needs …" says it.
    var pictureNeed: String { online ? "a working Black Forest Labs key" : "Draw Things" }
    /// Ready, and closed: Mimic opens it when a mini needs it.
    var drawThingsOpensWhenNeeded: Bool { results["drawthings-api"]?.label == Checks.opensWhenNeeded }
    /// Its API has answered in this check, so its connection is known to be on.
    var drawThingsConnected: Bool { ok("drawthings-api") && !drawThingsOpensWhenNeeded }

    /// Why a mini can't be made right now, or nil. Only known failures count: a check still
    /// running doesn't block.
    var blocking: String? {
        let missing = checks.compactMap { c in results[c.id].flatMap { $0.required && !$0.ok ? $0.label : nil } }
        if missing.isEmpty { return nil }
        return "Mimic isn't fully set up yet: \(missing.joined(separator: ", "))."
    }
}
