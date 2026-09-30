import Foundation
import UniformTypeIdentifiers

/// Pictures dropped on New Mini or imported from an iPhone: a picture file from Finder as it
/// is, anything else (a drag from Photos, which promises a file, or from a web page, which
/// gives the picture itself) saved to a file first. Never a web address: a page's picture comes
/// with one, and it isn't the picture. On the main actor: item providers aren't safe to pass
/// between threads.
@MainActor enum PictureDrop {
    /// `named`: it came with a name the mini can be named after.
    struct Item: Sendable { let url: URL; let named: Bool }

    static let types: [UTType] = [.fileURL, .image]

    static func pictures(_ providers: [NSItemProvider]) async -> [Item] {
        var items: [Item] = []
        for provider in providers { if let item = await picture(provider) { items.append(item) } }
        return items
    }

    private static func picture(_ provider: NSItemProvider) async -> Item? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(provider),
           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            return Item(url: url, named: true)
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let name = provider.suggestedName
        return await withCheckedContinuation { done in
            // The file is only there until this returns, so it's copied here.
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                done.resume(returning: url.flatMap { keep($0, name: name) })
            }
        }
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    nonisolated private static func keep(_ file: URL, name: String?) -> Item? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped pictures/\(UUID().uuidString)")
        let base = name.map { ($0 as NSString).deletingPathExtension } ?? "Picture"
        let url = folder.appendingPathComponent(base).appendingPathExtension(file.pathExtension)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: url)
        } catch { return nil }
        return Item(url: url, named: name != nil)
    }
}
