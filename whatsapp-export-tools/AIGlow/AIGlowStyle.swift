import SwiftUI

public struct AIGlowComponents: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let aura = AIGlowComponents(rawValue: 1 << 0)
    public static let ring = AIGlowComponents(rawValue: 1 << 1)
    public static let shimmer = AIGlowComponents(rawValue: 1 << 2)
    public static let all: AIGlowComponents = [.aura, .ring, .shimmer]
}

public enum AIGlowFillMode: String, Sendable {
    case outlineOnly
    case innerGlow
}

public enum AIGlowMotionMode: String, Sendable {
    case rotation
    case turbulence
}

public enum AIGlowAuraOuterContour: Equatable, Sendable {
    case matchTarget
    case roundedRect(cornerRadius: CGFloat, outset: CGFloat)
    case oval(scaleX: CGFloat, scaleY: CGFloat, outset: CGFloat)

    func normalized(fallback: AIGlowAuraOuterContour) -> AIGlowAuraOuterContour {
        switch self {
        case .matchTarget:
            return .matchTarget
        case .roundedRect(let cornerRadius, let outset):
            guard cornerRadius.isFinite, outset.isFinite else { return fallback }
            return .roundedRect(cornerRadius: max(cornerRadius, 0), outset: max(outset, 0))
        case .oval(let scaleX, let scaleY, let outset):
            guard scaleX.isFinite, scaleY.isFinite, outset.isFinite else { return fallback }
            return .oval(
                scaleX: max(scaleX, 0),
                scaleY: max(scaleY, 0),
                outset: max(outset, 0)
            )
        }
    }
}

/// Data-only styling options for AI Glow rendering.
public struct AIGlowStyle: Equatable, @unchecked Sendable {
    public let ringColors: [Color]
    public let auraColors: [Color]
    public var palette: AIGlowPalette?
    public let components: AIGlowComponents
    public let fillMode: AIGlowFillMode
    public var motionMode: AIGlowMotionMode
    public var turbulenceMotionScale: Double
    public let auraOuterContour: AIGlowAuraOuterContour
    public let ringLineWidthCore: CGFloat
    public let ringLineWidthSoft: CGFloat
    public let ringLineWidthBloom: CGFloat
    public let ringLineWidthShimmer: CGFloat
    public let ringBlurCoreDark: CGFloat
    public let ringBlurCoreLight: CGFloat
    public let ringBlurSoftDark: CGFloat
    public let ringBlurSoftLight: CGFloat
    public let ringBlurBloomDark: CGFloat
    public let ringBlurBloomLight: CGFloat
    public let ringBlurShimmerDark: CGFloat
    public let ringBlurShimmerLight: CGFloat
    public let ringOpacityCoreDark: Double
    public let ringOpacityCoreLight: Double
    public let ringOpacitySoftDark: Double
    public let ringOpacitySoftLight: Double
    public let ringOpacityBloomDark: Double
    public let ringOpacityBloomLight: Double
    public let ringOpacityShimmerDark: Double
    public let ringOpacityShimmerLight: Double
    public let ringShimmerAngleOffset: Double
    public let innerAuraBlurDark: CGFloat
    public let innerAuraBlurLight: CGFloat
    public let innerAuraOpacityDark: Double
    public let innerAuraOpacityLight: Double
    public let outerAuraLineWidth: CGFloat
    public let outerAuraBlurDark: CGFloat
    public let outerAuraBlurLight: CGFloat
    public let outerAuraOpacityDark: Double
    public let outerAuraOpacityLight: Double
    public let outerAuraSecondaryLineWidth: CGFloat
    public let outerAuraSecondaryBlurDark: CGFloat
    public let outerAuraSecondaryBlurLight: CGFloat
    public let outerAuraSecondaryOpacityDark: Double
    public let outerAuraSecondaryOpacityLight: Double
    public let outerAuraSecondaryOffset: CGSize
    public let outerAuraPadding: CGFloat
    public let outerAuraSecondaryPadding: CGFloat
    public let ringOuterPadding: CGFloat
    public let ringBloomPadding: CGFloat
    public let rotationDuration: Double
    public let rotationDurationRunning: Double
    public let rotationDurationReducedMotion: Double
    public var globalSpeedScale: Double
    public var speedScale: Double
    public var phaseOffset: Double
    public let ringBlendModeDark: BlendMode
    public let ringBlendModeLight: BlendMode
    public let auraBlendModeDark: BlendMode
    public let auraBlendModeLight: BlendMode
    public let saturationDark: Double
    public let saturationLight: Double
    public let contrastDark: Double
    public let contrastLight: Double
    public let runningRingBoostCore: Double
    public let runningRingBoostSoft: Double
    public let runningRingBoostBloom: Double
    public let runningRingBoostShimmer: Double
    public let runningInnerAuraBoostDark: Double
    public let runningInnerAuraBoostLight: Double
    public let runningOuterAuraBoostDark: Double
    public let runningOuterAuraBoostLight: Double
    public let runningOuterAuraSecondaryBoostDark: Double
    public let runningOuterAuraSecondaryBoostLight: Double
    public let runningInnerAuraBlurScale: CGFloat
    public let runningOuterAuraBlurScale: CGFloat
    public let outerPadding: CGFloat

