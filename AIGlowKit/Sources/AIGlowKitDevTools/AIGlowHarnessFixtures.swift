import SwiftUI
import AIGlowKit

public enum AIGlowHarnessFixtureKind: String, CaseIterable, Sendable {
    case form
    case focusedField
    case listTable
}

public struct AIGlowHarnessFixture: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let kind: AIGlowHarnessFixtureKind
    public let palette: AIGlowPalette
    public let fillMode: AIGlowFillMode
    public let components: AIGlowComponents
    public let active: Bool
    public let isRunning: Bool
}

public struct AIGlowHarnessFixtureGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let fixtures: [AIGlowHarnessFixture]
}

public enum AIGlowHarnessPolicy {
    public static let allowsExternalDataAccess = false

    public static func assertNoExternalDataAccess(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(!allowsExternalDataAccess, "External export loading is disabled in the AI Glow harness.", file: file, line: line)
    }
}

public enum AIGlowHarnessStrings {
    public static let title = "AI Glow Harness"
    public static let subtitle = "Synthetic fixtures only"
    public static let fixtureHint = "Select a fixture to preview"
    public static let exampleField = "Example Field"
    public static let secondaryField = "Synthetic Handle"
    public static let focusedField = "Focused Field"
    public static let listTitle = "Dense List"
    public static let tableTitle = "Compact Table"
    public static let tableColumnLabel = "Label"
    public static let tableColumnState = "State"
    public static let paletteGroup = "Palettes"
    public static let fillGroup = "Fill Modes"
    public static let componentsGroup = "Components"
    public static let focusGroup = "Focus"
    public static let listGroup = "List/Table"
    public static let fixtureDefaultPalette = "Default Palette"
    public static let fixtureCustomPalette = "Custom Palette"
    public static let fixtureFillOutline = "Fill: Outline Only"
    public static let fixtureFillInner = "Fill: Inner Glow"
    public static let fixtureAuraOnly = "Components: Aura Only"
    public static let fixtureRingOnly = "Components: Ring Only"
    public static let fixtureShimmerOnly = "Components: Shimmer Only"
    public static let fixtureFocusedField = "Focused Field Example"
    public static let fixtureListTable = "List/Table Example"
    public static let detailDefaultPalette = "Apple-fidelity baseline palette."
    public static let detailCustomPalette = "Synthetic custom palette with light/dark variants."
    public static let detailFillOutline = "Outline only."
    public static let detailFillInner = "Inner glow enabled."
    public static let detailAuraOnly = "Aura only."
    public static let detailRingOnly = "Ring only."
    public static let detailShimmerOnly = "Shimmer only."
    public static let detailFocusedField = "Focused field with glow."
    public static let detailListTable = "Dense list and table rendering."
    public static let tableFallback = "Table view requires macOS 13 or newer."
    public static let listItems = [
        "Item Alpha",
        "Item Beta",
        "Item Gamma",
        "Item Delta",
        "Item Epsilon",
        "Item Zeta"
    ]
    public static let tableRows = [
        "Row Alpha",
        "Row Beta",
        "Row Gamma"
    ]
    public static let tableStates = [
        "Ready",
        "Queued",
        "Done"
    ]

    public static var allTextTokens: [String] {
        [
            title,
            subtitle,
            fixtureHint,
            exampleField,
            secondaryField,
            focusedField,
            listTitle,
            tableTitle,
            tableColumnLabel,
            tableColumnState,
            paletteGroup,
            fillGroup,
            componentsGroup,
            focusGroup,
            listGroup,
            fixtureDefaultPalette,
            fixtureCustomPalette,
            fixtureFillOutline,
            fixtureFillInner,
            fixtureAuraOnly,
            fixtureRingOnly,
            fixtureShimmerOnly,
            fixtureFocusedField,
            fixtureListTable,
            detailDefaultPalette,
            detailCustomPalette,
            detailFillOutline,
            detailFillInner,
            detailAuraOnly,
            detailRingOnly,
            detailShimmerOnly,
            detailFocusedField,
            detailListTable,
            tableFallback
        ]
        + listItems
        + tableRows
        + tableStates
    }
}

public enum AIGlowHarnessFixtures {
    public static let customPalette: AIGlowPalette = {
        let light = AIGlowPalette.Variant(
            ringStops: [
                AIGlowGradientStop(location: 0.0, hex: 0x2DD4BF),
                AIGlowGradientStop(location: 0.4, hex: 0x34D399),
                AIGlowGradientStop(location: 0.7, hex: 0x22D3EE),
                AIGlowGradientStop(location: 1.0, hex: 0x2DD4BF)
            ],
            auraStops: [
                AIGlowGradientStop(location: 0.0, hex: 0x148F77, alpha: 0.9),
                AIGlowGradientStop(location: 0.4, hex: 0x1F9D55, alpha: 0.9),
                AIGlowGradientStop(location: 0.7, hex: 0x0E7490, alpha: 0.9),
                AIGlowGradientStop(location: 1.0, hex: 0x148F77, alpha: 0.9)
            ]
        )
        let dark = AIGlowPalette.Variant(
            ringStops: [
                AIGlowGradientStop(location: 0.0, hex: 0x1AA39A),
                AIGlowGradientStop(location: 0.4, hex: 0x1B9E77),
                AIGlowGradientStop(location: 0.7, hex: 0x0F8AA0),
                AIGlowGradientStop(location: 1.0, hex: 0x1AA39A)
            ],
            auraStops: [
                AIGlowGradientStop(location: 0.0, hex: 0x0B5F57, alpha: 0.85),
                AIGlowGradientStop(location: 0.4, hex: 0x0F6B4E, alpha: 0.85),
                AIGlowGradientStop(location: 0.7, hex: 0x0A5A6A, alpha: 0.85),
                AIGlowGradientStop(location: 1.0, hex: 0x0B5F57, alpha: 0.85)
            ]
        )
        return AIGlowPalette(name: "Synthetic Mint", light: light, dark: dark)
    }()

