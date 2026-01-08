import SwiftUI
import AppKit

/// Generates AI-glow snapshot images when the environment flag is enabled.
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
