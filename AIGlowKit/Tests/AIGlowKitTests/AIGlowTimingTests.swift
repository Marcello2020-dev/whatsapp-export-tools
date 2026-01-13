import XCTest
@testable import AIGlowKit

final class AIGlowTimingTests: XCTestCase {
    func testPhaseOffsetIsStartShiftOnly() {
        let period = 10.0
        let offset = 0.25

        let atStart = AIGlowAnimation.normalizedPhase(elapsed: 0, period: period, phaseOffset: offset)
        let atHalf = AIGlowAnimation.normalizedPhase(elapsed: period * 0.5, period: period, phaseOffset: offset)
        let atPeriod = AIGlowAnimation.normalizedPhase(elapsed: period, period: period, phaseOffset: offset)

        XCTAssertEqual(atStart, offset, accuracy: 1e-9)
        XCTAssertEqual(atHalf, 0.75, accuracy: 1e-9)
        XCTAssertEqual(atPeriod, offset, accuracy: 1e-9)
    }

    func testSpeedScalarsAffectPeriod() {
        var style = AIGlowStyle.default
        let base = AIGlowAnimation.rotationDuration(style: style, isRunning: false, reduceMotion: false)

        style.globalSpeedScale = 2.0
        style.speedScale = 1.0
        let fasterPeriod = AIGlowAnimation.rotationPeriod(style: style, isRunning: false, reduceMotion: false)
        XCTAssertEqual(fasterPeriod, base / 2.0, accuracy: 1e-9)

        style.globalSpeedScale = 1.0
        style.speedScale = 0.5
        let slowerPeriod = AIGlowAnimation.rotationPeriod(style: style, isRunning: false, reduceMotion: false)
        XCTAssertEqual(slowerPeriod, base / 0.5, accuracy: 1e-9)
    }

    func testReduceMotionSlowsRotation() {
        let style = AIGlowStyle.default
        let normal = AIGlowAnimation.rotationPeriod(style: style, isRunning: false, reduceMotion: false)
        let reduced = AIGlowAnimation.rotationPeriod(style: style, isRunning: false, reduceMotion: true)
        XCTAssertGreaterThan(reduced, normal)
    }

    func testReduceMotionIgnoresSpeedScalars() {
        var style = AIGlowStyle.default
        style.globalSpeedScale = 3.0
        style.speedScale = 2.0

        let reduced = AIGlowAnimation.rotationPeriod(style: style, isRunning: false, reduceMotion: true)
        let expected = max(style.rotationDurationReducedMotion, style.rotationDuration * 2)
        XCTAssertEqual(reduced, expected, accuracy: 1e-9)
    }
}
