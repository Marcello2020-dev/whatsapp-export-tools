import SwiftUI

enum WETAIGlowStyle {
    static func defaultStyle() -> AIGlowStyle {
        AIGlowStyle.wetDefault
    }

    static func logStyle(speedScale: Double) -> AIGlowStyle {
        AIGlowStyle.wetDefault.withSpeedScale(speedScale)
    }
}
