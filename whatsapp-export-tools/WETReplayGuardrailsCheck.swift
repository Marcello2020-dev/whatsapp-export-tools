import Foundation
import AppKit

@MainActor
struct WETReplayGuardrailsCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_REPLAY_GUARDRAILS_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private struct VerificationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func run() {
        let root = fixtureRoot()
        let outputWithSources = root.appendingPathComponent("output_with_sources", isDirectory: true)
        let legacyOutput = root.appendingPathComponent("output_legacy_no_sources", isDirectory: true)
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: root.path) {
                try fm.removeItem(at: root)
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            try seedOutputWithSources(at: outputWithSources)
            try seedLegacyOutput(at: legacyOutput)

            // A) Default: legacy output (artifacts, no Sources) is rejected.
            do {
                _ = try WhatsAppExportService.resolveInputSnapshot(inputURL: legacyOutput)
                throw VerificationError(message: "Expected legacy output to be rejected, but resolveInputSnapshot succeeded")
            } catch let error as WAInputError {
                guard case .replaySourcesRequired = error else {
                    throw VerificationError(message: "Expected replaySourcesRequired for legacy output, got: \(error)")
                }
            }

            // B) Replay mode: output root with Sources -> read root is Sources.
            let replaySnapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: outputWithSources)
            guard replaySnapshot.inputMode.isReplay else {
                throw VerificationError(message: "Expected replay mode for output with Sources")
            }
            guard let sourcesRoot = replaySnapshot.inputMode.sourcesRoot else {
                throw VerificationError(message: "Expected sourcesRoot in replay mode")
            }
            let exportDirPath = replaySnapshot.exportDir.standardizedFileURL.path
            if !exportDirPath.hasPrefix(sourcesRoot.standardizedFileURL.path) {
                throw VerificationError(message: "Replay exportDir not under Sources: \(exportDirPath)")
            }

            // C) Replay guard: selecting a folder inside output root but outside Sources rejects.
            let sidecarDir = outputWithSources.appendingPathComponent("Run-Sidecar", isDirectory: true)
            try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
            do {
                _ = try WhatsAppExportService.resolveInputSnapshot(inputURL: sidecarDir)
                throw VerificationError(message: "Expected non-Sources folder inside output root to be rejected")
            } catch let error as WAInputError {
                guard case .replaySourcesRequired = error else {
                    throw VerificationError(message: "Expected replaySourcesRequired for non-Sources folder, got: \(error)")
                }
            }

            // D) Replay mode: Sources folder itself is allowed.
            let sourcesRootInput = outputWithSources.appendingPathComponent(WETOutputNaming.sourcesFolderName, isDirectory: true)
            let sourcesSnapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: sourcesRootInput)
            guard sourcesSnapshot.inputMode.isReplay else {
                throw VerificationError(message: "Expected replay mode when selecting Sources folder")
            }

            print("WET_REPLAY_GUARDRAILS_CHECK: PASS")
        } catch {
            print("WET_REPLAY_GUARDRAILS_CHECK: FAIL: \(error)")
        }

        if NSApp != nil {
            NSApp.terminate(nil)
        } else {
            exit(0)
        }
    }

    private static func fixtureRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["WET_REPLAY_GUARDRAILS_FIXTURE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("_local/fixtures/wet/replay-guardrails", isDirectory: true)
    }

    private static func seedOutputWithSources(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let sourcesRoot = root.appendingPathComponent(WETOutputNaming.sourcesFolderName, isDirectory: true)
        try fm.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)

        let extracted = sourcesRoot.appendingPathComponent("WhatsApp Chat - Sample", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let chat = extracted.appendingPathComponent("Chat.txt")
        try "01.01.2024, 12:00 - User: Hello".write(to: chat, atomically: true, encoding: .utf8)

        let html = root.appendingPathComponent("Run-MaxHTML.html")
        try "<html>max</html>".write(to: html, atomically: true, encoding: .utf8)
        let manifest = root.appendingPathComponent("Run.manifest.json")
        try "{}".write(to: manifest, atomically: true, encoding: .utf8)
    }

    private static func seedLegacyOutput(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let html = root.appendingPathComponent("Run-MaxHTML.html")
        try "<html>max</html>".write(to: html, atomically: true, encoding: .utf8)
        let manifest = root.appendingPathComponent("Run.manifest.json")
        try "{}".write(to: manifest, atomically: true, encoding: .utf8)
        let chat = root.appendingPathComponent("Chat.txt")
        try "01.01.2024, 12:00 - User: Hello".write(to: chat, atomically: true, encoding: .utf8)
    }
}
