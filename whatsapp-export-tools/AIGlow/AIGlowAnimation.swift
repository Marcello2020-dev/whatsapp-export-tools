import SwiftUI

/// Animation helpers for AI glow rotation and boost timing.
struct AIGlowAnimation {
    static let boostInDuration: Double = 0.35
    static let boostOutDuration: Double = 0.35

    static func rotationDuration(style: AIGlowStyle, boost: Bool, reduceMotion: Bool) -> Double {
        if reduceMotion {
            return style.rotationDurationReducedMotion
        }
        return boost ? style.rotationDurationRunning : style.rotationDuration
    }

    static var boostInAnimation: Animation {
        .easeOut(duration: boostInDuration)
    }

    static var boostOutAnimation: Animation {
        .easeInOut(duration: boostOutDuration)
    }
}
