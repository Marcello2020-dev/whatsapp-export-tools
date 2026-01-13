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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.aiGlowReduceTransparencyOverride) private var reduceTransparencyOverride
    @ObservedObject private var ticker = AIGlowTicker.shared
    @State private var phaseStartTime: TimeInterval = 0
    @State private var boostProgress: Double = 0
    @State private var lastDebugPrintTime: TimeInterval = 0

    var body: some View {
        let base = glowBody
            .onAppear {
                resetPhaseStart(active: active)
                updateBoost()
            }
            .onChangeCompat(of: reduceMotion) {
                resetPhaseStart(active: active)
            }
            .onChangeCompat(of: active) {
                resetPhaseStart(active: active)
                updateBoost()
            }
            .onChangeCompat(of: isRunning) {
                resetPhaseStart(active: active)
                updateBoost()
            }

#if DEBUG
        return base
            .onChangeCompat(of: ticker.now) {
                guard active, let debugTag else { return }
                let now = ticker.now
                if now - lastDebugPrintTime >= 1.0 {
                    lastDebugPrintTime = now
                    let phase = String(format: "%.1f", currentPhase)
                    print("[AIGlowPhase:\(debugTag)] \(phase)°")
                }
            }
#else
        return base
#endif
    }

    private var glowBody: some View {
        let isLight = colorScheme == .light
        let saturation = isLight ? style.saturationLight : style.saturationDark
        let contrast = isLight ? style.contrastLight : style.contrastDark
        let baseSize = targetSize
        let phase = currentPhase
        let components = style.components
        let showAura = components.contains(.aura)
        let showRing = components.contains(.ring)
        let showShimmer = components.contains(.shimmer)
        let showInnerAura = showAura && style.fillMode == .innerGlow
        let ringGradient = AngularGradient(
            gradient: Gradient(colors: style.ringColors),
            center: .center,
            angle: .degrees(phase)
        )
        let auraGradient = AngularGradient(
            gradient: Gradient(colors: style.auraColors),
            center: .center,
            angle: .degrees(phase)
        )
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
        let ringOpacityCore = clamp(ringOpacityCoreBase + boostProgress * style.runningRingBoostCore, min: 0, max: 1)
        let ringOpacitySoft = clamp(ringOpacitySoftBase + boostProgress * style.runningRingBoostSoft, min: 0, max: 1)
        let ringOpacityBloom = clamp(ringOpacityBloomBase + boostProgress * style.runningRingBoostBloom, min: 0, max: 1)
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
            gradient: Gradient(colors: style.ringColors),
            center: .center,
            angle: .degrees(phase + style.ringShimmerAngleOffset)
        )

        if showInnerAura {
            innerAuraOpacity = min(innerAuraOpacity, baselineInnerOpacity)
        }

        if !showRing {
            outerAuraOpacity = min(outerAuraOpacity, baselineOuterOpacity)
            outerAuraSecondaryOpacity = min(outerAuraSecondaryOpacity, baselineOuterSecondaryOpacity)
            ringOpacityShimmer = min(ringOpacityShimmer, baselineShimmerOpacity)
        }

        if reduceTransparencyOverride ?? accessibilityReduceTransparency {
            innerAuraOpacity = 0
            outerAuraOpacity *= 0.45
            outerAuraSecondaryOpacity *= 0.45
        }

        return ZStack {
            if showInnerAura {
                ZStack {
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
                .compositingGroup()
            }

            if showAura {
                ZStack {
                    shape
                        .stroke(auraGradient, lineWidth: style.outerAuraLineWidth)
                        .frame(width: baseSize.width, height: baseSize.height)
                        .opacity(outerAuraOpacity)
                        .blur(radius: outerAuraBlur)
                        .blendMode(auraBlend)

                    shape
                        .stroke(auraGradient, lineWidth: style.outerAuraSecondaryLineWidth)
                        .frame(width: baseSize.width, height: baseSize.height)
                        .opacity(outerAuraSecondaryOpacity)
                        .blur(radius: outerAuraSecondaryBlur)
                        .offset(style.outerAuraSecondaryOffset)
                        .blendMode(auraBlend)
                }
                .compositingGroup()
            }

            if showRing || showShimmer {
                ZStack {
                    if showRing {
                        shape
                            .stroke(ringGradient, lineWidth: style.ringLineWidthCore)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .blur(radius: ringBlurCore)
                            .opacity(ringOpacityCore)
                            .blendMode(ringBlend)

                        shape
                            .stroke(ringGradient, lineWidth: style.ringLineWidthSoft)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .blur(radius: ringBlurSoft)
                            .opacity(ringOpacitySoft)
                            .blendMode(ringBlend)

                        shape
                            .stroke(ringGradient, lineWidth: style.ringLineWidthBloom)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .blur(radius: ringBlurBloom)
                            .opacity(ringOpacityBloom)
                            .blendMode(ringBlend)
                    }

                    if showShimmer {
                        shape
                            .stroke(shimmerGradient, lineWidth: style.ringLineWidthShimmer)
                            .frame(width: baseSize.width, height: baseSize.height)
                            .blur(radius: ringBlurShimmer)
                            .opacity(ringOpacityShimmer)
                            .blendMode(ringBlend)
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
        let duration = effectiveRotationDuration
        guard duration > 0 else { return 0 }
        let start = phaseStartTime == 0 ? ticker.now : phaseStartTime
        let elapsed = ticker.now - start
        let angle = (elapsed / duration) * 360
        return angle.truncatingRemainder(dividingBy: 360)
    }

    private var effectiveRotationDuration: Double {
        let base = AIGlowAnimation.rotationDuration(style: style, isRunning: isRunning, reduceMotion: reduceMotion)
        let scale = max(style.speedScale, 0.05)
        return base / scale
    }

    private func resetPhaseStart(active: Bool) {
        if active {
            phaseStartTime = ticker.now
        } else {
            phaseStartTime = 0
        }
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

private extension View {
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping () -> Void) -> some View {
        modifier(AIGlowChangeObserver(value: value, action: action))
    }
}

struct AIGlowReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var aiGlowReduceTransparencyOverride: Bool? {
        get { self[AIGlowReduceTransparencyOverrideKey.self] }
        set { self[AIGlowReduceTransparencyOverrideKey.self] = newValue }
    }
}
