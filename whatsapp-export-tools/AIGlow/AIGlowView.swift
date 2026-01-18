import SwiftUI
import Combine

/// Core rendering view for the Apple-Intelligence-style AI glow.
struct AIGlowOverlay: View {
    let active: Bool
    let isRunning: Bool
    let cornerRadius: CGFloat
    let style: AIGlowStyle
    let targetSize: CGSize
    let debugTag: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.aiGlowReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.aiGlowIncreasedContrastOverride) private var increasedContrastOverride
    @Environment(\.aiGlowReduceTransparencyOverride) private var reduceTransparencyOverride
    @State private var tickerNow: TimeInterval = ProcessInfo.processInfo.systemUptime
    @State private var isVisible: Bool = false
    @State private var phaseStartTime: TimeInterval = 0
    @State private var boostProgress: Double = 0
    @State private var lastDebugPrintTime: TimeInterval = 0

    var body: some View {
        let base = glowBody
            .onReceive(tickerPublisher) { now in
                tickerNow = now
            }
            .onAppear {
                isVisible = true
                resetPhaseStart(active: active)
                updateBoost()
            }
            .onDisappear {
                isVisible = false
            }
            .onChangeCompat(of: reduceMotion) {
                guard isVisible else { return }
                resetPhaseStart(active: active)
            }
            .onChangeCompat(of: active) {
                guard isVisible else { return }
                resetPhaseStart(active: active)
                updateBoost()
            }
            .onChangeCompat(of: isRunning) {
                guard isVisible else { return }
                resetPhaseStart(active: active)
                updateBoost()
            }

#if DEBUG
        return base
            .onChangeCompat(of: tickerNow) {
                guard active, let debugTag else { return }
                guard ProcessInfo.processInfo.environment["WET_AIGLOW_DEBUG"] == "1" else { return }
                let now = tickerNow
                if now - lastDebugPrintTime >= 1.0 {
                    lastDebugPrintTime = now
                    let phase = String(format: "%.1f", currentPhase * 360)
                    print("[AIGlowPhase:\(debugTag)] \(phase)°")
                }
            }
#else
        return base
#endif
    }

    private var glowBody: some View {
        let isLight = colorScheme == .light
        var saturation = isLight ? style.saturationLight : style.saturationDark
        var contrast = isLight ? style.contrastLight : style.contrastDark
        let shouldReduceMotion = reduceMotionOverride ?? reduceMotion
        let isHighContrast = increasedContrastOverride ?? (colorSchemeContrast == .increased)
        let shouldReduceTransparency = reduceTransparencyOverride ?? accessibilityReduceTransparency
        let baseMotionScale = shouldReduceMotion ? 0.35 : 1
        let baseSize = targetSize
        let phase = currentPhase
        let phaseDegrees = phase * 360
        let components = style.components
        let showAura = components.contains(.aura)
        let showRing = components.contains(.ring)
        let showShimmer = components.contains(.shimmer)
        let showInnerAura = showAura && style.fillMode == .innerGlow
        let useTurbulence = style.motionMode == .turbulence
        let motionScale = baseMotionScale * (useTurbulence ? style.turbulenceMotionScale : 1)
        let ringStops = style.ringGradientStops(for: colorScheme)
        let auraStops = style.auraGradientStops(for: colorScheme)
        let ringGradient = AngularGradient(
            gradient: Gradient(stops: ringStops),
            center: .center,
            angle: .degrees(phaseDegrees)
        )
        let auraGradient = AngularGradient(
            gradient: Gradient(stops: auraStops),
            center: .center,
            angle: .degrees(phaseDegrees)
        )
        let turbulenceAuraLayers = useTurbulence
            ? buildTurbulenceLayers(phase: phase, angleOffset: 0, motionScale: motionScale, minDimensionReference: 160)
            : []
        let turbulenceRingLayers = useTurbulence
            ? buildTurbulenceLayers(phase: phase, angleOffset: 0, motionScale: motionScale, minDimensionReference: 44)
            : []
        let turbulenceShimmerLayers = useTurbulence
            ? buildTurbulenceLayers(phase: phase, angleOffset: style.ringShimmerAngleOffset, motionScale: motionScale, minDimensionReference: 44)
            : []
        let ringBlend = isLight ? style.ringBlendModeLight : style.ringBlendModeDark
        let auraBlend = isLight ? style.auraBlendModeLight : style.auraBlendModeDark
        let innerAuraOpacityBase = isLight ? style.innerAuraOpacityLight : style.innerAuraOpacityDark
        let innerAuraBoost = isLight ? style.runningInnerAuraBoostLight : style.runningInnerAuraBoostDark
        var innerAuraOpacity = clamp(innerAuraOpacityBase + boostProgress * innerAuraBoost, min: 0, max: 1)
        let outerAuraOpacityBase = isLight ? style.outerAuraOpacityLight : style.outerAuraOpacityDark
        let outerAuraBoost = isLight ? style.runningOuterAuraBoostLight : style.runningOuterAuraBoostDark
        var outerAuraOpacity = clamp(outerAuraOpacityBase + boostProgress * outerAuraBoost, min: 0, max: 1)
        let outerAuraSecondaryBase = isLight ? style.outerAuraSecondaryOpacityLight : style.outerAuraSecondaryOpacityDark
        let outerAuraSecondaryBoost = isLight ? style.runningOuterAuraSecondaryBoostLight : style.runningOuterAuraSecondaryBoostDark
        var outerAuraSecondaryOpacity = clamp(outerAuraSecondaryBase + boostProgress * outerAuraSecondaryBoost, min: 0, max: 1)
        let innerAuraBlurBase = isLight ? style.innerAuraBlurLight : style.innerAuraBlurDark
        let innerAuraBlurScale = 1 - boostProgress * (1 - style.runningInnerAuraBlurScale)
        let innerAuraBlur = innerAuraBlurBase * innerAuraBlurScale
        let outerAuraBlurBase = isLight ? style.outerAuraBlurLight : style.outerAuraBlurDark
        let outerAuraBlurScale = 1 - boostProgress * (1 - style.runningOuterAuraBlurScale)
        let outerAuraBlur = outerAuraBlurBase * outerAuraBlurScale
        let outerAuraSecondaryBlur = isLight ? style.outerAuraSecondaryBlurLight : style.outerAuraSecondaryBlurDark
        let ringBlurCore = isLight ? style.ringBlurCoreLight : style.ringBlurCoreDark
        let ringBlurSoft = isLight ? style.ringBlurSoftLight : style.ringBlurSoftDark
        let ringBlurBloom = isLight ? style.ringBlurBloomLight : style.ringBlurBloomDark
        let ringBlurShimmer = isLight ? style.ringBlurShimmerLight : style.ringBlurShimmerDark
        let ringOpacityCoreBase = isLight ? style.ringOpacityCoreLight : style.ringOpacityCoreDark
        let ringOpacitySoftBase = isLight ? style.ringOpacitySoftLight : style.ringOpacitySoftDark
        let ringOpacityBloomBase = isLight ? style.ringOpacityBloomLight : style.ringOpacityBloomDark
        let ringOpacityShimmerBase = isLight ? style.ringOpacityShimmerLight : style.ringOpacityShimmerDark
        var ringOpacityCore = clamp(ringOpacityCoreBase + boostProgress * style.runningRingBoostCore, min: 0, max: 1)
        var ringOpacitySoft = clamp(ringOpacitySoftBase + boostProgress * style.runningRingBoostSoft, min: 0, max: 1)
        var ringOpacityBloom = clamp(ringOpacityBloomBase + boostProgress * style.runningRingBoostBloom, min: 0, max: 1)
        var ringOpacityShimmer = clamp(ringOpacityShimmerBase + boostProgress * style.runningRingBoostShimmer, min: 0, max: 1)
        let baseline = AIGlowStyle.default
        let baselineInnerBase = isLight ? baseline.innerAuraOpacityLight : baseline.innerAuraOpacityDark
        let baselineInnerBoost = isLight ? baseline.runningInnerAuraBoostLight : baseline.runningInnerAuraBoostDark
        let baselineInnerOpacity = clamp(baselineInnerBase + boostProgress * baselineInnerBoost, min: 0, max: 1)
        let baselineOuterBase = isLight ? baseline.outerAuraOpacityLight : baseline.outerAuraOpacityDark
        let baselineOuterBoost = isLight ? baseline.runningOuterAuraBoostLight : baseline.runningOuterAuraBoostDark
        let baselineOuterOpacity = clamp(baselineOuterBase + boostProgress * baselineOuterBoost, min: 0, max: 1)
        let baselineOuterSecondaryBase = isLight ? baseline.outerAuraSecondaryOpacityLight : baseline.outerAuraSecondaryOpacityDark
        let baselineOuterSecondaryBoost = isLight ? baseline.runningOuterAuraSecondaryBoostLight : baseline.runningOuterAuraSecondaryBoostDark
        let baselineOuterSecondaryOpacity = clamp(baselineOuterSecondaryBase + boostProgress * baselineOuterSecondaryBoost, min: 0, max: 1)
        let baselineShimmerBase = isLight ? baseline.ringOpacityShimmerLight : baseline.ringOpacityShimmerDark
        let baselineShimmerOpacity = clamp(baselineShimmerBase + boostProgress * baseline.runningRingBoostShimmer, min: 0, max: 1)
        let shape = AIGlowMask.roundedRect(cornerRadius: cornerRadius)
        let shimmerGradient = AngularGradient(
            gradient: Gradient(stops: ringStops),
            center: .center,
            angle: .degrees(phaseDegrees + style.ringShimmerAngleOffset)
        )
        let auraMaskInfo = auraMaskInfo(
            contour: style.auraOuterContour,
            baseSize: baseSize,
            outerPadding: style.outerPadding
        )

        if showInnerAura {
            innerAuraOpacity = min(innerAuraOpacity, baselineInnerOpacity)
        }

        if !showRing {
            outerAuraOpacity = min(outerAuraOpacity, baselineOuterOpacity)
            outerAuraSecondaryOpacity = min(outerAuraSecondaryOpacity, baselineOuterSecondaryOpacity)
            ringOpacityShimmer = min(ringOpacityShimmer, baselineShimmerOpacity)
        }

        if let auraMaskInfo {
            outerAuraOpacity = clamp(outerAuraOpacity * auraMaskInfo.attenuation, min: 0, max: 1)
            outerAuraSecondaryOpacity = clamp(outerAuraSecondaryOpacity * auraMaskInfo.attenuation, min: 0, max: 1)
        }

        if shouldReduceMotion {
            ringOpacityShimmer = clamp(ringOpacityShimmer * 0.35, min: 0, max: 1)
        }

        if isHighContrast {
            innerAuraOpacity = clamp(innerAuraOpacity * 0.6, min: 0, max: 1)
            outerAuraOpacity = clamp(outerAuraOpacity * 0.5, min: 0, max: 1)
            outerAuraSecondaryOpacity = clamp(outerAuraSecondaryOpacity * 0.5, min: 0, max: 1)
            ringOpacityCore = clamp(ringOpacityCore * 1.1, min: 0, max: 1)
            ringOpacitySoft = clamp(ringOpacitySoft * 1.05, min: 0, max: 1)
            ringOpacityBloom = clamp(ringOpacityBloom * 0.9, min: 0, max: 1)
            ringOpacityShimmer = clamp(ringOpacityShimmer * 0.9, min: 0, max: 1)
            saturation = min(saturation, 1.2)
            contrast = max(contrast, 1.1)
        }

        if shouldReduceTransparency {
            innerAuraOpacity = 0
            outerAuraOpacity = clamp(outerAuraOpacity * 0.35, min: 0, max: 1)
            outerAuraSecondaryOpacity = clamp(outerAuraSecondaryOpacity * 0.35, min: 0, max: 1)
            ringOpacityCore = clamp(ringOpacityCore * 1.1, min: 0, max: 1)
            ringOpacitySoft = clamp(ringOpacitySoft * 1.05, min: 0, max: 1)
            ringOpacityBloom = clamp(ringOpacityBloom * 0.85, min: 0, max: 1)
            ringOpacityShimmer = clamp(ringOpacityShimmer * 0.8, min: 0, max: 1)
            saturation = min(saturation, 1.1)
            contrast = max(contrast, 1.1)
        }

        // Large turbulence surfaces (e.g., Log) can read slightly washed out due to broader blur/bloom coverage.
        // Apply a gentle size-based saturation/contrast lift so the Log matches the smaller input-field glow.
        if useTurbulence {
            let minDim = max(1, min(baseSize.width, baseSize.height))
            let start: CGFloat = 140
            if minDim > start {
                let t = Double(min(1, (minDim - start) / 260))
                let satBoost = 1 + 0.12 * t
                let conBoost = 1 + 0.04 * t
                saturation = min(saturation * satBoost, isLight ? 2.2 : 1.6)
                contrast = max(contrast * conBoost, isLight ? 1.05 : 1.0)
            }
        }

        return ZStack {
            if showInnerAura {
                ZStack {
                    if useTurbulence {
                        ForEach(turbulenceAuraLayers) { layer in
                            shape
                                .fill(AngularGradient(
                                    gradient: Gradient(stops: auraStops),
                                    center: layer.center,
                                    angle: layer.angle
                                ))
                                .frame(width: baseSize.width, height: baseSize.height)
                                .opacity(innerAuraOpacity * layer.weight)
                                .blur(radius: innerAuraBlur)
                                .mask(
                                    shape
                                        .frame(width: baseSize.width, height: baseSize.height)
                                )
                                .blendMode(auraBlend)
                        }
                    } else {
                        shape
                            .fill(auraGradient)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .opacity(innerAuraOpacity)
                            .blur(radius: innerAuraBlur)
                            .mask(
                                shape
                                    .frame(width: baseSize.width, height: baseSize.height)
                            )
                            .blendMode(auraBlend)
                    }
                }
                .compositingGroup()
            }

            if showAura {
                ZStack {
                    if useTurbulence {
                        ForEach(turbulenceAuraLayers) { layer in
                            shape
                                .stroke(AngularGradient(
                                    gradient: Gradient(stops: auraStops),
                                    center: layer.center,
                                    angle: layer.angle
                                ), lineWidth: style.outerAuraLineWidth)
                                .frame(width: baseSize.width, height: baseSize.height)
                                .opacity(outerAuraOpacity * layer.weight)
                                .blur(radius: outerAuraBlur)
                                .blendMode(auraBlend)
                        }
                    } else {
                        shape
                            .stroke(auraGradient, lineWidth: style.outerAuraLineWidth)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .opacity(outerAuraOpacity)
                            .blur(radius: outerAuraBlur)
                            .blendMode(auraBlend)
                    }

                    if useTurbulence {
                        ForEach(turbulenceAuraLayers) { layer in
                            shape
                                .stroke(AngularGradient(
                                    gradient: Gradient(stops: auraStops),
                                    center: layer.center,
                                    angle: layer.angle
                                ), lineWidth: style.outerAuraSecondaryLineWidth)
                                .frame(width: baseSize.width, height: baseSize.height)
                                .opacity(outerAuraSecondaryOpacity * layer.weight)
                                .blur(radius: outerAuraSecondaryBlur)
                                .offset(style.outerAuraSecondaryOffset)
                                .blendMode(auraBlend)
                        }
                    } else {
                        shape
                            .stroke(auraGradient, lineWidth: style.outerAuraSecondaryLineWidth)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .opacity(outerAuraSecondaryOpacity)
                            .blur(radius: outerAuraSecondaryBlur)
                            .offset(style.outerAuraSecondaryOffset)
                            .blendMode(auraBlend)
                    }
                }
                .compositingGroup()
                .modifier(AIGlowOptionalMask(mask: auraMaskInfo?.mask))
            }

            if showRing || showShimmer {
                ZStack {
                    if showRing {
                        if useTurbulence {
                            ForEach(turbulenceRingLayers) { layer in
                                shape
                                    .stroke(AngularGradient(
                                        gradient: Gradient(stops: ringStops),
                                        center: layer.center,
                                        angle: layer.angle
                                    ), lineWidth: style.ringLineWidthCore)
                                    .frame(width: baseSize.width, height: baseSize.height)
                                    .blur(radius: ringBlurCore)
                                    .opacity(ringOpacityCore * layer.weight)
                                    .blendMode(ringBlend)
                            }
                        } else {
                            shape
                                .stroke(ringGradient, lineWidth: style.ringLineWidthCore)
                                .frame(width: baseSize.width, height: baseSize.height)
                                .blur(radius: ringBlurCore)
                                .opacity(ringOpacityCore)
                                .blendMode(ringBlend)
                        }

                        if useTurbulence {
                            ForEach(turbulenceRingLayers) { layer in
                                shape
                                    .stroke(AngularGradient(
                                        gradient: Gradient(stops: ringStops),
                                        center: layer.center,
                                        angle: layer.angle
                                    ), lineWidth: style.ringLineWidthSoft)
                                    .frame(width: baseSize.width, height: baseSize.height)
                                    .blur(radius: ringBlurSoft)
                                    .opacity(ringOpacitySoft * layer.weight)
                                    .blendMode(ringBlend)
                            }
                        } else {
                            shape
                                .stroke(ringGradient, lineWidth: style.ringLineWidthSoft)
                                .frame(width: baseSize.width, height: baseSize.height)
                                .blur(radius: ringBlurSoft)
                                .opacity(ringOpacitySoft)
                                .blendMode(ringBlend)
                        }

                        if useTurbulence {
                            ForEach(turbulenceRingLayers) { layer in
                                shape
                                    .stroke(AngularGradient(
                                        gradient: Gradient(stops: ringStops),
                                        center: layer.center,
                                        angle: layer.angle
                                    ), lineWidth: style.ringLineWidthBloom)
                                    .frame(width: baseSize.width, height: baseSize.height)
                                    .blur(radius: ringBlurBloom)
                                    .opacity(ringOpacityBloom * layer.weight)
                                    .blendMode(ringBlend)
                            }
                        } else {
                            shape
                                .stroke(ringGradient, lineWidth: style.ringLineWidthBloom)
                                .frame(width: baseSize.width, height: baseSize.height)
                                .blur(radius: ringBlurBloom)
                                .opacity(ringOpacityBloom)
                                .blendMode(ringBlend)
                        }
                    }

                    if showShimmer {
                        if useTurbulence {
                            ForEach(turbulenceShimmerLayers) { layer in
                                shape
                                    .stroke(AngularGradient(
                                        gradient: Gradient(stops: ringStops),
                                        center: layer.center,
                                        angle: layer.angle
                                    ), lineWidth: style.ringLineWidthShimmer)
                                    .frame(width: baseSize.width, height: baseSize.height)
                                    .blur(radius: ringBlurShimmer)
                                    .opacity(ringOpacityShimmer * layer.weight)
                                    .blendMode(ringBlend)
                            }
                        } else {
                            shape
                                .stroke(shimmerGradient, lineWidth: style.ringLineWidthShimmer)
                                .frame(width: baseSize.width, height: baseSize.height)
                                .blur(radius: ringBlurShimmer)
                                .opacity(ringOpacityShimmer)
                                .blendMode(ringBlend)
                        }
                    }
                }
                .compositingGroup()
            }
        }
        .frame(width: baseSize.width, height: baseSize.height)
        .padding(style.outerPadding)
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: active)
        .saturation(saturation)
        .contrast(contrast)
        .allowsHitTesting(false)
    }

    private struct AuraMaskInfo {
        let mask: AnyView
        let attenuation: Double
    }

    private struct TurbulenceSpec {
        let baseX: Double
        let baseY: Double
        let driftX: Double
        let driftY: Double
        let driftPhase: Double
        let anglePhase: Double
        let angleJitter: Double
        let weight: Double
    }

    private struct TurbulenceLayer: Identifiable {
        let id: Int
        let center: UnitPoint
        let angle: Angle
        let weight: Double
    }

    private static let turbulenceSpecs: [TurbulenceSpec] = [
        TurbulenceSpec(baseX: 0.22, baseY: 0.28, driftX: 0.14, driftY: 0.11, driftPhase: 0.10, anglePhase: 18, angleJitter: 70, weight: 0.34),
        TurbulenceSpec(baseX: 0.78, baseY: 0.26, driftX: 0.12, driftY: 0.13, driftPhase: 0.35, anglePhase: 142, angleJitter: 55, weight: 0.26),
        TurbulenceSpec(baseX: 0.30, baseY: 0.78, driftX: 0.13, driftY: 0.09, driftPhase: 0.65, anglePhase: 264, angleJitter: 60, weight: 0.22),
        TurbulenceSpec(baseX: 0.76, baseY: 0.78, driftX: 0.10, driftY: 0.12, driftPhase: 0.25, anglePhase: 92, angleJitter: 50, weight: 0.18)
    ]

    private func buildTurbulenceLayers(
        phase: Double,
        angleOffset: Double,
        motionScale: Double,
        minDimensionReference: CGFloat
    ) -> [TurbulenceLayer] {
        let minDim = max(1, min(targetSize.width, targetSize.height))
        let ref = max(1, minDimensionReference)

        // Size compensation:
        // Drift is defined in UnitPoint space. On large surfaces, the same UnitPoint drift becomes huge in pixels,
        // which (a) makes the motion feel faster and (b) shifts color distribution on the ring (blue drops out earlier).
        // Use a sqrt falloff so small controls are unchanged while large areas are damped smoothly.
        let sizeComp: Double = {
            let ratio = Double(ref / minDim)
            if ratio >= 1 { return 1 }
            return sqrt(ratio)
        }()

        let scaledMotion = max(motionScale, 0) * sizeComp

        return Self.turbulenceSpecs.enumerated().map { index, spec in
            let driftTime = phase + spec.driftPhase
            let driftTime2 = driftTime + 0.37

            let x = clamp(
                spec.baseX
                    + (spec.driftX * scaledMotion) * cos(driftTime * 2 * .pi)
                    + (spec.driftX * 0.4 * scaledMotion) * cos(driftTime2 * 2 * .pi),
                min: 0.08,
                max: 0.92
            )

            let y = clamp(
                spec.baseY
                    + (spec.driftY * scaledMotion) * sin(driftTime * 2 * .pi)
                    + (spec.driftY * 0.4 * scaledMotion) * sin(driftTime2 * 2 * .pi),
                min: 0.08,
                max: 0.92
            )

            // Macro rotation remains tied to `phase` (same period as input fields),
            // turbulence adds non-centered motion without changing the underlying phase speed.
            let baseAngle = phase * 360 + angleOffset + spec.anglePhase

            // Keep jitter small; it is also size-compensated via scaledMotion.
            let jitter = (Double.random(in: -1...1) * spec.angleJitter) * scaledMotion
            let angle = Angle(degrees: baseAngle + jitter)

            return TurbulenceLayer(
                id: index,
                center: UnitPoint(x: x, y: y),
                angle: angle,
                weight: spec.weight
            )
        }
    }

    private func auraMaskInfo(
        contour: AIGlowAuraOuterContour,
        baseSize: CGSize,
        outerPadding: CGFloat
    ) -> AuraMaskInfo? {
        guard baseSize.width > 0, baseSize.height > 0 else { return nil }

        let maxExtentScale: CGFloat = 1.6
        let minDimension = min(baseSize.width, baseSize.height)
        let maxOutsetByPadding = min(outerPadding, minDimension * 0.5)

        func clampScale(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 1 }
            return min(max(value, 0), maxExtentScale)
        }

        func clampOutset(_ outset: CGFloat, scaleX: CGFloat, scaleY: CGFloat) -> CGFloat {
            guard outset.isFinite else { return 0 }
            let maxOutsetX = max(0, (maxExtentScale - scaleX) * baseSize.width / 2)
            let maxOutsetY = max(0, (maxExtentScale - scaleY) * baseSize.height / 2)
            let maxOutset = min(maxOutsetByPadding, maxOutsetX, maxOutsetY)
            return min(max(outset, 0), maxOutset)
        }

        func attenuation(for maskSize: CGSize) -> Double {
            let widthScale = maskSize.width / baseSize.width
            let heightScale = maskSize.height / baseSize.height
            let extentScale = max(widthScale, heightScale)
            guard extentScale > 1 else { return 1 }
            return max(0.35, min(1, 1 / Double(extentScale)))
        }

        switch contour {
        case .matchTarget:
            return nil
        case .roundedRect(let overrideRadius, let outset):
            let clampedOutset = clampOutset(outset, scaleX: 1, scaleY: 1)
            let maskSize = CGSize(
                width: baseSize.width + clampedOutset * 2,
                height: baseSize.height + clampedOutset * 2
            )
            let radius = min(max(overrideRadius, 0), min(maskSize.width, maskSize.height) / 2)
            let mask = RoundedRectangle(cornerRadius: radius, style: .continuous)
                .frame(width: maskSize.width, height: maskSize.height)
            return AuraMaskInfo(mask: AnyView(mask), attenuation: attenuation(for: maskSize))
        case .oval(let scaleX, let scaleY, let outset):
            let clampedScaleX = clampScale(scaleX)
            let clampedScaleY = clampScale(scaleY)
            let clampedOutset = clampOutset(outset, scaleX: clampedScaleX, scaleY: clampedScaleY)
            let maskSize = CGSize(
                width: baseSize.width * clampedScaleX + clampedOutset * 2,
                height: baseSize.height * clampedScaleY + clampedOutset * 2
            )
            let mask = Ellipse()
                .frame(width: maskSize.width, height: maskSize.height)
            return AuraMaskInfo(mask: AnyView(mask), attenuation: attenuation(for: maskSize))
        }
    }

    private func updateBoost() {
        guard active else {
            boostProgress = 0
            return
        }
        if isRunning {
            withAnimation(AIGlowAnimation.boostInAnimation) {
                boostProgress = 1
            }
        } else {
            withAnimation(AIGlowAnimation.boostOutAnimation) {
                boostProgress = 0
            }
        }
    }

    private var currentPhase: Double {
        guard active else { return 0 }
        let period = effectiveRotationPeriod
        guard period > 0 else { return 0 }
        let start = phaseStartTime == 0 ? tickerNow : phaseStartTime
        let elapsed = tickerNow - start
        return AIGlowAnimation.normalizedPhase(
            elapsed: elapsed,
            period: period,
            phaseOffset: style.phaseOffset
        )
    }

    private var effectiveRotationPeriod: Double {
        let shouldReduceMotion = reduceMotionOverride ?? reduceMotion
        return AIGlowAnimation.rotationPeriod(style: style, isRunning: isRunning, reduceMotion: shouldReduceMotion)
    }

    private func resetPhaseStart(active: Bool) {
        if active {
            phaseStartTime = tickerNow
        } else {
            phaseStartTime = 0
        }
    }

    private var tickerPublisher: AnyPublisher<TimeInterval, Never> {
        if shouldAnimate {
            return AIGlowTicker.shared.publisher
        }
        return Empty().eraseToAnyPublisher()
    }

    private var shouldAnimate: Bool {
        guard active, isVisible else { return false }
        guard scenePhase == .active else { return false }
        if controlActiveState == .inactive { return false }
        return true
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

private struct AIGlowChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let action: () -> Void
    @State private var lastValue: Value

    init(value: Value, action: @escaping () -> Void) {
        self.value = value
        self.action = action
        _lastValue = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content
            .onReceive(Just(value)) { newValue in
                guard newValue != lastValue else { return }
                lastValue = newValue
                action()
            }
    }
}

private struct AIGlowOptionalMask: ViewModifier {
    let mask: AnyView?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let mask {
            content.mask(mask)
        } else {
            content
        }
    }
}

private extension View {
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping () -> Void) -> some View {
        modifier(AIGlowChangeObserver(value: value, action: action))
    }
}

struct AIGlowReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

struct AIGlowReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

struct AIGlowIncreasedContrastOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var aiGlowReduceTransparencyOverride: Bool? {
        get { self[AIGlowReduceTransparencyOverrideKey.self] }
        set { self[AIGlowReduceTransparencyOverrideKey.self] = newValue }
    }

    var aiGlowReduceMotionOverride: Bool? {
        get { self[AIGlowReduceMotionOverrideKey.self] }
        set { self[AIGlowReduceMotionOverrideKey.self] = newValue }
    }

    var aiGlowIncreasedContrastOverride: Bool? {
        get { self[AIGlowIncreasedContrastOverrideKey.self] }
        set { self[AIGlowIncreasedContrastOverrideKey.self] = newValue }
    }
}
