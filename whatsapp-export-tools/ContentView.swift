import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    private struct ExportResult: Sendable {
        let primaryHTML: URL?
        let htmls: [URL]
        let md: URL?
    }

    private static let customChatPartnerTag = "__CUSTOM_CHAT_PARTNER__"
    private static let labelWidth: CGFloat = 110
    private static let designMaxWidth: CGFloat = 1440
    private static let designMaxHeight: CGFloat = 900
    private static let optionsColumnMaxWidth: CGFloat = 480
    private static let aiMenuBadgeImage: NSImage = AIGlowPalette.menuBadgeImage


    // MARK: - Export options

    /// Three HTML variants, ordered by typical output size (largest → smallest).
    private enum HTMLVariant: String, CaseIterable, Identifiable {
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

    private struct WhatsAppBackground: View {
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
                Task {
                    guard let chatURL, let outBaseURL else { return }
                    await runExportFlow(chatURL: chatURL, outDir: outBaseURL, allowOverwrite: true)
                }
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
                Task {
                    guard let chatURL, let outBaseURL else {
                        appendLog("ERROR: Bitte zuerst Chat-Export und Zielordner auswählen.")
                        return
                    }
                    await runExportFlow(chatURL: chatURL, outDir: outBaseURL, allowOverwrite: false)
                }
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
        .aiGlow(active: isRunning, cornerRadius: 14, boost: isRunning)
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

    // MARK: - Export

    @MainActor
    private func runExportFlow(chatURL: URL, outDir: URL, allowOverwrite: Bool) async {
        if detectedParticipants.isEmpty {
            refreshParticipants(for: chatURL)
        }

        let exporter = resolvedExporterName()
        if exporter.isEmpty {
            appendLog("ERROR: Exporteur konnte nicht ermittelt werden.")
            return
        }

        let chatPartner = resolvedChatPartnerName()
        if chatPartner.isEmpty {
            appendLog("ERROR: Bitte einen Chat-Partner auswählen.")
            return
        }

        let subfolderName = suggestedChatSubfolderName(chatURL: chatURL, chatPartner: chatPartner)
        let exportDir = outDir.appendingPathComponent(subfolderName, isDirectory: true)

        // exportDir exists by workflow (picked by user + subfolder), but creating it is harmless.
        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        } catch {
            appendLog("ERROR: Failed to create output dir: \(exportDir.path)\n\(error)")
            return
        }

        isRunning = true
        defer { isRunning = false }

        appendLog("=== Export ===")
        appendLog("Chat: \(chatURL.path)")
        appendLog("Ziel: \(exportDir.path)")
        
        let selectedVariantsInOrder: [HTMLVariant] = [
            exportHTMLMax ? .embedAll : nil,
            exportHTMLMid ? .thumbnailsOnly : nil,
            exportHTMLMin ? .textOnly : nil
        ].compactMap { $0 }

        let wantsMD = exportMarkdown
        let wantsSidecar = exportSortedAttachments

        let htmlLabel: String = {
            var parts: [String] = []
            if exportHTMLMax { parts.append("-max") }
            if exportHTMLMid { parts.append("-mid") }
            if exportHTMLMin { parts.append("-min") }
            return parts.isEmpty ? "AUS" : parts.joined(separator: ", ")
        }()

        appendLog("HTML: \(htmlLabel)")
        appendLog("Markdown: \(wantsMD ? "AN" : "AUS")")
        appendLog("Sidecar: \(wantsSidecar ? "AN" : "AUS")")
        let wantsDeleteOriginals = wantsSidecar && deleteOriginalsAfterSidecar
        appendLog("Originale löschen: \(wantsDeleteOriginals ? "AN" : "AUS")")
        appendLog("Exportiert von: \(exporter)")
        appendLog("Chat-Partner: \(chatPartner)")

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
            return
        }
        
        do {
            let fm = FileManager.default

            func makeTempDir() throws -> URL {
                let tmp = exportDir.appendingPathComponent(".wa_export_tmp_\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                return tmp
            }

            func htmlDestURL(baseHTMLName: String, variant: HTMLVariant) -> URL {
                let ext = (baseHTMLName as NSString).pathExtension
                let stem = (baseHTMLName as NSString).deletingPathExtension
                let name: String
                if ext.isEmpty {
                    name = stem + variant.fileSuffix
                } else {
                    name = stem + variant.fileSuffix + "." + ext
                }
                return exportDir.appendingPathComponent(name)
            }

            // Probe once to learn the base filenames produced by the service (no sidecar).
            let probeDir = try makeTempDir()
            defer { try? fm.removeItem(at: probeDir) }

            let probe = try await WhatsAppExportService.export(
                chatURL: chatURL,
                outDir: probeDir,
                meNameOverride: exporter,
                participantNameOverrides: participantNameOverrides,
                enablePreviews: true,
                embedAttachments: true,
                embedAttachmentThumbnailsOnly: false,
                exportSortedAttachments: false,
                allowOverwrite: true
            )

            let baseHTMLName = probe.html.lastPathComponent
            let baseMDName = probe.md.lastPathComponent

            let plannedHTMLs: [URL] = selectedVariantsInOrder.map { htmlDestURL(baseHTMLName: baseHTMLName, variant: $0) }
            let plannedMD: URL? = wantsMD ? exportDir.appendingPathComponent(baseMDName) : nil

            if !allowOverwrite {
                var existing: [URL] = []
                existing.append(contentsOf: plannedHTMLs.filter { fm.fileExists(atPath: $0.path) })
                if let md = plannedMD, fm.fileExists(atPath: md.path) {
                    existing.append(md)
                }
                if !existing.isEmpty {
                    throw WAExportError.outputAlreadyExists(urls: existing)
                }
            } else {
                for u in plannedHTMLs where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
                if let md = plannedMD, fm.fileExists(atPath: md.path) { try? fm.removeItem(at: md) }
            }

            // Choose a primary variant for the exportDir run.
            // Needed for Sidecar and/or Markdown, or for the first selected HTML.
            let primaryVariant: HTMLVariant = selectedVariantsInOrder.first ?? .textOnly

            // Run once into exportDir so Sidecar (if enabled) lands in the target folder.
            let first = try await WhatsAppExportService.export(
                chatURL: chatURL,
                outDir: exportDir,
                meNameOverride: exporter,
                participantNameOverrides: participantNameOverrides,
                enablePreviews: primaryVariant.enablePreviews,
                embedAttachments: primaryVariant.embedAttachments,
                embedAttachmentThumbnailsOnly: primaryVariant.thumbnailsOnly,
                exportSortedAttachments: wantsSidecar,
                allowOverwrite: allowOverwrite
            )

            var htmlByVariant: [HTMLVariant: URL] = [:]

            // Handle HTML created by the exportDir run
            if selectedVariantsInOrder.contains(primaryVariant) {
                let dest = htmlDestURL(baseHTMLName: baseHTMLName, variant: primaryVariant)
                if allowOverwrite, fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: first.html, to: dest)
                htmlByVariant[primaryVariant] = dest
            } else {
                // HTML not requested -> delete the generated base HTML
                if fm.fileExists(atPath: first.html.path) {
                    try? fm.removeItem(at: first.html)
                }
            }

            // Handle Markdown created by the exportDir run
            var finalMD: URL? = nil
            if wantsMD {
                finalMD = first.md
            } else {
                if fm.fileExists(atPath: first.md.path) {
                    try? fm.removeItem(at: first.md)
                }
            }

            // Export remaining selected HTML variants into temp folders (no sidecar duplicates)
            for v in selectedVariantsInOrder where v != primaryVariant {
                let tmp = try makeTempDir()
                defer { try? fm.removeItem(at: tmp) }

                let r = try await WhatsAppExportService.export(
                    chatURL: chatURL,
                    outDir: tmp,
                    meNameOverride: exporter,
                    participantNameOverrides: participantNameOverrides,
                    enablePreviews: v.enablePreviews,
                    embedAttachments: v.embedAttachments,
                    embedAttachmentThumbnailsOnly: v.thumbnailsOnly,
                    exportSortedAttachments: false,
                    allowOverwrite: true
                )

                let dest = htmlDestURL(baseHTMLName: baseHTMLName, variant: v)
                if allowOverwrite, fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: r.html, to: dest)
                htmlByVariant[v] = dest
            }

            // Stable order for result/logging
            let ordered: [HTMLVariant] = [.embedAll, .thumbnailsOnly, .textOnly]
            let htmls: [URL] = ordered.compactMap { htmlByVariant[$0] }
            let primaryHTML: URL? = htmlByVariant[.embedAll] ?? htmls.first

            lastResult = ExportResult(primaryHTML: primaryHTML, htmls: htmls, md: finalMD)

            if htmls.isEmpty {
                appendLog("OK: HTML: AUS")
            } else {
                for u in htmls { appendLog("OK: wrote \(u.lastPathComponent)") }
            }
            if let md = finalMD {
                appendLog("OK: wrote \(md.lastPathComponent)")
            } else {
                appendLog("OK: Markdown: AUS")
            }

            if wantsDeleteOriginals {
                await offerSidecarDeletionIfPossible(
                    chatURL: chatURL,
                    outDir: exportDir,
                    baseHTMLName: baseHTMLName
                )
            }
        } catch {
            if let waErr = error as? WAExportError {
                switch waErr {
                case .outputAlreadyExists(let urls):
                    replaceExistingNames = urls.map { $0.lastPathComponent }
                    showReplaceAlert = true
                    appendLog("WARN: Output exists → Nachfrage anzeigen.")
                    return
                }
            }
            appendLog("ERROR: \(error)")
        }
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