    public init(
        ringColors: [Color],
        auraColors: [Color],
        palette: AIGlowPalette? = nil,
        components: AIGlowComponents,
        fillMode: AIGlowFillMode,
        motionMode: AIGlowMotionMode,
        turbulenceMotionScale: Double,
        auraOuterContour: AIGlowAuraOuterContour,
        ringLineWidthCore: CGFloat,
        ringLineWidthSoft: CGFloat,
        ringLineWidthBloom: CGFloat,
        ringLineWidthShimmer: CGFloat,
        ringBlurCoreDark: CGFloat,
        ringBlurCoreLight: CGFloat,
        ringBlurSoftDark: CGFloat,
        ringBlurSoftLight: CGFloat,
        ringBlurBloomDark: CGFloat,
        ringBlurBloomLight: CGFloat,
        ringBlurShimmerDark: CGFloat,
        ringBlurShimmerLight: CGFloat,
        ringOpacityCoreDark: Double,
        ringOpacityCoreLight: Double,
        ringOpacitySoftDark: Double,
        ringOpacitySoftLight: Double,
        ringOpacityBloomDark: Double,
        ringOpacityBloomLight: Double,
        ringOpacityShimmerDark: Double,
        ringOpacityShimmerLight: Double,
        ringShimmerAngleOffset: Double,
        innerAuraBlurDark: CGFloat,
        innerAuraBlurLight: CGFloat,
        innerAuraOpacityDark: Double,
        innerAuraOpacityLight: Double,
        outerAuraLineWidth: CGFloat,
        outerAuraBlurDark: CGFloat,
        outerAuraBlurLight: CGFloat,
        outerAuraOpacityDark: Double,
        outerAuraOpacityLight: Double,
        outerAuraSecondaryLineWidth: CGFloat,
        outerAuraSecondaryBlurDark: CGFloat,
        outerAuraSecondaryBlurLight: CGFloat,
        outerAuraSecondaryOpacityDark: Double,
        outerAuraSecondaryOpacityLight: Double,
        outerAuraSecondaryOffset: CGSize,
        outerAuraPadding: CGFloat,
        outerAuraSecondaryPadding: CGFloat,
        ringOuterPadding: CGFloat,
        ringBloomPadding: CGFloat,
        rotationDuration: Double,
        rotationDurationRunning: Double,
        rotationDurationReducedMotion: Double,
        globalSpeedScale: Double,
        speedScale: Double,
        phaseOffset: Double,
        ringBlendModeDark: BlendMode,
        ringBlendModeLight: BlendMode,
        auraBlendModeDark: BlendMode,
        auraBlendModeLight: BlendMode,
        saturationDark: Double,
        saturationLight: Double,
        contrastDark: Double,
        contrastLight: Double,
        runningRingBoostCore: Double,
        runningRingBoostSoft: Double,
        runningRingBoostBloom: Double,
        runningRingBoostShimmer: Double,
        runningInnerAuraBoostDark: Double,
        runningInnerAuraBoostLight: Double,
        runningOuterAuraBoostDark: Double,
        runningOuterAuraBoostLight: Double,
        runningOuterAuraSecondaryBoostDark: Double,
        runningOuterAuraSecondaryBoostLight: Double,
        runningInnerAuraBlurScale: CGFloat,
        runningOuterAuraBlurScale: CGFloat,
        outerPadding: CGFloat
    ) {
        self.ringColors = ringColors
        self.auraColors = auraColors
        self.palette = palette
        self.components = components
        self.fillMode = fillMode
        self.motionMode = motionMode
        self.turbulenceMotionScale = turbulenceMotionScale
        self.auraOuterContour = auraOuterContour
        self.ringLineWidthCore = ringLineWidthCore
        self.ringLineWidthSoft = ringLineWidthSoft
        self.ringLineWidthBloom = ringLineWidthBloom
        self.ringLineWidthShimmer = ringLineWidthShimmer
        self.ringBlurCoreDark = ringBlurCoreDark
        self.ringBlurCoreLight = ringBlurCoreLight
        self.ringBlurSoftDark = ringBlurSoftDark
        self.ringBlurSoftLight = ringBlurSoftLight
        self.ringBlurBloomDark = ringBlurBloomDark
        self.ringBlurBloomLight = ringBlurBloomLight
        self.ringBlurShimmerDark = ringBlurShimmerDark
        self.ringBlurShimmerLight = ringBlurShimmerLight
        self.ringOpacityCoreDark = ringOpacityCoreDark
        self.ringOpacityCoreLight = ringOpacityCoreLight
        self.ringOpacitySoftDark = ringOpacitySoftDark
        self.ringOpacitySoftLight = ringOpacitySoftLight
        self.ringOpacityBloomDark = ringOpacityBloomDark
        self.ringOpacityBloomLight = ringOpacityBloomLight
        self.ringOpacityShimmerDark = ringOpacityShimmerDark
        self.ringOpacityShimmerLight = ringOpacityShimmerLight
        self.ringShimmerAngleOffset = ringShimmerAngleOffset
        self.innerAuraBlurDark = innerAuraBlurDark
        self.innerAuraBlurLight = innerAuraBlurLight
        self.innerAuraOpacityDark = innerAuraOpacityDark
        self.innerAuraOpacityLight = innerAuraOpacityLight
        self.outerAuraLineWidth = outerAuraLineWidth
        self.outerAuraBlurDark = outerAuraBlurDark
        self.outerAuraBlurLight = outerAuraBlurLight
        self.outerAuraOpacityDark = outerAuraOpacityDark
        self.outerAuraOpacityLight = outerAuraOpacityLight
        self.outerAuraSecondaryLineWidth = outerAuraSecondaryLineWidth
        self.outerAuraSecondaryBlurDark = outerAuraSecondaryBlurDark
        self.outerAuraSecondaryBlurLight = outerAuraSecondaryBlurLight
        self.outerAuraSecondaryOpacityDark = outerAuraSecondaryOpacityDark
        self.outerAuraSecondaryOpacityLight = outerAuraSecondaryOpacityLight
        self.outerAuraSecondaryOffset = outerAuraSecondaryOffset
        self.outerAuraPadding = outerAuraPadding
        self.outerAuraSecondaryPadding = outerAuraSecondaryPadding
        self.ringOuterPadding = ringOuterPadding
        self.ringBloomPadding = ringBloomPadding
        self.rotationDuration = rotationDuration
        self.rotationDurationRunning = rotationDurationRunning
        self.rotationDurationReducedMotion = rotationDurationReducedMotion
        self.globalSpeedScale = globalSpeedScale
        self.speedScale = speedScale
        self.phaseOffset = phaseOffset
        self.ringBlendModeDark = ringBlendModeDark
        self.ringBlendModeLight = ringBlendModeLight
        self.auraBlendModeDark = auraBlendModeDark
        self.auraBlendModeLight = auraBlendModeLight
        self.saturationDark = saturationDark
        self.saturationLight = saturationLight
        self.contrastDark = contrastDark
        self.contrastLight = contrastLight
        self.runningRingBoostCore = runningRingBoostCore
        self.runningRingBoostSoft = runningRingBoostSoft
        self.runningRingBoostBloom = runningRingBoostBloom
        self.runningRingBoostShimmer = runningRingBoostShimmer
        self.runningInnerAuraBoostDark = runningInnerAuraBoostDark
        self.runningInnerAuraBoostLight = runningInnerAuraBoostLight
        self.runningOuterAuraBoostDark = runningOuterAuraBoostDark
        self.runningOuterAuraBoostLight = runningOuterAuraBoostLight
        self.runningOuterAuraSecondaryBoostDark = runningOuterAuraSecondaryBoostDark
        self.runningOuterAuraSecondaryBoostLight = runningOuterAuraSecondaryBoostLight
        self.runningInnerAuraBlurScale = runningInnerAuraBlurScale
        self.runningOuterAuraBlurScale = runningOuterAuraBlurScale
        self.outerPadding = outerPadding
    }

