import MimicCore
import SwiftUI

struct MimicApp: App {
    init() {
        // A job left running by a Mimic that crashed (or was force-quit) is stopped first:
        // otherwise a 14 GB Blender could run on with nothing watching it.
        if let install = Install.locate() { Leftover.stop(install.runs) }
    }

    var body: some Scene {
        WindowGroup("Mimic") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

struct ContentView: View {
    @State private var install = Install.locate()
    @State private var minis: [Mini] = []
    @State private var selection: Mini.ID?

    var body: some View {
        if let install {
            NavigationSplitView {
                List(minis, selection: $selection) { mini in
                    GalleryRow(mini: mini)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .navigationTitle("Your Minis")
            } detail: {
                if let mini = minis.first(where: { $0.id == selection }) {
                    MiniDetail(mini: mini)
                } else {
                    ContentUnavailableView("No mini selected", systemImage: "cube",
                                           description: Text("Pick a mini on the left."))
                }
            }
            .onAppear { reload(install) }
        } else {
            ContentUnavailableView("Can't find the Mimic folder", systemImage: "folder.badge.questionmark",
                                   description: Text("Run the installer, or set MIMIC_HOME."))
        }
    }

    private func reload(_ install: Install) {
        minis = Gallery.list(install.runs)
        if selection == nil { selection = minis.first?.id }
    }
}

struct GalleryRow: View {
    let mini: Mini
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: mini.renders.first?.url ?? mini.source) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.secondary.opacity(0.15) }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(mini.displayName).lineLimit(1)
                Text(mini.madeAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MiniDetail: View {
    let mini: Mini
    var body: some View {
        VStack(spacing: 12) {
            if let stl = mini.stl {
                MiniViewer(stl: stl)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView("This mini isn't finished yet.", systemImage: "hourglass")
            }
            HStack(spacing: 10) {
                ForEach([("Your picture", mini.source)] + mini.renders.map { ($0.view.capitalized, Optional($0.url)) },
                        id: \.0) { caption, url in
                    VStack(spacing: 4) {
                        AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.15) }
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .navigationTitle(mini.displayName)
    }
}
