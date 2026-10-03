import Foundation
import MimicCore

#if DEBUG
extension AppModel {
    /// Development only: `MIMIC_DEMO_PROGRESS=<mini>[:<speed>][:fail|:hold][:resize]` plays a
    /// pretend job through the job's popover, so its animations can be looked at without a
    /// real ten-minute job. Nothing runs and nothing is written; speed 20 (the default) plays
    /// a make in about half a minute, and hold stays in its long step.
    func demoProgress(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let speed = parts.dropFirst().compactMap(Double.init).first ?? 20
        let resize = parts.contains("resize"), fail = parts.contains("fail"), hold = parts.contains("hold")
        // Pretend seconds at which each step starts, and the end.
        let plan: [(step: JobStep, at: Double)] = resize ? [(.print, 0)] : [(.picture, 0), (.shape, 25), (.print, 480)]
        let end = resize ? 50.0 : 530
        Task {
            try? await Task.sleep(for: .seconds(1))  // the window first
            var s = JobStatus(name: parts[0], kind: resize ? .prep : .generate, step: plan[0].step, started: Date())
            s.stepStarted = s.started
            present { $0.jobAdded(note: queuedNote) }
            job = s
            DockProgress.follow(self)
            showJob()
            var t = 0.0
            while hold || t < end {
                try? await Task.sleep(for: .seconds(0.25))
                t += 0.25 * speed
                if hold { t = min(t, 300) }
                s.started = Date().addingTimeInterval(-t)
                let at = plan.last { $0.at <= t }!
                s.stepStarted = s.started.addingTimeInterval(at.at)
                s.step = at.step
                if fail && s.step == .print { break }
                job = s
            }
            s.running = false
            s.exit = fail ? 1 : 0
            if fail { s.step = .shape; s.problem = "The 3D engine stopped early (pretend)." }
            job = s
            reload()
        }
    }
}
#endif
