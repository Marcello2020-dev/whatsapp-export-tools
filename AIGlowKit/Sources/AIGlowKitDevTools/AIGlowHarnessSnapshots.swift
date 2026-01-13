import SwiftUI
import AppKit
import AIGlowKit

@MainActor
public enum AIGlowHarnessSnapshotRunner {
    public static let isEnabled: Bool = ProcessInfo.processInfo.environment["AIGLOW_HARNESS_SNAPSHOT"] == "1"

    public static func runIfNeeded() {
        guard isEnabled else { return }
        AIGlowHarnessPolicy.assertNoExternalDataAccess()
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

        let scenarios = AIGlowHarnessSnapshotScenario.defaultScenarios
        let fixtures = AIGlowHarnessFixtures.snapshotFixtures

        for fixture in fixtures {
            for scenario in scenarios {
                renderSnapshot(
                    fixture: fixture,
                    scenario: scenario,
                    outputDir: outputDir
                )
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private static func snapshotOutputDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIGLOW_HARNESS_SNAPSHOT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("Codex Reports/screenshots", isDirectory: true)
    }

    @available(macOS 13.0, *)
    private static func renderSnapshot(
        fixture: AIGlowHarnessFixture,
        scenario: AIGlowHarnessSnapshotScenario,
        outputDir: URL
    ) {
        let view = AIGlowHarnessSnapshotView(fixture: fixture, scenario: scenario)
            .environment(\.colorScheme, scenario.scheme)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            return
        }

        let filename = "aiglow-harness-\(fixture.id)-\(scenario.name).png"
        let url = outputDir.appendingPathComponent(filename)
        try? png.write(to: url)
    }
}

public struct AIGlowHarnessSnapshotScenario: Hashable, Sendable {
    public let name: String
    public let scheme: ColorScheme

    public static let defaultScenarios: [AIGlowHarnessSnapshotScenario] = [
        AIGlowHarnessSnapshotScenario(name: "light", scheme: .light),
        AIGlowHarnessSnapshotScenario(name: "dark", scheme: .dark)
    ]
}

struct AIGlowHarnessSnapshotView: View {
    let fixture: AIGlowHarnessFixture
    let scenario: AIGlowHarnessSnapshotScenario

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AIGlowHarnessStrings.title)
                    .font(.headline)
                Text("\(fixture.name) • \(scenario.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AIGlowHarnessFixturePreview(fixture: fixture)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
        }
        .padding(24)
        .frame(
            width: 1100,
            height: 720,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
