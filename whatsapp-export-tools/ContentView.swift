import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    private struct ExportResult: Sendable {
        let primaryHTML: URL?
        let htmls: [URL]
        let md: URL?
    }

    private static let customMeTag = "__CUSTOM_ME__"
    private static let labelWidth: CGFloat = 110
    private static let designMaxWidth: CGFloat = 1440
    private static let designMaxHeight: CGFloat = 900
    private static let optionsColumnMaxWidth: CGFloat = 480
    private static let aiGlowColors: [Color] = [
        Color(red: 0.98, green: 0.42, blue: 0.84),
        Color(red: 0.72, green: 0.45, blue: 0.98),
        Color(red: 0.36, green: 0.66, blue: 1.00),
        Color(red: 0.28, green: 0.86, blue: 0.96),
        Color(red: 0.43, green: 0.96, blue: 0.66),
        Color(red: 0.99, green: 0.92, blue: 0.52),
        Color(red: 0.99, green: 0.66, blue: 0.40),
        Color(red: 0.99, green: 0.40, blue: 0.38),
        Color(red: 0.98, green: 0.42, blue: 0.84)
    ]
    private static let aiGlowNSColors: [NSColor] = [
        NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.84, alpha: 1),
        NSColor(calibratedRed: 0.72, green: 0.45, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.66, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.28, green: 0.86, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.43, green: 0.96, blue: 0.66, alpha: 1),
        NSColor(calibratedRed: 0.99, green: 0.92, blue: 0.52, alpha: 1),
        NSColor(calibratedRed: 0.99, green: 0.66, blue: 0.40, alpha: 1),
        NSColor(calibratedRed: 0.99, green: 0.40, blue: 0.38, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.84, alpha: 1)
    ]
    private static let aiMenuBadgeImage: NSImage = {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        if let gradient = NSGradient(colors: aiGlowNSColors) {
            gradient.draw(in: path, angle: 0)
        } else {
            aiGlowNSColors.first?.setFill()
            path.fill()
        }
        NSColor.white.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()


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
    @State private var meSelection: String = ""
    @State private var meCustomName: String = ""
    @State private var autoDetectedMeName: String? = nil

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
    @State private var aiHighlightPhase: Double = 0

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
            if aiHighlightPhase == 0 {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    aiHighlightPhase = 360
                }
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
        .frame(width: Self.optionsColumnMaxWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var optionsSection: some View {
        WASection(title: "Optionen", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                outputAndSidecarOptions
                meSelectionRow
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
                        Text("HTML -max (Maximal: Alles einbetten)")
                        helpIcon("Bettet alle Medien per Base64 direkt in die HTML ein (größte Datei, komplett offline).")
                    }
                }
                .disabled(isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $exportHTMLMid) {
                    HStack(spacing: 6) {
                        Text("HTML -mid (Mittel: Nur Thumbnails)")
                        helpIcon("Bettet nur Thumbnails ein; größere Medien werden referenziert.")
                    }
                }
                .disabled(isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Toggle(isOn: $exportHTMLMin) {
                    HStack(spacing: 6) {
                        Text("HTML -min (Minimal: Nur Text)")
                        helpIcon("Gibt nur Text aus, keine Medien oder Thumbnails.")
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
                Text("Sidecar exportieren (optional, unabhängig von HTML/MD)")
                helpIcon("Erzeugt im Zielordner einen zusätzlichen Sidecar-Ordner und kopiert Attachments aus der WhatsApp-Quelle sortiert in Unterordner (videos/audios/documents). Dateinamen beginnen mit YYYY-MM-DD und behalten die WhatsApp-ID. Die HTML-Dateien bleiben vollständig standalone (keine Abhängigkeit vom Sidecar).")
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

    private var meSelectionRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Eigener Name:")
                helpIcon("Wähle, welcher Name als \"Ich\" markiert wird. Auto-Erkennung kann überschrieben werden. Bei Auto-Erkennung wird die Auswahl farbig hervorgehoben.")
            }
            .frame(width: Self.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    ForEach(detectedParticipants, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { meSelection == name },
                            set: { if $0 { meSelection = name } }
                        )) {
                            Label {
                                Text(name)
                            } icon: {
                                if autoDetectedMeName == name {
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
                        get: { meSelection == Self.customMeTag },
                        set: { if $0 { meSelection = Self.customMeTag } }
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
                        Text(meSelectionDisplayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: mePickerWidth, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )
                    .overlay(aiHighlightBorder(active: shouldShowAIGlow))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Eigener Name")

                if meSelection == Self.customMeTag {
                    TextField("z. B. Marcel", text: $meCustomName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: mePickerWidth, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mePickerWidth: CGFloat {
        let cardPadding: CGFloat = 20
        let labelSpacing: CGFloat = 12
        let available = Self.optionsColumnMaxWidth - cardPadding - Self.labelWidth - labelSpacing
        return max(220, available)
    }

    private var meSelectionDisplayName: String {
        if meSelection == Self.customMeTag {
            let trimmed = meCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Benutzerdefiniert…" : trimmed
        }
        let trimmed = meSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ich" : trimmed
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
                            .overlay(aiHighlightBorder(active: shouldShowPhoneSuggestionGlow(for: num), cornerRadius: 6))

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
        .overlay(aiHighlightBorder(active: isRunning, cornerRadius: 14))
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

    private func suggestedChatSubfolderName(chatURL: URL, meName: String) -> String {
        if let fromExportFolder = chatNameFromExportFolder(chatURL: chatURL) {
            return safeFolderName(fromExportFolder)
        }

        let meNorm = normalizedDisplayName(meName).lowercased()
        let partners = detectedParticipants
            .map { normalizedDisplayName($0) }
            .filter { !$0.isEmpty && $0.lowercased() != meNorm }

        let raw = partners.first ?? detectedParticipants.first ?? "WhatsApp Chat"
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
        guard let autoDetectedMeName else { return false }
        return meSelection == autoDetectedMeName
    }

    private func shouldShowPhoneSuggestionGlow(for phone: String) -> Bool {
        guard let suggestion = autoSuggestedPhoneNames[phone] else { return false }
        let current = normalizedDisplayName(phoneParticipantOverrides[phone] ?? "")
        guard !current.isEmpty else { return false }
        return current.lowercased() == normalizedDisplayName(suggestion).lowercased()
    }

    private func aiHighlightBorder(active: Bool, cornerRadius: CGFloat = 7) -> some View {
        let gradient = AngularGradient(
            gradient: Gradient(colors: Self.aiGlowColors),
            center: .center,
            angle: .degrees(aiHighlightPhase)
        )
        let pulse = 1 + 0.03 * sin(aiHighlightPhase * .pi / 180)

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(gradient, lineWidth: 1.6)
            RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                .stroke(gradient, lineWidth: 6)
                .blur(radius: 8)
                .opacity(0.75)
                .scaleEffect(pulse)
        }
        .padding(2)
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: active)
        .allowsHitTesting(false)
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
            if parts.isEmpty { parts = ["Ich"] }
            detectedParticipants = parts
            let detectedMeRaw = try? WhatsAppExportService.detectMeName(chatURL: chatURL)
            var detectedMe = detectedMeRaw.flatMap { parts.contains($0) ? $0 : nil }

            let partnerHint = chatNameFromExportFolder(chatURL: chatURL)
            if detectedMe == nil, let partnerHint, parts.count == 2 {
                let partnerNorm = normalizedDisplayName(partnerHint).lowercased()
                if parts.contains(where: { normalizedDisplayName($0).lowercased() == partnerNorm }) {
                    detectedMe = parts.first(where: { normalizedDisplayName($0).lowercased() != partnerNorm })
                } else {
                    let phoneCandidates = parts.filter { Self.isPhoneNumberLike($0) }
                    if phoneCandidates.count == 1 {
                        detectedMe = parts.first(where: { $0 != phoneCandidates[0] })
                    }
                }
            }
            autoDetectedMeName = detectedMe

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
            phoneParticipantOverrides = newOverrides
            autoSuggestedPhoneNames = newAutoSuggested

            if meSelection != Self.customMeTag {
                let cur = meSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                if cur.isEmpty || !detectedParticipants.contains(meSelection) {
                    if let detectedMe {
                        meSelection = detectedMe
                    } else {
                        meSelection = detectedParticipants.first ?? "Ich"
                    }
                }
            }
        } catch {
            detectedParticipants = ["Ich"]
            if meSelection != Self.customMeTag { meSelection = "Ich" }
            autoDetectedMeName = nil
            autoSuggestedPhoneNames = [:]
            appendLog("WARN: Teilnehmer konnten nicht ermittelt werden. \(error)")
        }
    }

    private func resolvedMeName() -> String {
        if meSelection == Self.customMeTag {
            return meCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let picked = meSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !picked.isEmpty { return picked }
        return detectedParticipants.first ?? "Ich"
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

        let meTrim = resolvedMeName()
        if meTrim.isEmpty {
            appendLog("ERROR: Bitte einen eigenen Namen auswählen oder einen benutzerdefinierten Namen eingeben.")
            return
        }

        let subfolderName = suggestedChatSubfolderName(chatURL: chatURL, meName: meTrim)
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
        appendLog("Ich: \(meTrim)")

        let participantNameOverrides: [String: String] = phoneParticipantOverrides.reduce(into: [:]) { acc, kv in
            let key = kv.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = kv.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !val.isEmpty {
                acc[key] = val
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
                meNameOverride: meTrim,
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
                meNameOverride: meTrim,
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
                    meNameOverride: meTrim,
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
}