    public static let groups: [AIGlowHarnessFixtureGroup] = [
        AIGlowHarnessFixtureGroup(
            id: "palette",
            name: AIGlowHarnessStrings.paletteGroup,
            fixtures: [
                AIGlowHarnessFixture(
                    id: "default-palette",
                    name: AIGlowHarnessStrings.fixtureDefaultPalette,
                    detail: AIGlowHarnessStrings.detailDefaultPalette,
                    kind: .form,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: .all,
                    active: true,
                    isRunning: false
                ),
                AIGlowHarnessFixture(
                    id: "custom-palette",
                    name: AIGlowHarnessStrings.fixtureCustomPalette,
                    detail: AIGlowHarnessStrings.detailCustomPalette,
                    kind: .form,
                    palette: customPalette,
                    fillMode: .innerGlow,
                    components: .all,
                    active: true,
                    isRunning: false
                )
            ]
        ),
        AIGlowHarnessFixtureGroup(
            id: "fill",
            name: AIGlowHarnessStrings.fillGroup,
            fixtures: [
                AIGlowHarnessFixture(
                    id: "fill-outline",
                    name: AIGlowHarnessStrings.fixtureFillOutline,
                    detail: AIGlowHarnessStrings.detailFillOutline,
                    kind: .form,
                    palette: .default,
                    fillMode: .outlineOnly,
                    components: .all,
                    active: true,
                    isRunning: false
                ),
                AIGlowHarnessFixture(
                    id: "fill-inner",
                    name: AIGlowHarnessStrings.fixtureFillInner,
                    detail: AIGlowHarnessStrings.detailFillInner,
                    kind: .form,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: .all,
                    active: true,
                    isRunning: false
                )
            ]
        ),
        AIGlowHarnessFixtureGroup(
            id: "components",
            name: AIGlowHarnessStrings.componentsGroup,
            fixtures: [
                AIGlowHarnessFixture(
                    id: "components-aura",
                    name: AIGlowHarnessStrings.fixtureAuraOnly,
                    detail: AIGlowHarnessStrings.detailAuraOnly,
                    kind: .form,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: [.aura],
                    active: true,
                    isRunning: false
                ),
                AIGlowHarnessFixture(
                    id: "components-ring",
                    name: AIGlowHarnessStrings.fixtureRingOnly,
                    detail: AIGlowHarnessStrings.detailRingOnly,
                    kind: .form,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: [.ring],
                    active: true,
                    isRunning: false
                ),
                AIGlowHarnessFixture(
                    id: "components-shimmer",
                    name: AIGlowHarnessStrings.fixtureShimmerOnly,
                    detail: AIGlowHarnessStrings.detailShimmerOnly,
                    kind: .form,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: [.shimmer],
                    active: true,
                    isRunning: true
                )
            ]
        ),
        AIGlowHarnessFixtureGroup(
            id: "focus",
            name: AIGlowHarnessStrings.focusGroup,
            fixtures: [
                AIGlowHarnessFixture(
                    id: "focused-field",
                    name: AIGlowHarnessStrings.fixtureFocusedField,
                    detail: AIGlowHarnessStrings.detailFocusedField,
                    kind: .focusedField,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: .all,
                    active: true,
                    isRunning: false
                )
            ]
        ),
        AIGlowHarnessFixtureGroup(
            id: "list-table",
            name: AIGlowHarnessStrings.listGroup,
            fixtures: [
                AIGlowHarnessFixture(
                    id: "list-table",
                    name: AIGlowHarnessStrings.fixtureListTable,
                    detail: AIGlowHarnessStrings.detailListTable,
                    kind: .listTable,
                    palette: .default,
                    fillMode: .innerGlow,
                    components: .all,
                    active: true,
                    isRunning: false
                )
            ]
        )
    ]

    public static let allFixtures: [AIGlowHarnessFixture] = groups.flatMap { $0.fixtures }

    public static func fixture(for id: String?) -> AIGlowHarnessFixture? {
        guard let id else { return nil }
        return allFixtures.first { $0.id == id }
    }

    public static let defaultSelectionID: String = allFixtures.first?.id ?? "default-palette"

    public static let snapshotFixtures: [AIGlowHarnessFixture] = allFixtures
}
