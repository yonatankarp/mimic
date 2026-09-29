import MimicCore
import SwiftUI

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
