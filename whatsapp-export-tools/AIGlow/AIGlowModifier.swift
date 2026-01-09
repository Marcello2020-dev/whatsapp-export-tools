import SwiftUI

/// Apply the Apple-Intelligence-style AI glow to any view.
struct AIGlowModifier: ViewModifier {
    let active: Bool
    let boost: Bool
    let cornerRadius: CGFloat
    let speedScale: Double
    let style: AIGlowStyle
    let debugTag: String?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                if proxy.size.width > 0, proxy.size.height > 0 {
                    AIGlowOverlay(
                        active: active,
                        boost: boost,
                        cornerRadius: cornerRadius,
                        speedScale: speedScale,
                        style: style,
                        targetSize: proxy.size,
                        debugTag: debugTag
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
        speedScale: Double = 1.0,
        style: AIGlowStyle = .appleIntelligenceDefault,
        debugTag: String? = nil
    ) -> some View {
        modifier(
            AIGlowModifier(
                active: active,
                boost: boost,
                cornerRadius: cornerRadius,
                speedScale: speedScale,
                style: style,
                debugTag: debugTag
            )
        )
    }
}
