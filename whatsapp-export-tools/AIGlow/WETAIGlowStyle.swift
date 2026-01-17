import SwiftUI

enum WETAIGlowStyle {
    public static func defaultStyle() -> AIGlowStyle {
        AIGlowStyle.wetDefault
    }

    public static func logStyle() -> AIGlowStyle {
        Self.defaultStyle()
            .withMotionMode(.turbulence)
            .withTurbulenceMotionScale(0.35)
    }
}
