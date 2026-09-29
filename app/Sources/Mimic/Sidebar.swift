import MimicCore
import SwiftUI

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
