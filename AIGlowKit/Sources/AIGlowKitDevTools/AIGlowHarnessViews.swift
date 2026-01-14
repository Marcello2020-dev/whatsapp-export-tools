import SwiftUI
import AIGlowKit

public struct AIGlowHarnessRootView: View {
    @State private var selectionID: String? = AIGlowHarnessFixtures.defaultSelectionID

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectionID) {
                ForEach(AIGlowHarnessFixtures.groups) { group in
                    Section(group.name) {
                        ForEach(group.fixtures) { fixture in
                            Text(fixture.name)
                                .tag(fixture.id)
                        }
                    }
                }
            }
            .navigationTitle(AIGlowHarnessStrings.title)
        } detail: {
            if let fixture = AIGlowHarnessFixtures.fixture(for: selectionID) {
                AIGlowHarnessFixtureDetailView(fixture: fixture)
            } else {
                Text(AIGlowHarnessStrings.fixtureHint)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
    }
}

struct AIGlowHarnessFixtureDetailView: View {
    let fixture: AIGlowHarnessFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fixture.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(fixture.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            AIGlowHarnessFixturePreview(fixture: fixture, isSnapshot: false)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AIGlowHarnessFixturePreview: View {
    let fixture: AIGlowHarnessFixture
    let isSnapshot: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var style: AIGlowStyle {
        AIGlowHarnessStyleBuilder.style(
            for: fixture,
            colorScheme: colorScheme,
            isSnapshot: isSnapshot
        )
    }

    var body: some View {
        let running = isSnapshot ? false : fixture.isRunning
        switch fixture.kind {
        case .form:
            AIGlowHarnessFormView(
                style: style,
                active: fixture.active,
                isRunning: running
            )
        case .focusedField:
            AIGlowHarnessFocusedFieldView(
                style: style,
                active: fixture.active,
                isRunning: running
            )
        case .listTable:
            AIGlowHarnessListTableView(
                style: style,
                active: fixture.active,
                isRunning: running
            )
        }
    }
}

struct AIGlowHarnessFormView: View {
    let style: AIGlowStyle
    let active: Bool
    let isRunning: Bool
    @State private var primaryValue: String = ""
    @State private var secondaryValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AIGlowHarnessStrings.exampleField)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("", text: $primaryValue)
                .textFieldStyle(.roundedBorder)
                .aiGlow(active: active, isRunning: isRunning, cornerRadius: 6, style: style)

            Text(AIGlowHarnessStrings.secondaryField)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("", text: $secondaryValue)
                .textFieldStyle(.roundedBorder)
                .aiGlow(active: active, isRunning: isRunning, cornerRadius: 6, style: style)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct AIGlowHarnessFocusedFieldView: View {
    let style: AIGlowStyle
    let active: Bool
    let isRunning: Bool
    @State private var focusedValue: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AIGlowHarnessStrings.focusedField)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("", text: $focusedValue)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .aiGlow(active: active, isRunning: isRunning, cornerRadius: 6, style: style)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .onAppear {
            isFocused = true
        }
    }
}

struct AIGlowHarnessListTableView: View {
    let style: AIGlowStyle
    let active: Bool
    let isRunning: Bool

