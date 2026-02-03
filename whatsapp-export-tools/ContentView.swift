import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    private struct ExportResult: Sendable {
        let primaryHTML: URL?
        let htmls: [URL]
        let md: URL?
    }

    private struct ExportContext: Sendable {
        let chatURL: URL
        let outDir: URL
        let partnerFolderName: String
        let exportDir: URL
        let tempWorkspaceURL: URL?
        let debugEnabled: Bool
        let allowOverwrite: Bool
        let isOverwriteRetry: Bool
        let preflight: OutputPreflight?
        let prepared: WhatsAppExportService.PreparedExport?
        let baseNameOverride: String?
        let exporter: String
        let chatPartner: String
        let chatPartners: [String]
        let chatPartnerSource: String
        let chatPartnerFolderOverride: String?
        let exporterConfidence: WETParticipantConfidence
        let partnerConfidence: WETParticipantConfidence
        let exporterWasOverridden: Bool
        let partnerWasOverridden: Bool
        let wasSwapped: Bool
        let allowPlaceholderAsMe: Bool
        let chatKind: WAParticipantChatKind
        let titleNamesOverride: String?
        let detectedPartnerRaw: String
        let overridePartnerRaw: String?
        let participantDetection: WAParticipantDetectionResult?
        let provenance: WETSourceProvenance
        let participantNameOverrides: [String: String]
        let selectedVariantsInOrder: [HTMLVariant]
        let plan: RunPlan
        let wantsMD: Bool
        let wantsSidecar: Bool
        let wantsRawArchiveCopy: Bool
        let wantsDeleteOriginals: Bool
        let htmlLabel: String
    }

    private struct ExportWorkResult: Sendable {
        let exportDir: URL
        let baseHTMLName: String
        let htmls: [URL]
        let md: URL?
        let primaryHTML: URL?
        let sidecarImmutabilityWarnings: [String]
        let outputSuffixArtifacts: [String]
    }

    private struct TargetFolderLabel: Equatable {
        let partner: String
        let baseName: String

        static let placeholder = TargetFolderLabel(partner: "—", baseName: "—")

        var displayPath: String {
            "\(partner)/\(baseName)"
        }
    }

    private enum RunStep: Hashable, Identifiable, Sendable {
        case sidecar
        case html(HTMLVariant)
        case markdown
        case rawArchive

        nonisolated var id: String {
            switch self {
            case .sidecar:
                return "sidecar"
            case .html(let variant):
                return "html-\(variant.rawValue)"
            case .markdown:
                return "markdown"
            case .rawArchive:
                return "raw-archive"
            }
        }

        nonisolated var label: String {
            logLabel
        }

        nonisolated var logLabel: String {
            switch self {
            case .sidecar:
                return "Sidecar"
            case .html(let variant):
                return variant.logLabel
            case .markdown:
                return "Markdown"
            case .rawArchive:
                return "Raw archive"
            }
        }

        nonisolated func localizedLabel(locale: Locale) -> String {
            switch self {
            case .sidecar:
                return String(localized: "wet.run.step.sidecar", locale: locale)
            case .html(let variant):
                return variant.localizedLabel(locale: locale)
            case .markdown:
                return String(localized: "wet.run.step.markdown", locale: locale)
            case .rawArchive:
                return String(localized: "wet.run.step.rawArchive", locale: locale)
            }
        }
    }

    private struct RunPlan: Sendable {
        let variants: [HTMLVariant]
        let wantsMD: Bool
        let wantsSidecar: Bool
        let wantsRawArchiveCopy: Bool

        nonisolated var variantSuffixes: [String] {
            variants.map { ContentView.htmlVariantSuffix(for: $0) }
        }

        nonisolated var wantsAnyThumbs: Bool {
            wantsSidecar || variants.contains(where: { $0 == .embedAll || $0 == .thumbnailsOnly })
        }

        nonisolated var runSteps: [RunStep] {
            var steps: [RunStep] = []
            if wantsRawArchiveCopy {
                // Raw archive copy happens before artifacts and is independent of Sidecar.
                steps.append(.rawArchive)
            }
            if wantsSidecar {
                steps.append(.sidecar)
            }
            for variant in variants {
                steps.append(.html(variant))
            }
            if wantsMD {
                steps.append(.markdown)
            }
            return steps
        }
    }

    private struct ParticipantResolution: Sendable, Equatable {
        var participantsDetected: [String]
        var detectedExporter: String?
        var detectedPartner: String?
        var exporterConfidence: WETParticipantConfidence
        var partnerConfidence: WETParticipantConfidence
        var detectionConfidence: WAParticipantDetectionConfidence
        var exporterOverride: String?
        var partnerOverride: String?
        var exporterAssumed: Bool
        var wasSwapped: Bool
        var chatKind: WAParticipantChatKind
        var groupTitle: String?
        var resolvedExporter: String
        var resolvedPartners: [String]

        static let empty = ParticipantResolution(
            participantsDetected: [],
            detectedExporter: nil,
            detectedPartner: nil,
            exporterConfidence: .none,
            partnerConfidence: .none,
            detectionConfidence: .low,
            exporterOverride: nil,
            partnerOverride: nil,
            exporterAssumed: false,
            wasSwapped: false,
            chatKind: .unknown,
            groupTitle: nil,
            resolvedExporter: "",
            resolvedPartners: []
        )

        private static func trimmedOrNil(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        var effectiveExporter: String {
            Self.trimmedOrNil(exporterOverride) ?? resolvedExporter
        }

        var effectivePartners: [String] {
            if chatKind == .group {
                let exporter = Self.trimmedOrNil(exporterOverride) ?? resolvedExporter
                let base = resolvedPartners.isEmpty ? participantsDetected : resolvedPartners
                if exporter.isEmpty { return base }
                let exporterKey = ContentView.normalizedKeyStatic(exporter)
                let partners = base.filter { ContentView.normalizedKeyStatic($0) != exporterKey }
                return partners.isEmpty ? base : partners
            }
            if let override = Self.trimmedOrNil(partnerOverride) {
                return [override]
            }
            let exporter = Self.trimmedOrNil(exporterOverride) ?? resolvedExporter
            if !exporter.isEmpty, !participantsDetected.isEmpty {
                let exporterKey = ContentView.normalizedKeyStatic(exporter)
                let partners = participantsDetected.filter { ContentView.normalizedKeyStatic($0) != exporterKey }
                if !partners.isEmpty {
                    return partners
                }
            }
            return resolvedPartners
        }

        var effectivePartner: String {
            if chatKind == .group {
                if let override = Self.trimmedOrNil(partnerOverride) {
                    return override
                }
                if let groupTitle, !groupTitle.isEmpty {
                    return groupTitle
                }
                return effectivePartners.first ?? ""
            }
            return effectivePartners.first ?? ""
        }

        var exporterWasOverridden: Bool {
            Self.trimmedOrNil(exporterOverride) != nil
        }

        var partnerWasOverridden: Bool {
            Self.trimmedOrNil(partnerOverride) != nil
        }

        var allowPlaceholderAsMe: Bool {
            if exporterWasOverridden { return true }
            if chatKind == .group {
                return detectionConfidence == .high || detectionConfidence == .medium
            }
            return exporterConfidence == .strong
        }
    }

    private enum RunStatus: Equatable {
        case ready
        case validating
        case exporting(RunStep)
        case completed
        case failed
        case cancelled
    }

    private enum WETTab: Hashable {
        case input
        case output
    }

    private enum RunStepState {
        case pending
        case running
        case done
        case failed
        case cancelled

        func localizedLabel(locale: Locale) -> String {
            switch self {
            case .pending: return String(localized: "wet.run.stepState.pending", locale: locale)
            case .running: return String(localized: "wet.run.stepState.running", locale: locale)
            case .done: return String(localized: "wet.run.stepState.done", locale: locale)
            case .failed: return String(localized: "wet.run.stepState.failed", locale: locale)
            case .cancelled: return String(localized: "wet.run.stepState.cancelled", locale: locale)
            }
        }
    }

    private struct RunStepProgress: Identifiable, Equatable {
        let step: RunStep
        var state: RunStepState
        var id: String { step.id }
    }

    private struct StepTiming: Equatable {
        var start: DispatchTime?
        var finalDuration: TimeInterval?

        mutating func startIfNeeded(at now: DispatchTime) {
            if start == nil { start = now }
        }

        mutating func stop(at now: DispatchTime, override: TimeInterval? = nil) {
            if let override {
                finalDuration = override
                return
            }
            guard let start else { return }
            finalDuration = ContentView.monotonicDuration(from: start, to: now)
        }

        func elapsed(now: DispatchTime) -> TimeInterval? {
            if let finalDuration {
                return finalDuration
            }
            guard let start else { return nil }
            return ContentView.monotonicDuration(from: start, to: now)
        }
    }

    private struct OutputPreflight: Sendable {
        let baseName: String
        let existing: [URL]
    }

    private struct OutputDeletionError: LocalizedError, Sendable {
        let url: URL
        let underlying: Error

        var errorDescription: String? {
            "Could not delete existing output: \(url.lastPathComponent)"
        }
    }

    private struct DeleteOriginalsGuardError: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private struct EmptyArtifactError: LocalizedError, Sendable {
        let url: URL
        let reason: String

        var errorDescription: String? {
            "Empty artifact not allowed: \(url.lastPathComponent) (\(reason))"
        }
    }

    private struct ExportProgressLogger: Sendable {
        let append: @Sendable (String) -> Void

        func log(_ message: String) {
            append(message)
        }
    }

    private static let customChatPartnerTag = "__CUSTOM_CHAT_PARTNER__"
    nonisolated private static let exportBaseMaxLength: Int = 200
    private enum Layout {
        static let labelWidth: CGFloat = 110
        static let chatPartnerWidth: CGFloat = 320
        static let participantsLabelMinWidth: CGFloat = 150
        static let overviewMaxWidth: CGFloat = 360
        static let topColumnSpacing: CGFloat = 16
        static let topLeftMinWidth: CGFloat = 520
        static let optionsColumnMinWidth: CGFloat = 360
        static let runDurationWidth: CGFloat = 52
        static let runRowHeight: CGFloat = 18
        static let runRowSpacing: CGFloat = 4
    }
    private static let designMaxWidth: CGFloat = 1440
    private static let designMaxHeight: CGFloat = 900
    private static let aiMenuBadgeImage: NSImage = AIGlowPalette.menuBadgeImage
#if DEBUG
    private static var didRunAIGlowHostStateCheck = false
#endif


    // MARK: - Export options

    /// Three HTML variants, ordered by typical output size (largest → smallest).
    private enum HTMLVariant: String, CaseIterable, Identifiable, Sendable {
        /// Largest: embed full attachments (images/videos/PDFs/etc.) into the HTML
        case embedAll
        /// Medium: embed only lightweight thumbnails for attachments (no full payload)
        case thumbnailsOnly
        /// Smallest: text-only export (no link previews, no thumbnails)
        case textOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .embedAll:
                return "Max: Embed everything (largest file)"
            case .thumbnailsOnly:
                return "Compact: Embed thumbnails only"
            case .textOnly:
                return "E-Mail: Text only (no previews, no thumbnails)"
            }
        }

        nonisolated var logLabel: String {
            switch self {
            case .embedAll:
                return "Max"
            case .thumbnailsOnly:
                return "Compact"
            case .textOnly:
                return "E-Mail"
            }
        }

        nonisolated func localizedLabel(locale: Locale) -> String {
            switch self {
            case .embedAll:
                return String(localized: "wet.variant.max", locale: locale)
            case .thumbnailsOnly:
                return String(localized: "wet.variant.compact", locale: locale)
            case .textOnly:
                return String(localized: "wet.variant.email", locale: locale)
            }
        }
        
        /// Suffix appended to the HTML filename (before extension)
        var fileSuffix: String {
            WETOutputNaming.htmlVariantSuffix(for: rawValue)
        }

        /// Whether to fetch/render online link previews.
        /// Per requirement: disabled only for the minimal text-only variant.
        nonisolated var enablePreviews: Bool {
            switch self {
            case .textOnly: return false
            case .embedAll, .thumbnailsOnly: return true
            }
        }

        /// Whether to embed any attachment representation into the HTML.
        nonisolated var embedAttachments: Bool {
            switch self {
            case .textOnly: return false
            case .embedAll, .thumbnailsOnly: return true
            }
        }

        /// If attachments are embedded, whether to embed thumbnails only (no full attachment payload).
        nonisolated var thumbnailsOnly: Bool {
            switch self {
            case .embedAll: return false
            case .thumbnailsOnly: return true
            case .textOnly: return false
            }
        }
    }

    // MARK: - Theme

    // WhatsApp-like palette (approx.)
    static let waGreen = Color(red: 0x25/255.0, green: 0xD3/255.0, blue: 0x66/255.0)   // #25D366
    static let waTeal  = Color(red: 0x12/255.0, green: 0x8C/255.0, blue: 0x7E/255.0)   // #128C7E
    static let waBlue  = Color(red: 0x34/255.0, green: 0xB7/255.0, blue: 0xF1/255.0)   // #34B7F1

    static let bgTop = waTeal.opacity(0.22)
    static let bgBottom = waGreen.opacity(0.12)

    // Subtle “card tint” gradient used by waCard()
    static let cardTintGradient = LinearGradient(
        colors: [waGreen.opacity(0.18), waBlue.opacity(0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Prefer a dedicated asset (if present) for in-app rendering; fallback to the actual app icon.
    static var appIconNSImage: NSImage {
        // NOTE: `AppIcon` is often an Icon Set and may not be addressable by name at runtime.
        // If you have a separate Image Set (recommended), name it e.g. `AppIconRender` and add it here.
        if let img = NSImage(named: "AppIconRender") { return img }
        if let img = NSImage(named: "AppIcon") { return img }
        return NSApp.applicationIconImage
    }

    struct WhatsAppBackground: View {
        var body: some View {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(
                        colors: [ContentView.bgTop, ContentView.bgBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Canvas { ctx, size in
                        let step: CGFloat = 34

                        for y in stride(from: 10.0, to: size.height, by: step) {
                            for x in stride(from: 10.0, to: size.width, by: step) {
                                let r = CGRect(x: x, y: y, width: 2.0, height: 2.0)
                                ctx.fill(Path(ellipseIn: r), with: .color(.white.opacity(0.05)))
                            }
                        }

                        for y in stride(from: 27.0, to: size.height, by: step) {
                            for x in stride(from: 27.0, to: size.width, by: step) {
                                let r = CGRect(x: x, y: y, width: 2.0, height: 2.0)
                                ctx.fill(Path(ellipseIn: r), with: .color(.black.opacity(0.10)))
                            }
                        }
                    }
                    .opacity(0.55)
                    .allowsHitTesting(false)

                    // Large app icon watermark
                    Image(nsImage: ContentView.appIconNSImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: min(geo.size.width, geo.size.height) * 0.82)
                        .opacity(0.13)
                        .blendMode(.softLight)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    // MARK: - State

    @State private var lastResult: ExportResult?

    @State private var chatURL: URL?
    @State private var outBaseURL: URL?
    @State private var chatURLAccess: SecurityScopedURL? = nil
    @State private var outBaseURLAccess: SecurityScopedURL? = nil
    @State private var didRestoreSettings: Bool = false
    @State private var isRestoringSettings: Bool = false
    @State private var selectedTab: WETTab = .input

    // Independent export toggles (default: all enabled)
    @State private var exportHTMLMax: Bool = true
    @State private var exportHTMLMid: Bool = true
    @State private var exportHTMLMin: Bool = true
    @State private var exportMarkdown: Bool = true

    // NEW: Optional "Sidecar" folder export (sorted attachments) next to the HTML/MD export.
    // IMPORTANT: HTML outputs must remain standalone and must NOT depend on the Sidecar folder.
    @State private var exportSortedAttachments: Bool = true
    @State private var includeRawArchive: Bool = false
    @State private var deleteOriginalsAfterSidecar: Bool = false

    @State private var detectedParticipants: [String] = []
    @State private var chatPartnerCandidates: [String] = []
    @State private var chatPartnerSelection: String = ""
    @State private var chatPartnerCustomName: String = ""
    @State private var autoDetectedChatPartnerName: String? = nil
    @State private var exporterName: String = ""
    @State private var participantResolution: ParticipantResolution = .empty
    @State private var participantDetection: WAParticipantDetectionResult? = nil
    @State private var detectedChatTitle: String? = nil
    @State private var detectedDateRange: ClosedRange<Date>? = nil
    @State private var detectedMediaCounts: WAMediaCounts = .zero
    @State private var inputKindBadgeKey: String? = nil
    @State private var replayModeActive: Bool = false

    // Optional overrides for participants that appear only as phone numbers in the WhatsApp export
    // Key = phone-number-like participant string as it appears in the export; Value = user-provided display name
    @State private var phoneParticipantOverrides: [String: String] = [:]
    @State private var autoSuggestedPhoneNames: [String: String] = [:]

    @State private var isRunning: Bool = false
    @State private var runStatus: RunStatus = .ready
    @State private var runProgress: [RunStepProgress] = []
    @State private var runStepTimings: [String: StepTiming] = [:]
    @State private var runStepTick: DispatchTime = .now()
    @State private var runStepTimer: Timer? = nil
    @State private var lastRunDuration: TimeInterval? = nil
    @State private var lastRunFailureSummary: String? = nil
    @State private var lastRunFailureArtifact: String? = nil
    @State private var currentRunStep: RunStep? = nil
    @State private var lastExportDir: URL? = nil
    @State private var targetFolderLabel: TargetFolderLabel = .placeholder
    @State private var showReplaceSheet: Bool = false
    @State private var replaceExistingNames: [String] = []
    @State private var replaceOutputPath: String = ""
    @State private var replaceBaseName: String = ""
    @State private var replaceExportDir: URL? = nil
    @State private var overwriteConfirmed: Bool = false
    @State private var pendingPreflight: OutputPreflight? = nil
    @State private var pendingPreparedExport: WhatsAppExportService.PreparedExport? = nil
    @State private var showDeleteOriginalsAlert: Bool = false
    @State private var deleteOriginalCandidates: [URL] = []
    @State private var deleteOriginalTempWorkspaceURL: URL? = nil
    @State private var didSetInitialWindowSize: Bool = false
    @State private var exportTask: Task<Void, Never>? = nil
    @State private var cancelRequested: Bool = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @EnvironmentObject private var diagnosticsLog: DiagnosticsLogStore

    // MARK: - View

    var body: some View {
        mainContent
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Self.waGreen)
        .background(WhatsAppBackground().ignoresSafeArea())
        .onAppear {
            applyInitialWindowSizeIfNeeded()
            if !didRestoreSettings {
                didRestoreSettings = true
                restorePersistedSettings()
            }
            if let u = chatURL, detectedParticipants.isEmpty {
                refreshParticipants(for: u)
            }
#if DEBUG
            runAIGlowHostStateCheckIfNeeded()
#endif
        }
        .sheet(isPresented: $showReplaceSheet) {
            replaceConfirmationSheet
        }
        .alert("wet.deleteOriginals.alert.title", isPresented: $showDeleteOriginalsAlert) {
            Button("wet.action.cancel", role: .cancel) {
                deleteOriginalCandidates = []
                deleteOriginalTempWorkspaceURL = nil
            }
            Button("wet.deleteOriginals.alert.confirm", role: .destructive) {
                let items = deleteOriginalCandidates
                deleteOriginalCandidates = []
                let tempWorkspace = deleteOriginalTempWorkspaceURL
                deleteOriginalTempWorkspaceURL = nil
                Task { await deleteOriginalItems(items, tempWorkspaceURL: tempWorkspace) }
            }
        } message: {
            let lines = deleteOriginalCandidates.map { $0.path }.joined(separator: "\n")
            Text(String(format: String(localized: "wet.deleteOriginals.alert.message", locale: locale), lines))
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    private var mainContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .waCard()

                tabSelector

                tabContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled(true)
    }

    private var tabSelector: some View {
        Picker("wet.tab.selector", selection: $selectedTab) {
            Text("wet.tab.input")
                .tag(WETTab.input)
            Text("wet.tab.output")
                .tag(WETTab.output)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("wet.tab.selector.accessibility"))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .input:
            WETInputTabView {
                topAreaSection
            }
        case .output:
            WETOutputTabView {
                outputTabContent
            }
        }
    }

    private var outputTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            optionsSection
            runCard
        }
    }

    private var runCard: some View {
        runSection
            .waCard()
            .aiGlow(
                active: isRunning,
                isRunning: isRunning,
                cornerRadius: 14,
                style: runGlowStyle,
                debugTag: "run"
            )
    }

    private struct WETInputTabView<Content: View>: View {
        let content: () -> Content

        init(@ViewBuilder content: @escaping () -> Content) {
            self.content = content
        }

        var body: some View {
            content()
        }
    }

    private struct WETOutputTabView<Content: View>: View {
        let content: () -> Content

        init(@ViewBuilder content: @escaping () -> Content) {
            self.content = content
        }

        var body: some View {
            content()
        }
    }

    private var replaceConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("wet.replace.title")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("wet.replace.outputFolder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(replaceOutputPath.isEmpty ? "—" : replaceOutputPath)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("wet.replace.exportBase")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(replaceBaseName.isEmpty ? "—" : replaceBaseName)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("wet.replace.itemsToReplace")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if replaceExistingNames.isEmpty {
                    Text("—")
                        .font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(replaceExistingNames, id: \.self) { name in
                            Text("• \(name)")
                                .font(.callout)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("wet.action.cancel", role: .cancel) {
                    dismissReplaceSheet(clearPending: true)
                }
                .keyboardShortcut(.defaultAction)

                Button("wet.replace.keepBoth") {
                    guard let chatURL, let outBaseURL, let exportDir = replaceExportDir else { return }
                    let variants: [HTMLVariant] = [
                        exportHTMLMax ? .embedAll : nil,
                        exportHTMLMid ? .thumbnailsOnly : nil,
                        exportHTMLMin ? .textOnly : nil
                    ].compactMap { $0 }
                    let wantsSidecar = exportSortedAttachments
                    let wantsRawArchiveCopy = wantsRawArchiveCopy()
                    guard let candidate = Self.deterministicKeepBothBaseName(
                        baseName: replaceBaseName,
                        variants: variants,
                        wantsMarkdown: exportMarkdown,
                        wantsSidecar: wantsSidecar,
                        wantsRawArchive: wantsRawArchiveCopy,
                        in: exportDir
                    ) else {
                        appendLog("ERROR: Could not generate deterministic Keep Both name.")
                        dismissReplaceSheet(clearPending: false)
                        return
                    }
                    dismissReplaceSheet(clearPending: false)
                    startExport(
                        chatURL: chatURL,
                        outDir: outBaseURL,
                        allowOverwrite: false,
                        baseNameOverride: candidate,
                        reusePrepared: true
                    )
                }

                Button("wet.replace.replace", role: .destructive) {
                    guard let chatURL, let outBaseURL else { return }
                    dismissReplaceSheet(clearPending: false)
                    overwriteConfirmed = true
                    startExport(chatURL: chatURL, outDir: outBaseURL, allowOverwrite: true)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    private func dismissReplaceSheet(clearPending: Bool) {
        showReplaceSheet = false
        replaceExistingNames = []
        replaceOutputPath = ""
        replaceBaseName = ""
        replaceExportDir = nil
        if clearPending {
            pendingPreflight = nil
            pendingPreparedExport = nil
        }
    }

    private var topAreaSection: some View {
        ViewThatFits(in: .horizontal) {
            topAreaWide
            topAreaNarrow
        }
    }

    private var topAreaWide: some View {
        HStack(alignment: .top, spacing: Layout.topColumnSpacing) {
            topLeftColumn
                .frame(minWidth: Layout.topLeftMinWidth, maxWidth: .infinity, alignment: .leading)
            overviewCard
                .frame(width: Layout.overviewMaxWidth, alignment: .leading)
        }
    }

    private var topAreaNarrow: some View {
        VStack(alignment: .leading, spacing: 12) {
            topLeftColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            overviewCard
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var topLeftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputPathSection
            outputPathSection
            participantsSection
        }
        .waCard()
    }

    private var inputPathSection: some View {
        WASection(title: "wet.section.input", systemImage: "tray.and.arrow.down") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("wet.input.chatExport.label")
                        .frame(width: Layout.labelWidth, alignment: .leading)

                    Text(displayChatPath(chatURL) ?? "—")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(chatURL?.path ?? "")

                    Button("wet.action.choose") { pickChatFile() }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(Text("wet.input.choose.accessibility"))
                        .disabled(isRunning)
                }
            }
        }
    }

    private var outputPathSection: some View {
        WASection(title: "wet.section.output", systemImage: "tray.and.arrow.up") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("wet.output.folder.label")
                        .frame(width: Layout.labelWidth, alignment: .leading)

                    Text(displayOutputPath(outBaseURL) ?? "—")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(outBaseURL?.path ?? "")

                    Button("wet.action.choose") { pickOutputFolder() }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(Text("wet.output.choose.accessibility"))
                        .disabled(isRunning)
                }
            }
        }
    }

    private var participantsSection: some View {
        WASection(title: "wet.section.participants", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 10) {
                chatPartnerSelectionRow
                phoneOverridesSection
            }
        }
    }

    private var overviewCard: some View {
        WASection(title: "wet.section.overview", systemImage: "info.circle") {
            overviewSummary
        }
        .waCard()
    }

    private var overviewSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let badgeKey = inputKindBadgeKey {
                Text(LocalizedStringKey(badgeKey))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.06))
                    .clipShape(Capsule())
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("wet.overview.detectedTitle.label")
                        .foregroundStyle(.secondary)
                        .frame(width: Layout.labelWidth, alignment: .leading)
                    Text(detectedChatTitle ?? "—")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("wet.overview.participantLabel.label")
                        .foregroundStyle(.secondary)
                        .frame(width: Layout.labelWidth, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(participantResolution.detectedPartner ?? "—")
                        if let confidence = inputSummaryConfidenceText {
                            Text(confidence)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("wet.overview.dateRange.label")
                        .foregroundStyle(.secondary)
                        .frame(width: Layout.labelWidth, alignment: .leading)
                    Text(inputSummaryDateRangeText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("wet.overview.mediaCounts.label")
                        .foregroundStyle(.secondary)
                        .frame(width: Layout.labelWidth, alignment: .leading)
                    Text(inputSummaryMediaCountsText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
        }
    }

    private var optionsSection: some View {
        ViewThatFits(in: .horizontal) {
            optionsWide
            optionsNarrow
        }
    }

    private var optionsWide: some View {
        HStack(alignment: .top, spacing: 12) {
            artifactsSection
                .waCard()
                .frame(minWidth: Layout.optionsColumnMinWidth, maxWidth: .infinity, alignment: .leading)
            sourceHandlingSection
                .waCard()
                .frame(minWidth: Layout.optionsColumnMinWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var optionsNarrow: some View {
        VStack(alignment: .leading, spacing: 12) {
            artifactsSection
                .waCard()
            sourceHandlingSection
                .waCard()
        }
    }

    private var artifactsSection: some View {
        WASection(title: "wet.section.artifacts", systemImage: "doc.on.doc") {
            VStack(alignment: .leading, spacing: 10) {
                outputsHeader
                outputsGrid

                Divider()
                    .padding(.vertical, 1)

                sidecarToggle
            }
            .controlSize(.small)
        }
    }

    private var sourceHandlingSection: some View {
        WASection(title: "wet.section.sourceHandling", systemImage: "archivebox") {
            VStack(alignment: .leading, spacing: 8) {
                rawArchiveToggle
                deleteOriginalsToggle
            }
            .controlSize(.small)
        }
    }

    private var outputsHeader: some View {
        HStack(spacing: 6) {
            Text("wet.section.artifacts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            helpIcon("wet.help.artifacts.header")
        }
    }

    private var outputsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Toggle(isOn: $exportHTMLMax) {
                    HStack(spacing: 6) {
                        Text("wet.artifacts.max.label")
                        helpIcon("wet.help.artifacts.max")
                    }
                }
                .accessibilityLabel(Text("wet.artifacts.max.accessibility"))
                .disabled(isRunning)
                .onChange(of: exportHTMLMax) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportHTMLMid) {
                    HStack(spacing: 6) {
                        Text("wet.artifacts.compact.label")
                        helpIcon("wet.help.artifacts.compact")
                    }
                }
                .accessibilityLabel(Text("wet.artifacts.compact.accessibility"))
                .disabled(isRunning)
                .onChange(of: exportHTMLMid) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Toggle(isOn: $exportHTMLMin) {
                    HStack(spacing: 6) {
                        Text("wet.artifacts.email.label")
                        helpIcon("wet.help.artifacts.email")
                    }
                }
                .accessibilityLabel(Text("wet.artifacts.email.accessibility"))
                .disabled(isRunning)
                .onChange(of: exportHTMLMin) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportMarkdown) {
                    HStack(spacing: 6) {
                        Text("wet.artifacts.markdown.label")
                        helpIcon("wet.help.artifacts.markdown")
                    }
                }
                .accessibilityLabel(Text("wet.artifacts.markdown.accessibility"))
                .disabled(isRunning)
                .onChange(of: exportMarkdown) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sidecarToggle: some View {
        Toggle(isOn: $exportSortedAttachments) {
            HStack(spacing: 6) {
                Text("wet.artifacts.sidecar.label")
                Text("wet.artifacts.sidecar.recommended")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                helpIcon("wet.help.artifacts.sidecar")
            }
        }
        .accessibilityLabel(Text("wet.artifacts.sidecar.accessibility"))
        .disabled(isRunning)
        .onChange(of: exportSortedAttachments) {
            persistExportSettings()
        }
    }

    private var deleteOriginalsToggle: some View {
        let copySourcesEnabled = wantsRawArchiveCopy()
        let disabled = isRunning || replayModeActive || !copySourcesEnabled
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $deleteOriginalsAfterSidecar) {
                HStack(spacing: 6) {
                    Text("wet.source.deleteOriginals.label")
                    helpIcon("wet.help.source.deleteOriginals")
                }
            }
            .accessibilityLabel(Text("wet.source.deleteOriginals.accessibility"))
            .disabled(disabled)
            .onChange(of: deleteOriginalsAfterSidecar) {
                persistExportSettings()
            }

            if !copySourcesEnabled {
                Text("wet.source.deleteOriginals.disabledHint")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rawArchiveToggle: some View {
        Toggle(isOn: $includeRawArchive) {
            HStack(spacing: 6) {
                Text("wet.source.copyRaw.label")
                helpIcon("wet.help.source.copyRaw")
            }
        }
        .accessibilityLabel(Text("wet.source.copyRaw.accessibility"))
        .disabled(isRunning || replayModeActive)
        .onChange(of: includeRawArchive) {
            if !includeRawArchive {
                deleteOriginalsAfterSidecar = false
            }
            persistExportSettings()
        }
    }

    private var chatPartnerSelectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("wet.participants.exporter.label")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    helpIcon("wet.help.participants.exporter")
                }
                .frame(minWidth: Layout.participantsLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

                TextField(
                    exporterDetectedPlaceholder,
                    text: exporterOverrideBinding
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("wet.participants.exporter.accessibility"))
                .frame(width: Layout.chatPartnerWidth, alignment: .leading)
                .disabled(isRunning)

                if let detected = participantResolution.detectedExporter, !detected.isEmpty {
                    Menu("wet.participants.useDetected") {
                        Button(detected) {
                            updateExporterOverride(detected)
                        }
                        Divider()
                        Button("wet.participants.clearOverride") {
                            updateExporterOverride(nil)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("wet.participants.partner.label")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    helpIcon("wet.help.participants.partner")
                }
                .frame(minWidth: Layout.participantsLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

                TextField(
                    partnerDetectedPlaceholder,
                    text: partnerOverrideBinding
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("wet.participants.partner.accessibility"))
                .frame(width: Layout.chatPartnerWidth, alignment: .leading)
                .disabled(isRunning)

                if !chatPartnerCandidates.isEmpty {
                    Menu("wet.participants.useDetected") {
                        ForEach(chatPartnerCandidates, id: \.self) { name in
                            Button(name) {
                                updatePartnerOverride(name)
                            }
                        }
                        Divider()
                        Button("wet.participants.clearOverride") {
                            updatePartnerOverride(nil)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Button("wet.participants.swap") {
                    swapParticipantOverrides()
                }
                .buttonStyle(.bordered)
                .disabled(isRunning || participantResolution.chatKind == .group)

                if needsParticipantConfirmation {
                    Text("wet.participants.uncertain")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if participantResolution.chatKind == .group {
                let partners = participantResolution.effectivePartners.map { applyPhoneOverrideIfNeeded($0) }
                let count = partners.count
                let compact = partners.prefix(5).joined(separator: ", ")
                let suffix = count > 5 ? " …" : ""
                Text(String(format: String(localized: "wet.participants.groupSummary", locale: locale),
                            count,
                            "\(compact)\(suffix)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chatPartnerSelectionDisplayName: String {
        if chatPartnerSelection == Self.customChatPartnerTag {
            let trimmed = chatPartnerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "wet.participants.custom", locale: locale) : trimmed
        }
        let trimmed = chatPartnerSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let auto = autoDetectedChatPartnerName {
                return applyPhoneOverrideIfNeeded(auto)
            }
            if let fallback = chatPartnerCandidates.first {
                return applyPhoneOverrideIfNeeded(fallback)
            }
            return String(localized: "wet.participants.defaultLabel", locale: locale)
        }
        return applyPhoneOverrideIfNeeded(trimmed)
    }

    @ViewBuilder
    private var phoneOverridesSection: some View {
        if !phoneOnlyParticipants.isEmpty {
            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("wet.participants.phoneOverrides.title")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    helpIcon("wet.help.participants.phoneOverrides")
                }

                ForEach(phoneOnlyParticipants, id: \.self) { num in
                    let overrideBinding = Binding<String>(
                        get: { phoneParticipantOverrides[num] ?? "" },
                        set: { newValue in
                            phoneParticipantOverrides[num] = newValue
                        }
                    )

                    HStack(spacing: 12) {
                        Text(num)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 210, alignment: .leading)

                        TextField("wet.participants.phoneOverrides.placeholder", text: overrideBinding)
                            .textFieldStyle(.roundedBorder)
                            .aiGlow(
                                active: shouldShowPhoneSuggestionGlow(for: num),
                                isRunning: false,
                                cornerRadius: 6,
                                style: WETAIGlowStyle.defaultStyle()
                            )
                            .disabled(isRunning)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var runActionButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard !isRunning else { return }
                guard let chatURL, let outBaseURL else {
                    appendLog("ERROR: Please choose a chat export and an output folder first.")
                    return
                }
                startExport(chatURL: chatURL, outDir: outBaseURL, allowOverwrite: false)
            } label: {
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.red)
                    }
                    Label {
                        Text(isRunning ? "wet.run.exporting" : "wet.run.export")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartExport)

            let cancelButton = Button("wet.action.cancel") {
                guard isRunning, !cancelRequested else { return }
                cancelRequested = true
                exportTask?.cancel()
                appendLog("Cancel requested…")
            }
            .disabled(!isRunning || cancelRequested)

            if isRunning && !cancelRequested {
                cancelButton.buttonStyle(.borderedProminent)
            } else {
                cancelButton.buttonStyle(.bordered)
            }

            if runStatus == .completed, let exportDir = lastExportDir {
                Button("wet.run.revealFinder") {
                    revealInFinder(exportDir)
                }
                .buttonStyle(.bordered)
            }

        }
    }

    private var runSection: some View {
        WASection(title: "wet.section.run", systemImage: "play.circle") {
            VStack(alignment: .leading, spacing: 10) {
                runHeaderBar
                runTargetFolderView
                runStatusDetailView
                runProgressContainer
            }
        }
    }

    private var runHeaderBar: some View {
        HStack(alignment: .center, spacing: 12) {
            runActionButtons
            Spacer(minLength: 8)
            Text(runStatusText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
    }

    private var runTargetFolderView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("wet.run.targetFolder.label")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(targetFolderLabel.partner)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(targetFolderLabel.baseName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 32, alignment: .topLeading)
    }

    private var runProgressContainer: some View {
        let steps = displayedRunSteps
        return VStack(alignment: .leading, spacing: 6) {
            if steps.isEmpty {
                Text("wet.run.selectOutputHint")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                runProgressView(steps: steps)
            }
        }
        .frame(minHeight: runProgressMinHeight(for: max(steps.count, 1)), alignment: .topLeading)
    }

    @ViewBuilder
    private var runStatusDetailView: some View {
        switch runStatus {
        case .completed:
            if let duration = lastRunDuration {
                Text(String(format: String(localized: "wet.run.totalDuration", locale: locale),
                            Self.formatDuration(duration)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .failed:
            let summary = failureSummaryText
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("wet.run.openDiagnostics") {
                    openWindow(id: DiagnosticsLogView.windowID)
                }
                .buttonStyle(.link)
            }
        case .cancelled:
            Text("wet.run.cancelled")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func runProgressView(steps: [RunStepProgress]) -> some View {
        VStack(alignment: .leading, spacing: Layout.runRowSpacing) {
            ForEach(steps) { step in
                HStack(spacing: 6) {
                    Image(systemName: progressIconName(for: step.state))
                        .foregroundStyle(progressIconColor(for: step.state))
                    Text(step.step.localizedLabel(locale: locale))
                    Spacer()
                    Text(runStepDurationText(for: step))
                        .monospacedDigit()
                        .frame(width: Layout.runDurationWidth, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .accessibilityLabel(
                    Text(String(format: String(localized: "wet.run.step.accessibility", locale: locale),
                                step.step.localizedLabel(locale: locale),
                                step.state.localizedLabel(locale: locale),
                                runStepDurationText(for: step)))
                )
            }
        }
    }

    private func runStepDurationText(for progress: RunStepProgress) -> String {
        guard progress.state != .pending else { return "—:—" }
        guard let timing = runStepTimings[progress.step.id] else { return "—" }
        if progress.state == .running {
            guard let elapsed = timing.elapsed(now: runStepTick) else { return "—" }
            return Self.formatDuration(elapsed)
        }
        if let duration = timing.finalDuration {
            return Self.formatDuration(duration)
        }
        if let elapsed = timing.elapsed(now: runStepTick) {
            return Self.formatDuration(elapsed)
        }
        return "—"
    }

    private var displayedRunSteps: [RunStepProgress] {
        if !runProgress.isEmpty { return runProgress }
        let plan = previewRunPlan
        return plan.runSteps.map { RunStepProgress(step: $0, state: .pending) }
    }

    private var previewRunPlan: RunPlan {
        let wantsRawArchiveCopy = wantsRawArchiveCopy()
        return RunPlan(
            variants: selectedVariantsInUI,
            wantsMD: exportMarkdown,
            wantsSidecar: exportSortedAttachments,
            wantsRawArchiveCopy: wantsRawArchiveCopy
        )
    }

    private func runProgressMinHeight(for rows: Int) -> CGFloat {
        let count = max(rows, 1)
        return (CGFloat(count) * Layout.runRowHeight) + (CGFloat(max(0, count - 1)) * Layout.runRowSpacing)
    }

    private var runGlowStyle: AIGlowStyle {
        WETAIGlowStyle.logStyle()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.appIconNSImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("wet.app.title")
                    .font(.system(size: 15, weight: .semibold))
                Text("wet.app.subtitle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Phone-only participant override helpers

    /// Heuristic: treat strings without letters and with enough digits as "phone-number-like".
    private static func isPhoneNumberLike(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.range(of: "[A-Za-z]", options: .regularExpression) != nil { return false }
        let digits = t.filter { $0.isNumber }
        return digits.count >= 6
    }

    private static func normalizedPhoneKey(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        var out = ""
        out.reserveCapacity(t.count)
        for ch in t {
            if ch.isNumber {
                out.append(ch)
                continue
            }
            if ch == "+" && out.isEmpty {
                out.append(ch)
                continue
            }
        }
        if out.hasPrefix("00") {
            out = "+" + String(out.dropFirst(2))
        }
        return out
    }

    private var phoneOnlyParticipants: [String] {
        detectedParticipants
            .filter { Self.isPhoneNumberLike($0) }
            .sorted()
    }

    private func displayChatPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.path
    }

    private func displayOutputPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.path
    }

    nonisolated private static let inputSummaryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private var inputSummaryDateRangeText: String {
        guard let detectedDateRange else { return "—" }
        let start = Self.inputSummaryDateFormatter.string(from: detectedDateRange.lowerBound)
        let end = Self.inputSummaryDateFormatter.string(from: detectedDateRange.upperBound)
        return "\(start) – \(end)"
    }

    private var inputSummaryMediaCountsText: String {
        let counts = detectedMediaCounts
        if counts.total == 0 { return "—" }
        return String(
            format: String(localized: "wet.overview.mediaCounts.format", locale: locale),
            counts.images,
            counts.videos,
            counts.audios,
            counts.documents
        )
    }

    private var inputSummaryConfidenceText: String? {
        let exporter = participantResolution.exporterConfidence
        let partner = participantResolution.partnerConfidence
        if participantResolution.detectionConfidence == .low || participantResolution.detectionConfidence == .unknown {
            return String(localized: "wet.participants.confidence.needsConfirmation", locale: locale)
        }
        if participantResolution.exporterAssumed {
            return String(localized: "wet.participants.confidence.needsConfirmation", locale: locale)
        }
        if exporter == .none || partner == .none {
            return String(localized: "wet.participants.confidence.needsConfirmation", locale: locale)
        }
        if exporter == .strong && partner == .strong {
            return String(localized: "wet.participants.confidence.confident", locale: locale)
        }
        return String(localized: "wet.participants.confidence.likely", locale: locale)
    }

    private var exporterDetectedPlaceholder: String {
        detectedPlaceholderText(
            detected: participantResolution.detectedExporter,
            assumed: participantResolution.exporterAssumed && participantResolution.exporterOverride == nil
        )
    }

    private var partnerDetectedPlaceholder: String {
        detectedPlaceholderText(
            detected: participantResolution.detectedPartner,
            assumed: false
        )
    }

    private func detectedPlaceholderText(detected: String?, assumed: Bool) -> String {
        let trimmed = detected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return String(localized: "wet.detected.none", locale: locale)
        }
        if assumed {
            return String(format: String(localized: "wet.detected.assumed", locale: locale), trimmed)
        }
        return String(format: String(localized: "wet.detected.value", locale: locale), trimmed)
    }

    nonisolated static func resolveExporterFallback(
        detected: String?,
        confidence: WETParticipantConfidence
    ) -> (name: String?, confidence: WETParticipantConfidence, assumed: Bool) {
        let detectedTrimmed = detected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detectedTrimmed.isEmpty {
            return (detectedTrimmed, confidence, false)
        }
        return ("Ich", .none, true)
    }

    nonisolated static func deriveExporterFromParticipants(
        detectedExporter: String?,
        detectedPartner: String?,
        participants: [String]
    ) -> String? {
        let detectedTrimmed = detectedExporter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detectedTrimmed.isEmpty { return detectedTrimmed }
        let partnerTrimmed = detectedPartner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if partnerTrimmed.isEmpty { return nil }
        if participants.count != 2 { return nil }

        let partnerKey = normalizedKeyStatic(partnerTrimmed)
        guard !partnerKey.isEmpty else { return nil }
        let others = participants.filter { normalizedKeyStatic($0) != partnerKey }
        if others.count == 1 {
            return others[0]
        }
        return nil
    }

    nonisolated private static func normalizedKeyStatic(_ s: String) -> String {
        let filteredScalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(filteredScalars))
        let normalized = cleaned.precomposedStringWithCanonicalMapping
        return normalized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private func suggestedChatSubfolderName(
        chatURL: URL,
        chatPartner: String
    ) -> WETPartnerNaming.NormalizationResult {
        let trimmed = normalizedDisplayName(chatPartner)
        let candidate: String
        if !trimmed.isEmpty {
            candidate = trimmed
        } else if let detectedChatTitle, !detectedChatTitle.isEmpty {
            candidate = detectedChatTitle
        } else if let fromExportFolder = chatNameFromExportFolder(chatURL: chatURL) {
            candidate = fromExportFolder
        } else {
            candidate = chatPartnerCandidates.first ?? detectedParticipants.first ?? "WhatsApp Chat"
        }
        return WETPartnerNaming.normalizePartnerFolderName(candidate)
    }

    nonisolated static func runRootDirectory(
        outDir: URL,
        partnerFolderName: String,
        baseName: String
    ) -> URL {
        outDir
            .appendingPathComponent(partnerFolderName, isDirectory: true)
            .appendingPathComponent(baseName, isDirectory: true)
    }

    private func contextWithExportDir(_ context: ExportContext, exportDir: URL) -> ExportContext {
        ExportContext(
            chatURL: context.chatURL,
            outDir: context.outDir,
            partnerFolderName: context.partnerFolderName,
            exportDir: exportDir,
            tempWorkspaceURL: context.tempWorkspaceURL,
            debugEnabled: context.debugEnabled,
            allowOverwrite: context.allowOverwrite,
            isOverwriteRetry: context.isOverwriteRetry,
            preflight: context.preflight,
            prepared: context.prepared,
            baseNameOverride: context.baseNameOverride,
            exporter: context.exporter,
            chatPartner: context.chatPartner,
            chatPartners: context.chatPartners,
            chatPartnerSource: context.chatPartnerSource,
            chatPartnerFolderOverride: context.chatPartnerFolderOverride,
            exporterConfidence: context.exporterConfidence,
            partnerConfidence: context.partnerConfidence,
            exporterWasOverridden: context.exporterWasOverridden,
            partnerWasOverridden: context.partnerWasOverridden,
            wasSwapped: context.wasSwapped,
            allowPlaceholderAsMe: context.allowPlaceholderAsMe,
            chatKind: context.chatKind,
            titleNamesOverride: context.titleNamesOverride,
            detectedPartnerRaw: context.detectedPartnerRaw,
            overridePartnerRaw: context.overridePartnerRaw,
            participantDetection: context.participantDetection,
            provenance: context.provenance,
            participantNameOverrides: context.participantNameOverrides,
            selectedVariantsInOrder: context.selectedVariantsInOrder,
            plan: context.plan,
            wantsMD: context.wantsMD,
            wantsSidecar: context.wantsSidecar,
            wantsRawArchiveCopy: context.wantsRawArchiveCopy,
            wantsDeleteOriginals: context.wantsDeleteOriginals,
            htmlLabel: context.htmlLabel
        )
    }

    private func chatNameFromExportFolder(chatURL: URL) -> String? {
        let folder = normalizedDisplayName(chatURL.deletingLastPathComponent().lastPathComponent)
        guard !folder.isEmpty else { return nil }

        let lower = folder.lowercased()
        let genericNames = [
            "whatsapp chat",
            "whatsapp-chat"
        ]
        if genericNames.contains(lower) {
            return nil
        }

        let prefixes = [
            "WhatsApp Chat - ",
            "WhatsApp Chat – ",
            "WhatsApp Chat — ",
            "WhatsApp Chat with ",
            "WhatsApp Chat mit ",
            "WhatsApp-Chat - ",
            "WhatsApp-Chat – ",
            "WhatsApp-Chat — ",
            "WhatsApp-Chat with ",
            "WhatsApp-Chat mit "
        ]

        for prefix in prefixes {
            if lower.hasPrefix(prefix.lowercased()) {
                let suffix = String(folder.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return suffix.isEmpty ? nil : suffix
            }
        }

        return folder
    }

    private func normalizedDisplayName(_ s: String) -> String {
        let filteredScalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(filteredScalars))
        let normalized = cleaned.precomposedStringWithCanonicalMapping
        return normalized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func normalizedKey(_ s: String) -> String {
        normalizedDisplayName(s).lowercased()
    }

    private func isSuggestedCurrentlyShown(current: String, suggested: String?) -> Bool {
        guard let suggested else { return false }
        let currentKey = normalizedKey(current)
        guard !currentKey.isEmpty else { return false }
        let suggestedKey = normalizedKey(suggested)
        guard !suggestedKey.isEmpty else { return false }
        return currentKey == suggestedKey
    }

    private func firstMatchingParticipant(_ name: String, in list: [String]) -> String? {
        let key = normalizedKey(name)
        guard !key.isEmpty else { return nil }
        return list.first { normalizedKey($0) == key }
    }

    private func uniqueByNormalized(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(items.count)
        for item in items {
            let key = normalizedKey(item)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func groupNameFromParticipants(_ parts: [String]) -> String {
        let cleaned = parts
            .map { normalizedDisplayName($0) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty { return "Gruppe" }
        if cleaned.count <= 3 { return cleaned.joined(separator: ", ") }
        let prefix = cleaned.prefix(3).joined(separator: ", ")
        return "\(prefix) +\(cleaned.count - 3)"
    }

    private func applyPhoneOverrideIfNeeded(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let override = phoneParticipantOverrides[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        if Self.isPhoneNumberLike(trimmed) {
            let key = Self.normalizedPhoneKey(trimmed)
            if !key.isEmpty {
                for (raw, val) in phoneParticipantOverrides {
                    let cand = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cand.isEmpty { continue }
                    if Self.normalizedPhoneKey(raw) == key {
                        return cand
                    }
                }
            }
        }
        return trimmed
    }

    private func rawChatPartnerOverrideCandidate() -> String? {
        if chatPartnerCandidates.count == 1 {
            return chatPartnerCandidates[0]
        }
        if let auto = autoDetectedChatPartnerName,
           let match = firstMatchingParticipant(auto, in: chatPartnerCandidates) {
            return match
        }
        return nil
    }

    private func safeFolderName(_ s: String, maxLen: Int = 120) -> String {
        WETPartnerNaming.safeFolderName(s, maxLen: maxLen)
    }

    private func helpIcon(_ key: String) -> some View {
        HelpButton(key: key)
    }

    private var shouldShowAIGlow: Bool {
        isSuggestedCurrentlyShown(current: chatPartnerSelection, suggested: autoDetectedChatPartnerName)
    }

    private func shouldShowPhoneSuggestionGlow(for phone: String) -> Bool {
        isSuggestedCurrentlyShown(current: phoneParticipantOverrides[phone] ?? "", suggested: autoSuggestedPhoneNames[phone])
    }

#if DEBUG
    private func runAIGlowHostStateCheckIfNeeded() {
        guard !Self.didRunAIGlowHostStateCheck else { return }
        guard ProcessInfo.processInfo.environment["WET_AIGLOW_HOST_STATE_CHECK"] == "1" else { return }
        Self.didRunAIGlowHostStateCheck = true

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let suggestion = "Alice Example"
        let other = "Bob Example"

        expect(isSuggestedCurrentlyShown(current: suggestion, suggested: suggestion), "suggestion shown => glow ON")
        expect(!isSuggestedCurrentlyShown(current: other, suggested: suggestion), "user diverges => glow OFF")
        expect(isSuggestedCurrentlyShown(current: suggestion, suggested: suggestion), "revert to suggestion => glow ON")
        expect(!isSuggestedCurrentlyShown(current: "", suggested: suggestion), "empty current => glow OFF")
        expect(!isSuggestedCurrentlyShown(current: suggestion, suggested: nil), "missing suggestion => glow OFF")
        expect(isSuggestedCurrentlyShown(current: "  ALICE   EXAMPLE ", suggested: "alice example"), "normalized match => glow ON")

        if failures.isEmpty {
            print("AIGlow host state check: PASS")
        } else {
            print("AIGlow host state check: FAIL (\(failures.count))")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
#endif

    private func applyInitialWindowSizeIfNeeded() {
        guard !didSetInitialWindowSize else { return }
        didSetInitialWindowSize = true

        DispatchQueue.main.async {
            guard let screen = NSScreen.main,
                  let window = NSApplication.shared.windows.first else { return }

            let visible = screen.visibleFrame
            let targetWidth = min(visible.width, Self.designMaxWidth)
            let targetHeight = min(visible.height, Self.designMaxHeight)

            var frame = window.frame
            frame.size.width = targetWidth
            frame.size.height = targetHeight
            frame.origin.x = visible.origin.x + (visible.width - targetWidth) / 2
            frame.origin.y = visible.origin.y + (visible.height - targetHeight) / 2
            window.setFrame(frame, display: true)
            window.maxSize = NSSize(width: targetWidth, height: targetHeight)
        }
    }

    // MARK: - Pickers

    private func pickChatFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "wet.input.panel.title", locale: locale)
        panel.message = String(localized: "wet.input.panel.message", locale: locale)
        panel.prompt = String(localized: "wet.action.choose", locale: locale)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, .plainText]
        if let current = chatURL {
            panel.directoryURL = current.deletingLastPathComponent()
            panel.nameFieldStringValue = current.lastPathComponent
        }

        if panel.runModal() == .OK, let url = panel.url {
            setChatURL(url)
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "wet.output.panel.title", locale: locale)
        panel.message = String(localized: "wet.output.panel.message", locale: locale)
        panel.prompt = String(localized: "wet.action.choose", locale: locale)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowedContentTypes = [.folder]
        if let current = outBaseURL {
            panel.directoryURL = current
        }

        if panel.runModal() == .OK, let url = panel.url {
            setOutputBaseURL(url)
        }
    }

    private func setChatURL(_ url: URL?) {
        let previousPath = chatURL?.standardizedFileURL.path
        chatURLAccess?.stopAccessing()
        guard let url else {
            chatURL = nil
            chatURLAccess = nil
            replayModeActive = false
            if !isRestoringSettings { persistExportSettings() }
            Task { @MainActor in
                if previousPath != nil {
                    resetPartnerStateForNewSource()
                }
                self.resetRunStateIfIdle()
            }
            return
        }
        var resolvedURL: URL? = nil
        if let scoped = SecurityScopedURL(url: url) {
            chatURLAccess = scoped
            resolvedURL = scoped.resourceURL
            chatURL = resolvedURL
        } else {
            appendLog("WARN: Security-scoped access to the chat export could not be enabled.")
            chatURL = nil
            chatURLAccess = nil
        }
        if !isRestoringSettings {
            persistExportSettings()
        }
        Task { @MainActor in
            self.resetRunStateIfIdle()
            let currentURL = resolvedURL ?? chatURL
            let currentPath = currentURL?.standardizedFileURL.path
            if currentPath != previousPath {
                resetPartnerStateForNewSource()
                if let currentURL {
                    refreshParticipants(for: currentURL)
                }
            }
        }
    }

    private func setOutputBaseURL(_ url: URL?) {
        outBaseURLAccess?.stopAccessing()
        guard let url else {
            outBaseURL = nil
            outBaseURLAccess = nil
            if !isRestoringSettings { persistExportSettings() }
            return
        }
        if let scoped = SecurityScopedURL(url: url) {
            outBaseURLAccess = scoped
            outBaseURL = scoped.resourceURL
        } else {
            appendLog("WARN: Security-scoped access to the output folder could not be enabled.")
            outBaseURL = nil
            outBaseURLAccess = nil
        }
        if !isRestoringSettings {
            persistExportSettings()
        }
        Task { @MainActor in
            self.resetRunStateIfIdle()
        }
    }

    // MARK: - Participants

    @MainActor
    private func refreshParticipants(for inputURL: URL) {
        let snapshot: WAInputSnapshot
        do {
            snapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: inputURL)
        } catch {
            appendLog("ERROR: \(error.localizedDescription)")
            replayModeActive = false
            return
        }
        defer {
            cleanupTempWorkspace(snapshot.tempWorkspaceURL, label: "InputPipeline")
        }

        replayModeActive = snapshot.inputMode.isReplay
        if replayModeActive {
            if includeRawArchive { includeRawArchive = false }
            if deleteOriginalsAfterSidecar { deleteOriginalsAfterSidecar = false }
        }

        let chatURL = snapshot.chatURL
        do {
            let detectionSnapshot = try WhatsAppExportService.participantDetectionSnapshot(
                chatURL: chatURL,
                provenance: snapshot.provenance,
                preferredMeName: exporterName
            )
            let detection = detectionSnapshot.detection

            participantDetection = detection
            detectedChatTitle = detection.meta.groupTitle ?? detection.chatTitleCandidate
            detectedDateRange = detectionSnapshot.dateRange
            detectedMediaCounts = detectionSnapshot.mediaCounts
            switch snapshot.provenance.inputKind {
            case .folder:
                inputKindBadgeKey = "wet.input.badge.folder"
            case .zip:
                inputKindBadgeKey = "wet.input.badge.zip"
            }

            var parts = detectionSnapshot.participants
            let usedFallbackParticipant = parts.isEmpty
            if parts.isEmpty { parts = ["Me"] }
            detectedParticipants = parts

            let partnerHintRaw: String? = {
                switch detection.chatKind {
                case .group:
                    return detection.meta.groupTitle ?? detection.chatTitleCandidate ?? detection.otherPartyCandidate
                case .oneToOne:
                    return detection.otherPartyCandidate ?? detection.chatTitleCandidate
                case .unknown:
                    return detection.chatTitleCandidate ?? detection.otherPartyCandidate
                }
            }()
            let partnerHint = partnerHintRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

            let detectedMeRaw = detection.exporterSelfCandidate
            var detectedExporterRaw = detectedMeRaw.flatMap { firstMatchingParticipant($0, in: parts) } ?? detectedMeRaw
            var exporterConfidence = detection.exporterConfidence
            var detectionConfidence = detection.confidence
            let detectedPartner: String? = {
                switch detection.chatKind {
                case .group:
                    return detection.meta.groupTitle ?? detection.chatTitleCandidate ?? detection.otherPartyCandidate
                case .oneToOne:
                    return detection.otherPartyCandidate ?? detection.chatTitleCandidate
                case .unknown:
                    return detection.otherPartyCandidate ?? detection.chatTitleCandidate
                }
            }()
            if (detectedExporterRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty,
               let derived = Self.deriveExporterFromParticipants(
                   detectedExporter: detectedExporterRaw,
                   detectedPartner: detectedPartner,
                   participants: parts
               ) {
                detectedExporterRaw = derived
                exporterConfidence = .weak
                if detectionConfidence == .low {
                    detectionConfidence = .medium
                }
            }

            let exporterFallback = Self.resolveExporterFallback(
                detected: detectedExporterRaw,
                confidence: exporterConfidence
            )
            let detectedExporter = exporterFallback.name
            let detectedForResolution: String? = {
                switch detectionConfidence {
                case .high, .medium:
                    return detectedExporter
                case .low, .unknown:
                    return nil
                }
            }()

            let resolved = WhatsAppExportService.resolveParticipants(
                participants: parts,
                detectedExporter: detectedForResolution,
                detectedPartner: detectedPartner,
                partnerHint: partnerHint,
                exporterOverride: nil,
                partnerOverride: nil,
                chatKind: detection.chatKind
            )
            var resolvedExporter = resolved.exporter
            var exporterAssumed = exporterFallback.assumed
            if resolvedExporter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvedExporter = "Ich"
                exporterAssumed = true
            }

            participantResolution = ParticipantResolution(
                participantsDetected: parts,
                detectedExporter: detectedExporter,
                detectedPartner: detectedPartner,
                exporterConfidence: exporterFallback.confidence,
                partnerConfidence: detection.partnerConfidence,
                detectionConfidence: detectionConfidence,
                exporterOverride: nil,
                partnerOverride: nil,
                exporterAssumed: exporterAssumed,
                wasSwapped: false,
                chatKind: detection.chatKind,
                groupTitle: detection.meta.groupTitle,
                resolvedExporter: resolvedExporter,
                resolvedPartners: resolved.partners
            )
            if debugLoggingEnabled {
                appendLog(
                    "DEBUG: participant resolution exporter=\"\(participantResolution.effectiveExporter)\" " +
                    "partner=\"\(participantResolution.effectivePartner)\" " +
                    "swapped=\(participantResolution.wasSwapped) " +
                    "exporterConfidence=\(participantResolution.exporterConfidence.rawValue) " +
                    "partnerConfidence=\(participantResolution.partnerConfidence.rawValue) " +
                    "detectionConfidence=\(participantResolution.detectionConfidence.rawValue)"
                )
            }
            if exporterFallback.confidence == .strong,
               let detectedExporter,
               !detectedExporter.isEmpty {
                updatePersistedExporterName(detectedExporter)
            }

            // Keep overrides only for phone-number-like participants; preserve existing typed names.
            let phones = parts.filter { Self.isPhoneNumberLike($0) }
            var newOverrides: [String: String] = [:]
            for p in phones {
                newOverrides[p] = phoneParticipantOverrides[p] ?? ""
            }
            var newAutoSuggested: [String: String] = [:]
            for (phone, suggestion) in autoSuggestedPhoneNames where phones.contains(phone) {
                newAutoSuggested[phone] = suggestion
            }
            if let partnerHint, phones.count == 1, parts.count == 2 {
                let phone = phones[0]
                let existing = newOverrides[phone]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if existing.isEmpty {
                    newOverrides[phone] = partnerHint
                }
                if newAutoSuggested[phone] == nil {
                    newAutoSuggested[phone] = partnerHint
                }
            }
            if let partnerHint, parts.count == 2, let detectedExporter {
                if let partnerRaw = parts.first(where: { normalizedKey($0) != normalizedKey(detectedExporter) }),
                   Self.isPhoneNumberLike(partnerRaw) {
                    let existing = newOverrides[partnerRaw]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if existing.isEmpty {
                        newOverrides[partnerRaw] = partnerHint
                    }
                    if newAutoSuggested[partnerRaw] == nil {
                        newAutoSuggested[partnerRaw] = partnerHint
                    }
                }
            }
            phoneParticipantOverrides = newOverrides
            autoSuggestedPhoneNames = newAutoSuggested

            var candidates: [String] = []
            let isGroup = detection.chatKind == .group || parts.count > 2
            if isGroup {
                let groupName = partnerHint ?? groupNameFromParticipants(parts)
                if !groupName.isEmpty {
                    candidates = [groupName]
                }
            } else {
                let resolvedExporter = participantResolution.resolvedExporter
                if !resolvedExporter.isEmpty {
                    candidates = parts.filter { normalizedKey($0) != normalizedKey(resolvedExporter) }
                } else {
                    candidates = parts
                }
                if let partnerHint, !partnerHint.isEmpty {
                    if let partnerMatch = firstMatchingParticipant(partnerHint, in: parts) {
                        candidates.removeAll { normalizedKey($0) == normalizedKey(partnerMatch) }
                        candidates.insert(partnerMatch, at: 0)
                    } else {
                        candidates.insert(partnerHint, at: 0)
                    }
                }
            }

            candidates = uniqueByNormalized(candidates)
            if candidates.isEmpty {
                if let partnerHint, !partnerHint.isEmpty {
                    candidates = [partnerHint]
                } else if !usedFallbackParticipant, let fallback = parts.first {
                    candidates = [fallback]
                } else {
                    candidates = ["WhatsApp Chat"]
                }
            }

            chatPartnerCandidates = candidates

            var autoPartner: String? = nil
            if let partnerHint, !partnerHint.isEmpty {
                if let match = firstMatchingParticipant(partnerHint, in: candidates) {
                    autoPartner = match
                } else {
                    autoPartner = partnerHint
                }
            }
            if autoPartner == nil, candidates.count == 1 {
                autoPartner = candidates[0]
            }
            autoDetectedChatPartnerName = autoPartner

            if chatPartnerSelection != Self.customChatPartnerTag {
                let currentKey = normalizedKey(chatPartnerSelection)
                let hasCurrent = candidates.contains { normalizedKey($0) == currentKey }
                if currentKey.isEmpty || !hasCurrent {
                    if let autoPartner {
                        chatPartnerSelection = autoPartner
                    } else if let first = candidates.first {
                        chatPartnerSelection = first
                    }
                }
            }
        } catch {
            detectedParticipants = []
            participantDetection = nil
            detectedChatTitle = nil
            detectedDateRange = nil
            detectedMediaCounts = .zero
            inputKindBadgeKey = nil
            let fallbackPartner = "WhatsApp Chat"
            chatPartnerCandidates = [fallbackPartner]
            autoDetectedChatPartnerName = fallbackPartner
            if chatPartnerSelection != Self.customChatPartnerTag {
                chatPartnerSelection = fallbackPartner
            }
            participantResolution = ParticipantResolution(
                participantsDetected: [],
                detectedExporter: nil,
                detectedPartner: fallbackPartner,
                exporterConfidence: .none,
                partnerConfidence: .none,
                detectionConfidence: .low,
                exporterOverride: nil,
                partnerOverride: nil,
                exporterAssumed: false,
                wasSwapped: false,
                chatKind: .unknown,
                groupTitle: nil,
                resolvedExporter: "",
                resolvedPartners: []
            )
            autoSuggestedPhoneNames = [:]
            appendLog("WARN: Participants could not be determined. \(error)")
        }
    }

    @MainActor
    private func resetPartnerStateForNewSource() {
        if debugLoggingEnabled {
            appendLog("DEBUG: Reset chat partner state for new source.")
        }
        chatPartnerCustomName = ""
        chatPartnerSelection = ""
        chatPartnerCandidates = []
        autoDetectedChatPartnerName = nil
        detectedParticipants = []
        participantDetection = nil
        detectedChatTitle = nil
        detectedDateRange = nil
        detectedMediaCounts = .zero
        inputKindBadgeKey = nil
        participantResolution = .empty
        phoneParticipantOverrides = [:]
        autoSuggestedPhoneNames = [:]
    }

    @MainActor
    private func cleanupTempWorkspace(_ url: URL?, label: String) {
        guard let url else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            appendLog("WARN: Could not remove temp workspace (\(label)): \(url.lastPathComponent)")
        }
    }

    private var exporterOverrideBinding: Binding<String> {
        Binding(
            get: { participantResolution.exporterOverride ?? "" },
            set: { newValue in
                updateExporterOverride(newValue)
            }
        )
    }

    private var partnerOverrideBinding: Binding<String> {
        Binding(
            get: { participantResolution.partnerOverride ?? "" },
            set: { newValue in
                updatePartnerOverride(newValue)
            }
        )
    }

    private var needsParticipantConfirmation: Bool {
        if participantResolution.exporterWasOverridden || participantResolution.wasSwapped {
            return false
        }
        if participantResolution.exporterAssumed { return true }
        if participantResolution.chatKind == .group {
            return participantResolution.detectionConfidence == .low
                || participantResolution.detectionConfidence == .unknown
        }
        if participantResolution.detectionConfidence == .low || participantResolution.detectionConfidence == .unknown {
            return true
        }
        if participantResolution.exporterConfidence != .strong { return true }
        return false
    }

    private func detectedExporterForResolution() -> String? {
        switch participantResolution.detectionConfidence {
        case .high, .medium:
            return participantResolution.detectedExporter
        case .low, .unknown:
            return nil
        }
    }

    private func swapParticipantOverrides() {
        let exporter = participantResolution.effectiveExporter
        let partner = participantResolution.effectivePartner
        participantResolution.exporterOverride = normalizedOverrideValue(partner)
        participantResolution.partnerOverride = normalizedOverrideValue(exporter)
        let swappedResolved = WhatsAppExportService.resolveParticipants(
            participants: participantResolution.participantsDetected,
            detectedExporter: detectedExporterForResolution(),
            detectedPartner: participantResolution.detectedPartner,
            partnerHint: autoDetectedChatPartnerName,
            exporterOverride: participantResolution.exporterOverride,
            partnerOverride: participantResolution.partnerOverride,
            chatKind: participantResolution.chatKind
        )
        participantResolution.resolvedExporter = swappedResolved.exporter
        participantResolution.resolvedPartners = swappedResolved.partners
        participantResolution.wasSwapped = true
        if let override = participantResolution.exporterOverride {
            updatePersistedExporterName(override)
        }
    }

    private func normalizedOverrideValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed == WhatsAppExportService.exporterPlaceholderToken { return nil }
        return trimmed
    }

    private func updateExporterOverride(_ value: String?) {
        let normalized = normalizedOverrideValue(value ?? "")
        participantResolution.exporterOverride = normalized
        let resolved = WhatsAppExportService.resolveParticipants(
            participants: participantResolution.participantsDetected,
            detectedExporter: detectedExporterForResolution(),
            detectedPartner: participantResolution.detectedPartner,
            partnerHint: autoDetectedChatPartnerName,
            exporterOverride: participantResolution.exporterOverride,
            partnerOverride: participantResolution.partnerOverride,
            chatKind: participantResolution.chatKind
        )
        participantResolution.resolvedExporter = resolved.exporter
        participantResolution.resolvedPartners = resolved.partners
        if let normalized {
            updatePersistedExporterName(normalized)
        }
    }

    private func updatePartnerOverride(_ value: String?) {
        participantResolution.partnerOverride = normalizedOverrideValue(value ?? "")
        let resolved = WhatsAppExportService.resolveParticipants(
            participants: participantResolution.participantsDetected,
            detectedExporter: detectedExporterForResolution(),
            detectedPartner: participantResolution.detectedPartner,
            partnerHint: autoDetectedChatPartnerName,
            exporterOverride: participantResolution.exporterOverride,
            partnerOverride: participantResolution.partnerOverride,
            chatKind: participantResolution.chatKind
        )
        participantResolution.resolvedExporter = resolved.exporter
        participantResolution.resolvedPartners = resolved.partners
    }

    private func updatePersistedExporterName(_ value: String) {
        let normalized = normalizedDisplayName(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if normalized == exporterName { return }
        exporterName = normalized
        persistExportSettings()
    }

    private func defaultExporterName() -> String {
        let raw = NSFullUserName()
        return normalizedDisplayName(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func effectiveExporterForOutput() -> String {
        let raw = participantResolution.effectiveExporter
        let trimmed = applyPhoneOverrideIfNeeded(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return WhatsAppExportService.exporterPlaceholderDisplayName
        }
        return trimmed
    }

    private func effectivePartnerForOutput() -> String {
        let rawPartner: String = {
            if participantResolution.chatKind == .group {
                if let override = participantResolution.partnerOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !override.isEmpty {
                    return override
                }
                if let groupTitle = participantResolution.groupTitle, !groupTitle.isEmpty {
                    return groupTitle
                }
                return participantResolution.detectedPartner ?? participantResolution.effectivePartner
            }
            return participantResolution.effectivePartner
        }()
        var trimmed = applyPhoneOverrideIfNeeded(rawPartner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "Chat" }
        let exporter = applyPhoneOverrideIfNeeded(participantResolution.effectiveExporter)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !exporter.isEmpty && normalizedKey(trimmed) == normalizedKey(exporter) {
            trimmed = "Chat"
        }
        return trimmed
    }

    // MARK: - Logging

    nonisolated private func appendLog(_ s: String) {
        Task { @MainActor in
            diagnosticsLog.append(s)
        }
    }

    @MainActor
    private func clearLog() {
        diagnosticsLog.clear()
    }

    private func logExportTiming(_ label: String, startUptime: TimeInterval) {
        #if DEBUG
        let deltaMs = Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
        print("[ExportTiming] \(label) +\(deltaMs)ms")
        #else
        _ = label
        _ = startUptime
        #endif
    }

    private var canStartExport: Bool {
        !isRunning && chatURL != nil && outBaseURL != nil && !needsParticipantConfirmation
    }

    private var debugLoggingEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["WET_DEBUG_LOG"] == "1" || env["WET_DEBUG"] == "1"
    }

    private var runStatusText: String {
        switch runStatus {
        case .ready:
            return String(localized: "wet.run.status.ready", locale: locale)
        case .validating:
            return String(localized: "wet.run.status.validating", locale: locale)
        case .exporting(let step):
            return String(format: String(localized: "wet.run.status.exporting", locale: locale),
                          step.localizedLabel(locale: locale))
        case .completed:
            return String(localized: "wet.run.status.completed", locale: locale)
        case .failed:
            return String(localized: "wet.run.status.failed", locale: locale)
        case .cancelled:
            return String(localized: "wet.run.status.cancelled", locale: locale)
        }
    }

    private var failureSummaryText: String {
        if let artifact = lastRunFailureArtifact, let summary = lastRunFailureSummary {
            return String(format: String(localized: "wet.run.failure.withArtifact", locale: locale),
                          artifact,
                          summary)
        }
        if let summary = lastRunFailureSummary {
            return String(format: String(localized: "wet.run.failure.withoutArtifact", locale: locale),
                          summary)
        }
        return String(localized: "wet.run.failure.generic", locale: locale)
    }

    private func progressIconName(for state: RunStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "circle.inset.filled"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    private func progressIconColor(for state: RunStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .orange
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        }
    }

    private func buildProgressSteps(plan: RunPlan) -> [RunStepProgress] {
        plan.runSteps.map { RunStepProgress(step: $0, state: .pending) }
    }

    @MainActor
    private func updateProgress(step: RunStep, state: RunStepState) {
        guard let index = runProgress.firstIndex(where: { $0.step == step }) else { return }
        runProgress[index].state = state
        ensureRunStepTimer(active: runProgress.contains { $0.state == .running })
    }

    @MainActor
    private func markStepState(_ step: RunStep, state: RunStepState, reportedDuration: TimeInterval? = nil) {
        let now = DispatchTime.now()
        switch state {
        case .running:
            var timing = runStepTimings[step.id] ?? StepTiming()
            timing.startIfNeeded(at: now)
            timing.finalDuration = nil
            runStepTimings[step.id] = timing
            currentRunStep = step
            runStatus = .exporting(step)
        case .done, .failed, .cancelled:
            var timing = runStepTimings[step.id] ?? StepTiming()
            timing.startIfNeeded(at: now)
            timing.stop(at: now, override: reportedDuration)
            runStepTimings[step.id] = timing
            if currentRunStep == step {
                currentRunStep = nil
            }
        case .pending:
            break
        }
        updateProgress(step: step, state: state)
        runStepTick = now
    }

    @MainActor
    private func ensureRunStepTimer(active: Bool) {
        if active {
            guard runStepTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                runStepTick = DispatchTime.now()
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            runStepTimer = timer
        } else {
            runStepTimer?.invalidate()
            runStepTimer = nil
        }
    }

    @MainActor
    private func markRunFailure(summary: String, artifact: String?) {
        lastRunFailureSummary = summary
        lastRunFailureArtifact = artifact
        runStatus = .failed
    }

    @MainActor
    private func resetRunStateIfIdle() {
        guard !isRunning else { return }
        runStatus = .ready
        lastRunFailureSummary = nil
        lastRunFailureArtifact = nil
        currentRunStep = nil
        ensureRunStepTimer(active: false)
    }

    @MainActor
    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    nonisolated private static func monotonicDuration(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return TimeInterval(Double(nanos) / 1_000_000_000)
    }

    nonisolated private static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    nonisolated private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    nonisolated private static func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    @MainActor
    private func writePerfReport(
        context: ExportContext,
        baseName: String,
        runStartWall: Date,
        totalDuration: TimeInterval,
        sidecarImmutabilityWarnings: [String],
        outputSuffixArtifacts: [String]
    ) {
        #if DEBUG
        let fm = FileManager.default
        let sourcePath = URL(fileURLWithPath: #filePath)
        let repoRoot = sourcePath.deletingLastPathComponent().deletingLastPathComponent()
        let reportsDir = repoRoot.appendingPathComponent("Codex Reports", isDirectory: true)
        guard fm.fileExists(atPath: reportsDir.path) else { return }

        let snapshot = WhatsAppExportService.perfSnapshot()
        let tsFormatter = DateFormatter()
        tsFormatter.locale = Locale(identifier: "en_US_POSIX")
        tsFormatter.timeZone = TimeZone.current
        tsFormatter.dateFormat = "yyyy-MM-dd_HHmm"

        let reportName = "perf_compact_\(tsFormatter.string(from: Date())).md"
        let reportURL = reportsDir.appendingPathComponent(reportName)

        let onOff = { (value: Bool) in value ? "ON" : "OFF" }
        let artifactOrder = ["Sidecar", "Max", "Compact", "E-Mail", "Markdown"]

        var lines: [String] = []
        lines.append("# Perf Compact Report")
        lines.append("")
        lines.append("## Baseline (given)")
        lines.append("- Sidecar: 0:42")
        lines.append("- Max: 0:21")
        lines.append("- Compact: 1:37")
        lines.append("- E-Mail: 0:02")
        lines.append("- Markdown: 0:01")
        lines.append("- Total: 2:42")
        lines.append("")
        lines.append("## Run")
        lines.append("- Start: \(Self.formatClockTime(runStartWall))")
        lines.append("- Export name: \(baseName)")
        lines.append("- Target folder: \(context.exportDir.path)")
        lines.append("- Options: Max=\(onOff(context.selectedVariantsInOrder.contains(.embedAll))) " +
                     "Compact=\(onOff(context.selectedVariantsInOrder.contains(.thumbnailsOnly))) " +
                     "E-Mail=\(onOff(context.selectedVariantsInOrder.contains(.textOnly))) " +
                     "Markdown=\(onOff(context.wantsMD)) " +
                     "Sidecar=\(onOff(context.wantsSidecar)) " +
                     "RawArchive=\(onOff(context.wantsRawArchiveCopy)) " +
                     "DeleteOriginals=\(onOff(context.wantsDeleteOriginals))")
        lines.append("- Total: \(Self.formatDuration(totalDuration))")
        lines.append("")
        lines.append("## Artifact durations")
        for key in artifactOrder {
            if let duration = snapshot.artifactDurationByLabel[key] {
                lines.append("- \(key): \(Self.formatDuration(duration))")
            } else {
                lines.append("- \(key): n/a")
            }
        }
        lines.append("")
        lines.append("## Attachment Index")
        lines.append("- Builds: \(snapshot.attachmentIndexBuildCount)")
        lines.append("- Files: \(snapshot.attachmentIndexBuildFiles)")
        lines.append("- Time: \(Self.formatSeconds(snapshot.attachmentIndexBuildTime))")
        lines.append("")
        lines.append("## Thumbnails")
        lines.append("- Store: requested=\(snapshot.thumbStoreRequested) reused=\(snapshot.thumbStoreReused) generated=\(snapshot.thumbStoreGenerated) time=\(Self.formatSeconds(snapshot.thumbStoreTime))")
        lines.append("- JPEG: hits=\(snapshot.thumbJPEGCacheHits) misses=\(snapshot.thumbJPEGMisses) time=\(Self.formatSeconds(snapshot.thumbJPEGTime))")
        lines.append("- PNG: hits=\(snapshot.thumbPNGCacheHits) misses=\(snapshot.thumbPNGMisses) time=\(Self.formatSeconds(snapshot.thumbPNGTime))")
        lines.append("- Inline (Compact): hits=\(snapshot.inlineThumbCacheHits) misses=\(snapshot.inlineThumbMisses) time=\(Self.formatSeconds(snapshot.inlineThumbTime))")
        lines.append("")
        lines.append("## HTML Render/Write")
        if snapshot.htmlRenderTimeByLabel.isEmpty {
            lines.append("- Render: n/a")
        } else {
            for key in snapshot.htmlRenderTimeByLabel.keys.sorted() {
                let render = snapshot.htmlRenderTimeByLabel[key] ?? 0
                let write = snapshot.htmlWriteTimeByLabel[key] ?? 0
                let bytes = snapshot.htmlWriteBytesByLabel[key] ?? 0
                lines.append("- \(key): render=\(Self.formatSeconds(render)) write=\(Self.formatSeconds(write)) bytes=\(bytes)")
            }
        }
        lines.append("")
        lines.append("## Publish (Move)")
        if snapshot.publishTimeByLabel.isEmpty {
            lines.append("- Publish: n/a")
        } else {
            for key in snapshot.publishTimeByLabel.keys.sorted() {
                let moveTime = snapshot.publishTimeByLabel[key] ?? 0
                lines.append("- \(key): \(Self.formatSeconds(moveTime))")
            }
        }
        lines.append("")
        lines.append("## Participant Detection")
        if let detection = context.participantDetection {
            lines.append("- Chosen label: \(context.chatPartner)")
            lines.append("- Source: \(context.chatPartnerSource)")
            lines.append("- Confidence: \(detection.confidence.rawValue)")
            lines.append("- Chat kind: \(detection.chatKind.rawValue)")
            lines.append("- Chat title candidate: \(detection.chatTitleCandidate ?? "n/a")")
            lines.append("- Other party candidate: \(detection.otherPartyCandidate ?? "n/a")")
            lines.append("- Exporter self candidate: \(detection.exporterSelfCandidate ?? "n/a")")
            if detection.evidence.isEmpty {
                lines.append("- Evidence: n/a")
            } else {
                lines.append("- Evidence:")
                for item in detection.evidence.prefix(8) {
                    lines.append("  - \(item.source): \(item.excerpt)")
                }
            }
        } else {
            lines.append("- Detection: n/a")
        }
        lines.append("")
        lines.append("## Validation Notes")
        let hygieneNote = outputSuffixArtifacts.isEmpty
            ? "OK"
            : "Suffix artifacts found: \(outputSuffixArtifacts.joined(separator: ", "))"
        lines.append("- Output hygiene (no \" 2\" files, no tmp dirs): \(hygieneNote)")
        let sidecarNote: String
        if !context.wantsSidecar {
            sidecarNote = "n/a (sidecar disabled)"
        } else if sidecarImmutabilityWarnings.isEmpty {
            sidecarNote = "OK"
        } else {
            let sample = sidecarImmutabilityWarnings.prefix(5).joined(separator: ", ")
            sidecarNote = "Drift detected: \(sample)"
        }
        lines.append("- Sidecar immutability: \(sidecarNote)")
        let duplicateNote = snapshot.attachmentIndexBuildCount <= 1
            ? "OK"
            : "WARNING: duplicate work detected"
        lines.append("- No-duplicate-work check: attachment index builds=\(snapshot.attachmentIndexBuildCount) (expected 1) — \(duplicateNote)")
        lines.append("- Timestamps: normalized at sidecar step + final safety pass; mismatches logged if detected.")
        lines.append("")
        lines.append("## Known Issues / Follow-ups")
        lines.append("- n/a")

        let reportText = lines.joined(separator: "\n") + "\n"
        try? reportText.write(to: reportURL, atomically: true, encoding: .utf8)
        #endif
    }

    nonisolated private static func debugMeasure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let result = try work()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "[ExportPerf] %@: %.2fs", label, elapsed))
        return result
        #else
        return try work()
        #endif
    }

    nonisolated private static func debugMeasureAsync<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await work()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "[ExportPerf] %@: %.2fs", label, elapsed))
        return result
        #else
        return try await work()
        #endif
    }

    nonisolated private static func htmlVariantSuffix(for variant: HTMLVariant) -> String {
        WETOutputNaming.htmlVariantSuffix(for: variant.rawValue)
    }

    nonisolated private static func htmlVariantLogLabel(for variant: HTMLVariant) -> String {
        switch variant {
        case .embedAll: return "Max"
        case .thumbnailsOnly: return "Compact"
        case .textOnly: return "E-Mail"
        }
    }

    nonisolated private static func outputHTMLURL(baseName: String, variant: HTMLVariant, in dir: URL) -> URL {
        dir.appendingPathComponent(WETOutputNaming.htmlVariantFilename(baseName: baseName, rawValue: variant.rawValue))
    }

    nonisolated private static func outputMarkdownURL(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent(WETOutputNaming.markdownFilename(baseName: baseName))
    }

    nonisolated private static func outputSidecarHTML(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent(WETOutputNaming.sidecarHTMLFilename(baseName: baseName))
    }

    nonisolated private static func outputSidecarDir(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent(WETOutputNaming.sidecarFolderName(baseName: baseName), isDirectory: true)
    }

    nonisolated private static func outputRawArchiveDir(baseName: String, in dir: URL) -> URL {
        SourceOps.rawArchiveDirectory(baseName: baseName, in: dir)
    }

    nonisolated private static func outputManifestURL(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(baseName).manifest.json")
    }

    nonisolated private static func outputSHA256URL(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(baseName).sha256")
    }

    nonisolated private static func manifestArtifactRelativePaths(
        baseName: String,
        variants: [HTMLVariant],
        wantsMarkdown: Bool,
        wantsSidecar: Bool
    ) -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(variants.count + 2)
        for variant in variants {
            paths.append(WETOutputNaming.htmlVariantFilename(baseName: baseName, rawValue: variant.rawValue))
        }
        if wantsMarkdown {
            paths.append(WETOutputNaming.markdownFilename(baseName: baseName))
        }
        if wantsSidecar {
            paths.append(WETOutputNaming.sidecarHTMLFilename(baseName: baseName))
        }
        return paths
    }

    nonisolated static func replaceDeleteTargets(
        baseName: String,
        variantSuffixes: [String],
        wantsMarkdown: Bool,
        wantsSidecar: Bool,
        wantsRawArchive: Bool,
        in dir: URL,
        includeLegacy: Bool = false
    ) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        for suffix in variantSuffixes {
            let name = "\(baseName)\(suffix).html"
            if seen.insert(name).inserted {
                urls.append(dir.appendingPathComponent(name))
            }
        }

        if wantsMarkdown {
            let mdURL = outputMarkdownURL(baseName: baseName, in: dir)
            if seen.insert(mdURL.lastPathComponent).inserted {
                urls.append(mdURL)
            }
        }

        if wantsSidecar {
            let sidecarHTML = outputSidecarHTML(baseName: baseName, in: dir)
            if seen.insert(sidecarHTML.lastPathComponent).inserted {
                urls.append(sidecarHTML)
            }
            let sidecarDir = outputSidecarDir(baseName: baseName, in: dir)
            if seen.insert(sidecarDir.lastPathComponent).inserted {
                urls.append(sidecarDir)
            }
        }

        if wantsRawArchive {
            let rawDir = outputRawArchiveDir(baseName: baseName, in: dir)
            if seen.insert(rawDir.lastPathComponent).inserted {
                urls.append(rawDir)
            }
        }

        if includeLegacy {
            for variant in HTMLVariant.allCases {
                let legacyName = WETOutputNaming.legacyHTMLVariantFilename(baseName: baseName, rawValue: variant.rawValue)
                if seen.insert(legacyName).inserted {
                    urls.append(dir.appendingPathComponent(legacyName))
                }
            }
            let legacySidecarHTML = WETOutputNaming.legacySidecarHTMLFilename(baseName: baseName)
            if seen.insert(legacySidecarHTML).inserted {
                urls.append(dir.appendingPathComponent(legacySidecarHTML))
            }
            let legacySidecarDir = WETOutputNaming.legacySidecarFolderName(baseName: baseName)
            if seen.insert(legacySidecarDir).inserted {
                urls.append(dir.appendingPathComponent(legacySidecarDir, isDirectory: true))
            }
            if wantsRawArchive {
                let legacyRaw = WETOutputNaming.legacyRawFolderName
                if seen.insert(legacyRaw).inserted {
                    urls.append(dir.appendingPathComponent(legacyRaw, isDirectory: true))
                }
            }
        }

        let manifestURL = outputManifestURL(baseName: baseName, in: dir)
        if seen.insert(manifestURL.lastPathComponent).inserted {
            urls.append(manifestURL)
        }

        let shaURL = outputSHA256URL(baseName: baseName, in: dir)
        if seen.insert(shaURL.lastPathComponent).inserted {
            urls.append(shaURL)
        }

        return urls
    }

    nonisolated static func replaceDialogLabels(existingNames: [String], baseName: String, locale: Locale) -> [String] {
        let sidecarLabel = String(localized: "wet.replace.label.sidecar", locale: locale)
        let rawArchiveLabel = String(localized: "wet.replace.label.rawArchive", locale: locale)
        let manifestLabel = String(localized: "wet.replace.label.manifest", locale: locale)
        let checksumLabel = String(localized: "wet.replace.label.checksum", locale: locale)
        let maxLabel = String(localized: "wet.replace.label.max", locale: locale)
        let compactLabel = String(localized: "wet.replace.label.compact", locale: locale)
        let emailLabel = String(localized: "wet.replace.label.email", locale: locale)
        let markdownLabel = String(localized: "wet.replace.label.markdown", locale: locale)

        var labels: Set<String> = []

        func isSidecarHTML(_ name: String) -> Bool {
            guard name.hasSuffix(".html") else { return false }
            let stem = (name as NSString).deletingPathExtension
            let newStem = WETOutputNaming.sidecarBaseName(baseName: baseName)
            let legacyStem = (WETOutputNaming.legacySidecarHTMLFilename(baseName: baseName) as NSString).deletingPathExtension
            return stem.hasPrefix(newStem) || stem.hasPrefix(legacyStem)
        }

        func isVariantHTML(_ name: String, suffixes: [String]) -> Bool {
            guard name.hasSuffix(".html") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return suffixes.contains { stem.hasPrefix("\(baseName)\($0)") }
        }

        func isMarkdown(_ name: String) -> Bool {
            guard name.hasSuffix(".md") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasPrefix(baseName)
        }

        func isSidecarDir(_ name: String) -> Bool {
            guard !name.hasSuffix(".html"), !name.hasSuffix(".md") else { return false }
            if name.hasPrefix(WETOutputNaming.sourcesFolderName) || name.hasPrefix(WETOutputNaming.legacyRawFolderName) {
                return false
            }
            return name == WETOutputNaming.sidecarFolderName(baseName: baseName)
                || name == WETOutputNaming.legacySidecarFolderName(baseName: baseName)
        }

        func isRawArchive(_ name: String) -> Bool {
            return name.hasPrefix(WETOutputNaming.sourcesFolderName) || name.hasPrefix(WETOutputNaming.legacyRawFolderName)
        }

        func isManifest(_ name: String) -> Bool {
            guard name.hasSuffix(".json") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasPrefix("\(baseName).manifest")
        }

        func isChecksum(_ name: String) -> Bool {
            guard name.hasSuffix(".sha256") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasPrefix(baseName)
        }

        for name in existingNames {
            if isSidecarHTML(name) || isSidecarDir(name) {
                labels.insert(sidecarLabel)
            }
            if isRawArchive(name) {
                labels.insert(rawArchiveLabel)
            }
            if isManifest(name) {
                labels.insert(manifestLabel)
            }
            if isChecksum(name) {
                labels.insert(checksumLabel)
            }
            if isVariantHTML(
                name,
                suffixes: [WETOutputNaming.htmlVariantSuffix(for: "embedAll"), "-max"]
            ) {
                labels.insert(maxLabel)
            }
            if isVariantHTML(
                name,
                suffixes: [WETOutputNaming.htmlVariantSuffix(for: "thumbnailsOnly"), "-mid"]
            ) {
                labels.insert(compactLabel)
            }
            if isVariantHTML(
                name,
                suffixes: [WETOutputNaming.htmlVariantSuffix(for: "textOnly"), "-min"]
            ) {
                labels.insert(emailLabel)
            }
            if isMarkdown(name) {
                labels.insert(markdownLabel)
            }
        }

        let ordered = [
            sidecarLabel,
            rawArchiveLabel,
            manifestLabel,
            checksumLabel,
            maxLabel,
            compactLabel,
            emailLabel,
            markdownLabel
        ]
        return ordered.filter { labels.contains($0) }
    }

    nonisolated private static func preparedWithBaseName(
        _ prepared: WhatsAppExportService.PreparedExport,
        baseName: String
    ) -> WhatsAppExportService.PreparedExport {
        if prepared.baseName == baseName { return prepared }
        return WhatsAppExportService.PreparedExport(
            messages: prepared.messages,
            meName: prepared.meName,
            baseName: baseName,
            chatURL: prepared.chatURL
        )
    }

    nonisolated private static func stableHashHex(_ s: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    nonisolated private static func trimmedBaseNameForSuffix(
        baseName: String,
        suffix: String,
        maxLen: Int
    ) -> String {
        guard maxLen > suffix.count else { return baseName }
        let available = maxLen - suffix.count
        if baseName.count <= available { return baseName }
        var trimmed = String(baseName.prefix(available))
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? String(baseName.prefix(maxLen)) : trimmed
    }

    nonisolated private static func deterministicKeepBothBaseName(
        baseName: String,
        variants: [HTMLVariant],
        wantsMarkdown: Bool,
        wantsSidecar: Bool,
        wantsRawArchive: Bool,
        in exportDir: URL
    ) -> String? {
        let exportRoot = exportDir.standardizedFileURL
        let variantSuffixes = variants.map { htmlVariantSuffix(for: $0) }
        let seed = "\(baseName)|\(exportRoot.path)"
        let fm = FileManager.default
        for index in 1...64 {
            let hash = stableHashHex("\(seed)|\(index)")
            let token = String(hash.prefix(6))
            let suffix = " · copy \(token)"
            let trimmedBase = trimmedBaseNameForSuffix(
                baseName: baseName,
                suffix: suffix,
                maxLen: exportBaseMaxLength
            )
            let candidate = trimmedBase + suffix

            let targets = replaceDeleteTargets(
                baseName: candidate,
                variantSuffixes: variantSuffixes,
                wantsMarkdown: wantsMarkdown,
                wantsSidecar: wantsSidecar,
                wantsRawArchive: wantsRawArchive,
                in: exportRoot
            )
            var exists = false
            for url in targets where fm.fileExists(atPath: url.path) {
                exists = true
                break
            }
            if exists { continue }

            let suffixArtifacts = outputSuffixArtifacts(
                baseName: candidate,
                variants: variants,
                wantsMarkdown: wantsMarkdown,
                wantsSidecar: wantsSidecar,
                wantsRawArchive: wantsRawArchive,
                in: exportRoot
            )
            if !suffixArtifacts.isEmpty { continue }

            return candidate
        }
        return nil
    }

    nonisolated static func isSafeReplaceDeleteTarget(_ target: URL, exportDir: URL) -> Bool {
        let root = exportDir.standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let targetPath = target.standardizedFileURL.path
        return targetPath.hasPrefix(rootPrefix)
    }

    nonisolated private static func isPath(_ candidate: URL, under root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private struct SidecarTimestampSnapshot: Sendable {
        let entries: [String: FileTimestamps]
    }

    private struct FileTimestamps: Sendable {
        let created: Date?
        let modified: Date?
    }

    nonisolated private static func captureSidecarTimestampSnapshot(
        sidecarBaseDir: URL,
        maxFiles: Int = 8
    ) -> SidecarTimestampSnapshot {
        let fm = FileManager.default
        let base = sidecarBaseDir.standardizedFileURL
        guard fm.fileExists(atPath: base.path) else {
            return SidecarTimestampSnapshot(entries: [:])
        }

        func timestamps(for url: URL) -> FileTimestamps? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return FileTimestamps(
                created: attrs[.creationDate] as? Date,
                modified: attrs[.modificationDate] as? Date
            )
        }

        var entries: [String: FileTimestamps] = [:]

        let allowedDirs: Set<String> = [
            "images",
            "videos",
            "audios",
            "documents"
        ]

        if let firstLevel = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in firstLevel {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else { continue }
                let relPath = entry.lastPathComponent
                guard allowedDirs.contains(relPath) else { continue }
                if let stamp = timestamps(for: entry) {
                    entries[relPath] = stamp
                }
            }
        }

        guard let en = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return SidecarTimestampSnapshot(entries: entries)
        }

        var fileCount = 0

        for case let url as URL in en {
            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard rv?.isRegularFile == true else { continue }
            if fileCount >= maxFiles { continue }
            fileCount += 1

            let relPath = url.path.replacingOccurrences(of: base.path + "/", with: "")
            guard relPath.hasPrefix("images/")
                || relPath.hasPrefix("videos/")
                || relPath.hasPrefix("audios/")
                || relPath.hasPrefix("documents/") else {
                continue
            }
            if let stamp = timestamps(for: url) {
                entries[relPath] = stamp
            }
            if fileCount >= maxFiles { break }
        }

        return SidecarTimestampSnapshot(entries: entries)
    }

    nonisolated private static func sidecarTimestampMismatches(
        snapshot: SidecarTimestampSnapshot,
        sidecarBaseDir: URL,
        tolerance: TimeInterval = 1.0
    ) -> [String] {
        let fm = FileManager.default
        let base = sidecarBaseDir.standardizedFileURL

        func datesClose(_ a: Date?, _ b: Date?) -> Bool {
            if a == nil && b == nil { return true }
            guard let a, let b else { return false }
            return abs(a.timeIntervalSinceReferenceDate - b.timeIntervalSinceReferenceDate) <= tolerance
        }

        var mismatches: [String] = []
        for (relPath, recorded) in snapshot.entries {
            let url = relPath == "." ? base : base.appendingPathComponent(relPath)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
                mismatches.append(relPath)
                continue
            }
            let current = FileTimestamps(
                created: attrs[.creationDate] as? Date,
                modified: attrs[.modificationDate] as? Date
            )
            if !datesClose(recorded.created, current.created) || !datesClose(recorded.modified, current.modified) {
                mismatches.append(relPath)
            }
        }
        return mismatches
    }

    nonisolated private static func outputSuffixArtifacts(
        baseName: String,
        variants: [HTMLVariant],
        wantsMarkdown: Bool,
        wantsSidecar: Bool,
        wantsRawArchive: Bool,
        in dir: URL
    ) -> [String] {
        let fm = FileManager.default
        let exportDir = dir.standardizedFileURL
        guard let entries = try? fm.contentsOfDirectory(
            at: exportDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var expected: [String] = []
        for variant in variants {
            expected.append("\(baseName)\(htmlVariantSuffix(for: variant)).html")
        }
        if wantsMarkdown {
            expected.append("\(baseName).md")
        }
        if wantsSidecar {
            expected.append(WETOutputNaming.sidecarHTMLFilename(baseName: baseName))
            expected.append(WETOutputNaming.sidecarFolderName(baseName: baseName))
        }
        if wantsRawArchive {
            expected.append(WETOutputNaming.sourcesFolderName)
        }
        expected.append("\(baseName).manifest.json")
        expected.append("\(baseName).sha256")

        func isSuffixedVariant(expectedName: String, actualName: String) -> Bool {
            guard actualName != expectedName else { return false }
            let expectedURL = URL(fileURLWithPath: expectedName)
            let actualURL = URL(fileURLWithPath: actualName)
            guard expectedURL.pathExtension == actualURL.pathExtension else { return false }
            let expectedBase = expectedURL.deletingPathExtension().lastPathComponent
            let actualBase = actualURL.deletingPathExtension().lastPathComponent

            func suffixNumber(from remainder: Substring) -> Int? {
                let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.hasPrefix("("), trimmed.hasSuffix(")") {
                    let inner = trimmed.dropFirst().dropLast()
                    let digits = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let num = Int(digits), num >= 2 else { return nil }
                    return num
                }
                guard let num = Int(trimmed), num >= 2 else { return nil }
                return num
            }

            guard actualBase.hasPrefix(expectedBase) else { return false }
            let remainder = actualBase.dropFirst(expectedBase.count)
            return suffixNumber(from: remainder) != nil
        }

        var offenders: [String] = []
        for entry in entries.map(\.lastPathComponent) {
            for expectedName in expected where isSuffixedVariant(expectedName: expectedName, actualName: entry) {
                offenders.append(entry)
                break
            }
        }
        return offenders.sorted()
    }

    private func wantsRawArchiveCopy() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return includeRawArchive || env["WET_INCLUDE_RAW_ARCHIVE"] == "1"
    }

    nonisolated static func validateDeleteOriginals(copySourcesEnabled: Bool, deleteOriginalsEnabled: Bool) -> String? {
        if deleteOriginalsEnabled && !copySourcesEnabled {
            return "Löschen der Quelldaten ist nur möglich, wenn zuvor die Rohdaten (Sources) kopiert wurden."
        }
        return nil
    }

    private var selectedVariantsInUI: [HTMLVariant] {
        [
            exportHTMLMax ? .embedAll : nil,
            exportHTMLMid ? .thumbnailsOnly : nil,
            exportHTMLMin ? .textOnly : nil
        ].compactMap { $0 }
    }

    // MARK: - Export

    @MainActor
    private func startExport(
        chatURL: URL,
        outDir: URL,
        allowOverwrite: Bool,
        baseNameOverride: String? = nil,
        reusePrepared: Bool = false
    ) {
        guard !isRunning else { return }
        clearLog()
        lastRunDuration = nil
        lastRunFailureSummary = nil
        lastRunFailureArtifact = nil
        currentRunStep = nil
        lastExportDir = nil
        targetFolderLabel = .placeholder
        runProgress = []
        runStepTimings = [:]
        runStepTick = DispatchTime.now()
        ensureRunStepTimer(active: false)
        runStatus = .validating
        if reusePrepared {
            pendingPreflight = nil
        }
        if !allowOverwrite && !reusePrepared {
            pendingPreflight = nil
            pendingPreparedExport = nil
        }
        WhatsAppExportService.resetAttachmentIndexCache()
        WhatsAppExportService.resetThumbnailCaches()
        WhatsAppExportService.resetPerfMetrics()
        let t0 = ProcessInfo.processInfo.systemUptime
        logExportTiming("T0 tap", startUptime: t0)
        isRunning = true
        cancelRequested = false
        logExportTiming("T1 running-state set", startUptime: t0)

        if detectedParticipants.isEmpty {
            refreshParticipants(for: chatURL)
        }

        let resolution = participantResolution
        let detectedPartnerRaw = resolution.detectedPartner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uiChatPartnerSource: String = {
            if resolution.wasSwapped { return "swap" }
            if resolution.partnerWasOverridden { return "override" }
            return "detected"
        }()

        var participantNameOverrides: [String: String] = phoneParticipantOverrides.reduce(into: [:]) { acc, kv in
            let key = kv.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = kv.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !val.isEmpty {
                acc[key] = val
            }
        }
        if let override = resolution.exporterOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           let detected = resolution.detectedExporter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detected.isEmpty,
           normalizedKey(override) != normalizedKey(detected) {
            participantNameOverrides[detected] = override
        }
        if let override = resolution.partnerOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           let detected = resolution.detectedPartner?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detected.isEmpty,
           normalizedKey(override) != normalizedKey(detected) {
            participantNameOverrides[detected] = override
        }

        let outputChatPartner = effectivePartnerForOutput()
        let outputChatPartners = participantResolution.effectivePartners
            .map { applyPhoneOverrideIfNeeded($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let overridePartnerEffective: String? = {
            let trimmed = resolution.partnerOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }()

        let snapshot: WAInputSnapshot
        do {
            snapshot = try WhatsAppExportService.resolveInputSnapshot(
                inputURL: chatURL,
                detectedPartnerRaw: detectedPartnerRaw,
                overridePartnerRaw: overridePartnerEffective
            )
        } catch {
            appendLog("ERROR: \(error.localizedDescription)")
            markRunFailure(summary: error.localizedDescription, artifact: "Validation")
            isRunning = false
            return
        }
        var cleanupOnExit = true
        defer {
            if cleanupOnExit {
                cleanupTempWorkspace(snapshot.tempWorkspaceURL, label: "InputPipeline")
            }
        }

        let resolvedChatURL = snapshot.chatURL
        let provenance = snapshot.provenance
        let replayMode = snapshot.inputMode

        let exporter = effectiveExporterForOutput()
        let allowPlaceholderAsMe = resolution.allowPlaceholderAsMe
        let titleNamesOverride = WhatsAppExportService.conversationLabelForOutput(
            exporter: exporter,
            partners: outputChatPartners.isEmpty ? nil : outputChatPartners,
            chatKind: resolution.chatKind,
            chatURL: resolvedChatURL
        )

        let selectedVariantsInOrder = selectedVariantsInUI

        let wantsMD = exportMarkdown
        let wantsSidecar = exportSortedAttachments
        let wantsRawArchiveExplicit = wantsRawArchiveCopy()
        if let message = Self.validateDeleteOriginals(
            copySourcesEnabled: wantsRawArchiveExplicit,
            deleteOriginalsEnabled: deleteOriginalsAfterSidecar
        ) {
            appendLog("ERROR: \(message)")
            markRunFailure(summary: message, artifact: "Validation")
            isRunning = false
            return
        }
        let wantsDeleteOriginals = deleteOriginalsAfterSidecar && !replayMode.isReplay
        let wantsRawArchiveCopy = !replayMode.isReplay && wantsRawArchiveExplicit

        let htmlLabel: String = {
            var parts: [String] = []
            if exportHTMLMax { parts.append(WETOutputNaming.htmlVariantSuffix(for: "embedAll")) }
            if exportHTMLMid { parts.append(WETOutputNaming.htmlVariantSuffix(for: "thumbnailsOnly")) }
            if exportHTMLMin { parts.append(WETOutputNaming.htmlVariantSuffix(for: "textOnly")) }
            return parts.isEmpty ? "OFF" : parts.joined(separator: ", ")
        }()

        let partnerForNamingRaw = overridePartnerEffective ?? detectedPartnerRaw
        let partnerForNamingNormalized = normalizedDisplayName(partnerForNamingRaw)
        let partnerForNamingFolderName = partnerForNamingNormalized.isEmpty
            ? nil
            : WETPartnerNaming.normalizedPartnerFolderName(partnerForNamingNormalized)
        let outputChatPartnerFolderOverride = partnerForNamingFolderName

        if selectedVariantsInOrder.isEmpty && !wantsMD && !wantsSidecar {
            appendLog("ERROR: Please enable at least one output (HTML, Markdown, or Sidecar).")
            markRunFailure(summary: "Enable at least one output (HTML, Markdown, or Sidecar).", artifact: "Validation")
            isRunning = false
            return
        }

        let plan = RunPlan(
            variants: selectedVariantsInOrder,
            wantsMD: wantsMD,
            wantsSidecar: wantsSidecar,
            wantsRawArchiveCopy: wantsRawArchiveCopy
        )
        runProgress = buildProgressSteps(plan: plan)
        runStepTimings = [:]
#if DEBUG
        assert(plan.runSteps.contains(.rawArchive) == wantsRawArchiveCopy)
#endif
        
        let debugEnabled = debugLoggingEnabled
        WETLog.configure(debugEnabled: debugEnabled)
        let debugLog: (String) -> Void = { [appendLog] message in
            WETLog.dbg(message, sink: appendLog)
        }

        debugLog("UI PARTNER OVERRIDE RAW: \"\(overridePartnerEffective ?? "")\"")
        debugLog("DETECTED PARTNER RAW: \"\(detectedPartnerRaw)\"")
        debugLog("EFFECTIVE PARTNER SANITIZED: \"\(partnerForNamingFolderName ?? "")\"")
        let inputKindLabel: String = {
            switch provenance.inputKind {
            case .folder:
                return "folder"
            case .zip:
                return "zip"
            }
        }()
        let zipName = provenance.originalZipURL?.lastPathComponent ?? ""
        debugLog("PROVENANCE: inputKind=\(inputKindLabel) detectedFolder=\"\(provenance.detectedFolderURL.path)\" originalZip=\"\(zipName)\"")

        let partnerFolderNormalization = suggestedChatSubfolderName(
            chatURL: resolvedChatURL,
            chatPartner: partnerForNamingRaw
        )
        if debugEnabled && partnerFolderNormalization.didChange {
            debugLog("PARTNER DIR NORMALIZED: \"\(partnerFolderNormalization.original)\" -> \"\(partnerFolderNormalization.normalized)\"")
        }
        let partnerFolderName = partnerFolderNormalization.normalized
        debugLog("PARTNER DIR NAME: \"\(partnerFolderName)\" detected=\"\(detectedPartnerRaw)\" override=\"\(overridePartnerEffective ?? "")\" effective=\"\(partnerForNamingRaw)\"")
        targetFolderLabel = TargetFolderLabel(partner: partnerFolderName, baseName: "—")
        let partnerRoot = outDir.appendingPathComponent(partnerFolderName, isDirectory: true)
        if replayMode.isReplay, let sourcesRoot = replayMode.sourcesRoot {
            appendLog("MODE: replay_sources")
            appendLog("READ ROOT: \(sourcesRoot.path)")
            appendLog("WRITE ROOT: \(partnerRoot.path)")
            appendLog("Raw-Archive-Copy disabled (replay mode)")
            appendLog("Delete Originals disabled (replay mode)")

            if Self.isPath(outDir, under: sourcesRoot) || Self.isPath(partnerRoot, under: sourcesRoot) {
                let msg = "Output folder is inside Sources. Choose a different output location."
                appendLog("ERROR: \(msg)")
                markRunFailure(summary: msg, artifact: "Validation")
                isRunning = false
                return
            }
        }

        let isOverwriteRetry = overwriteConfirmed
        let shouldReusePrepared = reusePrepared || isOverwriteRetry
        let preflight = isOverwriteRetry ? pendingPreflight : nil
        let prepared = shouldReusePrepared ? pendingPreparedExport : nil
        overwriteConfirmed = false
        if shouldReusePrepared {
            pendingPreparedExport = nil
        }
        if isOverwriteRetry {
            pendingPreflight = nil
        }

        let context = ExportContext(
            chatURL: resolvedChatURL,
            outDir: outDir,
            partnerFolderName: partnerFolderName,
            exportDir: partnerRoot,
            tempWorkspaceURL: snapshot.tempWorkspaceURL,
            debugEnabled: debugEnabled,
            allowOverwrite: allowOverwrite,
            isOverwriteRetry: isOverwriteRetry,
            preflight: preflight,
            prepared: prepared,
            baseNameOverride: baseNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
            exporter: exporter,
            chatPartner: outputChatPartner,
            chatPartners: outputChatPartners,
            chatPartnerSource: uiChatPartnerSource,
            chatPartnerFolderOverride: outputChatPartnerFolderOverride,
            exporterConfidence: resolution.exporterConfidence,
            partnerConfidence: resolution.partnerConfidence,
            exporterWasOverridden: resolution.exporterWasOverridden,
            partnerWasOverridden: resolution.partnerWasOverridden,
            wasSwapped: resolution.wasSwapped,
            allowPlaceholderAsMe: allowPlaceholderAsMe,
            chatKind: resolution.chatKind,
            titleNamesOverride: titleNamesOverride,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerEffective,
            participantDetection: participantDetection,
            provenance: provenance,
            participantNameOverrides: participantNameOverrides,
            selectedVariantsInOrder: selectedVariantsInOrder,
            plan: plan,
            wantsMD: wantsMD,
            wantsSidecar: wantsSidecar,
            wantsRawArchiveCopy: wantsRawArchiveCopy,
            wantsDeleteOriginals: wantsDeleteOriginals,
            htmlLabel: htmlLabel
        )

        cleanupOnExit = false
        let tempWorkspaceURL = snapshot.tempWorkspaceURL
        exportTask = Task {
            logExportTiming("T2 export task enqueued", startUptime: t0)
            await runExportFlow(context: context, startUptime: t0)
            cleanupTempWorkspace(tempWorkspaceURL, label: "InputPipeline")
        }
    }

    @MainActor
    private func runExportFlow(context: ExportContext, startUptime: TimeInterval) async {
        defer {
            isRunning = false
            exportTask = nil
            cancelRequested = false
            ensureRunStepTimer(active: false)
        }

        await Task.yield()
        logExportTiming("T3 pre-processing begin", startUptime: startUptime)
        runStatus = .validating

        let append: @Sendable (String) -> Void = { [appendLog] message in
            appendLog(message)
        }
        let logger = ExportProgressLogger(append: append)
        let env = ProcessInfo.processInfo.environment
        let debugEnabled = context.debugEnabled
        let debugLog: @Sendable (String) -> Void = { [appendLog] message in
            WETLog.dbg(message, sink: appendLog)
        }
        let perfEnabled = env["WET_PERF"] == "1"

        let prepared: WhatsAppExportService.PreparedExport
        do {
            if let provided = context.prepared {
                prepared = provided
            } else {
                prepared = try await Self.debugMeasureAsync("parse chat") {
                    let parseTask = Task.detached(priority: .userInitiated) {
                        try WhatsAppExportService.prepareExport(
                            chatURL: context.chatURL,
                            meNameOverride: context.exporter,
                            participantNameOverrides: context.participantNameOverrides
                        )
                    }
                    return try await withTaskCancellationHandler {
                        try await parseTask.value
                    } onCancel: {
                        parseTask.cancel()
                    }
                }
            }
        } catch {
            logger.log("ERROR: \(error)")
            markRunFailure(summary: error.localizedDescription, artifact: "Validation")
            return
        }
        let overrideTrimmed = context.baseNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let computedBaseName = WhatsAppExportService.composeExportBaseNameForOutput(
            messages: prepared.messages,
            chatURL: prepared.chatURL,
            exporter: context.exporter,
            partner: context.chatPartner,
            chatKind: context.chatKind
        )
        let baseName = overrideTrimmed.isEmpty ? computedBaseName : overrideTrimmed
        let preparedForRun = Self.preparedWithBaseName(prepared, baseName: baseName)
        let runRoot = Self.runRootDirectory(
            outDir: context.outDir,
            partnerFolderName: context.partnerFolderName,
            baseName: baseName
        )
        let runContext = contextWithExportDir(context, exportDir: runRoot)
        targetFolderLabel = TargetFolderLabel(partner: runContext.partnerFolderName, baseName: baseName)

        let inputRoot = runContext.provenance.detectedFolderURL.standardizedFileURL
        let outputRoot = runContext.exportDir.standardizedFileURL
        if Self.isPath(inputRoot, under: outputRoot) {
            let msg = "Input folder cannot be inside the output folder."
            logger.log("ERROR: \(msg)")
            markRunFailure(summary: msg, artifact: "Validation")
            return
        }

        if let detection = context.participantDetection {
            let winner = detection.evidence.first(where: { $0.source == "decision:winner" })?.excerpt ?? "n/a"
            let rejectSummary = detection.evidence
                .filter { $0.source.hasPrefix("reject:") }
                .map { "\($0.source.replacingOccurrences(of: "reject:", with: ""))=\($0.excerpt)" }
                .joined(separator: ", ")
            debugLog("DETECTION: winner=\(winner) confidence=\(detection.confidence.rawValue) chatKind=\(detection.chatKind.rawValue)")
            debugLog("DETECTION CANDIDATES: title=\(detection.chatTitleCandidate ?? "n/a") other=\(detection.otherPartyCandidate ?? "n/a") self=\(detection.exporterSelfCandidate ?? "n/a")")
            if !rejectSummary.isEmpty {
                debugLog("DETECTION REJECTS: \(rejectSummary)")
            }
        }

        let runStartWall = Date()
        let runStartUptime = ProcessInfo.processInfo.systemUptime
        let startSuffix = context.isOverwriteRetry ? " (Replace confirmed)" : ""
        logger.log("Start: \(Self.formatClockTime(runStartWall))\(startSuffix)")
        logger.log("RUN ROOT: \(runRoot.path)")
        logger.log("Target folder: \(runContext.partnerFolderName)/\(baseName)")
        logger.log("Export name: \(baseName)")
        let onOff = { (value: Bool) in value ? "ON" : "OFF" }
        logger.log(
            "Options: Max=\(onOff(runContext.selectedVariantsInOrder.contains(.embedAll))) " +
            "Compact=\(onOff(runContext.selectedVariantsInOrder.contains(.thumbnailsOnly))) " +
            "E-Mail=\(onOff(runContext.selectedVariantsInOrder.contains(.textOnly))) " +
            "Markdown=\(onOff(runContext.wantsMD)) " +
            "Sidecar=\(onOff(runContext.wantsSidecar)) " +
            "RawArchive=\(onOff(runContext.wantsRawArchiveCopy)) " +
            "DeleteOriginals=\(onOff(runContext.wantsDeleteOriginals))"
        )
        debugLog("RUN START: \(Self.formatClockTime(runStartWall))")
        debugLog("PARTNER NAME SOURCE: \(runContext.chatPartnerSource)")
        debugLog("PARTNER NAME EFFECTIVE: \(runContext.chatPartner)")
        debugLog("RUN ROOT: \(runRoot.path)")
        debugLog("EXPORT NAME: \(baseName)")
        debugLog("OPTIONS: Max=\(onOff(runContext.selectedVariantsInOrder.contains(.embedAll))) " +
                 "Compact=\(onOff(runContext.selectedVariantsInOrder.contains(.thumbnailsOnly))) " +
                 "E-Mail=\(onOff(runContext.selectedVariantsInOrder.contains(.textOnly))) " +
                 "Markdown=\(onOff(runContext.wantsMD)) " +
                 "Sidecar=\(onOff(runContext.wantsSidecar)) " +
                 "RawArchive=\(onOff(runContext.wantsRawArchiveCopy)) " +
                 "DeleteOriginals=\(onOff(runContext.wantsDeleteOriginals))")
        if perfEnabled {
            let caps = WhatsAppExportService.concurrencyCaps()
            logger.log("WET-PERF: caps cpu=\(caps.cpu) io=\(caps.io)")
            if let cpuOverride = env["WET_MAX_CPU"] {
                logger.log("WET-PERF: WET_MAX_CPU=\(cpuOverride)")
            }
            if let ioOverride = env["WET_MAX_IO"] {
                logger.log("WET-PERF: WET_MAX_IO=\(ioOverride)")
            }
        }

        do {
            let preflight: OutputPreflight
            if let provided = runContext.preflight {
                preflight = provided
            } else {
                preflight = try await Self.debugMeasureAsync("preflight") {
                    let preflightTask = Task.detached(priority: .userInitiated) {
                        try Self.performOutputPreflight(context: runContext, baseName: baseName)
                    }
                    return try await withTaskCancellationHandler {
                        try await preflightTask.value
                    } onCancel: {
                        preflightTask.cancel()
                    }
                }

                if !preflight.existing.isEmpty, !runContext.allowOverwrite {
                    pendingPreflight = preflight
                    pendingPreparedExport = prepared
                    throw WAExportError.outputAlreadyExists(urls: preflight.existing)
                }
            }

            currentRunStep = nil
            if runContext.wantsRawArchiveCopy {
                let rawStep = RunStep.rawArchive
                markStepState(rawStep, state: .running)
                logger.log("Start \(rawStep.label)")
                let rawStart = ProcessInfo.processInfo.systemUptime
                let rawResult = try await Task.detached(priority: .utility) {
                    try SourceOps.copyRawArchive(
                        baseName: baseName,
                        exportDir: runContext.exportDir,
                        outputRoot: runContext.outDir,
                        provenance: runContext.provenance,
                        allowOverwrite: runContext.allowOverwrite,
                        debugEnabled: debugEnabled,
                        debugLog: debugLog
                    )
                }.value
                let rawDuration = ProcessInfo.processInfo.systemUptime - rawStart
                logger.log("Sources kopiert: files=\(rawResult.copiedFileCount) dirs=\(rawResult.copiedDirCount) (\(Self.formatDuration(rawDuration)))")
                markStepState(rawStep, state: .done, reportedDuration: rawDuration)
            }
            let onStepStart: @Sendable (RunStep) -> Void = { step in
                Task { @MainActor in
                    self.markStepState(step, state: .running)
                }
            }

            let onStepDone: @Sendable (RunStep, TimeInterval) -> Void = { step, duration in
                Task { @MainActor in
                    self.markStepState(step, state: .done, reportedDuration: duration)
                }
            }

            let workTask = Task.detached(priority: .userInitiated) {
                try await Self.performExportWork(
                    context: runContext,
                    baseName: preflight.baseName,
                    prepared: preparedForRun,
                    log: append,
                    debugEnabled: debugEnabled,
                    debugLog: debugLog,
                    onStepStart: onStepStart,
                    onStepDone: onStepDone
                )
            }
            let workResult = try await withTaskCancellationHandler {
                try await workTask.value
            } onCancel: {
                workTask.cancel()
            }

            lastResult = ExportResult(
                primaryHTML: workResult.primaryHTML,
                htmls: workResult.htmls,
                md: workResult.md
            )

            do {
                let checksumStart = ProcessInfo.processInfo.systemUptime
                logger.log("Start Checksums")
                let artifactPaths = Self.manifestArtifactRelativePaths(
                    baseName: baseName,
                    variants: runContext.plan.variants,
                    wantsMarkdown: runContext.wantsMD,
                    wantsSidecar: runContext.wantsSidecar
                )
                let flags = WhatsAppExportService.ManifestArtifactFlags(
                    sidecar: runContext.wantsSidecar,
                    max: runContext.plan.variants.contains(.embedAll),
                    compact: runContext.plan.variants.contains(.thumbnailsOnly),
                    email: runContext.plan.variants.contains(.textOnly),
                    markdown: runContext.wantsMD,
                    deleteOriginals: runContext.wantsDeleteOriginals,
                    rawArchive: runContext.wantsRawArchiveCopy
                )
                let resolution = WhatsAppExportService.ManifestParticipantResolution(
                    exporterConfidence: runContext.exporterConfidence,
                    partnerConfidence: runContext.partnerConfidence,
                    exporterWasOverridden: runContext.exporterWasOverridden,
                    partnerWasOverridden: runContext.partnerWasOverridden,
                    wasSwapped: runContext.wasSwapped
                )
                _ = try WhatsAppExportService.writeDeterministicManifestAndChecksums(
                    exportDir: workResult.exportDir,
                    baseName: baseName,
                    chatURL: prepared.chatURL,
                    messages: prepared.messages,
                    meName: prepared.meName,
                    artifactRelativePaths: artifactPaths,
                    flags: flags,
                    resolution: resolution,
                    allowOverwrite: runContext.allowOverwrite,
                    debugEnabled: debugEnabled,
                    debugLog: debugLog
                )
                let checksumDuration = ProcessInfo.processInfo.systemUptime - checksumStart
                logger.log("Done Checksums (\(Self.formatDuration(checksumDuration)))")
            } catch {
                logger.log("ERROR: Checksums failed: \(error)")
                throw error
            }

            if runContext.wantsDeleteOriginals {
                await offerSourceDeletionIfPossible(
                    context: runContext,
                    baseName: baseName,
                    exportDir: workResult.exportDir
                )
            }

            let totalDuration = ProcessInfo.processInfo.systemUptime - runStartUptime
            logger.log("Completed: \(Self.formatDuration(totalDuration))")
            var published: [String] = []
            if runContext.wantsSidecar { published.append("Sidecar") }
            if runContext.wantsRawArchiveCopy { published.append("Raw archive") }
            published.append(contentsOf: runContext.plan.variants.map { Self.htmlVariantLogLabel(for: $0) })
            if runContext.wantsMD { published.append("Markdown") }
            let perfSnapshot = WhatsAppExportService.perfSnapshot()
            logger.log(
                "Counters: artifacts=\(published.count) " +
                "thumbs requested=\(perfSnapshot.thumbStoreRequested) " +
                "reused=\(perfSnapshot.thumbStoreReused) " +
                "generated=\(perfSnapshot.thumbStoreGenerated) " +
                "time=\(Self.formatSeconds(perfSnapshot.thumbStoreTime))"
            )
            logger.log(
                "Counters: attachmentIndex builds=\(perfSnapshot.attachmentIndexBuildCount) " +
                "files=\(perfSnapshot.attachmentIndexBuildFiles) " +
                "time=\(Self.formatSeconds(perfSnapshot.attachmentIndexBuildTime))"
            )
            debugLog("RUN DONE: \(Self.formatDuration(totalDuration)) published=\(published.joined(separator: ", "))")
            writePerfReport(
                context: runContext,
                baseName: baseName,
                runStartWall: runStartWall,
                totalDuration: totalDuration,
                sidecarImmutabilityWarnings: workResult.sidecarImmutabilityWarnings,
                outputSuffixArtifacts: workResult.outputSuffixArtifacts
            )
            lastRunDuration = totalDuration
            lastExportDir = workResult.exportDir
            lastRunFailureSummary = nil
            lastRunFailureArtifact = nil
            currentRunStep = nil
            runStatus = .completed
        } catch {
            if error is CancellationError {
                logger.log("Cancelled.")
                if let step = currentRunStep {
                    markStepState(step, state: .cancelled)
                }
                runStatus = .cancelled
                currentRunStep = nil
                return
            }
            if let deletionError = error as? OutputDeletionError {
                logger.log("ERROR: \(deletionError.errorDescription ?? "Could not delete existing outputs.")")
                if let step = currentRunStep {
                    markStepState(step, state: .failed)
                }
                markRunFailure(summary: deletionError.errorDescription ?? "Could not delete existing outputs.", artifact: currentRunStep?.label)
                return
            }
            if let waErr = error as? WAExportError {
                switch waErr {
                case .outputAlreadyExists:
                    let exportDir = runContext.exportDir.standardizedFileURL
                    let variantSuffixes = runContext.selectedVariantsInOrder.map { Self.htmlVariantSuffix(for: $0) }
                    let replaceTargets = Self.replaceDeleteTargets(
                        baseName: baseName,
                        variantSuffixes: variantSuffixes,
                        wantsMarkdown: runContext.wantsMD,
                        wantsSidecar: runContext.wantsSidecar,
                        wantsRawArchive: runContext.wantsRawArchiveCopy,
                        in: exportDir,
                        includeLegacy: true
                    )
                    let suffixArtifacts = Self.outputSuffixArtifacts(
                        baseName: baseName,
                        variants: runContext.plan.variants,
                        wantsMarkdown: runContext.wantsMD,
                        wantsSidecar: runContext.wantsSidecar,
                        wantsRawArchive: runContext.wantsRawArchiveCopy,
                        in: exportDir
                    )
                    let fm = FileManager.default
                    let existingNames = replaceTargets
                        .filter { fm.fileExists(atPath: $0.path) }
                        .map { $0.lastPathComponent }
                        + suffixArtifacts.filter { fm.fileExists(atPath: exportDir.appendingPathComponent($0).path) }
                    replaceExistingNames = Self.replaceDialogLabels(existingNames: existingNames, baseName: baseName, locale: locale)
                    replaceOutputPath = exportDir.path
                    replaceBaseName = baseName
                    replaceExportDir = exportDir
                    showReplaceSheet = true
                    let count = replaceExistingNames.count
                    logger.log("Existing outputs found: \(count) item(s). Waiting for replace confirmation…")
                    runStatus = .ready
                    return
                case .suffixArtifactsFound(let names):
                    logger.log("ERROR: Suffix artifacts found (please clean the output folder): \(names.joined(separator: ", "))")
                    markRunFailure(summary: "Suffix artifacts found: \(names.joined(separator: ", "))", artifact: "Validation")
                    return
                }
            }
            logger.log("ERROR: \(error)")
            if let step = currentRunStep {
                markStepState(step, state: .failed)
            }
            markRunFailure(summary: error.localizedDescription, artifact: currentRunStep?.label)
        }
    }

    nonisolated private static func performOutputPreflight(context: ExportContext, baseName: String) throws -> OutputPreflight {
        let fm = FileManager.default

        var existing: [URL] = []
        let exportDir = context.exportDir.standardizedFileURL
        if let message = validateDeleteOriginals(
            copySourcesEnabled: context.wantsRawArchiveCopy,
            deleteOriginalsEnabled: context.wantsDeleteOriginals
        ) {
            throw DeleteOriginalsGuardError(message: message)
        }

        let existingNames: Set<String> = (try? fm.contentsOfDirectory(
            at: exportDir,
            includingPropertiesForKeys: nil,
            options: []
        ))?.map(\.lastPathComponent).reduce(into: Set<String>()) { $0.insert($1) } ?? []

        let mdURL = Self.outputMarkdownURL(baseName: baseName, in: exportDir)
        if existingNames.contains(mdURL.lastPathComponent) { existing.append(mdURL) }

        let sidecarDir = Self.outputSidecarDir(baseName: baseName, in: exportDir)
        if existingNames.contains(sidecarDir.lastPathComponent) { existing.append(sidecarDir) }
        let sidecarHTML = Self.outputSidecarHTML(baseName: baseName, in: exportDir)
        if existingNames.contains(sidecarHTML.lastPathComponent) { existing.append(sidecarHTML) }

        if context.wantsRawArchiveCopy {
            let rawDir = Self.outputRawArchiveDir(baseName: baseName, in: exportDir)
            if existingNames.contains(rawDir.lastPathComponent) { existing.append(rawDir) }
        }

        if context.wantsSidecar {
            let legacySidecarHTML = WETOutputNaming.legacySidecarHTMLFilename(baseName: baseName)
            if existingNames.contains(legacySidecarHTML) {
                existing.append(exportDir.appendingPathComponent(legacySidecarHTML))
            }
            let legacySidecarDir = WETOutputNaming.legacySidecarFolderName(baseName: baseName)
            if existingNames.contains(legacySidecarDir) {
                existing.append(exportDir.appendingPathComponent(legacySidecarDir, isDirectory: true))
            }
        }
        if context.wantsRawArchiveCopy {
            let legacyRaw = WETOutputNaming.legacyRawFolderName
            if existingNames.contains(legacyRaw) {
                existing.append(exportDir.appendingPathComponent(legacyRaw, isDirectory: true))
            }
        }

        let manifestURL = Self.outputManifestURL(baseName: baseName, in: exportDir)
        if existingNames.contains(manifestURL.lastPathComponent) { existing.append(manifestURL) }

        let shaURL = Self.outputSHA256URL(baseName: baseName, in: exportDir)
        if existingNames.contains(shaURL.lastPathComponent) { existing.append(shaURL) }

        for variant in context.plan.variants {
            let variantURL = Self.outputHTMLURL(baseName: baseName, variant: variant, in: exportDir)
            if existingNames.contains(variantURL.lastPathComponent) { existing.append(variantURL) }
            let legacyVariant = WETOutputNaming.legacyHTMLVariantFilename(baseName: baseName, rawValue: variant.rawValue)
            if existingNames.contains(legacyVariant) {
                existing.append(exportDir.appendingPathComponent(legacyVariant))
            }
        }

        let suffixArtifacts = Self.outputSuffixArtifacts(
            baseName: baseName,
            variants: context.plan.variants,
            wantsMarkdown: context.wantsMD,
            wantsSidecar: context.wantsSidecar,
            wantsRawArchive: context.wantsRawArchiveCopy,
            in: exportDir
        )
        if !suffixArtifacts.isEmpty {
            existing.append(contentsOf: suffixArtifacts.map { exportDir.appendingPathComponent($0) })
        }

        return OutputPreflight(baseName: baseName, existing: existing)
    }

    nonisolated private static func performExportWork(
        context: ExportContext,
        baseName: String,
        prepared: WhatsAppExportService.PreparedExport,
        log: @Sendable (String) -> Void,
        debugEnabled: Bool,
        debugLog: @Sendable (String) -> Void,
        onStepStart: @Sendable (RunStep) -> Void,
        onStepDone: @Sendable (RunStep, TimeInterval) -> Void
    ) async throws -> ExportWorkResult {
        let fm = FileManager.default
        let exportDir = context.exportDir.standardizedFileURL
        let plan = context.plan
        let env = ProcessInfo.processInfo.environment
        let perfEnabled = env["WET_PERF"] == "1"
        let verboseDebug = debugEnabled && env["WET_DEBUG_VERBOSE"] == "1"
        if debugEnabled {
            let caps = WhatsAppExportService.concurrencyCaps()
            debugLog("CONCURRENCY CAPS: cpu=\(caps.cpu) io=\(caps.io)")
            if let cpuOverride = env["WET_MAX_CPU"] {
                debugLog("CONCURRENCY OVERRIDE: WET_MAX_CPU=\(cpuOverride)")
            }
            if let ioOverride = env["WET_MAX_IO"] {
                debugLog("CONCURRENCY OVERRIDE: WET_MAX_IO=\(ioOverride)")
            }
        }

        let baseHTMLName = "\(baseName).html"

        let stagingBase = try WhatsAppExportService.localStagingBaseDirectory()
        let targetIsICloud = WhatsAppExportService.isLikelyICloudBacked(exportDir)
        if debugEnabled {
            debugLog("STAGING BASE: \(stagingBase.path)")
            debugLog("PUBLISH TARGET: \(exportDir.path)")
            debugLog("TARGET ICLOUD: \(targetIsICloud)")
        }
        if perfEnabled {
            log("WET-PERF: target_iCloud=\(targetIsICloud)")
        }

        // Prewarm D1 attachment index once per run when any artifact might need attachment resolution.
        let wantsAttachmentIndex = plan.wantsSidecar
            || plan.wantsMD
            || plan.variants.contains(where: { $0 == .embedAll || $0 == .thumbnailsOnly })
        if wantsAttachmentIndex, WhatsAppExportService.hasAnyAttachmentMarkers(messages: prepared.messages) {
            WhatsAppExportService.prewarmAttachmentIndex(for: prepared.chatURL.deletingLastPathComponent())
        }

        let wantsThumbStore = plan.wantsAnyThumbs
        var attachmentEntries: [WhatsAppExportService.AttachmentCanonicalEntry] = []
        if wantsThumbStore, WhatsAppExportService.hasAnyAttachmentMarkers(messages: prepared.messages) {
            attachmentEntries = WhatsAppExportService.buildAttachmentCanonicalEntries(
                messages: prepared.messages,
                chatSourceDir: prepared.chatURL.deletingLastPathComponent()
            )
        }

        let stagingDir = try WhatsAppExportService.createStagingDirectory(in: stagingBase)
        if debugEnabled {
            debugLog("STAGING ROOT CREATED: \(stagingDir.path)")
        }
        var didRemoveStaging = false
        var tempThumbsRoot: URL? = nil
        defer {
            if !didRemoveStaging {
                if debugEnabled {
                    debugLog("REMOVE: \(stagingDir.path)")
                }
                try? fm.removeItem(at: stagingDir)
            }
            if let tempThumbsRoot, fm.fileExists(atPath: tempThumbsRoot.path) {
                if debugEnabled {
                    debugLog("REMOVE: \(tempThumbsRoot.path)")
                }
                try? fm.removeItem(at: tempThumbsRoot)
            }
            if debugEnabled {
                debugLog("STAGING CLEANUP: \(stagingDir.path)")
            }
        }

        enum Artifact: Equatable {
            case sidecar
            case html(HTMLVariant)
            case markdown
        }

        func runStep(for artifact: Artifact) -> RunStep {
            switch artifact {
            case .sidecar:
                return .sidecar
            case .html(let variant):
                return .html(variant)
            case .markdown:
                return .markdown
            }
        }

        func artifactLabel(_ artifact: Artifact) -> String {
            runStep(for: artifact).label
        }

        func logStart(_ artifact: Artifact) {
            let step = runStep(for: artifact)
            log("Start \(step.label)")
            onStepStart(step)
        }

        func logDone(_ artifact: Artifact, duration: TimeInterval) {
            let step = runStep(for: artifact)
            log("Done \(step.label) (\(Self.formatDuration(duration)))")
            onStepDone(step, duration)
        }

        var publishCounts: [String: Int] = [:]

        func recordPublishAttempt(_ url: URL, artifact: Artifact) -> Bool {
            let key = url.standardizedFileURL.path
            let count = publishCounts[key, default: 0]
            if count > 0 {
                log("BUG: Duplicate publish blocked: \(runStep(for: artifact).label) (\(url.lastPathComponent))")
                return false
            }
            publishCounts[key] = count + 1
            return true
        }

        func ensureNonEmptyArtifact(_ url: URL, artifact: Artifact) throws {
            do {
                let rv = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if rv.isDirectory == true {
                    func hasVisibleEntry(_ dir: URL) -> Bool {
                        let direct = (try? fm.contentsOfDirectory(
                            at: dir,
                            includingPropertiesForKeys: nil,
                            options: []
                        )) ?? []
                        if direct.contains(where: { !$0.lastPathComponent.hasPrefix(".") }) {
                            return true
                        }
                        guard let en = fm.enumerator(
                            at: dir,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) else {
                            return true
                        }
                        for case let entry as URL in en where !entry.lastPathComponent.hasPrefix(".") {
                            return true
                        }
                        return false
                    }
                    let contents = try fm.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    let visibleCount = contents.filter { entry in
                        !entry.lastPathComponent.hasPrefix(".")
                    }.count
                    if visibleCount == 0 && !hasVisibleEntry(url) {
                        throw EmptyArtifactError(url: url, reason: "directory is empty")
                    }
                } else if rv.isRegularFile == true {
                    let size = rv.fileSize ?? 0
                    if size == 0 {
                        throw EmptyArtifactError(url: url, reason: "file is empty")
                    }
                } else {
                    throw EmptyArtifactError(url: url, reason: "missing output")
                }
            } catch let error as EmptyArtifactError {
                throw error
            } catch {
                throw EmptyArtifactError(url: url, reason: "unreadable output")
            }
        }

        func recursiveFileCount(at url: URL) -> Int {
            let fm = FileManager.default
            guard let en = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                return 0
            }
            var count = 0
            for case let entry as URL in en {
                let rv = try? entry.resourceValues(forKeys: [.isRegularFileKey])
                if rv?.isRegularFile == true {
                    count += 1
                }
            }
            return count
        }

        let sidecarDebugEnabled = debugEnabled

        func logSidecarTree(root: URL, label: String) {
            guard sidecarDebugEnabled else { return }
            debugLog("\(label): \(root.path)")
            let fm = FileManager.default
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                debugLog("(empty)")
                return
            }
            var paths: [String] = []
            for case let url as URL in en {
                let rel = url.path.replacingOccurrences(of: root.path, with: "")
                paths.append(rel.isEmpty ? "/" : rel)
            }
            if paths.isEmpty {
                debugLog("(empty)")
                return
            }
            for p in paths.sorted() {
                debugLog(p)
            }
        }

        func logSidecarDiagnostics(_ url: URL, label: String) {
            guard sidecarDebugEnabled else { return }
            let fm = FileManager.default
            var isDir = ObjCBool(false)
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            debugLog("\(label): \(url.path)")
            debugLog("exists=\(exists) isDir=\(isDir.boolValue)")
            guard exists else { return }

            if isDir.boolValue {
                let contents = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                )) ?? []
                let visible = contents.filter { entry in
                    !entry.lastPathComponent.hasPrefix(".")
                }
                var fallbackCount: Int = 0
                if visible.isEmpty, let en = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let entry as URL in en where !entry.lastPathComponent.hasPrefix(".") {
                        fallbackCount += 1
                        if fallbackCount >= 10 { break }
                    }
                }
                if fallbackCount > 0 {
                    debugLog("childCount=\(visible.count) fallbackCount=\(fallbackCount)")
                } else {
                    debugLog("childCount=\(visible.count)")
                }
                for child in visible.prefix(10) {
                    let isChildDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    debugLog("child \(isChildDir ? "dir" : "file"): \(child.lastPathComponent)")
                }
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                debugLog("fileSize=\(size)")
            }
        }

        func logFirstLevelEntries(_ url: URL, label: String, skipHidden: Bool) {
            guard sidecarDebugEnabled else { return }
            let fm = FileManager.default
            let options: FileManager.DirectoryEnumerationOptions = skipHidden ? [.skipsHiddenFiles] : []
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options
            )) ?? []
            debugLog("\(label): \(url.path)")
            if contents.isEmpty {
                debugLog("(empty)")
                return
            }
            for entry in contents {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                debugLog("entry \(isDir ? "dir" : "file"): \(entry.lastPathComponent)")
            }
        }

        func finalizeSidecarTimestamps(sidecarBaseDir: URL, logMismatches: Bool) {
            if debugEnabled {
                debugLog("TIMESTAMP SYNC: \(sidecarBaseDir.path)")
            }
            if attachmentEntries.isEmpty { return }
            WhatsAppExportService.normalizeSidecarMediaTimestamps(
                entries: attachmentEntries,
                sidecarBaseDir: sidecarBaseDir
            )
            if logMismatches {
                let mismatches = WhatsAppExportService.sampleSidecarMediaTimestampMismatches(
                    entries: attachmentEntries,
                    sidecarBaseDir: sidecarBaseDir,
                    maxFiles: 3
                )
                if !mismatches.isEmpty {
                    log("WARN: Zeitstempelabweichung bei \(mismatches.count) Element(en).")
                }
            }
        }

        func publishMove(
            from staged: URL,
            to final: URL,
            artifact: Artifact,
            recordLabel: String,
            movedOutputs: inout [URL]
        ) throws {
            if debugEnabled {
                debugLog("PUBLISH START: \(final.path)")
                if verboseDebug {
                    debugLog("PUBLISH STAGED: \(staged.path)")
                }
            }
            guard recordPublishAttempt(final, artifact: artifact) else {
                if debugEnabled {
                    debugLog("REMOVE: \(staged.path)")
                }
                try? fm.removeItem(at: staged)
                return
            }

            do {
                try ensureNonEmptyArtifact(staged, artifact: artifact)
            } catch let error as EmptyArtifactError {
                if sidecarDebugEnabled, artifact == .sidecar {
                    logSidecarDiagnostics(staged, label: "Sidecar publish preflight failed")
                }
                throw error
            }

            // Ensure parent exists before attempting to move/replace.
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)

            let moveStart = ProcessInfo.processInfo.systemUptime
            if fm.fileExists(atPath: final.path) {
                if context.allowOverwrite {
                    let isDir = (try? final.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let backup = final
                        .deletingLastPathComponent()
                        .appendingPathComponent(".wa_backup_\(UUID().uuidString)", isDirectory: isDir)
                    if debugEnabled {
                        debugLog("OVERWRITE: backup existing -> \(backup.path)")
                        debugLog("PUBLISH REPLACE: \(final.path)")
                    }
                    try fm.moveItem(at: final, to: backup)
                    do {
                        try fm.moveItem(at: staged, to: final)
                        try? fm.removeItem(at: backup)
                    } catch {
                        if fm.fileExists(atPath: backup.path) {
                            try? fm.moveItem(at: backup, to: final)
                        }
                        throw error
                    }
                } else {
                    throw OutputCollisionError(url: final)
                }
            } else {
                try fm.moveItem(at: staged, to: final)
            }
            let moveDuration = ProcessInfo.processInfo.systemUptime - moveStart
            WhatsAppExportService.recordPublishDuration(label: recordLabel, duration: moveDuration)
            movedOutputs.append(final)
            if debugEnabled {
                debugLog("PUBLISH OK: \(final.path)")
            }
        }

        var steps: [Artifact] = []
        if context.wantsSidecar {
            steps.append(.sidecar)
        }
        for v in plan.variants {
            steps.append(.html(v))
        }
        if context.wantsMD {
            steps.append(.markdown)
        }

        var thumbnailStore: WhatsAppExportService.ThumbnailStore? = nil

        var movedOutputs: [URL] = []
        var htmlByVariant: [HTMLVariant: URL] = [:]
        var finalMD: URL? = nil
        var finalSidecarBaseDir: URL? = nil
        var sidecarSnapshot: SidecarTimestampSnapshot? = nil
        var sidecarImmutabilityWarnings: Set<String> = []
        var stagedSidecarHTML: URL? = nil
        var stagedSidecarBaseDir: URL? = nil
        var expectedSidecarAttachments = 0
        var didPublishExternalAssets = false

        if wantsThumbStore, !context.wantsSidecar {
            let thumbContext = try await WhatsAppExportService.prepareThumbnailStoreContext(
                wantsThumbs: wantsThumbStore,
                attachmentEntries: attachmentEntries,
                mode: .temp(baseName: baseName, chatURL: prepared.chatURL, stagingBase: stagingBase)
            )
            tempThumbsRoot = thumbContext.tempRoot
            thumbnailStore = thumbContext.reader
            if debugEnabled, let tempThumbsRoot {
                let tempThumbsDir = tempThumbsRoot.appendingPathComponent("_thumbs", isDirectory: true)
                debugLog("THUMBS TEMP: \(tempThumbsDir.path)")
            }
        }

        do {
            for step in steps {
                try Task.checkCancellation()
                if debugEnabled {
                    debugLog("VARIANT START: \(artifactLabel(step))")
                }
                logStart(step)
                let stepStart = ProcessInfo.processInfo.systemUptime
                switch step {
                case .sidecar:
                    let sidecarResult = try await Self.debugMeasureAsync("generate sidecar") {
                        try await WhatsAppExportService.renderSidecar(
                            prepared: prepared,
                            outDir: stagingDir,
                            allowStagingOverwrite: true,
                            detectedPartnerRaw: context.detectedPartnerRaw,
                            overridePartnerRaw: context.overridePartnerRaw,
                            originalZipURL: context.provenance.originalZipURL,
                            attachmentEntries: attachmentEntries,
                            titleNamesOverride: context.titleNamesOverride,
                            partnerNamesOverride: context.chatPartners,
                            allowPlaceholderAsMe: context.allowPlaceholderAsMe
                        )
                    }
                    if debugEnabled {
                        let kind: String
                        switch context.provenance.inputKind {
                        case .zip:
                            kind = "zip"
                        case .folder:
                            kind = "folder"
                        }
                        let zipName = context.provenance.originalZipURL?.lastPathComponent ?? ""
                        debugLog("SIDE: provenance inputKind=\(kind) detectedFolder=\"\(context.provenance.detectedFolderURL.path)\" originalZip=\"\(zipName)\"")
                    }
                    expectedSidecarAttachments = sidecarResult.expectedAttachments
                    if debugEnabled {
                        debugLog("SIDE: expected attachments: \(expectedSidecarAttachments)")
                    }
                    stagedSidecarHTML = sidecarResult.sidecarHTML
                    stagedSidecarBaseDir = sidecarResult.sidecarBaseDir
                    if verboseDebug, let stagedSidecarHTML {
                        debugLog("STAGE PATH: \(stagedSidecarHTML.path)")
                    }

                    if expectedSidecarAttachments == 0 {
                        if debugEnabled {
                            debugLog("SIDE: no attachments; publishing HTML-only sidecar.")
                        }
                    } else {
                        guard let stagedSidecarBaseDir else {
                            throw EmptyArtifactError(
                                url: stagingDir,
                                reason: "expected attachments > 0 but sidecar assets dir is missing"
                            )
                        }
                        if debugEnabled {
                            if verboseDebug {
                                debugLog("STAGE PATH: \(stagedSidecarBaseDir.path)")
                            }
                        }
                        if debugEnabled {
                            debugLog("SIDE: create assets dir: \(stagedSidecarBaseDir.path)")
                            let fm = FileManager.default
                            let htmlExists = fm.fileExists(atPath: stagedSidecarHTML?.path ?? "")
                            debugLog("SIDE: staged HTML exists=\(htmlExists) path=\(stagedSidecarHTML?.path ?? "")")
                            var isDir = ObjCBool(false)
                            let assetsExists = fm.fileExists(atPath: stagedSidecarBaseDir.path, isDirectory: &isDir)
                            debugLog("SIDE: staged assets dir exists=\(assetsExists && isDir.boolValue) path=\(stagedSidecarBaseDir.path)")
                            let firstLevel = (try? fm.contentsOfDirectory(
                                at: stagedSidecarBaseDir,
                                includingPropertiesForKeys: [.isDirectoryKey],
                                options: [.skipsHiddenFiles]
                            )) ?? []
                            if firstLevel.isEmpty {
                                debugLog("SIDE: staging root first-level entries: (empty)")
                            } else {
                                for entry in firstLevel {
                                    debugLog("SIDE: staging entry: \(entry.lastPathComponent)")
                                }
                            }
                        }
                        logSidecarTree(root: stagedSidecarBaseDir, label: "Sidecar staging root before validation")
                        logSidecarDiagnostics(stagedSidecarBaseDir, label: "Sidecar staging dir before validation")
                        logFirstLevelEntries(stagingDir, label: "Sidecar staging root entries (all)", skipHidden: false)
                        logFirstLevelEntries(stagedSidecarBaseDir, label: "Sidecar staging dir entries (all)", skipHidden: false)
                        try ensureNonEmptyArtifact(stagedSidecarBaseDir, artifact: .sidecar)
                        try WhatsAppExportService.validateSidecarLayout(sidecarBaseDir: stagedSidecarBaseDir)
                    }
                    guard let stagedSidecarHTML else {
                        throw EmptyArtifactError(url: stagingDir, reason: "sidecar HTML missing")
                    }
                    logSidecarDiagnostics(stagedSidecarHTML, label: "Sidecar HTML before validation")
                    try ensureNonEmptyArtifact(stagedSidecarHTML, artifact: .sidecar)
                    try Task.checkCancellation()

                    if debugEnabled {
                        debugLog("VALIDATE OK: Sidecar")
                    }

                    let finalSidecarDir = Self.outputSidecarDir(baseName: baseName, in: exportDir)
                    let finalSidecarHTML = Self.outputSidecarHTML(baseName: baseName, in: exportDir)
                    if expectedSidecarAttachments > 0 {
                        guard let stagedSidecarBaseDir else {
                            throw EmptyArtifactError(url: stagingDir, reason: "sidecar assets missing")
                        }
                        logSidecarDiagnostics(stagedSidecarBaseDir, label: "Sidecar staging dir before publish")
                        if debugEnabled {
                            debugLog("PUBLISH TARGET: \(finalSidecarDir.path)")
                            if verboseDebug {
                                debugLog("PUBLISH STAGED: \(stagedSidecarBaseDir.path)")
                            }
                        }
                        try publishMove(
                            from: stagedSidecarBaseDir,
                            to: finalSidecarDir,
                            artifact: .sidecar,
                            recordLabel: artifactLabel(.sidecar),
                            movedOutputs: &movedOutputs
                        )
                        if debugEnabled {
                            debugLog("CLEANUP: staged sidecar dir moved")
                        }
                    }
                    logSidecarDiagnostics(stagedSidecarHTML, label: "Sidecar HTML before publish")
                    if debugEnabled {
                        debugLog("PUBLISH TARGET: \(finalSidecarHTML.path)")
                        if verboseDebug {
                            debugLog("PUBLISH STAGED: \(stagedSidecarHTML.path)")
                        }
                    }
                    try publishMove(
                        from: stagedSidecarHTML,
                        to: finalSidecarHTML,
                        artifact: .sidecar,
                        recordLabel: artifactLabel(.sidecar),
                        movedOutputs: &movedOutputs
                    )
                    if debugEnabled {
                        debugLog("CLEANUP: staged sidecar HTML moved")
                    }
                    if expectedSidecarAttachments > 0 {
                        finalizeSidecarTimestamps(sidecarBaseDir: finalSidecarDir, logMismatches: false)
                        finalSidecarBaseDir = finalSidecarDir
                        if wantsThumbStore, !attachmentEntries.isEmpty {
                            let thumbsDir = finalSidecarDir.appendingPathComponent("_thumbs", isDirectory: true)
                            thumbnailStore = WhatsAppExportService.ThumbnailStore(
                                entries: attachmentEntries,
                                thumbsDir: thumbsDir,
                                allowWrite: false
                            )
                            if debugEnabled {
                                debugLog("THUMBS SIDECR: \(thumbsDir.path)")
                            }
                        }
                        sidecarSnapshot = captureSidecarTimestampSnapshot(sidecarBaseDir: finalSidecarDir)
                    }
                case .html(let variant):
                    let useThumbHrefs = context.wantsSidecar && variant.thumbnailsOnly
                    let thumbRelBaseDir = useThumbHrefs ? exportDir : nil
                    let stagedHTML = try await Self.debugMeasureAsync("generate \(artifactLabel(.html(variant)))") {
                        try await WhatsAppExportService.renderHTMLPrepared(
                            prepared: prepared,
                            outDir: stagingDir,
                            fileSuffix: Self.htmlVariantSuffix(for: variant),
                            enablePreviews: variant.enablePreviews,
                            embedAttachments: variant.embedAttachments,
                            embedAttachmentThumbnailsOnly: variant.thumbnailsOnly,
                            titleNamesOverride: context.titleNamesOverride,
                            partnerNamesOverride: context.chatPartners,
                            allowPlaceholderAsMe: context.allowPlaceholderAsMe,
                            thumbnailsUseStoreHref: useThumbHrefs,
                            attachmentRelBaseDir: thumbRelBaseDir,
                            thumbnailStore: thumbnailStore,
                            perfLabel: artifactLabel(.html(variant))
                        )
                    }
                    if verboseDebug {
                        debugLog("STAGE PATH: \(stagedHTML.path)")
                    }
                    try ensureNonEmptyArtifact(stagedHTML, artifact: .html(variant))
                    try Task.checkCancellation()
                    if debugEnabled {
                        debugLog("VALIDATE OK: \(stagedHTML.path)")
                    }
                    let finalHTML = Self.outputHTMLURL(baseName: baseName, variant: variant, in: exportDir)
                    if debugEnabled {
                        debugLog("PUBLISH TARGET: \(finalHTML.path)")
                        if verboseDebug {
                            debugLog("PUBLISH STAGED: \(stagedHTML.path)")
                        }
                    }
                    try publishMove(
                        from: stagedHTML,
                        to: finalHTML,
                        artifact: .html(variant),
                        recordLabel: artifactLabel(.html(variant)),
                        movedOutputs: &movedOutputs
                    )
                    if debugEnabled {
                        debugLog("CLEANUP: staged HTML moved")
                    }
                    if !didPublishExternalAssets {
                        let publishedAssets = try WhatsAppExportService.publishExternalAssetsIfPresent(
                            stagingRoot: stagingDir,
                            exportDir: exportDir,
                            allowOverwrite: context.allowOverwrite,
                            debugEnabled: debugEnabled,
                            debugLog: debugLog
                        )
                        if !publishedAssets.isEmpty {
                            didPublishExternalAssets = true
                            if debugEnabled {
                                let publishedNames = publishedAssets.map { $0.lastPathComponent }
                                debugLog("EXTERNAL ASSETS: published \(publishedNames.joined(separator: ", "))")
                            }
                        }
                    }
                    htmlByVariant[variant] = finalHTML
                case .markdown:
                    let mdChatURL = prepared.chatURL
                    let mdAttachmentRelBaseDir: URL? = finalSidecarBaseDir != nil ? exportDir : nil
                    let mdAttachmentOverrides: [String: URL]? = {
                        guard let finalSidecarBaseDir, !attachmentEntries.isEmpty else { return nil }
                        var map: [String: URL] = [:]
                        map.reserveCapacity(attachmentEntries.count)
                        for entry in attachmentEntries {
                            map[entry.fileName] = finalSidecarBaseDir.appendingPathComponent(entry.canonicalRelPath)
                        }
                        return map
                    }()
                    let stagedMDURL = try Self.debugMeasure("generate Markdown") {
                        try WhatsAppExportService.renderMarkdown(
                            prepared: prepared,
                            outDir: stagingDir,
                            chatURLOverride: mdChatURL,
                            titleNamesOverride: context.titleNamesOverride,
                            partnerNamesOverride: context.chatPartners,
                            allowPlaceholderAsMe: context.allowPlaceholderAsMe,
                            attachmentRelBaseDir: mdAttachmentRelBaseDir,
                            attachmentOverrideByName: mdAttachmentOverrides
                        )
                    }
                    if verboseDebug {
                        debugLog("STAGE PATH: \(stagedMDURL.path)")
                    }
                    try ensureNonEmptyArtifact(stagedMDURL, artifact: .markdown)
                    try Task.checkCancellation()
                    if debugEnabled {
                        debugLog("VALIDATE OK: \(stagedMDURL.path)")
                    }
                    let finalMDURL = Self.outputMarkdownURL(baseName: baseName, in: exportDir)
                    if debugEnabled {
                        debugLog("PUBLISH TARGET: \(finalMDURL.path)")
                        if verboseDebug {
                            debugLog("PUBLISH STAGED: \(stagedMDURL.path)")
                        }
                    }
                    try publishMove(
                        from: stagedMDURL,
                        to: finalMDURL,
                        artifact: .markdown,
                        recordLabel: artifactLabel(.markdown),
                        movedOutputs: &movedOutputs
                    )
                    if debugEnabled {
                        debugLog("CLEANUP: staged Markdown moved")
                    }
                    finalMD = finalMDURL
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - stepStart
                if debugEnabled {
                    debugLog("VARIANT DONE: \(artifactLabel(step)) duration=\(Self.formatDuration(elapsed))")
                }
                logDone(step, duration: elapsed)
                WhatsAppExportService.recordArtifactDuration(label: artifactLabel(step), duration: elapsed)
                if step != .sidecar, let finalSidecarBaseDir, let snapshot = sidecarSnapshot {
                    let mismatches = sidecarTimestampMismatches(
                        snapshot: snapshot,
                        sidecarBaseDir: finalSidecarBaseDir
                    )
                    if !mismatches.isEmpty {
                        for item in mismatches {
                            sidecarImmutabilityWarnings.insert(item)
                        }
                        log("WARN: Sidecar immutability drift detected (\(mismatches.count) item(s)).")
                        finalizeSidecarTimestamps(sidecarBaseDir: finalSidecarBaseDir, logMismatches: true)
                        sidecarSnapshot = captureSidecarTimestampSnapshot(sidecarBaseDir: finalSidecarBaseDir)
                    }
                }
            }

            if let finalSidecarBaseDir {
                finalizeSidecarTimestamps(sidecarBaseDir: finalSidecarBaseDir, logMismatches: true)
            }
        } catch {
            if !(error is CancellationError) {
                for u in movedOutputs.reversed() {
                    if debugEnabled {
                        debugLog("REMOVE: \(u.path)")
                    }
                    try? fm.removeItem(at: u)
                }
            }
            throw error
        }

        if context.allowOverwrite {
            let suffixArtifacts = Self.outputSuffixArtifacts(
                baseName: baseName,
                variants: plan.variants,
                wantsMarkdown: context.wantsMD,
                wantsSidecar: context.wantsSidecar,
                wantsRawArchive: context.wantsRawArchiveCopy,
                in: exportDir
            )
            if !suffixArtifacts.isEmpty {
                log("INFO: Cleaning suffix artifacts: \(suffixArtifacts.joined(separator: ", "))")
                if debugEnabled {
                    debugLog("OVERWRITE: cleaning suffix artifacts count=\(suffixArtifacts.count)")
                }
            }
            for name in suffixArtifacts {
                let target = exportDir.appendingPathComponent(name).standardizedFileURL
                guard Self.isSafeReplaceDeleteTarget(target, exportDir: exportDir) else {
                    continue
                }
                guard fm.fileExists(atPath: target.path) else { continue }
                if debugEnabled {
                    debugLog("REMOVE: \(target.path)")
                }
                try? fm.removeItem(at: target)
            }
        }

        if debugEnabled {
            debugLog("REMOVE: \(stagingDir.path)")
        }
        try? fm.removeItem(at: stagingDir)
        didRemoveStaging = true

        let htmls: [URL] = plan.variants.compactMap { htmlByVariant[$0] }
        let primaryHTML: URL? = htmlByVariant[.embedAll] ?? htmls.first

        let suffixArtifacts = Self.outputSuffixArtifacts(
            baseName: baseName,
            variants: plan.variants,
            wantsMarkdown: context.wantsMD,
            wantsSidecar: context.wantsSidecar,
            wantsRawArchive: context.wantsRawArchiveCopy,
            in: exportDir
        )
        if !suffixArtifacts.isEmpty {
            throw WAExportError.suffixArtifactsFound(names: suffixArtifacts)
        }

        if debugEnabled, let finalSidecarBaseDir {
            let thumbsDir = finalSidecarBaseDir.appendingPathComponent("_thumbs", isDirectory: true)
            var isDir = ObjCBool(false)
            let exists = fm.fileExists(atPath: thumbsDir.path, isDirectory: &isDir)
            let count = (exists && isDir.boolValue) ? recursiveFileCount(at: thumbsDir) : 0
            debugLog("SIDECAR THUMBS FINAL: exists=\(exists && isDir.boolValue) fileCount=\(count) path=\(thumbsDir.path)")
        }

        return ExportWorkResult(
            exportDir: exportDir,
            baseHTMLName: baseHTMLName,
            htmls: htmls,
            md: finalMD,
            primaryHTML: primaryHTML,
            sidecarImmutabilityWarnings: sidecarImmutabilityWarnings.sorted(),
            outputSuffixArtifacts: suffixArtifacts
        )
    }

    @MainActor
    private func offerSourceDeletionIfPossible(
        context: ExportContext,
        baseName: String,
        exportDir: URL
    ) async {
        let verification = await Task.detached(priority: .utility) {
            SourceOps.verifyRawArchive(
                baseName: baseName,
                exportDir: exportDir,
                provenance: context.provenance
            )
        }.value

        let candidates = verification.deletableOriginals
        if candidates.isEmpty {
            return
        }

        deleteOriginalCandidates = candidates
        deleteOriginalTempWorkspaceURL = context.tempWorkspaceURL
        showDeleteOriginalsAlert = true
    }

    @MainActor
    private func deleteOriginalItems(_ items: [URL], tempWorkspaceURL: URL?) async {
        let result = await Task.detached(priority: .utility) {
            SourceOps.deleteOriginalItems(items, tempWorkspaceURL: tempWorkspaceURL)
        }.value

        let failed = result.failed
        if !failed.isEmpty {
            appendLog("ERROR: Delete failed: \(failed.map { $0.path }.joined(separator: ", "))")
        }
    }

    private func restorePersistedSettings() {
        guard let snapshot = WETExportSettingsStorage.shared.load() else {
            if exporterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                exporterName = defaultExporterName()
            }
            return
        }
        isRestoringSettings = true
        defer {
            isRestoringSettings = false
            persistExportSettings()
        }

        exportHTMLMax = snapshot.exportHTMLMax
        exportHTMLMid = snapshot.exportHTMLMid
        exportHTMLMin = snapshot.exportHTMLMin
        exportMarkdown = snapshot.exportMarkdown
        exportSortedAttachments = snapshot.exportSortedAttachments
        includeRawArchive = snapshot.includeRawArchive
        deleteOriginalsAfterSidecar = snapshot.deleteOriginalsAfterSidecar
        exporterName = snapshot.exporterName ?? ""
        if exporterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            exporterName = defaultExporterName()
        }

        if let chatBookmark = snapshot.chatBookmark {
            if let url = resolveBookmark(chatBookmark, expectDirectory: false) {
                setChatURL(url)
            } else {
                appendLog("WARN: Last chat export is no longer available. Please reselect it.")
                setChatURL(nil)
            }
        }

        if let outputBookmark = snapshot.outputBookmark {
            if let url = resolveBookmark(outputBookmark, expectDirectory: true) {
                setOutputBaseURL(url)
            } else {
                appendLog("WARN: Last output folder is no longer available. Please reselect it.")
                setOutputBaseURL(nil)
            }
        }
    }

    private func persistExportSettings() {
        guard !isRestoringSettings else { return }
        let exporterNameSnapshot: String? = {
            let trimmed = normalizedDisplayName(exporterName).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let snapshot = WETExportSettingsSnapshot(
            schemaVersion: WETExportSettingsSnapshot.currentVersion,
            chatBookmark: bookmarkData(for: chatURL),
            outputBookmark: bookmarkData(for: outBaseURL),
            exportHTMLMax: exportHTMLMax,
            exportHTMLMid: exportHTMLMid,
            exportHTMLMin: exportHTMLMin,
            exportMarkdown: exportMarkdown,
            exportSortedAttachments: exportSortedAttachments,
            includeRawArchive: includeRawArchive,
            deleteOriginalsAfterSidecar: deleteOriginalsAfterSidecar,
            exporterName: exporterNameSnapshot
        )
        WETExportSettingsStorage.shared.save(snapshot)
    }

    private func bookmarkData(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data, expectDirectory: Bool) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists { return nil }
        if expectDirectory && !isDirectory.boolValue { return nil }
        if !expectDirectory && isDirectory.boolValue { return nil }
        _ = stale
        return url
    }
}

// MARK: - Helpers (file-level)

private struct WASection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct HelpButton: View {
    let key: String
    @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.de.rawValue
    @State private var isPresented = false

    private var localizedBundle: Bundle {
        guard let path = Bundle.main.path(forResource: appLanguageRaw, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(localizedBundle.localizedString(forKey: key, value: nil, table: nil))
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .accessibilityLabel(Text("wet.help.accessibility"))
    }
}

private struct WACard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return content
            .padding(10)
            .background(
                ZStack {
                    // Color tint layer (WhatsApp palette) — very light so the watermark can shine through
                    shape
                        .fill(ContentView.cardTintGradient)
                        .opacity(0.06)

                    // Glass layer — significantly more transparent so the background watermark is clearly visible
                    shape
                        .fill(.ultraThinMaterial)
                        .opacity(0.16)
                }
            )
            .overlay(
                shape
                    .stroke(ContentView.waGreen.opacity(0.05), lineWidth: 1)
            )
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

extension View {
    func waCard() -> some View {
        modifier(WACard())
    }
}

private final class SecurityScopedURL {
    private let url: URL
    private var isAccessing: Bool = false

    var resourceURL: URL { url }

    init?(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
        self.isAccessing = true
    }

    func stopAccessing() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit {
        stopAccessing()
    }
}

private struct WETExportSettingsSnapshot: Codable {
    static let currentVersion = 4

    let schemaVersion: Int
    let chatBookmark: Data?
    let outputBookmark: Data?
    let exportHTMLMax: Bool
    let exportHTMLMid: Bool
    let exportHTMLMin: Bool
    let exportMarkdown: Bool
    let exportSortedAttachments: Bool
    let includeRawArchive: Bool
    let deleteOriginalsAfterSidecar: Bool
    let exporterName: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case chatBookmark
        case outputBookmark
        case exportHTMLMax
        case exportHTMLMid
        case exportHTMLMin
        case exportMarkdown
        case exportSortedAttachments
        case includeRawArchive
        case deleteOriginalsAfterSidecar
        case exporterName
    }

    init(
        schemaVersion: Int,
        chatBookmark: Data?,
        outputBookmark: Data?,
        exportHTMLMax: Bool,
        exportHTMLMid: Bool,
        exportHTMLMin: Bool,
        exportMarkdown: Bool,
        exportSortedAttachments: Bool,
        includeRawArchive: Bool,
        deleteOriginalsAfterSidecar: Bool,
        exporterName: String?
    ) {
        self.schemaVersion = schemaVersion
        self.chatBookmark = chatBookmark
        self.outputBookmark = outputBookmark
        self.exportHTMLMax = exportHTMLMax
        self.exportHTMLMid = exportHTMLMid
        self.exportHTMLMin = exportHTMLMin
        self.exportMarkdown = exportMarkdown
        self.exportSortedAttachments = exportSortedAttachments
        self.includeRawArchive = includeRawArchive
        self.deleteOriginalsAfterSidecar = deleteOriginalsAfterSidecar
        self.exporterName = exporterName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1
        chatBookmark = try? container.decode(Data.self, forKey: .chatBookmark)
        outputBookmark = try? container.decode(Data.self, forKey: .outputBookmark)
        exportHTMLMax = (try? container.decode(Bool.self, forKey: .exportHTMLMax)) ?? true
        exportHTMLMid = (try? container.decode(Bool.self, forKey: .exportHTMLMid)) ?? true
        exportHTMLMin = (try? container.decode(Bool.self, forKey: .exportHTMLMin)) ?? true
        exportMarkdown = (try? container.decode(Bool.self, forKey: .exportMarkdown)) ?? true
        exportSortedAttachments = (try? container.decode(Bool.self, forKey: .exportSortedAttachments)) ?? true
        includeRawArchive = (try? container.decode(Bool.self, forKey: .includeRawArchive)) ?? false
        deleteOriginalsAfterSidecar = (try? container.decode(Bool.self, forKey: .deleteOriginalsAfterSidecar)) ?? false
        exporterName = try? container.decode(String.self, forKey: .exporterName)
    }
}

private final class WETExportSettingsStorage {
    static let shared = WETExportSettingsStorage()

    private let defaults = UserDefaults.standard
    private let storageKey = "wet.exportSettings"

    func load() -> WETExportSettingsSnapshot? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WETExportSettingsSnapshot.self, from: data)
    }

    func save(_ snapshot: WETExportSettingsSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
