import SwiftUI

// Liquid Glass: the look every floating panel and button in Mimic shares.

extension View {
    /// A floating glass panel: cards, badges, the viewer's controls.
    func glassCard(cornerRadius: CGFloat = 12) -> some View { glassEffect(.regular, in: .rect(cornerRadius: cornerRadius)) }

    /// A glass button; `prominent` for the one main action on a screen.
    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
    }
}