    public static let appleIntelligenceDefault = AIGlowStyle(
        ringColors: AIGlowPalette.ringColors,
        auraColors: AIGlowPalette.auraColors,
        palette: nil,
        components: .all,
        fillMode: .innerGlow,
        motionMode: .rotation,
        turbulenceMotionScale: 1.0,
        auraOuterContour: .matchTarget,
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
        globalSpeedScale: 1.0,
        speedScale: 1.0,
        phaseOffset: 0,
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

    public static let `default` = appleIntelligenceDefault
    public static let whatsAppGreen = AIGlowStyle.default.withPalette(.whatsAppGreen)
    public static let wetDefault = whatsAppGreen

    public func normalized() -> AIGlowStyle {
        let baseline = AIGlowStyle.default
        return AIGlowStyle(
            ringColors: ringColors,
            auraColors: auraColors,
            palette: palette?.normalized(),
            components: components.intersection(.all),
            fillMode: fillMode,
            motionMode: motionMode,
            turbulenceMotionScale: Self.positiveFinite(turbulenceMotionScale, fallback: baseline.turbulenceMotionScale),
            auraOuterContour: auraOuterContour.normalized(fallback: baseline.auraOuterContour),
            ringLineWidthCore: Self.nonNegativeFinite(ringLineWidthCore, fallback: baseline.ringLineWidthCore),
            ringLineWidthSoft: Self.nonNegativeFinite(ringLineWidthSoft, fallback: baseline.ringLineWidthSoft),
            ringLineWidthBloom: Self.nonNegativeFinite(ringLineWidthBloom, fallback: baseline.ringLineWidthBloom),
            ringLineWidthShimmer: Self.nonNegativeFinite(ringLineWidthShimmer, fallback: baseline.ringLineWidthShimmer),
            ringBlurCoreDark: Self.nonNegativeFinite(ringBlurCoreDark, fallback: baseline.ringBlurCoreDark),
            ringBlurCoreLight: Self.nonNegativeFinite(ringBlurCoreLight, fallback: baseline.ringBlurCoreLight),
            ringBlurSoftDark: Self.nonNegativeFinite(ringBlurSoftDark, fallback: baseline.ringBlurSoftDark),
            ringBlurSoftLight: Self.nonNegativeFinite(ringBlurSoftLight, fallback: baseline.ringBlurSoftLight),
            ringBlurBloomDark: Self.nonNegativeFinite(ringBlurBloomDark, fallback: baseline.ringBlurBloomDark),
            ringBlurBloomLight: Self.nonNegativeFinite(ringBlurBloomLight, fallback: baseline.ringBlurBloomLight),
            ringBlurShimmerDark: Self.nonNegativeFinite(ringBlurShimmerDark, fallback: baseline.ringBlurShimmerDark),
            ringBlurShimmerLight: Self.nonNegativeFinite(ringBlurShimmerLight, fallback: baseline.ringBlurShimmerLight),
            ringOpacityCoreDark: Self.unitInterval(ringOpacityCoreDark),
            ringOpacityCoreLight: Self.unitInterval(ringOpacityCoreLight),
            ringOpacitySoftDark: Self.unitInterval(ringOpacitySoftDark),
            ringOpacitySoftLight: Self.unitInterval(ringOpacitySoftLight),
            ringOpacityBloomDark: Self.unitInterval(ringOpacityBloomDark),
            ringOpacityBloomLight: Self.unitInterval(ringOpacityBloomLight),
            ringOpacityShimmerDark: Self.unitInterval(ringOpacityShimmerDark),
            ringOpacityShimmerLight: Self.unitInterval(ringOpacityShimmerLight),
            ringShimmerAngleOffset: ringShimmerAngleOffset,
            innerAuraBlurDark: Self.nonNegativeFinite(innerAuraBlurDark, fallback: baseline.innerAuraBlurDark),
            innerAuraBlurLight: Self.nonNegativeFinite(innerAuraBlurLight, fallback: baseline.innerAuraBlurLight),
            innerAuraOpacityDark: Self.unitInterval(innerAuraOpacityDark),
            innerAuraOpacityLight: Self.unitInterval(innerAuraOpacityLight),
            outerAuraLineWidth: Self.nonNegativeFinite(outerAuraLineWidth, fallback: baseline.outerAuraLineWidth),
            outerAuraBlurDark: Self.nonNegativeFinite(outerAuraBlurDark, fallback: baseline.outerAuraBlurDark),
            outerAuraBlurLight: Self.nonNegativeFinite(outerAuraBlurLight, fallback: baseline.outerAuraBlurLight),
            outerAuraOpacityDark: Self.unitInterval(outerAuraOpacityDark),
            outerAuraOpacityLight: Self.unitInterval(outerAuraOpacityLight),
            outerAuraSecondaryLineWidth: Self.nonNegativeFinite(outerAuraSecondaryLineWidth, fallback: baseline.outerAuraSecondaryLineWidth),
            outerAuraSecondaryBlurDark: Self.nonNegativeFinite(outerAuraSecondaryBlurDark, fallback: baseline.outerAuraSecondaryBlurDark),
            outerAuraSecondaryBlurLight: Self.nonNegativeFinite(outerAuraSecondaryBlurLight, fallback: baseline.outerAuraSecondaryBlurLight),
            outerAuraSecondaryOpacityDark: Self.unitInterval(outerAuraSecondaryOpacityDark),
            outerAuraSecondaryOpacityLight: Self.unitInterval(outerAuraSecondaryOpacityLight),
            outerAuraSecondaryOffset: outerAuraSecondaryOffset,
            outerAuraPadding: Self.nonNegativeFinite(outerAuraPadding, fallback: baseline.outerAuraPadding),
            outerAuraSecondaryPadding: Self.nonNegativeFinite(outerAuraSecondaryPadding, fallback: baseline.outerAuraSecondaryPadding),
            ringOuterPadding: Self.nonNegativeFinite(ringOuterPadding, fallback: baseline.ringOuterPadding),
            ringBloomPadding: Self.nonNegativeFinite(ringBloomPadding, fallback: baseline.ringBloomPadding),
            rotationDuration: Self.positiveFinite(rotationDuration, fallback: baseline.rotationDuration),
            rotationDurationRunning: Self.positiveFinite(rotationDurationRunning, fallback: baseline.rotationDurationRunning),
            rotationDurationReducedMotion: Self.positiveFinite(rotationDurationReducedMotion, fallback: baseline.rotationDurationReducedMotion),
            globalSpeedScale: Self.positiveFinite(globalSpeedScale, fallback: baseline.globalSpeedScale),
            speedScale: Self.positiveFinite(speedScale, fallback: baseline.speedScale),
            phaseOffset: Self.normalizedPhaseOffset(phaseOffset, fallback: baseline.phaseOffset),
            ringBlendModeDark: ringBlendModeDark,
            ringBlendModeLight: ringBlendModeLight,
            auraBlendModeDark: auraBlendModeDark,
            auraBlendModeLight: auraBlendModeLight,
            saturationDark: Self.nonNegativeFinite(saturationDark, fallback: baseline.saturationDark),
            saturationLight: Self.nonNegativeFinite(saturationLight, fallback: baseline.saturationLight),
            contrastDark: Self.nonNegativeFinite(contrastDark, fallback: baseline.contrastDark),
            contrastLight: Self.nonNegativeFinite(contrastLight, fallback: baseline.contrastLight),
            runningRingBoostCore: Self.unitInterval(runningRingBoostCore),
            runningRingBoostSoft: Self.unitInterval(runningRingBoostSoft),
            runningRingBoostBloom: Self.unitInterval(runningRingBoostBloom),
            runningRingBoostShimmer: Self.unitInterval(runningRingBoostShimmer),
            runningInnerAuraBoostDark: Self.unitInterval(runningInnerAuraBoostDark),
            runningInnerAuraBoostLight: Self.unitInterval(runningInnerAuraBoostLight),
            runningOuterAuraBoostDark: Self.unitInterval(runningOuterAuraBoostDark),
            runningOuterAuraBoostLight: Self.unitInterval(runningOuterAuraBoostLight),
            runningOuterAuraSecondaryBoostDark: Self.unitInterval(runningOuterAuraSecondaryBoostDark),
            runningOuterAuraSecondaryBoostLight: Self.unitInterval(runningOuterAuraSecondaryBoostLight),
            runningInnerAuraBlurScale: Self.unitInterval(runningInnerAuraBlurScale),
            runningOuterAuraBlurScale: Self.unitInterval(runningOuterAuraBlurScale),
            outerPadding: Self.nonNegativeFinite(outerPadding, fallback: baseline.outerPadding)
        )
    }

    public func ringGradientStops(for colorScheme: ColorScheme) -> [Gradient.Stop] {
        if let palette {
            return palette.normalized().ringGradientStops(for: colorScheme)
        }
        return Self.evenStops(colors: ringColors)
    }

    public func auraGradientStops(for colorScheme: ColorScheme) -> [Gradient.Stop] {
        if let palette {
            return palette.normalized().auraGradientStops(for: colorScheme)
        }
        return Self.evenStops(colors: auraColors)
    }

    public func withPalette(_ palette: AIGlowPalette?) -> AIGlowStyle {
        var copy = self
        copy.palette = palette
        return copy
    }

    public func withSpeedScale(_ scale: Double) -> AIGlowStyle {
        var copy = self
        copy.speedScale = scale
        return copy
    }

    public func withGlobalSpeedScale(_ scale: Double) -> AIGlowStyle {
        var copy = self
        copy.globalSpeedScale = scale
        return copy
    }

    public func withPhaseOffset(_ offset: Double) -> AIGlowStyle {
        var copy = self
        copy.phaseOffset = offset
        return copy
    }

    public func withMotionMode(_ mode: AIGlowMotionMode) -> AIGlowStyle {
        var copy = self
        copy.motionMode = mode
        return copy
    }

    public func withTurbulenceMotionScale(_ scale: Double) -> AIGlowStyle {
        var copy = self
        copy.turbulenceMotionScale = scale
        return copy
    }

    private static func unitInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }

    private static func unitInterval(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }

    private static func nonNegativeFinite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return value < 0 ? 0 : value
    }

    private static func nonNegativeFinite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return value < 0 ? 0 : value
    }

    private static func positiveFinite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return value <= 0 ? max(fallback, 0.001) : value
    }

    private static func normalizedPhaseOffset(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private static func evenStops(colors: [Color]) -> [Gradient.Stop] {
        guard !colors.isEmpty else { return [] }
        let count = max(colors.count - 1, 1)
        return colors.enumerated().map { index, color in
            let location = Double(index) / Double(count)
            return Gradient.Stop(color: color, location: location)
        }
    }
}
