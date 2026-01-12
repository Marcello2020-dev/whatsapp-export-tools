import SwiftUI

/// Tunable parameters for the Apple-Intelligence-style AI glow.
struct AIGlowStyle {
    let ringColors: [Color]
    let auraColors: [Color]
    let ringLineWidthCore: CGFloat
    let ringLineWidthSoft: CGFloat
    let ringLineWidthBloom: CGFloat
    let ringLineWidthShimmer: CGFloat
    let ringBlurCoreDark: CGFloat
    let ringBlurCoreLight: CGFloat
    let ringBlurSoftDark: CGFloat
    let ringBlurSoftLight: CGFloat
    let ringBlurBloomDark: CGFloat
    let ringBlurBloomLight: CGFloat
    let ringBlurShimmerDark: CGFloat
    let ringBlurShimmerLight: CGFloat
    let ringOpacityCoreDark: Double
    let ringOpacityCoreLight: Double
    let ringOpacitySoftDark: Double
    let ringOpacitySoftLight: Double
    let ringOpacityBloomDark: Double
    let ringOpacityBloomLight: Double
    let ringOpacityShimmerDark: Double
    let ringOpacityShimmerLight: Double
    let ringShimmerAngleOffset: Double
    let innerAuraBlurDark: CGFloat
    let innerAuraBlurLight: CGFloat
    let innerAuraOpacityDark: Double
    let innerAuraOpacityLight: Double
    let outerAuraLineWidth: CGFloat
    let outerAuraBlurDark: CGFloat
    let outerAuraBlurLight: CGFloat
    let outerAuraOpacityDark: Double
    let outerAuraOpacityLight: Double
    let outerAuraSecondaryLineWidth: CGFloat
    let outerAuraSecondaryBlurDark: CGFloat
    let outerAuraSecondaryBlurLight: CGFloat
    let outerAuraSecondaryOpacityDark: Double
    let outerAuraSecondaryOpacityLight: Double
    let outerAuraSecondaryOffset: CGSize
    let outerAuraPadding: CGFloat
    let outerAuraSecondaryPadding: CGFloat
    let ringOuterPadding: CGFloat
    let ringBloomPadding: CGFloat
    let rotationDuration: Double
    let rotationDurationRunning: Double
    let rotationDurationReducedMotion: Double
    var speedScale: Double
    let ringBlendModeDark: BlendMode
    let ringBlendModeLight: BlendMode
    let auraBlendModeDark: BlendMode
    let auraBlendModeLight: BlendMode
    let saturationDark: Double
    let saturationLight: Double
    let contrastDark: Double
    let contrastLight: Double
    let runningRingBoostCore: Double
    let runningRingBoostSoft: Double
    let runningRingBoostBloom: Double
    let runningRingBoostShimmer: Double
    let runningInnerAuraBoostDark: Double
    let runningInnerAuraBoostLight: Double
    let runningOuterAuraBoostDark: Double
    let runningOuterAuraBoostLight: Double
    let runningOuterAuraSecondaryBoostDark: Double
    let runningOuterAuraSecondaryBoostLight: Double
    let runningInnerAuraBlurScale: CGFloat
    let runningOuterAuraBlurScale: CGFloat
    let outerPadding: CGFloat

    static let appleIntelligenceDefault = AIGlowStyle(
        ringColors: AIGlowPalette.ringColors,
        auraColors: AIGlowPalette.auraColors,
        ringLineWidthCore: 3.4,
        ringLineWidthSoft: 5.4,
        ringLineWidthBloom: 11.0,
        ringLineWidthShimmer: 1.6,
        ringBlurCoreDark: 1.8,
        ringBlurCoreLight: 1.6,
        ringBlurSoftDark: 9,
        ringBlurSoftLight: 7,
        ringBlurBloomDark: 44,
        ringBlurBloomLight: 36,
        ringBlurShimmerDark: 4.5,
        ringBlurShimmerLight: 3.5,
        ringOpacityCoreDark: 0.98,
        ringOpacityCoreLight: 0.90,
        ringOpacitySoftDark: 0.88,
        ringOpacitySoftLight: 0.74,
        ringOpacityBloomDark: 0.72,
        ringOpacityBloomLight: 0.58,
        ringOpacityShimmerDark: 0.50,
        ringOpacityShimmerLight: 0.42,
        ringShimmerAngleOffset: 24,
        innerAuraBlurDark: 40,
        innerAuraBlurLight: 30,
        innerAuraOpacityDark: 0.72,
        innerAuraOpacityLight: 0.54,
        outerAuraLineWidth: 24,
        outerAuraBlurDark: 100,
        outerAuraBlurLight: 78,
        outerAuraOpacityDark: 0.48,
        outerAuraOpacityLight: 0.34,
        outerAuraSecondaryLineWidth: 46,
        outerAuraSecondaryBlurDark: 160,
        outerAuraSecondaryBlurLight: 130,
        outerAuraSecondaryOpacityDark: 0.22,
        outerAuraSecondaryOpacityLight: 0.16,
        outerAuraSecondaryOffset: CGSize(width: 12, height: -10),
        outerAuraPadding: 0,
        outerAuraSecondaryPadding: 0,
        ringOuterPadding: 0,
        ringBloomPadding: 0,
        rotationDuration: 11.5,
        rotationDurationRunning: 7,
        rotationDurationReducedMotion: 60,
        speedScale: 1.0,
        ringBlendModeDark: .plusLighter,
        ringBlendModeLight: .overlay,
        auraBlendModeDark: .plusLighter,
        auraBlendModeLight: .overlay,
        saturationDark: 1.30,
        saturationLight: 1.85,
        contrastDark: 1.05,
        contrastLight: 1.12,
        runningRingBoostCore: 0.12,
        runningRingBoostSoft: 0.14,
        runningRingBoostBloom: 0.20,
        runningRingBoostShimmer: 0.12,
        runningInnerAuraBoostDark: 0.20,
        runningInnerAuraBoostLight: 0.15,
        runningOuterAuraBoostDark: 0.20,
        runningOuterAuraBoostLight: 0.15,
        runningOuterAuraSecondaryBoostDark: 0.12,
        runningOuterAuraSecondaryBoostLight: 0.10,
        runningInnerAuraBlurScale: 0.92,
        runningOuterAuraBlurScale: 0.90,
        outerPadding: 200
    )

    static let `default` = appleIntelligenceDefault

    func withSpeedScale(_ scale: Double) -> AIGlowStyle {
        var copy = self
        copy.speedScale = scale
        return copy
    }
}
