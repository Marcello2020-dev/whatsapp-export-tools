import SwiftUI

/// Apply the Apple-Intelligence-style AI glow to any view.
struct AIGlowModifier: ViewModifier {
    let active: Bool
    let isRunning: Bool
    let cornerRadius: CGFloat
    let style: AIGlowStyle
    let debugTag: String?

    func body(content: Content) -> some View {
        let resolvedStyle = style.normalized()
        content.background {
            GeometryReader { proxy in
                if proxy.size.width > 0, proxy.size.height > 0 {
                    AIGlowOverlay(
                        active: active,
                        isRunning: isRunning,
                        cornerRadius: cornerRadius,
                        style: resolvedStyle,
                        targetSize: proxy.size,
                        debugTag: debugTag
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
    }
}

public extension View {
    /// Adds the Apple-Intelligence-style glow behind the current view.
    func aiGlow(
        active: Bool,
        isRunning: Bool,
        cornerRadius: CGFloat,
        style: AIGlowStyle = .default,
        debugTag: String? = nil
    ) -> some View {
        modifier(
            AIGlowModifier(
                active: active,
                isRunning: isRunning,
                cornerRadius: cornerRadius,
                style: style,
                debugTag: debugTag
            )
        )
    }
}
