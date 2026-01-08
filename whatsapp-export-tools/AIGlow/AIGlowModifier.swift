import SwiftUI

/// Apply the Apple-Intelligence-style AI glow to any view.
struct AIGlowModifier: ViewModifier {
    let active: Bool
    let boost: Bool
    let cornerRadius: CGFloat
    let style: AIGlowStyle

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                if proxy.size.width > 0, proxy.size.height > 0 {
                    AIGlowOverlay(
                        active: active,
                        boost: boost,
                        cornerRadius: cornerRadius,
                        style: style,
                        targetSize: proxy.size
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
    }
}

extension View {
    /// Adds the Apple-Intelligence-style glow behind the current view.
    func aiGlow(
        active: Bool,
        cornerRadius: CGFloat,
        boost: Bool = false,
        style: AIGlowStyle = .appleIntelligenceDefault
    ) -> some View {
        modifier(
            AIGlowModifier(
                active: active,
                boost: boost,
                cornerRadius: cornerRadius,
                style: style
            )
        )
    }
}
