import Foundation
import AppKit

@MainActor
/// Test harness that ensures placeholder exports (e.g., when WhatsApp says “Du”) don't leak into final names.
struct WETExporterPlaceholderCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_EXPORTER_PLACEHOLDER_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    /// Exercises participant detection/resolution with a suite of fixtures and validates expectations.
    private static func run() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixturesRoot = root.deletingLastPathComponent().appendingPathComponent("Fixtures")
        let chatURL = fixturesRoot.appendingPathComponent("wet-exporter-placeholder/_chat.txt")
        let weakPartnerChatURL = fixturesRoot.appendingPathComponent("wet-weak-partner/000000/Chat.txt")
        let twoPartyChatURL = fixturesRoot.appendingPathComponent("wet-two-party/000000/Chat.txt")
        let groupChatURL = fixturesRoot.appendingPathComponent("wet-group-chat/_chat.txt")
        let groupEventChatURL = fixturesRoot.appendingPathComponent("wet-group-event-bracket/_chat.txt")

        var failures: [String] = []
        // Tracks expectation failures so we can report each failed invariant before exiting.
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
            expect(detection.detection.exporterConfidence == .none, "exporterConfidence is none")
            expect(detection.detection.partnerConfidence != .none, "partnerConfidence is not none")

            let fallback = ContentView.resolveExporterFallback(
                detected: detection.detection.exporterSelfCandidate,
                confidence: detection.detection.exporterConfidence
            )
            expect(fallback.name == "Ich", "fallback exporter uses Ich")
            expect(fallback.confidence == .none, "fallback exporter confidence is none")
            expect(fallback.assumed, "fallback exporter marked assumed")

            let messageCount = try WhatsAppExportService._messageCountForTesting(chatURL)
            expect(messageCount == 5, "message count == 5")

            let swapLabel = WhatsAppExportService.conversationLabelForOutput(
                exporter: "Person A",
                partner: "Person B",
                chatKind: .oneToOne,
                chatURL: snapshot.chatURL
            )
            expect(swapLabel == "Person A ↔ Person B", "label uses exporter/partner")
            let swapLabelReversed = WhatsAppExportService.conversationLabelForOutput(
                exporter: "Person B",
                partner: "Person A",
                chatKind: .oneToOne,
                chatURL: snapshot.chatURL
            )
            expect(swapLabelReversed == "Person B ↔ Person A", "label swaps exporter/partner")
            let noDupLabel = WhatsAppExportService.conversationLabelForOutput(
                exporter: "Person A",
                partner: "Person A",
                chatKind: .oneToOne,
                chatURL: snapshot.chatURL
            )
            expect(!noDupLabel.contains("Person A ↔ Person A"), "label avoids duplicate names")

            let prepared = try WhatsAppExportService.prepareExport(
                chatURL: snapshot.chatURL,
                meNameOverride: "Person A"
            )
            let baseName = WhatsAppExportService.composeExportBaseNameForOutput(
                messages: prepared.messages,
                chatURL: snapshot.chatURL,
                exporter: "Person A",
                partner: "Person A",
                chatKind: .oneToOne
            )
            expect(!baseName.contains("Person A ↔ Person A"), "baseName avoids duplicate names")

            let weakSnapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: weakPartnerChatURL)
            let weakDetection = try WhatsAppExportService.participantDetectionSnapshot(
                chatURL: weakSnapshot.chatURL,
                provenance: weakSnapshot.provenance
            )
            expect(weakDetection.detection.partnerConfidence == .weak, "weak partner confidence for phone-only export")

            let twoPartySnapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: twoPartyChatURL)
            let twoPartyDetection = try WhatsAppExportService.participantDetectionSnapshot(
                chatURL: twoPartySnapshot.chatURL,
                provenance: twoPartySnapshot.provenance
            )
            let derived = ContentView.deriveExporterFromParticipants(
                detectedExporter: twoPartyDetection.detection.exporterSelfCandidate,
                detectedPartner: twoPartyDetection.detection.otherPartyCandidate ?? twoPartyDetection.detection.chatTitleCandidate,
                participants: twoPartyDetection.participants
            )
            expect(derived != nil, "derived exporter from 2 participants")
            let resolvedTwoParty = WhatsAppExportService.resolveParticipants(
                participants: twoPartyDetection.participants,
                detectedExporter: nil,
                detectedPartner: twoPartyDetection.detection.otherPartyCandidate ?? twoPartyDetection.detection.chatTitleCandidate,
                partnerHint: twoPartyDetection.detection.otherPartyCandidate ?? twoPartyDetection.detection.chatTitleCandidate,
                exporterOverride: nil,
                partnerOverride: nil,
                chatKind: twoPartyDetection.detection.chatKind
            )
            expect(!resolvedTwoParty.exporter.isEmpty, "resolved exporter from partner hint")
            expect(resolvedTwoParty.partners.count == 1, "resolved partner count 1")

            let groupSnapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: groupChatURL)
            let groupDetection = try WhatsAppExportService.participantDetectionSnapshot(
                chatURL: groupSnapshot.chatURL,
                provenance: groupSnapshot.provenance,
                preferredMeName: "Person A"
            )
            expect(groupDetection.detection.chatKind == .group, "group chat detected")
            expect(groupDetection.detection.meta.groupTitle == "Group Chat", "group title parsed")
            expect(!groupDetection.participants.contains("Group Chat"), "group title excluded from participants")
            expect(groupDetection.participants.contains("Person A"), "group participants include Person A")
            expect(groupDetection.participants.contains("Person B"), "group participants include Person B")
            expect(groupDetection.participants.contains("Person C"), "group participants include Person C")

            let groupPrepared = try WhatsAppExportService.prepareExport(
                chatURL: groupSnapshot.chatURL,
                meNameOverride: "Person A"
            )
            let groupTemp = FileManager.default.temporaryDirectory.appendingPathComponent(
                "wet-group-check-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: groupTemp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: groupTemp) }

            let groupPartners = groupDetection.participants.filter {
                $0.lowercased() != "person a".lowercased()
            }
            let mdURL = try WhatsAppExportService.renderMarkdown(
                prepared: groupPrepared,
                outDir: groupTemp,
                partnerNamesOverride: groupPartners,
                allowPlaceholderAsMe: true
            )
            let mdText = try String(contentsOf: mdURL, encoding: .utf8)
            expect(mdText.contains("**Person A (Ich)**"), "override marks outgoing in markdown")
            expect(mdText.contains("**Person B**"), "partner line present in markdown")

            let eventMessages = try WhatsAppExportService._messagesForTesting(groupEventChatURL)
            expect(eventMessages.count >= 2, "group event fixture has at least 2 messages")
            if eventMessages.count >= 2 {
                let penultimate = eventMessages[eventMessages.count - 2]
                let last = eventMessages[eventMessages.count - 1]
                let penultimateIsSystem = WhatsAppExportService._isSystemMessageForTesting(
                    authorRaw: penultimate.author,
                    text: penultimate.text
                )
                let lastIsSystem = WhatsAppExportService._isSystemMessageForTesting(
                    authorRaw: last.author,
                    text: last.text
                )
                expect(!penultimateIsSystem, "penultimate user message remains non-system")
                expect(lastIsSystem, "event line parsed as system message")
                expect(last.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "event line has empty author")
                expect(last.text.contains("hat dich entfernt"), "event text captured in system message")
            }

            let fm = FileManager.default
            let tempRoot = fm.temporaryDirectory.appendingPathComponent("wet-resolution-check-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempRoot) }

            let htmlName = WETOutputNaming.htmlVariantFilename(baseName: baseName, variant: .embedAll)
            let htmlURL = tempRoot.appendingPathComponent(htmlName)
            try "ok".write(to: htmlURL, atomically: true, encoding: .utf8)

            let flags = WhatsAppExportService.ManifestArtifactFlags(
                sidecar: false,
                max: true,
                compact: false,
                email: false,
                markdown: false,
                deleteOriginals: false,
                rawArchive: false
            )
            let resolution = WhatsAppExportService.ManifestParticipantResolution(
                exporterConfidence: .none,
                partnerConfidence: .weak,
                exporterWasOverridden: true,
                partnerWasOverridden: true,
                wasSwapped: true
            )
            let result = try WhatsAppExportService.writeDeterministicManifestAndChecksums(
                exportDir: tempRoot,
                baseName: baseName,
                chatURL: snapshot.chatURL,
                messages: prepared.messages,
                meName: prepared.meName,
                artifactRelativePaths: [htmlName],
                flags: flags,
                resolution: resolution,
                allowOverwrite: true,
                debugEnabled: false,
                debugLog: nil
            )
            let manifestText = try String(contentsOf: result.manifestURL, encoding: .utf8)
            expect(manifestText.contains("\"resolution\""), "manifest includes resolution")
            expect(manifestText.contains("\"exporterConfidence\""), "manifest includes exporterConfidence")
            expect(manifestText.contains("\"partnerConfidence\""), "manifest includes partnerConfidence")

#if DEBUG
            let css = WhatsAppExportService._htmlCSSForTesting()
            expect(css.contains(".row.me{justify-content:flex-end;}"), "CSS aligns outgoing rows right")
            expect(css.contains(".row.other{justify-content:flex-start;}"), "CSS aligns incoming rows left")
            expect(css.contains(".bubble{") && css.contains("text-align: left;"), "bubble text aligns left")
            expect(css.contains(".bubble.me .meta{ text-align: right; }"), "outgoing timestamp aligns right")
            if let bubbleMeBlock = cssBlock(css, selector: ".bubble.me") {
                expect(!bubbleMeBlock.contains("text-align"), "bubble.me has no text-align override")
            }
#endif
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

    private static func cssBlock(_ css: String, selector: String) -> String? {
        guard let start = css.range(of: "\(selector){") else { return nil }
        guard let end = css.range(of: "}", range: start.upperBound..<css.endIndex) else { return nil }
        return String(css[start.upperBound..<end.lowerBound])
    }
}
