
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {

    private struct ExportResult: Sendable {
        let html: URL
        let md: URL
    }

    private static let customMeTag = "__CUSTOM_ME__"

    // MARK: - Theme

    private static let whatsGreen = Color(
        red: 37.0 / 255.0,
        green: 211.0 / 255.0,
        blue: 102.0 / 255.0
    )

    private static let bgTop = Color(nsColor: .controlBackgroundColor)
    private static let bgBottom = Color(nsColor: .windowBackgroundColor)

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
                    .opacity(0.85)
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

    @State private var noPreviews: Bool = false

    // Default: embed attachments into HTML (single-file export)
    @State private var embedAttachments: Bool = true

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

                    Toggle("Online-Linkvorschauen deaktivieren", isOn: $noPreviews)
                        .toggleStyle(.switch)

                    Toggle("Anhänge in HTML einbetten (Ein-Datei-Export)", isOn: $embedAttachments)
                        .toggleStyle(.switch)

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
        .tint(.accentColor)
        .background(WhatsAppBackground().ignoresSafeArea())
        .onAppear {
            if let u = chatURL, detectedParticipants.isEmpty {
                refreshParticipants(for: u)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Self.whatsGreen)
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
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
        let previewsState = noPreviews ? "deaktiviert" : "aktiv"
        let embedState = embedAttachments ? "ja" : "nein"

        appendLog("Linkvorschauen: \(previewsState)")
        appendLog("Anhänge einbetten: \(embedState)")
        appendLog("Ich: \(meTrim)")

        do {
            let r = try await WhatsAppExportService.export(
                chatURL: chatURL,
                outDir: outDir,
                meNameOverride: meTrim,
                enablePreviews: !noPreviews,
                embedAttachments: embedAttachments
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
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func waCard() -> some View {
        modifier(WACard())
    }
}
