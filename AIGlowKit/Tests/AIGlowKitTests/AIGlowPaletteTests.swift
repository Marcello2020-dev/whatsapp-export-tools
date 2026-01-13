import XCTest
@testable import AIGlowKit

final class AIGlowPaletteTests: XCTestCase {
    func testNormalizationIsDeterministic() {
        let palette = AIGlowPalette(
            name: "Deterministic",
            light: .init(
                ringStops: [
                    AIGlowGradientStop(location: 1, color: AIGlowRGBA(red: 1, green: 0, blue: 0)),
                    AIGlowGradientStop(location: 0, color: AIGlowRGBA(red: 0, green: 1, blue: 0))
                ],
                auraStops: [
                    AIGlowGradientStop(location: 0.5, color: AIGlowRGBA(red: 0, green: 0, blue: 1))
                ]
            )
        )

        let normalized1 = palette.normalized()
        let normalized2 = palette.normalized()

        XCTAssertEqual(normalized1, normalized2)
    }

    func testNormalizationClampsValues() {
        let stops = [
            AIGlowGradientStop(
                location: -0.5,
                color: AIGlowRGBA(red: -1, green: 1.5, blue: 0.5, alpha: 2)
            ),
            AIGlowGradientStop(
                location: 2.0,
                color: AIGlowRGBA(red: 0.25, green: 0.25, blue: 0.25, alpha: -0.1)
            )
        ]
        let palette = AIGlowPalette(
            name: "Clamp",
            light: .init(ringStops: stops, auraStops: stops)
        )

        let normalized = palette.normalized()
        let ringStops = normalized.light.ringStops

        XCTAssertEqual(ringStops.count, 2)
        XCTAssertEqual(ringStops[0].location, 0)
        XCTAssertEqual(ringStops[1].location, 1)
        XCTAssertEqual(ringStops[0].color.red, 0)
        XCTAssertEqual(ringStops[0].color.green, 1)
        XCTAssertEqual(ringStops[0].color.alpha, 1)
        XCTAssertEqual(ringStops[1].color.alpha, 0)
    }

    func testNormalizationFallsBackOnInvalidStops() {
        let invalidStops = [
            AIGlowGradientStop(location: Double.nan, color: AIGlowRGBA(red: 1, green: 0, blue: 0))
        ]
        let palette = AIGlowPalette(
            name: "Invalid",
            light: .init(ringStops: invalidStops, auraStops: invalidStops)
        )

        let normalized = palette.normalized()

        XCTAssertEqual(normalized.light.ringStops, AIGlowPalette.default.light.ringStops)
        XCTAssertEqual(normalized.light.auraStops, AIGlowPalette.default.light.auraStops)
    }
}
