//
//  whatsapp_export_toolsApp.swift
//  whatsapp-export-tools
//
//  Created by Marcel Mißbach on 04.01.26.
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case en
    case de

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

@main
struct whatsapp_export_toolsApp: App {
    @StateObject private var diagnosticsLog = DiagnosticsLogStore()
    @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.en.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .en
    }

    init() {
        Task { @MainActor in
            WETBareDomainPreviewCheck.runIfNeeded()
            WETBareDomainLinkifyCheck.runIfNeeded()
            WETSystemMessageCheck.runIfNeeded()
            WETExporterPlaceholderCheck.runIfNeeded()
            WETReplaceSelectionCheck.runIfNeeded()
            WETExternalAssetsCheck.runIfNeeded()
            WETDeterminismCheck.runIfNeeded()
            WETReplayGuardrailsCheck.runIfNeeded()
            WETOutputStructureDedupCheck.runIfNeeded()
            WETDeleteOriginalsGateCheck.runIfNeeded()
            AIGlowSnapshotRunner.runIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup("wet.app.windowTitle") {
            Group {
                if WETBareDomainPreviewCheck.isEnabled {
                    Text("wet.checks.preview")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETBareDomainLinkifyCheck.isEnabled {
                    Text("wet.checks.linkify")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETSystemMessageCheck.isEnabled {
                    Text("wet.checks.systemMessages")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETExporterPlaceholderCheck.isEnabled {
                    Text("wet.checks.exporterPlaceholder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETReplaceSelectionCheck.isEnabled {
                    Text("wet.checks.replaceSelection")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETExternalAssetsCheck.isEnabled {
                    Text("wet.checks.externalAssets")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETDeterminismCheck.isEnabled {
                    Text("wet.checks.determinism")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETReplayGuardrailsCheck.isEnabled {
                    Text("wet.checks.replayGuardrails")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETOutputStructureDedupCheck.isEnabled {
                    Text("wet.checks.outputStructureDedup")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if WETDeleteOriginalsGateCheck.isEnabled {
                    Text("wet.checks.deleteOriginalsGate")
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
            .environment(\.locale, appLanguage.locale)
            .onAppear {
                WETBareDomainPreviewCheck.runIfNeeded()
                WETBareDomainLinkifyCheck.runIfNeeded()
                WETSystemMessageCheck.runIfNeeded()
                WETExporterPlaceholderCheck.runIfNeeded()
                WETReplaceSelectionCheck.runIfNeeded()
                WETExternalAssetsCheck.runIfNeeded()
                WETDeterminismCheck.runIfNeeded()
                WETReplayGuardrailsCheck.runIfNeeded()
                WETOutputStructureDedupCheck.runIfNeeded()
                WETDeleteOriginalsGateCheck.runIfNeeded()
                AIGlowSnapshotRunner.runIfNeeded()
            }
        }
        .defaultSize(width: 980, height: 780)
        .commands {
            DiagnosticsLogCommands()
            LanguageCommands()
        }

        WindowGroup("wet.diagnostics.title", id: DiagnosticsLogView.windowID) {
            DiagnosticsLogView()
                .environmentObject(diagnosticsLog)
                .environment(\.locale, appLanguage.locale)
        }
    }
}

private struct DiagnosticsLogCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("wet.diagnostics.menuItem") {
                openWindow(id: DiagnosticsLogView.windowID)
            }
        }
    }
}

private struct LanguageCommands: Commands {
    @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.en.rawValue

    var body: some Commands {
        CommandMenu("wet.menu.language") {
            Picker("wet.menu.language.label", selection: $appLanguageRaw) {
                Text("wet.menu.language.english")
                    .tag(AppLanguage.en.rawValue)
                Text("wet.menu.language.german")
                    .tag(AppLanguage.de.rawValue)
            }
        }
    }
}
