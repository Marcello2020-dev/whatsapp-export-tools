import SwiftUI

enum WETAIGlowStyle {
    private static let turbulenceSpeedScale: Double = 0.5

    public static func defaultStyle() -> AIGlowStyle {
        AIGlowStyle.wetDefault
    }

    public static func logStyle() -> AIGlowStyle {
        Self.defaultStyle()
            .withMotionMode(.turbulence)
            .withTurbulenceMotionScale(0.35)
            .withSpeedScale(turbulenceSpeedScale)
    }
}