private struct AIGlowPaletteDefinition {
    let name: String
    let ringHex: [UInt32]
    let auraHex: [UInt32]
}

private enum AIGlowPaletteOption: String, CaseIterable {
    case appleBaseline = "apple-baseline"
    case intelligenceGlow = "intelligence-glow"
    case siriPill = "siri-pill"

    var definition: AIGlowPaletteDefinition {
        switch self {
        case .appleBaseline:
            return AIGlowPaletteDefinition(
                name: "Apple Baseline",
                ringHex: [
                    0x457DE3, 0x646DD2, 0xB46AE9, 0xD672AE, 0xEF869D, 0x457DE3
                ],
                auraHex: [
                    0x24457B, 0x31366C, 0x6E418B, 0x87426F, 0x703448, 0x24457B
                ]
            )
        case .intelligenceGlow:
            return AIGlowPaletteDefinition(
                name: "Intelligence Glow",
                ringHex: [
                    0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xFF6778, 0xFFBA71, 0xC686FF
                ],
                auraHex: [
                    0x5A6299, 0x9E7296, 0xA0414B, 0xA07749, 0x5A6299, 0x9E7296
                ]
            )
        case .siriPill:
            return AIGlowPaletteDefinition(
                name: "Siri Pill",
                ringHex: [
                    0xFF6778, 0xFFBA71, 0x8D99FF, 0xF5B9EA, 0xFF6778
                ],
                auraHex: [
                    0xA0414B, 0xA07749, 0x5A6299, 0x9E7296, 0xA0414B
                ]
            )
        }
    }
}

