import SwiftUI

// Liquid Glass on macOS 26 and later; the closest standard look on macOS 15, which Mimic
// still supports.

extension View {
    /// A floating glass panel: cards, badges, the viewer's controls.
    func glassCard(cornerRadius: CGFloat = 12) -> some View { modifier(GlassCard(radius: cornerRadius)) }

    /// A glass button; `prominent` for the one main action on a screen.
    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }
}

private struct GlassCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}
