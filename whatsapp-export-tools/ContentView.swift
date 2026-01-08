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
    private static let optionsColumnMaxWidth: CGFloat = 640


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
            case .embedAll: return "__max"
            case .thumbnailsOnly: return "__mid"
            case .textOnly: return "__min"
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

    @State private var isRunning: Bool = false
    @State private var logText: String = ""

    @State private var showReplaceAlert: Bool = false
    @State private var replaceExistingNames: [String] = []
    @State private var showDeleteOriginalsAlert: Bool = false
    @State private var deleteOriginalCandidates: [URL] = []
    @State private var didSetInitialWindowSize: Bool = false

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .waCard()

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

            HStack(alignment: .top, spacing: 12) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        WASection(title: "Optionen", systemImage: "slider.horizontal.3") {
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Text("Ausgaben")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        helpIcon("Jede Ausgabe ist unabhängig aktivierbar. Standard: alles aktiviert (inkl. Sidecar).")
                                    }

                                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                        GridRow {
                                            Toggle(isOn: $exportHTMLMax) {
                                                HStack(spacing: 6) {
                                                    Text("HTML __max (Maximal: Alles einbetten)")
                                                    helpIcon("Bettet alle Medien per Base64 direkt in die HTML ein (größte Datei, komplett offline).")
                                                }
                                            }
                                            .disabled(isRunning)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                            Toggle(isOn: $exportHTMLMid) {
                                                HStack(spacing: 6) {
                                                    Text("HTML __mid (Mittel: Nur Thumbnails)")
                                                    helpIcon("Bettet nur Thumbnails ein; größere Medien werden referenziert.")
                                                }
                                            }
                                            .disabled(isRunning)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        GridRow {
                                            Toggle(isOn: $exportHTMLMin) {
                                                HStack(spacing: 6) {
                                                    Text("HTML __min (Minimal: Nur Text)")
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
                                    .controlSize(.small)

                                    Divider()
                                        .padding(.vertical, 1)

                                    Toggle(isOn: $exportSortedAttachments) {
                                        HStack(spacing: 6) {
                                            Text("Sidecar exportieren (optional, unabhängig von HTML/MD)")
                                            helpIcon("Erzeugt im Zielordner einen zusätzlichen Sidecar-Ordner und kopiert Attachments aus der WhatsApp-Quelle sortiert in Unterordner (videos/audios/documents). Dateinamen beginnen mit YYYY-MM-DD und behalten die WhatsApp-ID. Die HTML-Dateien bleiben vollständig standalone (keine Abhängigkeit vom Sidecar).")
                                        }
                                    }
                                    .disabled(isRunning)

                                    Toggle(isOn: $deleteOriginalsAfterSidecar) {
                                        HStack(spacing: 6) {
                                            Text("Originaldaten nach Sidecar-Export löschen (optional, nach Prüfung)")
                                            helpIcon("Vergleicht die kopierten Sidecar-Daten mit den Originalen. Nur bei identischer Kopie erscheint eine Nachfrage zum Löschen der Originale.")
                                        }
                                    }
                                    .disabled(isRunning || !exportSortedAttachments)
                                }
                                .controlSize(.small)

                                HStack(spacing: 12) {
                                    HStack(spacing: 6) {
                                        Text("Ich:")
                                        helpIcon("Wähle, welcher Name als \"Ich\" markiert wird. Auto-Erkennung kann überschrieben werden.")
                                    }
                                    .frame(width: Self.labelWidth, alignment: .leading)

                                    Picker("Ich", selection: $meSelection) {
                                        ForEach(detectedParticipants, id: \.self) { n in
                                            Text(n).tag(n)
                                        }
                                        Divider()
                                        Text("Benutzerdefiniert…").tag(Self.customMeTag)
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 210, alignment: .leading)

                                    if let autoDetectedMeName {
                                        autoBadge(autoDetectedMeName)
                                    }

                                    if meSelection == Self.customMeTag {
                                        TextField("z. B. Marcel", text: $meCustomName)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(minWidth: 210)
                                    }

                                    Spacer(minLength: 0)
                                }

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
                                            HStack(spacing: 12) {
                                                Text(num)
                                                    .font(.system(.body, design: .monospaced))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .frame(width: 210, alignment: .leading)

                                                TextField("Name (z. B. Max Mustermann)", text: bindingForPhoneOverride(num))
                                                    .textFieldStyle(.roundedBorder)

                                                Spacer(minLength: 0)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .waCard()

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
                    .frame(maxWidth: Self.optionsColumnMaxWidth, alignment: .topLeading)
                }
                .frame(maxWidth: Self.optionsColumnMaxWidth, maxHeight: .infinity, alignment: .topLeading)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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

    private func bindingForPhoneOverride(_ number: String) -> Binding<String> {
        Binding(
            get: { phoneParticipantOverrides[number] ?? "" },
            set: { phoneParticipantOverrides[number] = $0 }
        )
    }

    private func displayChatPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.path
    }

    private func displayOutputPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.path
    }

    private func helpIcon(_ text: String) -> some View {
        Image(systemName: "questionmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
            .imageScale(.medium)
            .help(Text(text))
    }

    private func autoBadge(_ name: String) -> some View {
        Label("Auto", systemImage: "sparkle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(.white.opacity(0.08))
            )
            .help(Text("Ich-Perspektive automatisch erkannt: \(name)"))
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
            let detectedMe = detectedMeRaw.flatMap { parts.contains($0) ? $0 : nil }
            autoDetectedMeName = detectedMe

            // Keep overrides only for phone-number-like participants; preserve existing typed names.
            let phones = parts.filter { Self.isPhoneNumberLike($0) }
            var newOverrides: [String: String] = [:]
            for p in phones {
                newOverrides[p] = phoneParticipantOverrides[p] ?? ""
            }
            phoneParticipantOverrides = newOverrides

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
        // outDir exists by workflow (picked by user), but creating it is harmless.
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            appendLog("ERROR: Failed to create output dir: \(outDir.path)\n\(error)")
            return
        }

        if detectedParticipants.isEmpty {
            refreshParticipants(for: chatURL)
        }

        let meTrim = resolvedMeName()
        if meTrim.isEmpty {
            appendLog("ERROR: Bitte 'Ich' auswählen oder einen benutzerdefinierten Namen eingeben.")
            return
        }

        isRunning = true
        defer { isRunning = false }

        appendLog("=== Export ===")
        appendLog("Chat: \(chatURL.path)")
        appendLog("Ziel: \(outDir.path)")
        
        let selectedVariantsInOrder: [HTMLVariant] = [
            exportHTMLMax ? .embedAll : nil,
            exportHTMLMid ? .thumbnailsOnly : nil,
            exportHTMLMin ? .textOnly : nil
        ].compactMap { $0 }

        let wantsMD = exportMarkdown
        let wantsSidecar = exportSortedAttachments

        let htmlLabel: String = {
            var parts: [String] = []
            if exportHTMLMax { parts.append("__max") }
            if exportHTMLMid { parts.append("__mid") }
            if exportHTMLMin { parts.append("__min") }
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
                let tmp = outDir.appendingPathComponent(".wa_export_tmp_\(UUID().uuidString)", isDirectory: true)
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
                return outDir.appendingPathComponent(name)
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
            let plannedMD: URL? = wantsMD ? outDir.appendingPathComponent(baseMDName) : nil

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

            // Choose a primary variant for the outDir run.
            // Needed for Sidecar and/or Markdown, or for the first selected HTML.
            let primaryVariant: HTMLVariant = selectedVariantsInOrder.first ?? .textOnly

            // Run once into outDir so Sidecar (if enabled) lands in the target folder.
            let first = try await WhatsAppExportService.export(
                chatURL: chatURL,
                outDir: outDir,
                meNameOverride: meTrim,
                participantNameOverrides: participantNameOverrides,
                enablePreviews: primaryVariant.enablePreviews,
                embedAttachments: primaryVariant.embedAttachments,
                embedAttachmentThumbnailsOnly: primaryVariant.thumbnailsOnly,
                exportSortedAttachments: wantsSidecar,
                allowOverwrite: allowOverwrite
            )

            var htmlByVariant: [HTMLVariant: URL] = [:]

            // Handle HTML created by the outDir run
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

            // Handle Markdown created by the outDir run
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
                    outDir: outDir,
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