private enum AIGlowPalette {
    static let activeOption: AIGlowPaletteOption = {
        if let raw = ProcessInfo.processInfo.environment["AI_GLOW_PALETTE"],
           let option = AIGlowPaletteOption(rawValue: raw) {
            return option
        }
        return .siriPill
    }()

    static let ringHex: [UInt32] = activeOption.definition.ringHex
    static let auraHex: [UInt32] = activeOption.definition.auraHex
    static let ringColors: [Color] = ringHex.map { Color(hex: $0) }
    static let auraColors: [Color] = auraHex.map { Color(hex: $0) }
    static let ringNSColors: [NSColor] = ringHex.map { NSColor(hex: $0) }
    static let menuBadgeImage: NSImage = .aiGlowBadge(colors: ringNSColors)
    static let paletteName: String = activeOption.definition.name
}

private struct AIGlowStyle {
    let ringColors: [Color]
    let auraColors: [Color]
    let ringLineWidthCore: CGFloat
    let ringLineWidthSoft: CGFloat
    let ringLineWidthBloom: CGFloat
    let ringLineWidthShimmer: CGFloat
    let ringBlurCoreDark: CGFloat
    let ringBlurCoreLight: CGFloat
    let ringBlurSoftDark: CGFloat
    let ringBlurSoftLight: CGFloat
    let ringBlurBloomDark: CGFloat
    let ringBlurBloomLight: CGFloat
    let ringBlurShimmerDark: CGFloat
    let ringBlurShimmerLight: CGFloat
    let ringOpacityCoreDark: Double
    let ringOpacityCoreLight: Double
    let ringOpacitySoftDark: Double
    let ringOpacitySoftLight: Double
    let ringOpacityBloomDark: Double
    let ringOpacityBloomLight: Double
    let ringOpacityShimmerDark: Double
    let ringOpacityShimmerLight: Double
    let ringShimmerAngleOffset: Double
    let innerAuraBlurDark: CGFloat
    let innerAuraBlurLight: CGFloat
    let innerAuraOpacityDark: Double
    let innerAuraOpacityLight: Double
    let outerAuraLineWidth: CGFloat
    let outerAuraBlurDark: CGFloat
    let outerAuraBlurLight: CGFloat
    let outerAuraOpacityDark: Double
    let outerAuraOpacityLight: Double
    let outerAuraSecondaryLineWidth: CGFloat
    let outerAuraSecondaryBlurDark: CGFloat
    let outerAuraSecondaryBlurLight: CGFloat
    let outerAuraSecondaryOpacityDark: Double
    let outerAuraSecondaryOpacityLight: Double
    let outerAuraSecondaryOffset: CGSize
    let outerAuraPadding: CGFloat
    let outerAuraSecondaryPadding: CGFloat
    let ringOuterPadding: CGFloat
    let ringBloomPadding: CGFloat
    let rotationDuration: Double
    let rotationDurationRunning: Double
    let rotationDurationReducedMotion: Double
    let ringBlendModeDark: BlendMode
    let ringBlendModeLight: BlendMode
    let auraBlendModeDark: BlendMode
    let auraBlendModeLight: BlendMode
    let saturationDark: Double
    let saturationLight: Double
    let contrastDark: Double
    let contrastLight: Double
    let runningRingBoostCore: Double
    let runningRingBoostSoft: Double
    let runningRingBoostBloom: Double
    let runningRingBoostShimmer: Double
    let runningInnerAuraBoostDark: Double
    let runningInnerAuraBoostLight: Double
    let runningOuterAuraBoostDark: Double
    let runningOuterAuraBoostLight: Double
    let runningOuterAuraSecondaryBoostDark: Double
    let runningOuterAuraSecondaryBoostLight: Double
    let runningInnerAuraBlurScale: CGFloat
    let runningOuterAuraBlurScale: CGFloat
    let outerPadding: CGFloat

