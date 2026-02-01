//
//  whatsapp_export_toolsApp.swift
//  whatsapp-export-tools
//
//  Created by Marcel Mißbach on 04.01.26.
//

import SwiftUI

@main
struct whatsapp_export_toolsApp: App {
    @StateObject private var diagnosticsLog = DiagnosticsLogStore()

    init() {
        Task { @MainActor in
            WETBareDomainPreviewCheck.runIfNeeded()
            WETBareDomainLinkifyCheck.runIfNeeded()
            WETSystemMessageCheck.runIfNeeded()
            WETReplaceSelectionCheck.runIfNeeded()
            WETExternalAssetsCheck.runIfNeeded()
            WETDeterminismCheck.runIfNeeded()
            WETReplayGuardrailsCheck.runIfNeeded()
            AIGlowSnapshotRunner.runIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup("WhatsApp Export Tools") {
            Group {
                if WETBareDomainPreviewCheck.isEnabled {
                    Text("Running WET bare-domain preview check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETBareDomainLinkifyCheck.isEnabled {
                    Text("Running WET bare-domain linkify check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETSystemMessageCheck.isEnabled {
                    Text("Running WET system message check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETReplaceSelectionCheck.isEnabled {
                    Text("Running WET replace selection check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETExternalAssetsCheck.isEnabled {
                    Text("Running WET external assets check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETDeterminismCheck.isEnabled {
                    Text("Running WET determinism check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETReplayGuardrailsCheck.isEnabled {
                    Text("Running WET replay guardrails check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if AIGlowSnapshotRunner.isEnabled {
                    AIGlowSnapshotView(isRunning: false)
                } else {
                    ContentView()
                }
            }
            .environmentObject(diagnosticsLog)
            .onAppear {
                WETBareDomainPreviewCheck.runIfNeeded()
                WETBareDomainLinkifyCheck.runIfNeeded()
                WETSystemMessageCheck.runIfNeeded()
                WETReplaceSelectionCheck.runIfNeeded()
                WETExternalAssetsCheck.runIfNeeded()
                WETDeterminismCheck.runIfNeeded()
                WETReplayGuardrailsCheck.runIfNeeded()
                AIGlowSnapshotRunner.runIfNeeded()
            }
        }
        .defaultSize(width: 980, height: 780)
        .commands {
            DiagnosticsLogCommands()
        }

        WindowGroup(DiagnosticsLogView.windowTitle, id: DiagnosticsLogView.windowID) {
            DiagnosticsLogView()
                .environmentObject(diagnosticsLog)
        }
    }
}

private struct DiagnosticsLogCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Diagnostics Log") {
                openWindow(id: DiagnosticsLogView.windowID)
            }
        }
    }
}
