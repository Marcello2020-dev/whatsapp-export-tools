import SwiftUI
import AppKit

/// Generates AI-glow snapshot images when the environment flag is enabled.
@MainActor
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

        let scenarios: [(String, ColorScheme, Bool, Bool)] = [
            ("dark-idle", .dark, false, false),
            ("dark-running", .dark, true, false),
            ("light-idle", .light, false, false),
            ("light-running", .light, true, false),
            ("dark-idle-reduce-transparency", .dark, false, true),
            ("light-idle-reduce-transparency", .light, false, true)
        ]

        for (name, scheme, isRunning, reduceTransparency) in scenarios {
            renderSnapshot(
                name: name,
                scheme: scheme,
                isRunning: isRunning,
                reduceTransparency: reduceTransparency,
                outputDir: outputDir
            )
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
    private static func renderSnapshot(
        name: String,
        scheme: ColorScheme,
        isRunning: Bool,
        reduceTransparency: Bool,
        outputDir: URL
    ) {
        let view = AIGlowSnapshotView(isRunning: isRunning)
            .environment(\.colorScheme, scheme)
            .environment(\.aiGlowReduceTransparencyOverride, reduceTransparency)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            return
        }

        let url = outputDir.appendingPathComponent("ai-glow-\(name).png")
        try? png.write(to: url)
    }
}

struct AIGlowSnapshotView: View {
    let isRunning: Bool
    @State private var sampleName: String = "Sample Contact"
    @State private var samplePhoneName: String = "Sample Contact"

    private var logGlowStyle: AIGlowStyle {
        AIGlowStyle.default.withSpeedScale(0.7)
    }

    private var sampleLog: String {
        [
            "=== Export Preview ===",
            "Chat: /path/to/chat.txt",
            "Output: /path/to/output",
            "HTML: max, mid, min",
            "Sidecar: enabled",
            "Exported by: Example User",
            "Chat partner: Sample Contact"
        ].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Glow Snapshot")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Chat partner")
                    .frame(width: 120, alignment: .leading)
                TextField("", text: $sampleName)
                    .textFieldStyle(.roundedBorder)
                    .aiGlow(active: true, isRunning: isRunning, cornerRadius: 6)
            }

            HStack(spacing: 12) {
                Text("+00 000 000000")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 120, alignment: .leading)
                TextField("", text: $samplePhoneName)
                    .textFieldStyle(.roundedBorder)
                    .aiGlow(active: true, isRunning: isRunning, cornerRadius: 6)
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
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .aiGlow(active: true, isRunning: isRunning, cornerRadius: 12, style: logGlowStyle)

            Spacer()
        }
        .padding(24)
        .frame(width: 900, height: 620, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}
