import Foundation
import AppKit

@MainActor
struct WETExporterPlaceholderCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_EXPORTER_PLACEHOLDER_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private static func run() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let chatURL = root.appendingPathComponent("Fixtures/wet-exporter-placeholder/_chat.txt")

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        do {
            let snapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: chatURL)
            let detection = try WhatsAppExportService.participantDetectionSnapshot(
                chatURL: snapshot.chatURL,
                provenance: snapshot.provenance
            )

            let participants = detection.participants
            let lower = participants.map { $0.lowercased() }
            expect(participants.contains("Person B"), "participants include Person B")
            expect(!lower.contains("du"), "participants exclude Du")
            expect(!lower.contains("you"), "participants exclude You")
            expect(!participants.contains(WhatsAppExportService.exporterPlaceholderToken), "participants exclude placeholder token")

            let meName = try WhatsAppExportService.detectMeName(chatURL: snapshot.chatURL)
            expect(meName == nil, "exporter inference is unknown")
            expect(detection.detection.exporterSelfCandidate == nil, "exporterSelfCandidate is nil")
            expect(detection.detection.exporterPlaceholderSeen, "exporter placeholder detected")

            let messageCount = try WhatsAppExportService._messageCountForTesting(chatURL)
            expect(messageCount == 5, "message count == 5")
        } catch {
            failures.append("unexpected error: \(error)")
        }

        if failures.isEmpty {
            print("WET_EXPORTER_PLACEHOLDER_CHECK: PASS")
        } else {
            print("WET_EXPORTER_PLACEHOLDER_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
    }
}