    static let appleIntelligenceDefault = AIGlowStyle(
        ringColors: AIGlowPalette.ringColors,
        auraColors: AIGlowPalette.auraColors,
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
}

private struct AIGlowOverlay: View {
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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
        let duration: Double
        if reduceMotion {
            duration = style.rotationDurationReducedMotion
        } else {
            duration = boost ? style.rotationDurationRunning : style.rotationDuration
        }
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
            withAnimation(.easeOut(duration: 0.35)) {
                boostProgress = 1
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
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

struct AIGlowSnapshotRunner {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["AI_GLOW_SNAPSHOT"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        generateSnapshots()
    }

    private static func generateSnapshots() {
        guard #available(macOS 13.0, *) else { return }

        let outputDir = snapshotOutputDirectory()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            return
        }

        let scenarios: [(String, ColorScheme, Bool)] = [
            ("dark-idle", .dark, false),
            ("dark-running", .dark, true),
            ("light-idle", .light, false),
            ("light-running", .light, true)
        ]

        for (name, scheme, isRunning) in scenarios {
            renderSnapshot(name: name, scheme: scheme, isRunning: isRunning, outputDir: outputDir)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private static func snapshotOutputDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AI_GLOW_SNAPSHOT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("Codex Reports/screenshots", isDirectory: true)
    }

    @available(macOS 13.0, *)
    private static func renderSnapshot(name: String, scheme: ColorScheme, isRunning: Bool, outputDir: URL) {
        let view = ContentView.GlowSnapshotView(isRunning: isRunning)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return
        }

        let url = outputDir.appendingPathComponent("ai-glow-\(name).png")
        try? png.write(to: url)
    }
}

extension ContentView {
    struct GlowSnapshotView: View {
        let isRunning: Bool
        @State private var sampleName: String = "Lisa Nötzold"
        @State private var samplePhoneName: String = "Lisa Nötzold"

        private var sampleLog: String {
            [
                "=== Export ===",
                "Chat: /Users/Marcel/Documents/WhatsApp Chats/WhatsApp Chat - Lisa Nötzold/_chat.txt",
                "Ziel: /Users/Marcel/Desktop/Test WhatsApp",
                "HTML: -max, -mid, -min",
                "Sidecar: AN",
                "Exportiert von: Marcel",
                "Chat-Partner: Lisa Nötzold"
            ].joined(separator: "\n")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Glow Snapshot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("Chat-Partner")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $sampleName)
                        .textFieldStyle(.roundedBorder)
                        .aiGlow(active: true, cornerRadius: 6, boost: isRunning)
                }

                HStack(spacing: 12) {
                    Text("+49 179 5006315")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $samplePhoneName)
                        .textFieldStyle(.roundedBorder)
                        .aiGlow(active: true, cornerRadius: 6, boost: isRunning)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Log")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ScrollView([.vertical, .horizontal]) {
                        Text(sampleLog)
                            .font(.system(.body, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(8)
                    }
                    .frame(height: 200)
                }
                .waCard()
                .aiGlow(active: true, cornerRadius: 14, boost: isRunning)

                Spacer()
            }
            .padding(24)
            .frame(width: 900, height: 620, alignment: .topLeading)
            .background(WhatsAppBackground().ignoresSafeArea())
        }
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

private extension View {
    func waCard() -> some View {
        modifier(WACard())
    }

    func aiGlow(active: Bool, cornerRadius: CGFloat, boost: Bool = false, style: AIGlowStyle = .appleIntelligenceDefault) -> some View {
        background {
            GeometryReader { proxy in
                if proxy.size.width > 0, proxy.size.height > 0 {
                    AIGlowOverlay(
                        active: active,
                        boost: boost,
                        cornerRadius: cornerRadius,
                        style: style,
                        targetSize: proxy.size
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}

private extension NSImage {
    static func aiGlowBadge(colors: [NSColor]) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: path, angle: 0)
        } else {
            colors.first?.setFill()
            path.fill()
        }
        NSColor.white.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
