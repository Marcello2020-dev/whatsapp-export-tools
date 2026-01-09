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
        let exporter: String
        let chatPartner: String
        let participantNameOverrides: [String: String]
        let selectedVariantsInOrder: [HTMLVariant]
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
    }

    private struct OutputPreflight: Sendable {
        let baseName: String
        let existing: [URL]
    }

    private struct ExportProgressLogger: Sendable {
        let append: @Sendable (String) -> Void
        let startUptime: TimeInterval

        func log(_ message: String) {
            append(message)
        }

        func elapsedString() -> String {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startUptime)
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            if mins > 0 { return "\(mins)m \(secs)s" }
            return "\(secs)s"
        }
    }

    private struct ProgressPulse: Sendable {
        let message: String
        let interval: TimeInterval
        let log: @Sendable (String) -> Void
        private var task: Task<Void, Never>?

        init(message: String, interval: TimeInterval, log: @Sendable @escaping (String) -> Void) {
            self.message = message
            self.interval = interval
            self.log = log
            self.task = nil
        }

        mutating func start() {
            guard interval > 0 else { return }
            task = Task.detached { [message, interval, log] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    log(message)
                }
            }
        }

        mutating func stop() {
            task?.cancel()
            task = nil
        }
    }

    private static let customChatPartnerTag = "__CUSTOM_CHAT_PARTNER__"
    private static let labelWidth: CGFloat = 110
    private static let designMaxWidth: CGFloat = 1440
    private static let designMaxHeight: CGFloat = 900
    private static let optionsColumnMaxWidth: CGFloat = 480
    private static let aiMenuBadgeImage: NSImage = AIGlowPalette.menuBadgeImage
    static let logGlowSpeedScale: Double = 0.7


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

    // Independent export toggles (default: all enabled)
    @State private var exportHTMLMax: Bool = true
    @State private var exportHTMLMid: Bool = true
    @State private var exportHTMLMin: Bool = true
    @State private var exportMarkdown: Bool = true
    
    // NEW: Optional "Sidecar" folder export (sorted attachments) next to the HTML/MD export.
    // IMPORTANT: HTML outputs must remain standalone and must NOT depend on the Sidecar folder.
    @State private var exportSortedAttachments: Bool = true
    @State private var deleteOriginalsAfterSidecar: Bool = false

    @State private var detectedParticipants: [String] = []
    @State private var chatPartnerCandidates: [String] = []
    @State private var chatPartnerSelection: String = ""
    @State private var chatPartnerCustomName: String = ""
    @State private var autoDetectedChatPartnerName: String? = nil
    @State private var exporterName: String = ""

    // Optional overrides for participants that appear only as phone numbers in the WhatsApp export
    // Key = phone-number-like participant string as it appears in the export; Value = user-provided display name
    @State private var phoneParticipantOverrides: [String: String] = [:]
    @State private var autoSuggestedPhoneNames: [String: String] = [:]

    @State private var isRunning: Bool = false
    @State private var logText: String = ""

    @State private var showReplaceAlert: Bool = false
    @State private var replaceExistingNames: [String] = []
    @State private var showDeleteOriginalsAlert: Bool = false
    @State private var deleteOriginalCandidates: [URL] = []
    @State private var didSetInitialWindowSize: Bool = false

    // MARK: - View

    var body: some View {
        mainContent
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Self.waGreen)
        .background(WhatsAppBackground().ignoresSafeArea())
        .onAppear {
            applyInitialWindowSizeIfNeeded()
            if let u = chatURL, detectedParticipants.isEmpty {
                refreshParticipants(for: u)
            }
        }
        .alert("Datei bereits vorhanden", isPresented: $showReplaceAlert) {
            Button("Abbrechen", role: .cancel) { }
            Button("Ersetzen") {
                guard let chatURL, let outBaseURL else { return }
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
                    }
                }
            }
        }
        .waCard()
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
        }
        .controlSize(.small)
    }

    private var outputsHeader: some View {
        HStack(spacing: 6) {
            Text("Ausgaben")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            helpIcon("Jede Ausgabe ist unabhängig aktivierbar. Standard: alles aktiviert (inkl. Sidecar).")
        }
    }

    private var outputsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Toggle(isOn: $exportHTMLMax) {
                    HStack(spacing: 6) {
                        Text("Max (1 Datei, alles enthalten)")
                        helpIcon("Beste Lesbarkeit und volle Offline-Ansicht. Alle Medien werden direkt in die HTML eingebettet (Base64). Ideal für langfristige persönliche Archivierung und für Weitergabe als einzelne Datei. Nachteil: Datei wird deutlich größer.")
                    }
                }
                .disabled(isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportHTMLMid) {
                    HStack(spacing: 6) {
                        Text("Kompakt (mit Vorschauen)")
                        helpIcon("Gute Übersicht bei deutlich kleinerer Dateigröße. Vorschaubilder (Thumbnails) sind eingebettet, große Medien bleiben ausgelagert. Ideal, wenn der Chat-Charakter erhalten bleiben soll, aber die Datei nicht zu groß werden darf.")
                    }
                }
                .disabled(isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Toggle(isOn: $exportHTMLMin) {
                    HStack(spacing: 6) {
                        Text("E-Mail (minimal, Text-only)")
                        helpIcon("Sehr klein und robust für E-Mail & schnelles Teilen. Keine Medien werden eingebettet oder angezeigt. Ideal, wenn nur Text/Struktur zählt oder wenn Mail-Gateways große Anhänge blocken.")
                    }
                }
                .disabled(isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportMarkdown) {
                    HStack(spacing: 6) {
                        Text("Markdown (.md)")
                        helpIcon("Erzeugt eine Markdown-Ausgabe des Chats.")
                    }
                }
                .disabled(isRunning)
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
                helpIcon("Wie MAX in der Darstellung, aber ohne Base64-Overhead. HTML referenziert Medien im Sidecar-Ordner (z. B. ./media/…). Ideal für Weitergabe als ZIP (HTML + Ordner), weil die Gesamtgröße kleiner bleibt und Browser schneller laden.")
            }
        }
        .disabled(isRunning)
    }

    private var deleteOriginalsToggle: some View {
        Toggle(isOn: $deleteOriginalsAfterSidecar) {
            HStack(spacing: 6) {
                Text("Originaldaten nach Sidecar-Export löschen (optional, nach Prüfung)")
                helpIcon("Vergleicht die kopierten Sidecar-Daten mit den Originalen. Nur bei identischer Kopie erscheint eine Nachfrage zum Löschen der Originale.")
            }
        }
        .disabled(isRunning || !exportSortedAttachments)
    }

    private var chatPartnerSelectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Exportiert von:")
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
                        .aiGlow(active: shouldShowAIGlow, cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat-Partner")

                    if chatPartnerSelection == Self.customChatPartnerTag {
                        TextField("z. B. Alex", text: $chatPartnerCustomName)
                            .textFieldStyle(.roundedBorder)
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
                            if let suggestion = autoSuggestedPhoneNames[num] {
                                let match = normalizedDisplayName(newValue).lowercased() == normalizedDisplayName(suggestion).lowercased()
                                if !match {
                                    autoSuggestedPhoneNames[num] = nil
                                }
                            }
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
                            .aiGlow(active: shouldShowPhoneSuggestionGlow(for: num), cornerRadius: 6)

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
                    Label(isRunning ? "Läuft…" : "Exportieren", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            Button {
                logText = ""
            } label: {
                Label("Log leeren", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(isRunning)

            Spacer()
        }
        .padding(.top, 2)
    }

    private var logSection: some View {
        WASection(title: "Log", systemImage: "doc.text.magnifyingglass") {
            ScrollView([.vertical, .horizontal]) {
                Text(logText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .waCard()
        .aiGlow(
            active: isRunning,
            cornerRadius: 14,
            boost: isRunning,
            speedScale: Self.logGlowSpeedScale,
            debugTag: "log"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
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
                Text("WhatsApp-Chat-Export nach HTML und Markdown")
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

    private func suggestedChatSubfolderName(chatURL: URL, chatPartner: String) -> String {
        let trimmed = normalizedDisplayName(chatPartner)
        if !trimmed.isEmpty {
            return safeFolderName(trimmed)
        }
        if let fromExportFolder = chatNameFromExportFolder(chatURL: chatURL) {
            return safeFolderName(fromExportFolder)
        }
        let raw = chatPartnerCandidates.first ?? detectedParticipants.first ?? "WhatsApp Chat"
        return safeFolderName(raw)
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
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func normalizedKey(_ s: String) -> String {
        normalizedDisplayName(s).lowercased()
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
        var x = s
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
        guard let autoDetectedChatPartnerName else { return false }
        return normalizedKey(chatPartnerSelection) == normalizedKey(autoDetectedChatPartnerName)
    }

    private func shouldShowPhoneSuggestionGlow(for phone: String) -> Bool {
        guard let suggestion = autoSuggestedPhoneNames[phone] else { return false }
        let current = normalizedDisplayName(phoneParticipantOverrides[phone] ?? "")
        guard !current.isEmpty else { return false }
        return current.lowercased() == normalizedDisplayName(suggestion).lowercased()
    }

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
        panel.message = "Bitte die WhatsApp-Exportdatei _chat.txt auswählen."
        panel.prompt = "Auswählen"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.plainText]

        if panel.runModal() == .OK {
            chatURL = panel.url
            if let url = panel.url { refreshParticipants(for: url) }
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

        if panel.runModal() == .OK {
            outBaseURL = panel.url
        }
    }

    // MARK: - Participants

    @MainActor
    private func refreshParticipants(for chatURL: URL) {
        do {
            var parts = try WhatsAppExportService.participants(chatURL: chatURL)
            let usedFallbackParticipant = parts.isEmpty
            if parts.isEmpty { parts = ["Ich"] }
            detectedParticipants = parts

            let partnerHintRaw = chatNameFromExportFolder(chatURL: chatURL)
            let partnerHint = partnerHintRaw?.trimmingCharacters(in: .whitespacesAndNewlines)

            let detectedMeRaw = try? WhatsAppExportService.detectMeName(chatURL: chatURL)
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
            for (phone, suggestion) in autoSuggestedPhoneNames {
                guard phones.contains(phone) else { continue }
                let current = normalizedDisplayName(newOverrides[phone] ?? "")
                if !current.isEmpty,
                   current.lowercased() == normalizedDisplayName(suggestion).lowercased() {
                    newAutoSuggested[phone] = suggestion
                }
            }
            if let partnerHint, phones.count == 1, parts.count == 2 {
                let phone = phones[0]
                let existing = newOverrides[phone]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if existing.isEmpty {
                    newOverrides[phone] = partnerHint
                    newAutoSuggested[phone] = partnerHint
                }
            }
            if let partnerHint, parts.count == 2, let detectedExporter {
                if let partnerRaw = parts.first(where: { normalizedKey($0) != normalizedKey(detectedExporter) }),
                   Self.isPhoneNumberLike(partnerRaw) {
                    let existing = newOverrides[partnerRaw]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if existing.isEmpty {
                        newOverrides[partnerRaw] = partnerHint
                        newAutoSuggested[partnerRaw] = partnerHint
                    }
                }
            }
            phoneParticipantOverrides = newOverrides
            autoSuggestedPhoneNames = newAutoSuggested

            var candidates: [String] = []
            if parts.count > 2 {
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
            let fallbackPartner = chatNameFromExportFolder(chatURL: chatURL) ?? "WhatsApp Chat"
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

    nonisolated private func appendLog(_ s: String) {
        Task { @MainActor in
            self.logText += s
            if !s.hasSuffix("\n") { self.logText += "\n" }
        }
    }

    private func logExportTiming(_ label: String, startUptime: TimeInterval) {
        let deltaMs = Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
        print("[ExportTiming] \(label) +\(deltaMs)ms")
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

    // MARK: - Export

    @MainActor
    private func startExport(chatURL: URL, outDir: URL, allowOverwrite: Bool) {
        guard !isRunning else { return }
        let t0 = ProcessInfo.processInfo.systemUptime
        logExportTiming("T0 tap", startUptime: t0)
        isRunning = true
        logExportTiming("T1 running-state set", startUptime: t0)

        if detectedParticipants.isEmpty {
            refreshParticipants(for: chatURL)
        }

        let exporter = resolvedExporterName()
        if exporter.isEmpty {
            appendLog("ERROR: Exporteur konnte nicht ermittelt werden.")
            isRunning = false
            return
        }

        let chatPartner = resolvedChatPartnerName()
        if chatPartner.isEmpty {
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

        if selectedVariantsInOrder.isEmpty && !wantsMD && !wantsSidecar {
            appendLog("ERROR: Bitte mindestens eine Ausgabe aktivieren (HTML, Markdown oder Sidecar).")
            isRunning = false
            return
        }

        let subfolderName = suggestedChatSubfolderName(chatURL: chatURL, chatPartner: chatPartner)
        let exportDir = outDir.appendingPathComponent(subfolderName, isDirectory: true)

        let context = ExportContext(
            chatURL: chatURL,
            outDir: outDir,
            exportDir: exportDir,
            allowOverwrite: allowOverwrite,
            exporter: exporter,
            chatPartner: chatPartner,
            participantNameOverrides: participantNameOverrides,
            selectedVariantsInOrder: selectedVariantsInOrder,
            wantsMD: wantsMD,
            wantsSidecar: wantsSidecar,
            wantsDeleteOriginals: wantsDeleteOriginals,
            htmlLabel: htmlLabel
        )

        Task {
            logExportTiming("T2 export task enqueued", startUptime: t0)
            await runExportFlow(context: context, startUptime: t0)
        }
    }

    @MainActor
    private func runExportFlow(context: ExportContext, startUptime: TimeInterval) async {
        defer { isRunning = false }

        await Task.yield()
        logExportTiming("T3 pre-processing begin", startUptime: startUptime)

        let append: @Sendable (String) -> Void = { [appendLog] message in
            appendLog(message)
        }
        let logger = ExportProgressLogger(append: append, startUptime: startUptime)
        logger.log("=== Export gestartet ===")
        logExportTiming("T4 first log line", startUptime: startUptime)

        let variantSummary = context.selectedVariantsInOrder.map { $0.logLabel }
        let variantsLine = variantSummary.isEmpty ? "AUS" : variantSummary.joined(separator: ", ")
        logger.log("Ausgaben: HTML \(variantsLine) · Markdown \(context.wantsMD ? "AN" : "AUS") · Sidecar \(context.wantsSidecar ? "AN" : "AUS")")
        logger.log("Originale löschen: \(context.wantsDeleteOriginals ? "AN" : "AUS")")
        logger.log("Zielordner: \(context.exportDir.lastPathComponent)")
        logger.log("Chat-Partner: \(context.chatPartner) · Exportiert von: \(context.exporter)")

        do {
            logger.log("Prüfe vorhandene Ausgaben…")
            var preflightPulse = ProgressPulse(
                message: "Prüfung läuft…",
                interval: 6,
                log: append
            )
            preflightPulse.start()
            defer { preflightPulse.stop() }

            let preflight = try await Task.detached(priority: .userInitiated) {
                try Self.performOutputPreflight(context: context)
            }.value

            if preflight.existing.isEmpty {
                logger.log("Keine vorhandenen Ausgaben gefunden.")
            } else if context.allowOverwrite {
                logger.log("Vorhandene Ausgaben werden ersetzt: \(preflight.existing.count) Datei(en).")
            } else {
                throw WAExportError.outputAlreadyExists(urls: preflight.existing)
            }

            logger.log("Verarbeite Chat…")
            var exportPulse = ProgressPulse(
                message: "Export läuft…",
                interval: 8,
                log: append
            )
            exportPulse.start()
            defer { exportPulse.stop() }

            let workResult = try await Task.detached(priority: .userInitiated) {
                try await Self.performExportWork(
                    context: context,
                    baseName: preflight.baseName,
                    log: append
                )
            }.value

            lastResult = ExportResult(
                primaryHTML: workResult.primaryHTML,
                htmls: workResult.htmls,
                md: workResult.md
            )

            if context.wantsDeleteOriginals {
                await offerSidecarDeletionIfPossible(
                    chatURL: context.chatURL,
                    outDir: workResult.exportDir,
                    baseHTMLName: workResult.baseHTMLName
                )
            }

            let producedFiles = (workResult.htmls + (workResult.md.map { [$0] } ?? []))
                .map { $0.lastPathComponent }
                .joined(separator: ", ")
            logger.log("Export abgeschlossen in \(logger.elapsedString()).")
            if !producedFiles.isEmpty {
                logger.log("Erzeugte Dateien: \(producedFiles)")
            }
            logger.log("Zielordner: \(workResult.exportDir.lastPathComponent)")
        } catch {
            if let waErr = error as? WAExportError {
                switch waErr {
                case .outputAlreadyExists(let urls):
                    replaceExistingNames = urls.map { $0.lastPathComponent }
                    showReplaceAlert = true
                    let count = urls.count
                    logger.log("Vorhandene Ausgaben gefunden: \(count) Datei(en). Warte auf Bestätigung zum Ersetzen…")
                    return
                }
            }
            logger.log("ERROR: \(error)")
        }
    }

    nonisolated private static func performOutputPreflight(context: ExportContext) throws -> OutputPreflight {
        let fm = FileManager.default
        let baseName = try WhatsAppExportService.computeOutputBaseName(
            chatURL: context.chatURL,
            meNameOverride: context.exporter,
            participantNameOverrides: context.participantNameOverrides
        )

        var existing: [URL] = []
        let exportDir = context.exportDir
        let baseHTML = exportDir.appendingPathComponent("\(baseName).html")
        if fm.fileExists(atPath: baseHTML.path) { existing.append(baseHTML) }

        let baseMD = exportDir.appendingPathComponent("\(baseName).md")
        if fm.fileExists(atPath: baseMD.path) { existing.append(baseMD) }

        if context.wantsSidecar {
            let sidecarFolder = exportDir.appendingPathComponent(baseName, isDirectory: true)
            if fm.fileExists(atPath: sidecarFolder.path) { existing.append(sidecarFolder) }
        }

        for variant in context.selectedVariantsInOrder {
            let suffix = Self.htmlVariantSuffix(for: variant)
            let variantURL = exportDir.appendingPathComponent("\(baseName)\(suffix).html")
            if fm.fileExists(atPath: variantURL.path) { existing.append(variantURL) }
        }

        return OutputPreflight(baseName: baseName, existing: existing)
    }

    nonisolated private static func performExportWork(
        context: ExportContext,
        baseName: String,
        log: @Sendable (String) -> Void
    ) async throws -> ExportWorkResult {
        let fm = FileManager.default
        let exportDir = context.exportDir

        // exportDir exists by workflow (picked by user + subfolder), but creating it is harmless.
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        func makeTempDir() throws -> URL {
            let tmp = exportDir.appendingPathComponent(".wa_export_tmp_\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }

        func htmlDestURL(baseName: String, variant: HTMLVariant) -> URL {
            let name = baseName + Self.htmlVariantSuffix(for: variant) + ".html"
            return exportDir.appendingPathComponent(name)
        }

        let baseHTMLName = "\(baseName).html"

        let plannedHTMLs: [URL] = context.selectedVariantsInOrder.map {
            htmlDestURL(baseName: baseName, variant: $0)
        }

        if context.allowOverwrite {
            for u in plannedHTMLs where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        }

        // Choose a primary variant for the exportDir run.
        // Needed for Sidecar and/or Markdown, or for the first selected HTML.
        let primaryVariant: HTMLVariant = context.selectedVariantsInOrder.first ?? .textOnly

        log("Generiere \(Self.htmlVariantLogLabel(for: primaryVariant))…")
        // Run once into exportDir so Sidecar (if enabled) lands in the target folder.
        let first = try await WhatsAppExportService.export(
            chatURL: context.chatURL,
            outDir: exportDir,
            meNameOverride: context.exporter,
            participantNameOverrides: context.participantNameOverrides,
            enablePreviews: primaryVariant.enablePreviews,
            embedAttachments: primaryVariant.embedAttachments,
            embedAttachmentThumbnailsOnly: primaryVariant.thumbnailsOnly,
            exportSortedAttachments: context.wantsSidecar,
            allowOverwrite: context.allowOverwrite
        )

        var htmlByVariant: [HTMLVariant: URL] = [:]

        // Handle HTML created by the exportDir run
        if context.selectedVariantsInOrder.contains(primaryVariant) {
            let dest = htmlDestURL(baseName: baseName, variant: primaryVariant)
            if context.allowOverwrite, fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: first.html, to: dest)
            htmlByVariant[primaryVariant] = dest
            log("Fertig: \(Self.htmlVariantLogLabel(for: primaryVariant)) (\(dest.lastPathComponent))")
        } else {
            // HTML not requested -> delete the generated base HTML
            if fm.fileExists(atPath: first.html.path) {
                try? fm.removeItem(at: first.html)
            }
        }

        // Handle Markdown created by the exportDir run
        var finalMD: URL? = nil
        if context.wantsMD {
            finalMD = first.md
            log("Fertig: Markdown (\(first.md.lastPathComponent))")
        } else if fm.fileExists(atPath: first.md.path) {
            try? fm.removeItem(at: first.md)
        }
        if context.wantsSidecar {
            let sidecarHTML = "\(baseName)-sdc.html"
            log("Fertig: Sidecar (\(sidecarHTML))")
        }

        // Export remaining selected HTML variants into temp folders (no sidecar duplicates)
        for v in context.selectedVariantsInOrder where v != primaryVariant {
            let tmp = try makeTempDir()
            defer { try? fm.removeItem(at: tmp) }

            log("Generiere \(Self.htmlVariantLogLabel(for: v))…")
            let r = try await WhatsAppExportService.export(
                chatURL: context.chatURL,
                outDir: tmp,
                meNameOverride: context.exporter,
                participantNameOverrides: context.participantNameOverrides,
                enablePreviews: v.enablePreviews,
                embedAttachments: v.embedAttachments,
                embedAttachmentThumbnailsOnly: v.thumbnailsOnly,
                exportSortedAttachments: false,
                allowOverwrite: true
            )

            let dest = htmlDestURL(baseName: baseName, variant: v)
            if context.allowOverwrite, fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: r.html, to: dest)
            htmlByVariant[v] = dest
            log("Fertig: \(Self.htmlVariantLogLabel(for: v)) (\(dest.lastPathComponent))")
        }

        // Stable order for result/logging
        let ordered: [HTMLVariant] = [.embedAll, .thumbnailsOnly, .textOnly]
        let htmls: [URL] = ordered.compactMap { htmlByVariant[$0] }
        let primaryHTML: URL? = htmlByVariant[.embedAll] ?? htmls.first

        return ExportWorkResult(
            exportDir: exportDir,
            baseHTMLName: baseHTMLName,
            htmls: htmls,
            md: finalMD,
            primaryHTML: primaryHTML
        )
    }

    @MainActor
    private func offerSidecarDeletionIfPossible(chatURL: URL, outDir: URL, baseHTMLName: String) async {
        let baseStem = (baseHTMLName as NSString).deletingPathExtension
        let sidecarBaseDir = outDir.appendingPathComponent(baseStem, isDirectory: true)
        let originalDir = chatURL.deletingLastPathComponent()

        appendLog("Sidecar: Prüfe Originaldaten…")

        let verification = await Task.detached(priority: .utility) {
            WhatsAppExportService.verifySidecarCopies(
                originalExportDir: originalDir,
                sidecarBaseDir: sidecarBaseDir
            )
        }.value

        if !verification.exportDirMatches {
            appendLog("Sidecar: Export-Ordner stimmt nicht mit der Kopie überein.")
        }
        if verification.zipMatches == false {
            appendLog("Sidecar: Export-ZIP stimmt nicht mit der Kopie überein.")
        }

        let candidates = verification.deletableOriginals
        if candidates.isEmpty {
            appendLog("Sidecar: Keine löschbaren Originale gefunden.")
            return
        }

        deleteOriginalCandidates = candidates
        showDeleteOriginalsAlert = true
        appendLog("Sidecar: Löschung anbieten für \(candidates.map { $0.lastPathComponent }.joined(separator: ", "))")
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

        let (deleted, failed) = result

        for u in deleted {
            appendLog("OK: gelöscht \(u.path)")
        }
        if !failed.isEmpty {
            appendLog("ERROR: Löschen fehlgeschlagen: \(failed.map { $0.path }.joined(separator: ", "))")
        }
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
