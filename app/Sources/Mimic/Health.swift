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
    /// asking after it had seen it ready. However many windows call it, one loop asks (#347).
    func watchDrawThings(_ install: Install?) async {
        guard let install else { return }
        await drawThingsWatch.join { await self.watch(install) }
    }

    @ObservationIgnored private let drawThingsWatch = SharedLoop()

    private func watch(_ install: Install) async {
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

    /// What the checks so far decide (`Readiness`); the app's views read it through these.
    var readiness: Readiness { Readiness(checks: checks, results: results) }
    func ok(_ id: String) -> Bool { readiness.ok(id) }
    /// Pictures are made online, so Draw Things isn't needed. Its key is checked with the others,
    /// never by the Draw Things watch: that would ask every few seconds.
    var online: Bool { readiness.online }
    var picturesReady: Bool { readiness.picturesReady }
    var pictureNeed: String { readiness.pictureNeed(ImageService.load(.standard)) }
    var drawThingsOpensWhenNeeded: Bool { readiness.drawThingsOpensWhenNeeded }
    var drawThingsConnected: Bool { readiness.drawThingsConnected }
    var blocking: String? { readiness.blocking }
}
