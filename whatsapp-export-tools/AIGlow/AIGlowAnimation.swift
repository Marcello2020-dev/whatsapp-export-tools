import SwiftUI
import Combine

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

/// Shared ticker for AI glow updates (caps refresh rate).
final class AIGlowTicker: ObservableObject {
    static let shared = AIGlowTicker()
    static let defaultFPS: Double = 30

    @Published private(set) var now: TimeInterval
    private var timer: Timer?

    private init() {
        now = ProcessInfo.processInfo.systemUptime
        start()
    }

    private func start() {
        let interval = 1.0 / max(Self.defaultFPS, 1)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.now = ProcessInfo.processInfo.systemUptime
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