    private var rows: [AIGlowHarnessRow] {
        let labels = AIGlowHarnessStrings.listItems
        let states = AIGlowHarnessStrings.tableStates
        return labels.enumerated().map { index, label in
            let state = states[index % states.count]
            return AIGlowHarnessRow(id: label, label: label, state: state)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AIGlowHarnessStrings.listTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            List(rows) { row in
                HStack {
                    AIGlowHarnessGlowBadge(
                        text: row.label,
                        style: style,
                        active: active,
                        isRunning: isRunning
                    )
                    Spacer()
                    Text(row.state)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .frame(height: 180)
            .listStyle(.plain)

            Text(AIGlowHarnessStrings.tableTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if #available(macOS 13.0, *) {
                Table(rows) {
                    TableColumn(AIGlowHarnessStrings.tableColumnLabel) { row in
                        AIGlowHarnessGlowBadge(
                            text: row.label,
                            style: style,
                            active: active,
                            isRunning: isRunning
                        )
                    }
                    TableColumn(AIGlowHarnessStrings.tableColumnState) { row in
                        Text(row.state)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 180)
            } else {
                Text(AIGlowHarnessStrings.tableFallback)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

struct AIGlowHarnessGlowBadge: View {
    let text: String
    let style: AIGlowStyle
    let active: Bool
    let isRunning: Bool

    var body: some View {
        Text(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .aiGlow(active: active, isRunning: isRunning, cornerRadius: 6, style: style)
    }
}

struct AIGlowHarnessRow: Identifiable, Hashable {
    let id: String
    let label: String
    let state: String
}

enum AIGlowHarnessStyleBuilder {
    static func style(
        for fixture: AIGlowHarnessFixture,
        colorScheme: ColorScheme,
        isSnapshot: Bool
    ) -> AIGlowStyle {
        let palette = fixture.palette.normalized()
        let ringColors = palette.ringColors(for: colorScheme)
        let auraColors = palette.auraColors(for: colorScheme)
        let base = AIGlowStyle.default.overriding(
            ringColors: ringColors,
            auraColors: auraColors,
            components: fixture.components,
            fillMode: fixture.fillMode
        )
        guard isSnapshot else { return base }
        return base.overriding(
            rotationDuration: 1.0e9,
            rotationDurationRunning: 1.0e9,
            rotationDurationReducedMotion: 1.0e9,
            phaseOffset: 0,
            runningRingBoostCore: 0,
            runningRingBoostSoft: 0,
            runningRingBoostBloom: 0,
            runningRingBoostShimmer: 0,
            runningInnerAuraBoostDark: 0,
            runningInnerAuraBoostLight: 0,
            runningOuterAuraBoostDark: 0,
            runningOuterAuraBoostLight: 0,
            runningOuterAuraSecondaryBoostDark: 0,
            runningOuterAuraSecondaryBoostLight: 0,
            runningInnerAuraBlurScale: 1,
            runningOuterAuraBlurScale: 1
        )
    }
}

private extension AIGlowStyle {
    func overriding(
        ringColors: [Color]? = nil,
        auraColors: [Color]? = nil,
        components: AIGlowComponents? = nil,
        fillMode: AIGlowFillMode? = nil,
        rotationDuration: Double? = nil,
        rotationDurationRunning: Double? = nil,
        rotationDurationReducedMotion: Double? = nil,
        phaseOffset: Double? = nil,
        runningRingBoostCore: Double? = nil,
        runningRingBoostSoft: Double? = nil,
        runningRingBoostBloom: Double? = nil,
        runningRingBoostShimmer: Double? = nil,
        runningInnerAuraBoostDark: Double? = nil,
        runningInnerAuraBoostLight: Double? = nil,
        runningOuterAuraBoostDark: Double? = nil,
        runningOuterAuraBoostLight: Double? = nil,
        runningOuterAuraSecondaryBoostDark: Double? = nil,
        runningOuterAuraSecondaryBoostLight: Double? = nil,
        runningInnerAuraBlurScale: CGFloat? = nil,
        runningOuterAuraBlurScale: CGFloat? = nil
    ) -> AIGlowStyle {
        AIGlowStyle(
            ringColors: ringColors ?? self.ringColors,
            auraColors: auraColors ?? self.auraColors,
            components: components ?? self.components,
            fillMode: fillMode ?? self.fillMode,
            auraOuterContour: auraOuterContour,
            ringLineWidthCore: ringLineWidthCore,
            ringLineWidthSoft: ringLineWidthSoft,
            ringLineWidthBloom: ringLineWidthBloom,
            ringLineWidthShimmer: ringLineWidthShimmer,
            ringBlurCoreDark: ringBlurCoreDark,
            ringBlurCoreLight: ringBlurCoreLight,
            ringBlurSoftDark: ringBlurSoftDark,
            ringBlurSoftLight: ringBlurSoftLight,
            ringBlurBloomDark: ringBlurBloomDark,
            ringBlurBloomLight: ringBlurBloomLight,
            ringBlurShimmerDark: ringBlurShimmerDark,
            ringBlurShimmerLight: ringBlurShimmerLight,
            ringOpacityCoreDark: ringOpacityCoreDark,
            ringOpacityCoreLight: ringOpacityCoreLight,
            ringOpacitySoftDark: ringOpacitySoftDark,
            ringOpacitySoftLight: ringOpacitySoftLight,
            ringOpacityBloomDark: ringOpacityBloomDark,
            ringOpacityBloomLight: ringOpacityBloomLight,
            ringOpacityShimmerDark: ringOpacityShimmerDark,
            ringOpacityShimmerLight: ringOpacityShimmerLight,
            ringShimmerAngleOffset: ringShimmerAngleOffset,
            innerAuraBlurDark: innerAuraBlurDark,
            innerAuraBlurLight: innerAuraBlurLight,
            innerAuraOpacityDark: innerAuraOpacityDark,
            innerAuraOpacityLight: innerAuraOpacityLight,
            outerAuraLineWidth: outerAuraLineWidth,
            outerAuraBlurDark: outerAuraBlurDark,
            outerAuraBlurLight: outerAuraBlurLight,
            outerAuraOpacityDark: outerAuraOpacityDark,
            outerAuraOpacityLight: outerAuraOpacityLight,
            outerAuraSecondaryLineWidth: outerAuraSecondaryLineWidth,
            outerAuraSecondaryBlurDark: outerAuraSecondaryBlurDark,
            outerAuraSecondaryBlurLight: outerAuraSecondaryBlurLight,
            outerAuraSecondaryOpacityDark: outerAuraSecondaryOpacityDark,
            outerAuraSecondaryOpacityLight: outerAuraSecondaryOpacityLight,
            outerAuraSecondaryOffset: outerAuraSecondaryOffset,
            outerAuraPadding: outerAuraPadding,
            outerAuraSecondaryPadding: outerAuraSecondaryPadding,
            ringOuterPadding: ringOuterPadding,
            ringBloomPadding: ringBloomPadding,
            rotationDuration: rotationDuration ?? self.rotationDuration,
            rotationDurationRunning: rotationDurationRunning ?? self.rotationDurationRunning,
            rotationDurationReducedMotion: rotationDurationReducedMotion ?? self.rotationDurationReducedMotion,
            globalSpeedScale: globalSpeedScale,
            speedScale: speedScale,
            phaseOffset: phaseOffset ?? self.phaseOffset,
            ringBlendModeDark: ringBlendModeDark,
            ringBlendModeLight: ringBlendModeLight,
            auraBlendModeDark: auraBlendModeDark,
            auraBlendModeLight: auraBlendModeLight,
            saturationDark: saturationDark,
            saturationLight: saturationLight,
            contrastDark: contrastDark,
            contrastLight: contrastLight,
            runningRingBoostCore: runningRingBoostCore ?? self.runningRingBoostCore,
            runningRingBoostSoft: runningRingBoostSoft ?? self.runningRingBoostSoft,
            runningRingBoostBloom: runningRingBoostBloom ?? self.runningRingBoostBloom,
            runningRingBoostShimmer: runningRingBoostShimmer ?? self.runningRingBoostShimmer,
            runningInnerAuraBoostDark: runningInnerAuraBoostDark ?? self.runningInnerAuraBoostDark,
            runningInnerAuraBoostLight: runningInnerAuraBoostLight ?? self.runningInnerAuraBoostLight,
            runningOuterAuraBoostDark: runningOuterAuraBoostDark ?? self.runningOuterAuraBoostDark,
            runningOuterAuraBoostLight: runningOuterAuraBoostLight ?? self.runningOuterAuraBoostLight,
            runningOuterAuraSecondaryBoostDark: runningOuterAuraSecondaryBoostDark ?? self.runningOuterAuraSecondaryBoostDark,
            runningOuterAuraSecondaryBoostLight: runningOuterAuraSecondaryBoostLight ?? self.runningOuterAuraSecondaryBoostLight,
            runningInnerAuraBlurScale: runningInnerAuraBlurScale ?? self.runningInnerAuraBlurScale,
            runningOuterAuraBlurScale: runningOuterAuraBlurScale ?? self.runningOuterAuraBlurScale,
            outerPadding: outerPadding
        )
    }
}
