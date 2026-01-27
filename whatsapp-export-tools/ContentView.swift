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
        let exportDir: URL
        let allowOverwrite: Bool
        let isOverwriteRetry: Bool
        let preflight: OutputPreflight?
        let prepared: WhatsAppExportService.PreparedExport?
        let exporter: String
        let chatPartner: String
        let chatPartnerSource: String
        let chatPartnerFolderOverride: String?
        let detectedPartnerRaw: String
        let overridePartnerRaw: String?
        let participantDetection: WAParticipantDetectionResult?
        let provenance: WETSourceProvenance
        let participantNameOverrides: [String: String]
        let selectedVariantsInOrder: [HTMLVariant]
        let plan: RunPlan
        let wantsMD: Bool
        let wantsSidecar: Bool
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

    private struct RunPlan: Sendable {
        let variants: [HTMLVariant]
        let wantsMD: Bool
        let wantsSidecar: Bool

        nonisolated var variantSuffixes: [String] {
            variants.map { ContentView.htmlVariantSuffix(for: $0) }
        }

        nonisolated var wantsAnyThumbs: Bool {
            wantsSidecar || variants.contains(where: { $0 == .embedAll || $0 == .thumbnailsOnly })
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
            "Konnte vorhandene Ausgabe nicht löschen: \(url.lastPathComponent)"
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
    private static let labelWidth: CGFloat = 110
    private static let designMaxWidth: CGFloat = 1440
    private static let designMaxHeight: CGFloat = 900
    private static let optionsColumnMaxWidth: CGFloat = 480
    private static let aiMenuBadgeImage: NSImage = AIGlowPalette.menuBadgeImage
    private static let logLineHeight: CGFloat = 17
    private static let logPadLinesPerSide: Int = 1
    private static let logSectionVerticalPadding: CGFloat = 16
    private static let logMinLinesContent: Int = 8

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
                return "Maximal: Alles einbetten (größte Datei)"
            case .thumbnailsOnly:
                return "Mittel: Nur Thumbnails einbetten"
            case .textOnly:
                return "Minimal: Nur Text (keine Linkvorschauen, keine Thumbnails)"
            }
        }

        var logLabel: String {
            switch self {
            case .embedAll:
                return "Max"
            case .thumbnailsOnly:
                return "Kompakt"
            case .textOnly:
                return "E-Mail"
            }
        }
        
        /// Suffix appended to the HTML filename (before extension)
        var fileSuffix: String {
            switch self {
            case .embedAll: return "-max"
            case .thumbnailsOnly: return "-mid"
            case .textOnly: return "-min"
            }
        }

        /// Whether to fetch/render online link previews.
        /// Per requirement: disabled only for the minimal text-only variant.
        var enablePreviews: Bool {
            switch self {
            case .textOnly: return false
            case .embedAll, .thumbnailsOnly: return true
            }
        }

        /// Whether to embed any attachment representation into the HTML.
        var embedAttachments: Bool {
            switch self {
            case .textOnly: return false
            case .embedAll, .thumbnailsOnly: return true
            }
        }

        /// If attachments are embedded, whether to embed thumbnails only (no full attachment payload).
        var thumbnailsOnly: Bool {
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

    // Independent export toggles (default: all enabled)
    @State private var exportHTMLMax: Bool = true
    @State private var exportHTMLMid: Bool = true
    @State private var exportHTMLMin: Bool = true
    @State private var exportMarkdown: Bool = true

    // NEW: Optional "Sidecar" folder export (sorted attachments) next to the HTML/MD export.
    // IMPORTANT: HTML outputs must remain standalone and must NOT depend on the Sidecar folder.
    @State private var exportSortedAttachments: Bool = true
    @State private var deleteOriginalsAfterSidecar: Bool = false
    @State private var wetDebugLoggingEnabled: Bool = false

    @State private var detectedParticipants: [String] = []
    @State private var chatPartnerCandidates: [String] = []
    @State private var chatPartnerSelection: String = ""
    @State private var chatPartnerCustomName: String = ""
    @State private var autoDetectedChatPartnerName: String? = nil
    @State private var exporterName: String = ""
    @State private var participantDetection: WAParticipantDetectionResult? = nil
    @State private var detectedChatTitle: String? = nil
    @State private var detectedDateRange: ClosedRange<Date>? = nil
    @State private var detectedMediaCounts: WAMediaCounts = .zero
    @State private var inputKindBadge: String? = nil

    // Optional overrides for participants that appear only as phone numbers in the WhatsApp export
    // Key = phone-number-like participant string as it appears in the export; Value = user-provided display name
    @State private var phoneParticipantOverrides: [String: String] = [:]
    @State private var autoSuggestedPhoneNames: [String: String] = [:]

    @State private var isRunning: Bool = false
    @State private var logText: String = ""
    @State private var logLines: [String] = []
    @State private var logAutoScrollWorkItem: DispatchWorkItem? = nil

    @State private var showReplaceAlert: Bool = false
    @State private var replaceExistingNames: [String] = []
    @State private var overwriteConfirmed: Bool = false
    @State private var pendingPreflight: OutputPreflight? = nil
    @State private var pendingPreparedExport: WhatsAppExportService.PreparedExport? = nil
    @State private var showDeleteOriginalsAlert: Bool = false
    @State private var deleteOriginalCandidates: [URL] = []
    @State private var didSetInitialWindowSize: Bool = false
    @State private var exportTask: Task<Void, Never>? = nil
    @State private var cancelRequested: Bool = false

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
        .alert("Datei bereits vorhanden", isPresented: $showReplaceAlert) {
            Button("Abbrechen", role: .cancel) { }
            Button("Ersetzen") {
                guard let chatURL, let outBaseURL else { return }
                overwriteConfirmed = true
                startExport(chatURL: chatURL, outDir: outBaseURL, allowOverwrite: true)
            }
        } message: {
            Text(
                "Im Zielordner existieren bereits:\n" +
                replaceExistingNames.joined(separator: "\n") +
                "\n\nSoll(en) diese Datei(en) ersetzt werden?"
            )
        }
        .alert("Originaldaten löschen?", isPresented: $showDeleteOriginalsAlert) {
            Button("Abbrechen", role: .cancel) {
                deleteOriginalCandidates = []
            }
            Button("Originale löschen", role: .destructive) {
                let items = deleteOriginalCandidates
                deleteOriginalCandidates = []
                Task { await deleteOriginalItems(items) }
            }
        } message: {
            let lines = deleteOriginalCandidates.map { $0.path }.joined(separator: "\n")
            Text(
                "Die Sidecar-Kopie wurde geprüft. Diese Originale können gelöscht werden:\n" +
                lines
            )
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .waCard()

            inputsSection

            optionsAndLogSection
        }
    }

    private var inputsSection: some View {
        WASection(title: "Eingaben", systemImage: "bubble.left.and.bubble.right.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Chat-Export:")
                            .frame(width: Self.labelWidth, alignment: .leading)

                        Text(displayChatPath(chatURL) ?? "—")
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(chatURL?.path ?? "")

                        Button("Auswählen…") { pickChatFile() }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Chat-Export auswählen")
                    }

                    GridRow {
                        Text("Zielordner:")
                            .frame(width: Self.labelWidth, alignment: .leading)

                        Text(displayOutputPath(outBaseURL) ?? "—")
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(outBaseURL?.path ?? "")

                        Button("Auswählen…") { pickOutputFolder() }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Zielordner auswählen")
                    }
                }

                if chatURL != nil {
                    Divider()
                        .padding(.vertical, 2)
                    inputSummary
                }
            }
        }
        .waCard()
    }

    private var inputSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let badge = inputKindBadge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.06))
                    .clipShape(Capsule())
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Detected chat title:")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    Text(detectedChatTitle ?? "—")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Participant label:")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(autoDetectedChatPartnerName ?? "—")
                        if let confidence = inputSummaryConfidenceText {
                            Text(confidence)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Message date range:")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    Text(inputSummaryDateRangeText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Media counts:")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    Text(inputSummaryMediaCountsText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
        }
    }

    private var optionsAndLogSection: some View {
        HStack(alignment: .top, spacing: 12) {
            optionsColumn
            logSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var optionsColumn: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                optionsSection
                actionsRow
            }
            .frame(width: Self.optionsColumnMaxWidth, alignment: .topLeading)
        }
        .scrollClipDisabled(true)
        .frame(width: Self.optionsColumnMaxWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var optionsSection: some View {
        WASection(title: "Optionen", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                outputAndSidecarOptions
                chatPartnerSelectionRow
                phoneOverridesSection
            }
        }
        .waCard()
    }

    private var outputAndSidecarOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            outputsHeader
            outputsGrid

            Divider()
                .padding(.vertical, 1)

            sidecarToggle
            deleteOriginalsToggle
            debugLoggingToggle
        }
        .controlSize(.small)
    }

    private var outputsHeader: some View {
        HStack(spacing: 6) {
            Text("Ausgaben")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            helpIcon("Alle Ausgaben sind optional; Standard: alles an (inkl. Sidecar).")
        }
    }

    private var outputsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Toggle(isOn: $exportHTMLMax) {
                    HStack(spacing: 6) {
                        Text("Max (1 Datei, alles enthalten)")
                        helpIcon("Größte Datei, alles eingebettet (Base64). Ideal für vollständige Offline-Ansicht; Datei wird deutlich größer.")
                    }
                }
                .accessibilityLabel("HTML Max")
                .disabled(isRunning)
                .onChange(of: exportHTMLMax) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportHTMLMid) {
                    HStack(spacing: 6) {
                        Text("Kompakt (mit Vorschauen)")
                        helpIcon("Gute Übersicht mit kleinerer Datei. Thumbnails eingebettet, große Medien ausgelagert.")
                    }
                }
                .accessibilityLabel("HTML Kompakt")
                .disabled(isRunning)
                .onChange(of: exportHTMLMid) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Toggle(isOn: $exportHTMLMin) {
                    HStack(spacing: 6) {
                        Text("E-Mail (minimal, Text-only)")
                        helpIcon("Sehr klein, nur Text. Keine Medien oder Vorschauen.")
                    }
                }
                .accessibilityLabel("HTML E-Mail")
                .disabled(isRunning)
                .onChange(of: exportHTMLMin) {
                    persistExportSettings()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportMarkdown) {
                    HStack(spacing: 6) {
                        Text("Markdown (.md)")
                        helpIcon("Erzeugt eine Markdown-Ausgabe des Chats.")
                    }
                }
                .accessibilityLabel("Markdown Ausgabe")
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
                Text("Sidecar (Archiv, beste Performance)")
                Text("Empfohlen")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                helpIcon("Wie Max, aber Medien im Sidecar-Ordner. Ideal als ZIP (HTML + Ordner) und schneller im Browser.")
            }
        }
        .accessibilityLabel("Sidecar Ausgabe")
        .disabled(isRunning)
        .onChange(of: exportSortedAttachments) {
            persistExportSettings()
        }
    }

    private var deleteOriginalsToggle: some View {
        Toggle(isOn: $deleteOriginalsAfterSidecar) {
            HStack(spacing: 6) {
                Text("Originaldaten nach Sidecar-Erstellung löschen (optional, nach Prüfung)")
                helpIcon("Vergleicht Sidecar und Original. Löschen nur nach identischer Prüfung.")
            }
        }
        .accessibilityLabel("Originaldaten löschen")
        .disabled(isRunning || !exportSortedAttachments)
        .onChange(of: deleteOriginalsAfterSidecar) {
            persistExportSettings()
        }
    }

    private var debugLoggingToggle: some View {
        Toggle(isOn: $wetDebugLoggingEnabled) {
            HStack(spacing: 6) {
                Text("Debug logging")
                helpIcon("Emits detailed staging/validation/publish logs. Use only for troubleshooting.")
            }
        }
        .accessibilityLabel("Debug logging")
        .disabled(isRunning)
        .onChange(of: wetDebugLoggingEnabled) {
            persistExportSettings()
        }
    }

    private var chatPartnerSelectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Erstellt von:")
                    .frame(width: Self.labelWidth, alignment: .leading)
                Text(resolvedExporterName())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Chat-Partner:")
                    helpIcon("Wähle das Gegenüber (Name oder Nummer), mit dem du gechattet hast.")
                }
                .frame(width: Self.labelWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Menu {
                        ForEach(chatPartnerCandidates, id: \.self) { name in
                            Toggle(isOn: Binding(
                                get: { chatPartnerSelection == name },
                                set: { if $0 { chatPartnerSelection = name } }
                            )) {
                                Label {
                                    Text(name)
                                } icon: {
                                    if autoDetectedChatPartnerName == name {
                                        Image(nsImage: Self.aiMenuBadgeImage)
                                            .renderingMode(.original)
                                    } else {
                                        Image(systemName: "circle")
                                            .opacity(0)
                                    }
                                }
                            }
                        }
                        Divider()
                        Toggle(isOn: Binding(
                            get: { chatPartnerSelection == Self.customChatPartnerTag },
                            set: { if $0 { chatPartnerSelection = Self.customChatPartnerTag } }
                        )) {
                            Label {
                                Text("Benutzerdefiniert…")
                            } icon: {
                                Image(systemName: "circle")
                                    .opacity(0)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(chatPartnerSelectionDisplayName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .aiGlow(
                            active: shouldShowAIGlow,
                            isRunning: false,
                            cornerRadius: 6,
                            style: WETAIGlowStyle.defaultStyle()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat-Partner")

                    if chatPartnerSelection == Self.customChatPartnerTag {
                        TextField("z. B. Alex", text: $chatPartnerCustomName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Chat-Partner benutzerdefiniert")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chatPartnerSelectionDisplayName: String {
        if chatPartnerSelection == Self.customChatPartnerTag {
            let trimmed = chatPartnerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Benutzerdefiniert…" : trimmed
        }
        let trimmed = chatPartnerSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let auto = autoDetectedChatPartnerName {
                return applyPhoneOverrideIfNeeded(auto)
            }
            if let fallback = chatPartnerCandidates.first {
                return applyPhoneOverrideIfNeeded(fallback)
            }
            return "Chat-Partner"
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
                    Text("Unbekannte Telefonnummern (optional umbenennen)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    helpIcon("Diese Eingabe wird nur für Teilnehmende angeboten, die im Export ausschließlich als Telefonnummer erscheinen.")
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

                        TextField("Name (z. B. Max Mustermann)", text: overrideBinding)
                            .textFieldStyle(.roundedBorder)
                            .aiGlow(
                                active: shouldShowPhoneSuggestionGlow(for: num),
                                isRunning: false,
                                cornerRadius: 6,
                                style: WETAIGlowStyle.defaultStyle()
                            )

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            Button {
                guard !isRunning else { return }
                guard let chatURL, let outBaseURL else {
                    appendLog("ERROR: Bitte zuerst Chat-Export und Zielordner auswählen.")
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
                    Label(isRunning ? "Läuft…" : "Generieren", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            Button {
                clearLog()
            } label: {
                Label("Log leeren", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(isRunning)

            let cancelButton = Button("Abbrechen") {
                guard isRunning, !cancelRequested else { return }
                cancelRequested = true
                exportTask?.cancel()
                appendLog("Abbruch angefordert…")
            }
            .disabled(!isRunning || cancelRequested)

            if isRunning && !cancelRequested {
                cancelButton.buttonStyle(.borderedProminent)
            } else {
                cancelButton.buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(.top, 2)
    }

    private var logSection: some View {
        WASection(title: "Log", systemImage: "doc.text.magnifyingglass") {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayLogText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                        Color.clear
                            .frame(height: 1)
                            .id("logBottom")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: logLines.count) { _, _ in
                    guard !logLines.isEmpty else { return }
                    logAutoScrollWorkItem?.cancel()
                    let work = DispatchWorkItem {
                        proxy.scrollTo("logBottom", anchor: .bottomLeading)
                    }
                    logAutoScrollWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                }
            }
        }
        .waCard()
        .aiGlow(
            active: isRunning,
            isRunning: false,
            cornerRadius: 14,
            style: logGlowStyle,
            debugTag: "log"
        )
        .frame(maxWidth: .infinity, minHeight: logSectionHeight, maxHeight: logSectionHeight, alignment: .topLeading)
    }

    private var logGlowStyle: AIGlowStyle {
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
                Text("WhatsApp Export Tools")
                    .font(.system(size: 15, weight: .semibold))
                Text("WhatsApp-Chat als HTML und Markdown")
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
        return "Images \(counts.images) · Videos \(counts.videos) · Audio \(counts.audios) · Documents \(counts.documents)"
    }

    private var inputSummaryConfidenceText: String? {
        guard let confidence = participantDetection?.confidence else { return nil }
        switch confidence {
        case .high: return "Confident"
        case .medium: return "Likely"
        case .low: return "Uncertain"
        }
    }

    private func suggestedChatSubfolderName(
        chatURL: URL,
        chatPartner: String,
        detectedPartnerRaw: String,
        overridePartnerRaw: String?
    ) -> String {
        let trimmed = normalizedDisplayName(chatPartner)
        let base: String
        if !trimmed.isEmpty {
            base = safeFolderName(trimmed)
        } else if let detectedChatTitle, !detectedChatTitle.isEmpty {
            base = safeFolderName(detectedChatTitle)
        } else if let fromExportFolder = chatNameFromExportFolder(chatURL: chatURL) {
            base = safeFolderName(fromExportFolder)
        } else {
            let raw = chatPartnerCandidates.first ?? detectedParticipants.first ?? "WhatsApp Chat"
            base = safeFolderName(raw)
        }
        return WhatsAppExportService.applyPartnerOverrideToName(
            originalName: base,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw
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
        var x = s.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        let filteredScalars = x.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        x = String(String.UnicodeScalarView(filteredScalars))
        x = x.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        x = x.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        if x.isEmpty { x = "WhatsApp Chat" }
        if x.count > maxLen {
            x = String(x.prefix(maxLen)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        return x
    }

    private func helpIcon(_ text: String) -> some View {
        HelpButton(text: text)
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
        panel.title = "WhatsApp-Chat-Export auswählen"
        panel.message = "Bitte WhatsApp-Exportordner, ZIP oder _chat.txt auswählen."
        panel.prompt = "Auswählen"
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
            refreshParticipants(for: url)
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Zielordner auswählen"
        panel.message = "Bitte den Zielordner für die Exportdateien auswählen."
        panel.prompt = "Auswählen"
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
        chatURLAccess?.stopAccessing()
        guard let url else {
            chatURL = nil
            chatURLAccess = nil
            if !isRestoringSettings { persistExportSettings() }
            return
        }
        if let scoped = SecurityScopedURL(url: url) {
            chatURLAccess = scoped
            chatURL = scoped.resourceURL
        } else {
            appendLog("WARN: Sicherheitszugriff auf den Chat-Export konnte nicht aktiviert werden.")
            chatURL = nil
            chatURLAccess = nil
        }
        if !isRestoringSettings {
            persistExportSettings()
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
            appendLog("WARN: Sicherheitszugriff auf den Zielordner konnte nicht aktiviert werden.")
            outBaseURL = nil
            outBaseURLAccess = nil
        }
        if !isRestoringSettings {
            persistExportSettings()
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
            return
        }
        defer {
            cleanupTempWorkspace(snapshot.tempWorkspaceURL, label: "InputPipeline")
        }

        let chatURL = snapshot.chatURL
        do {
            let detectionSnapshot = try WhatsAppExportService.participantDetectionSnapshot(
                chatURL: chatURL,
                provenance: snapshot.provenance
            )
            let detection = detectionSnapshot.detection

            participantDetection = detection
            detectedChatTitle = detection.chatTitleCandidate
            detectedDateRange = detectionSnapshot.dateRange
            detectedMediaCounts = detectionSnapshot.mediaCounts
            switch snapshot.provenance.inputKind {
            case .folder:
                inputKindBadge = "Folder"
            case .zip:
                inputKindBadge = "ZIP"
            }

            var parts = detectionSnapshot.participants
            let usedFallbackParticipant = parts.isEmpty
            if parts.isEmpty { parts = ["Ich"] }
            detectedParticipants = parts

            let partnerHintRaw: String? = {
                switch detection.chatKind {
                case .group:
                    return detection.chatTitleCandidate ?? detection.otherPartyCandidate
                case .oneToOne:
                    return detection.otherPartyCandidate ?? detection.chatTitleCandidate
                case .unknown:
                    return detection.chatTitleCandidate ?? detection.otherPartyCandidate
                }
            }()
            let partnerHint = partnerHintRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

            let detectedMeRaw = detection.exporterSelfCandidate
            var detectedExporter: String? = nil

            if let detectedMeRaw, let match = firstMatchingParticipant(detectedMeRaw, in: parts) {
                detectedExporter = match
            }

            if detectedExporter == nil, let partnerHint, parts.count == 2 {
                if let partnerMatch = firstMatchingParticipant(partnerHint, in: parts) {
                    detectedExporter = parts.first { normalizedKey($0) != normalizedKey(partnerMatch) }
                } else {
                    let phoneCandidates = parts.filter { Self.isPhoneNumberLike($0) }
                    if phoneCandidates.count == 1 {
                        detectedExporter = parts.first { normalizedKey($0) != normalizedKey(phoneCandidates[0]) }
                    }
                }
            }

            if detectedExporter == nil {
                detectedExporter = parts.first
            }
            exporterName = detectedExporter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
                if let detectedExporter {
                    candidates = parts.filter { normalizedKey($0) != normalizedKey(detectedExporter) }
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
            inputKindBadge = nil
            let fallbackPartner = "WhatsApp Chat"
            chatPartnerCandidates = [fallbackPartner]
            autoDetectedChatPartnerName = fallbackPartner
            if chatPartnerSelection != Self.customChatPartnerTag {
                chatPartnerSelection = fallbackPartner
            }
            exporterName = "Ich"
            autoSuggestedPhoneNames = [:]
            appendLog("WARN: Teilnehmer konnten nicht ermittelt werden. \(error)")
        }
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

    private func resolvedExporterName() -> String {
        let trimmed = exporterName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let fallback = detectedParticipants.first ?? "Ich"
            return applyPhoneOverrideIfNeeded(fallback)
        }
        return applyPhoneOverrideIfNeeded(trimmed)
    }

    private func resolvedChatPartnerName() -> String {
        if chatPartnerSelection == Self.customChatPartnerTag {
            let trimmed = chatPartnerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let trimmed = chatPartnerSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return applyPhoneOverrideIfNeeded(trimmed)
        }
        if let auto = autoDetectedChatPartnerName {
            return applyPhoneOverrideIfNeeded(auto)
        }
        if let fallback = chatPartnerCandidates.first {
            return applyPhoneOverrideIfNeeded(fallback)
        }
        return ""
    }

    // MARK: - Logging

    private var outputStepCount: Int {
        var count = 0
        if exportSortedAttachments { count += 1 }
        if exportHTMLMax { count += 1 }
        if exportHTMLMid { count += 1 }
        if exportHTMLMin { count += 1 }
        if exportMarkdown { count += 1 }
        return count
    }

    private var maxLogLinesContent: Int {
        let headerLines = 4 // Start + Zielordner + Exportname + Optionen
        let perArtifactLines = outputStepCount * 2
        let footerLines = 1 // Abgeschlossen
        let bufferLines = 3
        let lines = headerLines + perArtifactLines + footerLines + bufferLines
        return max(lines, Self.logMinLinesContent)
    }

    private var maxLogLinesDisplay: Int {
        maxLogLinesContent + (Self.logPadLinesPerSide * 2)
    }

    private var logSectionHeight: CGFloat {
        Self.logLineHeight * CGFloat(maxLogLinesDisplay) + Self.logSectionVerticalPadding
    }

    private var displayLogText: String {
        let pad = String(repeating: "\n", count: Self.logPadLinesPerSide)
        if logText.isEmpty {
            return pad + pad
        }
        return pad + logText + pad
    }

    nonisolated private func appendLog(_ s: String) {
        Task { @MainActor in
            let pieces = s.split(whereSeparator: \.isNewline).map(String.init)
            if pieces.isEmpty { return }
            self.logLines.append(contentsOf: pieces)
            let chunk = pieces.joined(separator: "\n")
            if self.logText.isEmpty {
                self.logText = chunk
            } else {
                self.logText.append("\n")
                self.logText.append(chunk)
            }
        }
    }

    @MainActor
    private func clearLog() {
        logLines.removeAll(keepingCapacity: true)
        logText = ""
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

        let onOff = { (value: Bool) in value ? "AN" : "AUS" }
        let artifactOrder = ["Sidecar", "Max", "Kompakt", "E-Mail", "Markdown"]

        var lines: [String] = []
        lines.append("# Perf Compact Report")
        lines.append("")
        lines.append("## Baseline (given)")
        lines.append("- Sidecar: 0:42")
        lines.append("- Max: 0:21")
        lines.append("- Kompakt: 1:37")
        lines.append("- E-Mail: 0:02")
        lines.append("- Markdown: 0:01")
        lines.append("- Total: 2:42")
        lines.append("")
        lines.append("## Run")
        lines.append("- Start: \(Self.formatClockTime(runStartWall))")
        lines.append("- Exportname: \(baseName)")
        lines.append("- Zielordner: \(context.exportDir.path)")
        lines.append("- Optionen: Max=\(onOff(context.selectedVariantsInOrder.contains(.embedAll))) " +
                     "Kompakt=\(onOff(context.selectedVariantsInOrder.contains(.thumbnailsOnly))) " +
                     "E-Mail=\(onOff(context.selectedVariantsInOrder.contains(.textOnly))) " +
                     "Markdown=\(onOff(context.wantsMD)) " +
                     "Sidecar=\(onOff(context.wantsSidecar)) " +
                     "Originale löschen=\(onOff(context.wantsDeleteOriginals))")
        lines.append("- Total: \(Self.formatDuration(totalDuration))")
        lines.append("")
        lines.append("## Artifact-Durations")
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
        switch variant {
        case .embedAll: return "-max"
        case .thumbnailsOnly: return "-mid"
        case .textOnly: return "-min"
        }
    }

    nonisolated private static func htmlVariantLogLabel(for variant: HTMLVariant) -> String {
        switch variant {
        case .embedAll: return "Max"
        case .thumbnailsOnly: return "Kompakt"
        case .textOnly: return "E-Mail"
        }
    }

    nonisolated private static func outputHTMLURL(baseName: String, variant: HTMLVariant, in dir: URL) -> URL {
        let name = baseName + htmlVariantSuffix(for: variant) + ".html"
        return dir.appendingPathComponent(name)
    }

    nonisolated private static func outputMarkdownURL(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(baseName).md")
    }

    nonisolated private static func outputSidecarHTML(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(baseName)-sdc.html")
    }

    nonisolated private static func outputSidecarDir(baseName: String, in dir: URL) -> URL {
        dir.appendingPathComponent(baseName, isDirectory: true)
    }

    nonisolated static func replaceDeleteTargets(
        baseName: String,
        variantSuffixes: [String],
        wantsMarkdown: Bool,
        wantsSidecar: Bool,
        in dir: URL
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

        return urls
    }

    nonisolated static func replaceDialogLabels(existingNames: [String], baseName: String) -> [String] {
        var labels: Set<String> = []

        func isSidecarHTML(_ name: String) -> Bool {
            name.hasPrefix("\(baseName)-sdc") && name.hasSuffix(".html")
        }

        func isVariantHTML(_ name: String, suffix: String) -> Bool {
            guard name.hasSuffix(".html") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasPrefix("\(baseName)\(suffix)")
        }

        func isMarkdown(_ name: String) -> Bool {
            guard name.hasSuffix(".md") else { return false }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasPrefix(baseName)
        }

        func isSidecarDir(_ name: String) -> Bool {
            guard !name.hasSuffix(".html"), !name.hasSuffix(".md") else { return false }
            return name.hasPrefix(baseName)
        }

        for name in existingNames {
            if isSidecarHTML(name) || isSidecarDir(name) {
                labels.insert("Sidecar")
            }
            if isVariantHTML(name, suffix: "-max") {
                labels.insert("Max")
            }
            if isVariantHTML(name, suffix: "-mid") {
                labels.insert("Kompakt")
            }
            if isVariantHTML(name, suffix: "-min") {
                labels.insert("E-Mail")
            }
            if isMarkdown(name) {
                labels.insert("Markdown")
            }
        }

        let ordered = ["Sidecar", "Max", "Kompakt", "E-Mail", "Markdown"]
        return ordered.filter { labels.contains($0) }
    }

    nonisolated static func isSafeReplaceDeleteTarget(_ target: URL, exportDir: URL) -> Bool {
        let root = exportDir.standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let targetPath = target.standardizedFileURL.path
        return targetPath.hasPrefix(rootPrefix)
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

        guard let en = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return SidecarTimestampSnapshot(entries: entries)
        }

        // Track files only to avoid noisy directory timestamp drift (e.g., Finder metadata).
        var fileCount = 0

        for case let url as URL in en {
            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard rv?.isRegularFile == true else { continue }
            if fileCount >= maxFiles { continue }
            fileCount += 1

            let relPath = url.path.replacingOccurrences(of: base.path + "/", with: "")
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
            expected.append("\(baseName)-sdc.html")
            expected.append(baseName)
        }

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

    // MARK: - Export

    @MainActor
    private func startExport(chatURL: URL, outDir: URL, allowOverwrite: Bool) {
        guard !isRunning else { return }
        clearLog()
        if !allowOverwrite {
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

        let chatPartnerSelectionTrimmed = chatPartnerSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatPartnerCustomTrimmed = chatPartnerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)

        let uiChatPartnerRaw: String
        let uiChatPartnerSource: String
        if chatPartnerSelection == Self.customChatPartnerTag, !chatPartnerCustomTrimmed.isEmpty {
            uiChatPartnerRaw = chatPartnerCustomTrimmed
            uiChatPartnerSource = "ui_override"
        } else if !chatPartnerSelectionTrimmed.isEmpty {
            uiChatPartnerRaw = chatPartnerSelectionTrimmed
            uiChatPartnerSource = "ui_selection"
        } else if let auto = autoDetectedChatPartnerName, !auto.isEmpty {
            uiChatPartnerRaw = auto
            uiChatPartnerSource = "auto"
        } else if let fallback = chatPartnerCandidates.first {
            uiChatPartnerRaw = fallback
            uiChatPartnerSource = "fallback"
        } else {
            uiChatPartnerRaw = ""
            uiChatPartnerSource = "fallback"
        }

        let detectedPartnerRaw: String = {
            let auto = autoDetectedChatPartnerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !auto.isEmpty { return auto }
            let first = chatPartnerCandidates.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return first
        }()

        var participantNameOverrides: [String: String] = phoneParticipantOverrides.reduce(into: [:]) { acc, kv in
            let key = kv.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = kv.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !val.isEmpty {
                acc[key] = val
            }
        }
        if chatPartnerSelection == Self.customChatPartnerTag {
            let custom = chatPartnerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty, let raw = rawChatPartnerOverrideCandidate() {
                participantNameOverrides[raw] = custom
            }
        }

        let outputChatPartner = resolvedChatPartnerName()
        let normalizedDetected = normalizedDisplayName(detectedPartnerRaw)
        let normalizedOutput = normalizedDisplayName(outputChatPartner)
        let overridePartnerEffective: String? = {
            let trimmedOutput = outputChatPartner.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty { return nil }
            if uiChatPartnerSource == "ui_override" || uiChatPartnerSource == "ui_selection" {
                return trimmedOutput
            }
            if !normalizedOutput.isEmpty && normalizedOutput != normalizedDetected {
                return trimmedOutput
            }
            return nil
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

        let exporter = resolvedExporterName()
        if exporter.isEmpty {
            appendLog("ERROR: Ersteller konnte nicht ermittelt werden.")
            isRunning = false
            return
        }

        if uiChatPartnerRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog("ERROR: Bitte einen Chat-Partner auswählen.")
            isRunning = false
            return
        }

        let selectedVariantsInOrder: [HTMLVariant] = [
            exportHTMLMax ? .embedAll : nil,
            exportHTMLMid ? .thumbnailsOnly : nil,
            exportHTMLMin ? .textOnly : nil
        ].compactMap { $0 }

        let wantsMD = exportMarkdown
        let wantsSidecar = exportSortedAttachments
        let wantsDeleteOriginals = wantsSidecar && deleteOriginalsAfterSidecar

        let htmlLabel: String = {
            var parts: [String] = []
            if exportHTMLMax { parts.append("-max") }
            if exportHTMLMid { parts.append("-mid") }
            if exportHTMLMin { parts.append("-min") }
            return parts.isEmpty ? "AUS" : parts.joined(separator: ", ")
        }()

        let partnerForNamingRaw = overridePartnerEffective ?? detectedPartnerRaw
        let partnerForNamingNormalized = normalizedDisplayName(partnerForNamingRaw)
        let partnerForNamingFolderName = partnerForNamingNormalized.isEmpty
            ? nil
            : safeFolderName(partnerForNamingNormalized)
        let outputChatPartnerFolderOverride = partnerForNamingFolderName

        if selectedVariantsInOrder.isEmpty && !wantsMD && !wantsSidecar {
            appendLog("ERROR: Bitte mindestens eine Ausgabe aktivieren (HTML, Markdown oder Sidecar).")
            isRunning = false
            return
        }

        let plan = RunPlan(
            variants: selectedVariantsInOrder,
            wantsMD: wantsMD,
            wantsSidecar: wantsSidecar
        )

        let env = ProcessInfo.processInfo.environment
        let debugEnabled = wetDebugLoggingEnabled
            || env["WET_SIDECAR_DEBUG"] == "1"
            || env["WET_DEBUG"] == "1"
        let debugLog: (String) -> Void = { [appendLog] message in
            guard debugEnabled else { return }
            appendLog("WET-DBG: \(message)")
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

        let subfolderName = suggestedChatSubfolderName(
            chatURL: resolvedChatURL,
            chatPartner: partnerForNamingRaw,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerEffective
        )
        debugLog("TARGET DIR NAME: \"\(subfolderName)\" detected=\"\(detectedPartnerRaw)\" override=\"\(overridePartnerEffective ?? "")\" effective=\"\(partnerForNamingRaw)\"")
        let exportDir = outDir.appendingPathComponent(subfolderName, isDirectory: true)

        let isOverwriteRetry = overwriteConfirmed
        let preflight = isOverwriteRetry ? pendingPreflight : nil
        let prepared = isOverwriteRetry ? pendingPreparedExport : nil
        overwriteConfirmed = false
        if isOverwriteRetry {
            pendingPreflight = nil
            pendingPreparedExport = nil
        }

        let context = ExportContext(
            chatURL: resolvedChatURL,
            outDir: outDir,
            exportDir: exportDir,
            allowOverwrite: allowOverwrite,
            isOverwriteRetry: isOverwriteRetry,
            preflight: preflight,
            prepared: prepared,
            exporter: exporter,
            chatPartner: outputChatPartner,
            chatPartnerSource: uiChatPartnerSource,
            chatPartnerFolderOverride: outputChatPartnerFolderOverride,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerEffective,
            participantDetection: participantDetection,
            provenance: provenance,
            participantNameOverrides: participantNameOverrides,
            selectedVariantsInOrder: selectedVariantsInOrder,
            plan: plan,
            wantsMD: wantsMD,
            wantsSidecar: wantsSidecar,
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
        }

        await Task.yield()
        logExportTiming("T3 pre-processing begin", startUptime: startUptime)

        let append: @Sendable (String) -> Void = { [appendLog] message in
            appendLog(message)
        }
        let logger = ExportProgressLogger(append: append)
        let env = ProcessInfo.processInfo.environment
        let debugEnabled = wetDebugLoggingEnabled
            || env["WET_SIDECAR_DEBUG"] == "1"
            || env["WET_DEBUG"] == "1"
        let debugLog: @Sendable (String) -> Void = { [appendLog] message in
            guard debugEnabled else { return }
            appendLog("WET-DBG: \(message)")
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
            return
        }
        let baseName = prepared.baseName

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
        let startSuffix = context.isOverwriteRetry ? " (Ersetzen bestätigt)" : ""
        logger.log("Start: \(Self.formatClockTime(runStartWall))\(startSuffix)")
        logger.log("Zielordner: \(context.exportDir.lastPathComponent)")
        logger.log("Exportname: \(baseName)")
        let onOff = { (value: Bool) in value ? "AN" : "AUS" }
        logger.log(
            "Optionen: Max=\(onOff(context.selectedVariantsInOrder.contains(.embedAll))) " +
            "Kompakt=\(onOff(context.selectedVariantsInOrder.contains(.thumbnailsOnly))) " +
            "E-Mail=\(onOff(context.selectedVariantsInOrder.contains(.textOnly))) " +
            "Markdown=\(onOff(context.wantsMD)) " +
            "Sidecar=\(onOff(context.wantsSidecar)) " +
            "Originale löschen=\(onOff(context.wantsDeleteOriginals))"
        )
        debugLog("RUN START: \(Self.formatClockTime(runStartWall))")
        debugLog("PARTNER NAME SOURCE: \(context.chatPartnerSource)")
        debugLog("PARTNER NAME EFFECTIVE: \(context.chatPartner)")
        debugLog("TARGET DIR: \(context.exportDir.path)")
        debugLog("EXPORT NAME: \(baseName)")
        debugLog("OPTIONS: Max=\(onOff(context.selectedVariantsInOrder.contains(.embedAll))) " +
                 "Kompakt=\(onOff(context.selectedVariantsInOrder.contains(.thumbnailsOnly))) " +
                 "E-Mail=\(onOff(context.selectedVariantsInOrder.contains(.textOnly))) " +
                 "Markdown=\(onOff(context.wantsMD)) " +
                 "Sidecar=\(onOff(context.wantsSidecar)) " +
                 "DeleteOriginals=\(onOff(context.wantsDeleteOriginals))")
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
            if let provided = context.preflight {
                preflight = provided
            } else {
                preflight = try await Self.debugMeasureAsync("preflight") {
                    let preflightTask = Task.detached(priority: .userInitiated) {
                        try Self.performOutputPreflight(context: context, baseName: baseName)
                    }
                    return try await withTaskCancellationHandler {
                        try await preflightTask.value
                    } onCancel: {
                        preflightTask.cancel()
                    }
                }

                if !preflight.existing.isEmpty, !context.allowOverwrite {
                    pendingPreflight = preflight
                    pendingPreparedExport = prepared
                    throw WAExportError.outputAlreadyExists(urls: preflight.existing)
                }
            }

            let workTask = Task.detached(priority: .userInitiated) {
                try await Self.performExportWork(
                    context: context,
                    baseName: preflight.baseName,
                    prepared: prepared,
                    log: append,
                    debugEnabled: debugEnabled,
                    debugLog: debugLog
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

            if context.wantsDeleteOriginals {
                await offerSidecarDeletionIfPossible(
                    chatURL: context.chatURL,
                    outDir: workResult.exportDir,
                    baseHTMLName: workResult.baseHTMLName,
                    detectedPartnerRaw: context.detectedPartnerRaw,
                    overridePartnerRaw: context.overridePartnerRaw,
                    originalZipURL: context.provenance.originalZipURL
                )
            }

            let totalDuration = ProcessInfo.processInfo.systemUptime - runStartUptime
            logger.log("Abgeschlossen: \(Self.formatDuration(totalDuration))")
            var published: [String] = []
            if context.wantsSidecar { published.append("Sidecar") }
            published.append(contentsOf: context.plan.variants.map { Self.htmlVariantLogLabel(for: $0) })
            if context.wantsMD { published.append("Markdown") }
            debugLog("RUN DONE: \(Self.formatDuration(totalDuration)) published=\(published.joined(separator: ", "))")
            writePerfReport(
                context: context,
                baseName: baseName,
                runStartWall: runStartWall,
                totalDuration: totalDuration,
                sidecarImmutabilityWarnings: workResult.sidecarImmutabilityWarnings,
                outputSuffixArtifacts: workResult.outputSuffixArtifacts
            )
        } catch {
            if error is CancellationError {
                logger.log("Abgebrochen.")
                return
            }
            if let deletionError = error as? OutputDeletionError {
                logger.log("ERROR: \(deletionError.errorDescription ?? "Konnte vorhandene Ausgaben nicht löschen.")")
                return
            }
            if let waErr = error as? WAExportError {
                switch waErr {
                case .outputAlreadyExists:
                    let exportDir = context.exportDir.standardizedFileURL
                    let variantSuffixes = context.selectedVariantsInOrder.map { Self.htmlVariantSuffix(for: $0) }
                    let replaceTargets = Self.replaceDeleteTargets(
                        baseName: baseName,
                        variantSuffixes: variantSuffixes,
                        wantsMarkdown: context.wantsMD,
                        wantsSidecar: context.wantsSidecar,
                        in: exportDir
                    )
                    let suffixArtifacts = Self.outputSuffixArtifacts(
                        baseName: baseName,
                        variants: context.plan.variants,
                        wantsMarkdown: context.wantsMD,
                        wantsSidecar: context.wantsSidecar,
                        in: exportDir
                    )
                    let fm = FileManager.default
                    let existingNames = replaceTargets
                        .filter { fm.fileExists(atPath: $0.path) }
                        .map { $0.lastPathComponent }
                        + suffixArtifacts.filter { fm.fileExists(atPath: exportDir.appendingPathComponent($0).path) }
                    replaceExistingNames = Self.replaceDialogLabels(existingNames: existingNames, baseName: baseName)
                    showReplaceAlert = true
                    let count = replaceExistingNames.count
                    logger.log("Vorhandene Ausgaben gefunden: \(count) Datei(en). Warte auf Bestätigung zum Ersetzen…")
                    return
                case .suffixArtifactsFound(let names):
                    logger.log("ERROR: Suffix-Artefakte gefunden (bitte Zielordner bereinigen): \(names.joined(separator: ", "))")
                    return
                }
            }
            logger.log("ERROR: \(error)")
        }
    }

    nonisolated private static func performOutputPreflight(context: ExportContext, baseName: String) throws -> OutputPreflight {
        let fm = FileManager.default

        var existing: [URL] = []
        let exportDir = context.exportDir.standardizedFileURL

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

        for variant in context.plan.variants {
            let variantURL = Self.outputHTMLURL(baseName: baseName, variant: variant, in: exportDir)
            if existingNames.contains(variantURL.lastPathComponent) { existing.append(variantURL) }
        }

        let suffixArtifacts = Self.outputSuffixArtifacts(
            baseName: baseName,
            variants: context.plan.variants,
            wantsMarkdown: context.wantsMD,
            wantsSidecar: context.wantsSidecar,
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
        debugLog: @Sendable (String) -> Void
    ) async throws -> ExportWorkResult {
        let fm = FileManager.default
        let exportDir = context.exportDir.standardizedFileURL
        let plan = context.plan
        let env = ProcessInfo.processInfo.environment
        let perfEnabled = env["WET_PERF"] == "1"
        let verboseDebug = env["WET_DEBUG_VERBOSE"] == "1"
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

        func artifactLabel(_ artifact: Artifact) -> String {
            switch artifact {
            case .sidecar:
                return "Sidecar"
            case .html(let variant):
                return Self.htmlVariantLogLabel(for: variant)
            case .markdown:
                return "Markdown"
            }
        }

        func logStart(_ artifact: Artifact) {
            log("Start \(artifactLabel(artifact))")
        }

        func logDone(_ artifact: Artifact, duration: TimeInterval) {
            log("Done \(artifactLabel(artifact)) (\(Self.formatDuration(duration)))")
        }

        var publishCounts: [String: Int] = [:]

        func recordPublishAttempt(_ url: URL, artifact: Artifact) -> Bool {
            let key = url.standardizedFileURL.path
            let count = publishCounts[key, default: 0]
            if count > 0 {
                log("BUG: Zweite Veröffentlichung blockiert: \(artifactLabel(artifact)) (\(url.lastPathComponent))")
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

        let sidecarDebugEnabled = debugEnabled || ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1"
        let sidecarSourceDir = prepared.chatURL.deletingLastPathComponent()
        let sidecarOriginalNameBefore = context.provenance.originalZipURL?
            .deletingPathExtension()
            .lastPathComponent ?? sidecarSourceDir.lastPathComponent
        let sidecarOriginalFolderName = WhatsAppExportService.applyPartnerOverrideToName(
            originalName: sidecarOriginalNameBefore,
            detectedPartnerRaw: context.detectedPartnerRaw,
            overridePartnerRaw: context.overridePartnerRaw
        )

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
            let sourceDir = sidecarSourceDir
            let finalSidecarOriginalDir = sidecarBaseDir.appendingPathComponent(
                sidecarOriginalFolderName,
                isDirectory: true
            )
            if debugEnabled {
                debugLog("TIMESTAMP SYNC: \(finalSidecarOriginalDir.path)")
            }
            if sidecarDebugEnabled || logMismatches {
                WhatsAppExportService.normalizeOriginalCopyTimestamps(
                    sourceDir: sourceDir,
                    destDir: finalSidecarOriginalDir,
                    skippingPathPrefixes: [
                        context.outDir.standardizedFileURL.path,
                        sidecarBaseDir.standardizedFileURL.path
                    ]
                )
                if logMismatches {
                    let mismatches = WhatsAppExportService.sampleTimestampMismatches(
                        sourceDir: sourceDir,
                        destDir: finalSidecarOriginalDir,
                        maxFiles: 3,
                        maxDirs: 2,
                        skippingPathPrefixes: [
                            context.outDir.standardizedFileURL.path,
                            sidecarBaseDir.standardizedFileURL.path
                        ]
                    )
                    if !mismatches.isEmpty {
                        log("WARN: Zeitstempelabweichung bei \(mismatches.count) Element(en).")
                    }
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
        var finalSidecarOriginalDir: URL? = nil
        var sidecarSnapshot: SidecarTimestampSnapshot? = nil
        var sidecarImmutabilityWarnings: Set<String> = []
        var stagedSidecarHTML: URL? = nil
        var stagedSidecarBaseDir: URL? = nil
        var expectedSidecarAttachments = 0
        var didPublishExternalAssets = false

        if wantsThumbStore, !context.wantsSidecar, !attachmentEntries.isEmpty {
            let tempRoot = WhatsAppExportService.temporaryThumbsWorkspace(
                baseName: baseName,
                chatURL: prepared.chatURL,
                stagingBase: stagingBase
            )
            tempThumbsRoot = tempRoot
            if fm.fileExists(atPath: tempRoot.path) {
                try? fm.removeItem(at: tempRoot)
            }
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let tempThumbsDir = tempRoot.appendingPathComponent("_thumbs", isDirectory: true)
            let writeStore = WhatsAppExportService.ThumbnailStore(
                entries: attachmentEntries,
                thumbsDir: tempThumbsDir,
                allowWrite: true
            )
            await writeStore.precomputeAll()
            thumbnailStore = WhatsAppExportService.ThumbnailStore(
                entries: attachmentEntries,
                thumbsDir: tempThumbsDir,
                allowWrite: false
            )
            if debugEnabled {
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
                    let sourceDir = sidecarSourceDir
                    if debugEnabled {
                        debugLog("SIDECAR ORIGINAL NAME BEFORE: \"\(sidecarOriginalNameBefore)\"")
                        debugLog("SIDECAR ORIGINAL NAME AFTER: \"\(sidecarOriginalFolderName)\"")
                    }
                    let sidecarResult = try await Self.debugMeasureAsync("generate sidecar") {
                        try await WhatsAppExportService.renderSidecar(
                            prepared: prepared,
                            outDir: stagingDir,
                            allowStagingOverwrite: true,
                            detectedPartnerRaw: context.detectedPartnerRaw,
                            overridePartnerRaw: context.overridePartnerRaw,
                            originalZipURL: context.provenance.originalZipURL,
                            attachmentEntries: attachmentEntries
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
                        let stagedSidecarOriginalDir = stagedSidecarBaseDir.appendingPathComponent(
                            sidecarOriginalFolderName,
                            isDirectory: true
                        )
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
                        if sidecarDebugEnabled {
                            WhatsAppExportService.normalizeOriginalCopyTimestamps(
                                sourceDir: sourceDir,
                                destDir: stagedSidecarOriginalDir,
                                skippingPathPrefixes: [
                                    context.outDir.standardizedFileURL.path,
                                    stagedSidecarBaseDir.standardizedFileURL.path
                                ]
                            )
                            let mismatches = WhatsAppExportService.sampleTimestampMismatches(
                                sourceDir: sourceDir,
                                destDir: stagedSidecarOriginalDir,
                                maxFiles: 3,
                                maxDirs: 3,
                                skippingPathPrefixes: [
                                    context.outDir.standardizedFileURL.path,
                                    stagedSidecarBaseDir.standardizedFileURL.path
                                ]
                            )
                            if !mismatches.isEmpty {
                                debugLog("WARN: Zeitstempelabweichung bei \(mismatches.count) Element(en).")
                            }
                        }
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
                        finalSidecarOriginalDir = finalSidecarDir.appendingPathComponent(
                            sidecarOriginalFolderName,
                            isDirectory: true
                        )
                        sidecarSnapshot = captureSidecarTimestampSnapshot(sidecarBaseDir: finalSidecarDir)
                    }
                case .html(let variant):
                    let stagedHTML = try await Self.debugMeasureAsync("generate \(artifactLabel(.html(variant)))") {
                        try await WhatsAppExportService.renderHTMLPrepared(
                            prepared: prepared,
                            outDir: stagingDir,
                            fileSuffix: Self.htmlVariantSuffix(for: variant),
                            enablePreviews: variant.enablePreviews,
                            embedAttachments: variant.embedAttachments,
                            embedAttachmentThumbnailsOnly: variant.thumbnailsOnly,
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
                    let mdChatURL = finalSidecarOriginalDir?
                        .appendingPathComponent(prepared.chatURL.lastPathComponent) ?? prepared.chatURL
                    let mdAttachmentRelBaseDir: URL? = finalSidecarOriginalDir != nil ? exportDir : nil
                    let stagedMDURL = try Self.debugMeasure("generate Markdown") {
                        try WhatsAppExportService.renderMarkdown(
                            prepared: prepared,
                            outDir: stagingDir,
                            chatURLOverride: mdChatURL,
                            attachmentRelBaseDir: mdAttachmentRelBaseDir
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
            in: exportDir
        )
        if !suffixArtifacts.isEmpty {
            throw WAExportError.suffixArtifactsFound(names: suffixArtifacts)
        }

        if debugEnabled, let finalSidecarBaseDir {
            let sourceDir = prepared.chatURL.deletingLastPathComponent()
            let originalNameBefore: String
            if let originalZipURL = context.provenance.originalZipURL {
                originalNameBefore = originalZipURL.deletingPathExtension().lastPathComponent
            } else {
                originalNameBefore = sourceDir.lastPathComponent
            }
            let originalNameAfter = WhatsAppExportService.applyPartnerOverrideToName(
                originalName: originalNameBefore,
                detectedPartnerRaw: context.detectedPartnerRaw,
                overridePartnerRaw: context.overridePartnerRaw
            )
            debugLog("SIDECAR ORIGINAL NAME BEFORE: \"\(originalNameBefore)\"")
            debugLog("SIDECAR ORIGINAL NAME AFTER: \"\(originalNameAfter)\"")

            if let (zipBefore, zipAfter) = WhatsAppExportService.resolvedSidecarZipName(
                sourceDir: sourceDir,
                detectedPartnerRaw: context.detectedPartnerRaw,
                overridePartnerRaw: context.overridePartnerRaw,
                originalZipURL: context.provenance.originalZipURL
            ) {
                debugLog("SIDECAR ZIP NAME BEFORE: \"\(zipBefore)\"")
                debugLog("SIDECAR ZIP NAME AFTER: \"\(zipAfter)\"")
            }

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
    private func offerSidecarDeletionIfPossible(
        chatURL: URL,
        outDir: URL,
        baseHTMLName: String,
        detectedPartnerRaw: String,
        overridePartnerRaw: String?,
        originalZipURL: URL?
    ) async {
        let baseStem = (baseHTMLName as NSString).deletingPathExtension
        let sidecarBaseDir = outDir.appendingPathComponent(baseStem, isDirectory: true)
        let originalDir = chatURL.deletingLastPathComponent()

        let verification = await Task.detached(priority: .utility) {
            WhatsAppExportService.verifySidecarCopies(
                originalExportDir: originalDir,
                sidecarBaseDir: sidecarBaseDir,
                detectedPartnerRaw: detectedPartnerRaw,
                overridePartnerRaw: overridePartnerRaw,
                originalZipURL: originalZipURL
            )
        }.value

        let candidates = verification.deletableOriginals
        if candidates.isEmpty {
            return
        }

        deleteOriginalCandidates = candidates
        showDeleteOriginalsAlert = true
    }

    @MainActor
    private func deleteOriginalItems(_ items: [URL]) async {
        let result = await Task.detached(priority: .utility) {
            var deleted: [URL] = []
            var failed: [URL] = []
            let fm = FileManager.default

            for u in items {
                do {
                    try fm.removeItem(at: u)
                    deleted.append(u)
                } catch {
                    failed.append(u)
                }
            }
            return (deleted, failed)
        }.value

        let (_, failed) = result
        if !failed.isEmpty {
            appendLog("ERROR: Löschen fehlgeschlagen: \(failed.map { $0.path }.joined(separator: ", "))")
        }
    }

    private func restorePersistedSettings() {
        guard let snapshot = WETExportSettingsStorage.shared.load() else { return }
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
        deleteOriginalsAfterSidecar = snapshot.deleteOriginalsAfterSidecar
        wetDebugLoggingEnabled = snapshot.wetDebugLoggingEnabled

        if let chatBookmark = snapshot.chatBookmark {
            if let url = resolveBookmark(chatBookmark, expectDirectory: false) {
                setChatURL(url)
            } else {
                appendLog("WARN: Letzter Chat-Export nicht verfügbar. Bitte erneut auswählen.")
                setChatURL(nil)
            }
        }

        if let outputBookmark = snapshot.outputBookmark {
            if let url = resolveBookmark(outputBookmark, expectDirectory: true) {
                setOutputBaseURL(url)
            } else {
                appendLog("WARN: Letzter Zielordner nicht verfügbar. Bitte erneut auswählen.")
                setOutputBaseURL(nil)
            }
        }
    }

    private func persistExportSettings() {
        guard !isRestoringSettings else { return }
        let snapshot = WETExportSettingsSnapshot(
            schemaVersion: WETExportSettingsSnapshot.currentVersion,
            chatBookmark: bookmarkData(for: chatURL),
            outputBookmark: bookmarkData(for: outBaseURL),
            exportHTMLMax: exportHTMLMax,
            exportHTMLMid: exportHTMLMid,
            exportHTMLMin: exportHTMLMin,
            exportMarkdown: exportMarkdown,
            exportSortedAttachments: exportSortedAttachments,
            deleteOriginalsAfterSidecar: deleteOriginalsAfterSidecar,
            wetDebugLoggingEnabled: wetDebugLoggingEnabled
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

// MARK: - Helpers (Dateiebene)

private struct WASection<Content: View>: View {
    let title: String
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
    let text: String
    @State private var isPresented = false

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
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .accessibilityLabel("Hilfe")
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
    static let currentVersion = 2

    let schemaVersion: Int
    let chatBookmark: Data?
    let outputBookmark: Data?
    let exportHTMLMax: Bool
    let exportHTMLMid: Bool
    let exportHTMLMin: Bool
    let exportMarkdown: Bool
    let exportSortedAttachments: Bool
    let deleteOriginalsAfterSidecar: Bool
    let wetDebugLoggingEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case chatBookmark
        case outputBookmark
        case exportHTMLMax
        case exportHTMLMid
        case exportHTMLMin
        case exportMarkdown
        case exportSortedAttachments
        case deleteOriginalsAfterSidecar
        case wetDebugLoggingEnabled
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
        deleteOriginalsAfterSidecar: Bool,
        wetDebugLoggingEnabled: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.chatBookmark = chatBookmark
        self.outputBookmark = outputBookmark
        self.exportHTMLMax = exportHTMLMax
        self.exportHTMLMid = exportHTMLMid
        self.exportHTMLMin = exportHTMLMin
        self.exportMarkdown = exportMarkdown
        self.exportSortedAttachments = exportSortedAttachments
        self.deleteOriginalsAfterSidecar = deleteOriginalsAfterSidecar
        self.wetDebugLoggingEnabled = wetDebugLoggingEnabled
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
        deleteOriginalsAfterSidecar = (try? container.decode(Bool.self, forKey: .deleteOriginalsAfterSidecar)) ?? false
        wetDebugLoggingEnabled = (try? container.decode(Bool.self, forKey: .wetDebugLoggingEnabled)) ?? false
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
