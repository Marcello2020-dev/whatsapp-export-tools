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
            AIGlowHarnessFixturePreview(fixture: fixture)
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
    @Environment(\.colorScheme) private var colorScheme

    private var style: AIGlowStyle {
        AIGlowHarnessStyleBuilder.style(for: fixture, colorScheme: colorScheme)
    }

    var body: some View {
        switch fixture.kind {
        case .form:
            AIGlowHarnessFormView(
                style: style,
                active: fixture.active,
                isRunning: fixture.isRunning
            )
        case .focusedField:
            AIGlowHarnessFocusedFieldView(
                style: style,
                active: fixture.active,
                isRunning: fixture.isRunning
            )
        case .listTable:
            AIGlowHarnessListTableView(
                style: style,
                active: fixture.active,
                isRunning: fixture.isRunning
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
    static func style(for fixture: AIGlowHarnessFixture, colorScheme: ColorScheme) -> AIGlowStyle {
        let palette = fixture.palette.normalized()
        let ringColors = palette.ringColors(for: colorScheme)
        let auraColors = palette.auraColors(for: colorScheme)
        return AIGlowStyle.default.overriding(
            ringColors: ringColors,
            auraColors: auraColors,
            components: fixture.components,
            fillMode: fixture.fillMode
        )
    }
}

private extension AIGlowStyle {
    func overriding(
        ringColors: [Color]? = nil,
        auraColors: [Color]? = nil,
        components: AIGlowComponents? = nil,
        fillMode: AIGlowFillMode? = nil
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
            rotationDuration: rotationDuration,
            rotationDurationRunning: rotationDurationRunning,
            rotationDurationReducedMotion: rotationDurationReducedMotion,
            globalSpeedScale: globalSpeedScale,
            speedScale: speedScale,
            phaseOffset: phaseOffset,
            ringBlendModeDark: ringBlendModeDark,
            ringBlendModeLight: ringBlendModeLight,
            auraBlendModeDark: auraBlendModeDark,
            auraBlendModeLight: auraBlendModeLight,
            saturationDark: saturationDark,
            saturationLight: saturationLight,
            contrastDark: contrastDark,
            contrastLight: contrastLight,
            runningRingBoostCore: runningRingBoostCore,
            runningRingBoostSoft: runningRingBoostSoft,
            runningRingBoostBloom: runningRingBoostBloom,
            runningRingBoostShimmer: runningRingBoostShimmer,
            runningInnerAuraBoostDark: runningInnerAuraBoostDark,
            runningInnerAuraBoostLight: runningInnerAuraBoostLight,
            runningOuterAuraBoostDark: runningOuterAuraBoostDark,
            runningOuterAuraBoostLight: runningOuterAuraBoostLight,
            runningOuterAuraSecondaryBoostDark: runningOuterAuraSecondaryBoostDark,
            runningOuterAuraSecondaryBoostLight: runningOuterAuraSecondaryBoostLight,
            runningInnerAuraBlurScale: runningInnerAuraBlurScale,
            runningOuterAuraBlurScale: runningOuterAuraBlurScale,
            outerPadding: outerPadding
        )
    }
}
