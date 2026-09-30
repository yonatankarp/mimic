import Foundation

/// Watches the minis folder and each project in it for entries added, removed or renamed (not
/// files written inside a mini, which a running job does all the time), and calls `changed` on
/// the main thread, once for a burst of changes.
public final class FolderWatch {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watching: [URL]?
    private var pending: DispatchWorkItem?
    private let changed: @MainActor () -> Void

    public init(changed: @escaping @MainActor () -> Void) { self.changed = changed }

    /// Watches `runs` and these projects, instead of whatever it watched before (nothing to do
    /// when they're the same).
    public func follow(_ runs: URL, projects: [String]) {
        let folders = [runs] + projects.map { runs.appendingPathComponent($0) }
        guard folders != watching else { return }
        watching = folders
        sources.forEach { $0.cancel() }
        sources = folders.compactMap { folder in
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.soon() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func soon() {
        pending?.cancel()
        let work = DispatchWorkItem { [changed] in MainActor.assumeIsolated { changed() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit { sources.forEach { $0.cancel() } }
}
