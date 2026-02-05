//
//  whatsapp_export_toolsApp.swift
//  whatsapp-export-tools
//
//  Created by Marcel Mißbach on 04.01.26.
//

import SwiftUI
import AppKit

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
    @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.de.rawValue

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
            WETZipTimestampResolverCheck.runIfNeeded()
            ContentView.WETParallelExportCheck.runIfNeeded()
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
                } else if WETZipTimestampResolverCheck.isEnabled {
                    Text("wet.checks.zipTimestamp")
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
                WETZipTimestampResolverCheck.runIfNeeded()
                ContentView.WETParallelExportCheck.runIfNeeded()
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

@MainActor
private struct WETZipTimestampResolverCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_ZIP_TS_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private static func run() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let tz = TimePolicy.canonicalTimeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        func dosDate(year: Int, month: Int, day: Int) -> UInt16 {
            let y = max(0, year - 1980)
            return UInt16((y << 9) | (month << 5) | day)
        }

        func dosTime(hour: Int, minute: Int, second: Int) -> UInt16 {
            let sec = max(0, min(59, second)) / 2
            return UInt16((hour << 11) | (minute << 5) | sec)
        }

        func components(_ date: Date) -> DateComponents {
            cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        }

        let ut = Date(timeIntervalSince1970: 1_600_000_000)
        let dosD = dosDate(year: 2022, month: 10, day: 1)
        let dosT = dosTime(hour: 10, minute: 30, second: 0)
        let utRes = WhatsAppExportService.ZipEntryTimestampResolver.resolve(
            utMTime: ut,
            dosDate: dosD,
            dosTime: dosT,
            timeZone: tz,
            diagnosticsEnabled: true
        )
        expect(utRes?.mtime == ut, "UT mtime preferred over DOS")
        expect(utRes?.source == .ut5455, "UT source selected")

        let startD = dosDate(year: 2023, month: 3, day: 26)
        let startT1 = dosTime(hour: 1, minute: 30, second: 0)
        let startT2 = dosTime(hour: 3, minute: 30, second: 0)

        let startRes1 = WhatsAppExportService.ZipEntryTimestampResolver.resolve(
            utMTime: nil,
            dosDate: startD,
            dosTime: startT1,
            timeZone: tz,
            diagnosticsEnabled: true
        )
        let startRes2 = WhatsAppExportService.ZipEntryTimestampResolver.resolve(
            utMTime: nil,
            dosDate: startD,
            dosTime: startT2,
            timeZone: tz,
            diagnosticsEnabled: true
        )

        if let d1 = startRes1?.mtime {
            let c1 = components(d1)
            expect(c1.year == 2023 && c1.month == 3 && c1.day == 26 && c1.hour == 1 && c1.minute == 30, "DST start 01:30 components preserved")
            expect(Int(tz.daylightSavingTimeOffset(for: d1)) == 0, "DST start 01:30 offset is 0")
        } else {
            expect(false, "DST start 01:30 resolve")
        }

        if let d2 = startRes2?.mtime {
            let c2 = components(d2)
            expect(c2.year == 2023 && c2.month == 3 && c2.day == 26 && c2.hour == 3 && c2.minute == 30, "DST start 03:30 components preserved")
            expect(Int(tz.daylightSavingTimeOffset(for: d2)) == 3600, "DST start 03:30 offset is 3600")
        } else {
            expect(false, "DST start 03:30 resolve")
        }

        let endD = dosDate(year: 2023, month: 10, day: 29)
        let endT1 = dosTime(hour: 1, minute: 30, second: 0)
        let endT2 = dosTime(hour: 3, minute: 30, second: 0)

        let endRes1 = WhatsAppExportService.ZipEntryTimestampResolver.resolve(
            utMTime: nil,
            dosDate: endD,
            dosTime: endT1,
            timeZone: tz,
            diagnosticsEnabled: true
        )
        let endRes2 = WhatsAppExportService.ZipEntryTimestampResolver.resolve(
            utMTime: nil,
            dosDate: endD,
            dosTime: endT2,
            timeZone: tz,
            diagnosticsEnabled: true
        )

        if let d3 = endRes1?.mtime {
            let c3 = components(d3)
            expect(c3.year == 2023 && c3.month == 10 && c3.day == 29 && c3.hour == 1 && c3.minute == 30, "DST end 01:30 components preserved")
            expect(Int(tz.daylightSavingTimeOffset(for: d3)) == 3600, "DST end 01:30 offset is 3600")
        } else {
            expect(false, "DST end 01:30 resolve")
        }

        if let d4 = endRes2?.mtime {
            let c4 = components(d4)
            expect(c4.year == 2023 && c4.month == 10 && c4.day == 29 && c4.hour == 3 && c4.minute == 30, "DST end 03:30 components preserved")
            expect(Int(tz.daylightSavingTimeOffset(for: d4)) == 0, "DST end 03:30 offset is 0")
        } else {
            expect(false, "DST end 03:30 resolve")
        }

        if failures.isEmpty {
            print("WET_ZIP_TS_CHECK: PASS")
        } else {
            print("WET_ZIP_TS_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
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
    @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.de.rawValue

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
