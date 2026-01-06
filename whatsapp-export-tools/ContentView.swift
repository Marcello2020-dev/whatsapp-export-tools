import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    private struct ExportResult: Sendable {
        let html: URL
        let md: URL
    }

    private static let customMeTag = "__CUSTOM_ME__"

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

    // HTML output variant (ordered by typical size: largest → smallest)
    @State private var htmlVariant: HTMLVariant = .embedAll

    @State private var detectedParticipants: [String] = []
    @State private var meSelection: String = ""
    @State private var meCustomName: String = ""

    @State private var isRunning: Bool = false
    @State private var logText: String = ""

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            header
                .waCard()

            WASection(title: "Eingaben", systemImage: "bubble.left.and.bubble.right.fill") {
                VStack(alignment: .leading, spacing: 12) {

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Chat-Export:")
                                .frame(width: 120, alignment: .leading)

                            Text(chatURL?.path ?? "—")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Auswählen…") { pickChatFile() }
                                .buttonStyle(.bordered)
                        }

                        GridRow {
                            Text("Zielordner:")
                                .frame(width: 120, alignment: .leading)

                            Text(outBaseURL?.path ?? "—")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Auswählen…") { pickOutputFolder() }
                                .buttonStyle(.bordered)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("HTML-Optionen")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Picker("HTML-Variante", selection: $htmlVariant) {
                            ForEach(HTMLVariant.allCases) { v in
                                Text(v.title).tag(v)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text("Reihenfolge nach Dateigröße: Maximal → Mittel → Minimal.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Text("Ich:")
                            .frame(width: 120, alignment: .leading)

                        Picker("Ich", selection: $meSelection) {
                            ForEach(detectedParticipants, id: \.self) { n in
                                Text(n).tag(n)
                            }
                            Divider()
                            Text("Benutzerdefiniert…").tag(Self.customMeTag)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 240, alignment: .leading)

                        if meSelection == Self.customMeTag {
                            TextField("z. B. Marcel", text: $meCustomName)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 240)
                        }

                        Spacer(minLength: 0)
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
                        await runExportFlow(chatURL: chatURL, outDir: outBaseURL)
                    }
                } label: {
                    Label(isRunning ? "Läuft…" : "Exportieren", systemImage: "square.and.arrow.up")
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

            WASection(title: "Log", systemImage: "doc.text.magnifyingglass") {
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        Text(logText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .frame(minHeight: geo.size.height, alignment: .topLeading)
                            .padding(8)
                    }
                }
                .frame(minHeight: 280)
            }
            .waCard()
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Self.waGreen)
        .background(WhatsAppBackground().ignoresSafeArea())
        .onAppear {
            if let u = chatURL, detectedParticipants.isEmpty {
                refreshParticipants(for: u)
            }
        }
        .frame(minWidth: 980, minHeight: 780)
    }

    private var header: some View {
        HStack(spacing: 12) {
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
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("WhatsApp Export Tools")
                    .font(.system(size: 16, weight: .semibold))
                Text("WhatsApp-Chat-Export nach HTML und Markdown")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
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

            if meSelection != Self.customMeTag {
                let cur = meSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                if cur.isEmpty || !detectedParticipants.contains(meSelection) {
                    meSelection = detectedParticipants.first ?? "Ich"
                }
            }
        } catch {
            detectedParticipants = ["Ich"]
            if meSelection != Self.customMeTag { meSelection = "Ich" }
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
    private func runExportFlow(chatURL: URL, outDir: URL) async {
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
        appendLog("HTML-Variante: \(htmlVariant.title)")
        appendLog("Ich: \(meTrim)")

        do {
            let r = try await WhatsAppExportService.export(
                chatURL: chatURL,
                outDir: outDir,
                meNameOverride: meTrim,
                enablePreviews: htmlVariant.enablePreviews,
                embedAttachments: htmlVariant.embedAttachments,
                embedAttachmentThumbnailsOnly: htmlVariant.thumbnailsOnly
            )
            lastResult = ExportResult(html: r.html, md: r.md)
            appendLog("OK: wrote \(r.html.lastPathComponent)")
            appendLog("OK: wrote \(r.md.lastPathComponent)")
        } catch {
            appendLog("ERROR: \(error)")
        }
    }
}

// MARK: - Helpers (Dateiebene)

private struct WASection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct WACard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return content
            .padding(12)
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
