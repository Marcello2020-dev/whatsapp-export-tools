import SwiftUI
import Combine

/// Animation helpers for AI glow rotation and boost timing.
struct AIGlowAnimation {
    static let boostInDuration: Double = 0.35
    static let boostOutDuration: Double = 0.35

    static func rotationDuration(style: AIGlowStyle, isRunning: Bool, reduceMotion: Bool) -> Double {
        if reduceMotion {
            return style.rotationDurationReducedMotion
        }
        return isRunning ? style.rotationDurationRunning : style.rotationDuration
    }

    static func rotationPeriod(style: AIGlowStyle, isRunning: Bool, reduceMotion: Bool) -> Double {
        let base = rotationDuration(style: style, isRunning: isRunning, reduceMotion: reduceMotion)
        if reduceMotion {
            let normal = rotationDuration(style: style, isRunning: isRunning, reduceMotion: false)
            return max(base, normal * 2)
        }
        let globalScale = max(style.globalSpeedScale, 0.05)
        let instanceScale = max(style.speedScale, 0.05)
        return base / (globalScale * instanceScale)
    }

    static func normalizedPhase(elapsed: TimeInterval, period: Double, phaseOffset: Double) -> Double {
        guard period > 0 else { return 0 }
        let cycles = elapsed / period
        let phase = cycles + phaseOffset
        let remainder = phase - floor(phase)
        return remainder < 0 ? remainder + 1 : remainder
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
    private var subscriberCount: Int = 0
    private lazy var sharedPublisher: AnyPublisher<TimeInterval, Never> = {
        $now
            .handleEvents(
                receiveSubscription: { [weak self] _ in
                    self?.incrementSubscribers()
                },
                receiveCancel: { [weak self] in
                    self?.decrementSubscribers()
                }
            )
            .eraseToAnyPublisher()
    }()

    private init() {
        now = ProcessInfo.processInfo.systemUptime
    }

    var publisher: AnyPublisher<TimeInterval, Never> {
        sharedPublisher
    }

    private func incrementSubscribers() {
        subscriberCount += 1
        if subscriberCount == 1 {
            start()
        }
    }

    private func decrementSubscribers() {
        subscriberCount = max(subscriberCount - 1, 0)
        if subscriberCount == 0 {
            stop()
        }
    }

    private func start() {
        guard timer == nil else { return }
        now = ProcessInfo.processInfo.systemUptime
        let interval = 1.0 / max(Self.defaultFPS, 1)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.now = ProcessInfo.processInfo.systemUptime
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
