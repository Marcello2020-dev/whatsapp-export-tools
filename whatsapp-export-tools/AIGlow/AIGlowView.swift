import SwiftUI

/// Core rendering view for the Apple-Intelligence-style AI glow.
struct AIGlowOverlay: View {
    let active: Bool
    let boost: Bool
    let cornerRadius: CGFloat
    let style: AIGlowStyle
    let targetSize: CGSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0
    @State private var boostProgress: Double = 0

    var body: some View {
        glowBody
            .onAppear {
                updateAnimation()
                updateBoost()
            }
            .onChange(of: reduceMotion) { updateAnimation() }
            .onChange(of: active) {
                updateAnimation()
                updateBoost()
            }
            .onChange(of: boost) {
                updateAnimation()
                updateBoost()
            }
    }

    private var glowBody: some View {
        let isLight = colorScheme == .light
        let saturation = isLight ? style.saturationLight : style.saturationDark
        let contrast = isLight ? style.contrastLight : style.contrastDark
        let baseSize = targetSize
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
        let innerAuraOpacity = clamp(innerAuraOpacityBase + boostProgress * innerAuraBoost, min: 0, max: 1)
        let outerAuraOpacityBase = isLight ? style.outerAuraOpacityLight : style.outerAuraOpacityDark
        let outerAuraBoost = isLight ? style.runningOuterAuraBoostLight : style.runningOuterAuraBoostDark
        let outerAuraOpacity = clamp(outerAuraOpacityBase + boostProgress * outerAuraBoost, min: 0, max: 1)
        let outerAuraSecondaryBase = isLight ? style.outerAuraSecondaryOpacityLight : style.outerAuraSecondaryOpacityDark
        let outerAuraSecondaryBoost = isLight ? style.runningOuterAuraSecondaryBoostLight : style.runningOuterAuraSecondaryBoostDark
        let outerAuraSecondaryOpacity = clamp(outerAuraSecondaryBase + boostProgress * outerAuraSecondaryBoost, min: 0, max: 1)
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
        let ringOpacityShimmer = clamp(ringOpacityShimmerBase + boostProgress * style.runningRingBoostShimmer, min: 0, max: 1)
        let shape = AIGlowMask.roundedRect(cornerRadius: cornerRadius)
        let shimmerGradient = AngularGradient(
            gradient: Gradient(colors: style.ringColors),
            center: .center,
            angle: .degrees(phase + style.ringShimmerAngleOffset)
        )

        return ZStack {
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

            ZStack {
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

                shape
                    .stroke(shimmerGradient, lineWidth: style.ringLineWidthShimmer)
                    .frame(width: baseSize.width, height: baseSize.height)
                    .blur(radius: ringBlurShimmer)
                    .opacity(ringOpacityShimmer)
                    .blendMode(ringBlend)
            }
            .compositingGroup()
        }
        .frame(width: baseSize.width, height: baseSize.height)
        .padding(style.outerPadding)
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: active)
        .saturation(saturation)
        .contrast(contrast)
        .allowsHitTesting(false)
    }

    private func updateAnimation() {
        guard active else {
            phase = 0
            return
        }
        let duration = AIGlowAnimation.rotationDuration(style: style, boost: boost, reduceMotion: reduceMotion)
        guard duration > 0 else {
            phase = 0
            return
        }
        phase = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            phase = 360
        }
    }

    private func updateBoost() {
        guard active else {
            boostProgress = 0
            return
        }
        if boost {
            withAnimation(AIGlowAnimation.boostInAnimation) {
                boostProgress = 1
            }
        } else {
            withAnimation(AIGlowAnimation.boostOutAnimation) {
                boostProgress = 0
            }
        }
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}
