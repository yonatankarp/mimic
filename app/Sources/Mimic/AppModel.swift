import AppKit
import MimicCore
import Observation

/// The state every window shares: the Mimic folder, the gallery, the selection and the one job.
/// Views read it from the environment (`@Environment(AppModel.self)`).
@MainActor @Observable
final class AppModel {
    let install: Install?
    let jobs: JobRunner?
    var minis: [Mini] = []
    var selection: Mini.ID?
    /// The job's latest status, updated on the main thread; nil before the first job.
    var job: JobStatus?

    init() {
        install = Install.locate()
        jobs = install.map { JobRunner(install: $0) }
        jobs?.onChange = { [weak self] s in Task { @MainActor in self?.jobChanged(s) } }
        reload()
    }

    var selected: Mini? { minis.first { $0.id == selection } }

    func reload() {
        guard let install else { return }
        minis = Gallery.list(install.runs)
        if selection == nil || selected == nil { selection = minis.first?.id }
    }

    private func jobChanged(_ s: JobStatus) {
        job = s
        if !s.running { reload() }
    }

    /// Opens a print file in the picked slicer, or the Mac's default app for STL files.
    func openInSlicer(_ stl: URL) {
        if let slicer = Slicer.preferred() {
            NSWorkspace.shared.open([stl], withApplicationAt: slicer.app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(stl)
        }
    }

    var slicerName: String { Slicer.preferred()?.name ?? "your slicer" }
}
