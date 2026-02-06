import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Provides a small utility pane that lets the user inspect, copy, save, or clear the live diagnostics log.
struct DiagnosticsLogView: View {
    /// Fixed identifier used when opening the diagnostics sheet/window.
    static let windowID = "diagnostics-log"

    @Environment(\.locale) private var locale
    @EnvironmentObject private var diagnosticsLog: DiagnosticsLogStore

    /// Primary view: control buttons and a monospace text editor for the streamed log output.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("wet.diagnostics.copy") {
                    copyLogToPasteboard()
                }
                .buttonStyle(.bordered)

                Button("wet.diagnostics.save") {
                    saveLog()
                }
                .buttonStyle(.bordered)

                Button("wet.diagnostics.clear") {
                    diagnosticsLog.clear()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            TextEditor(text: .constant(diagnosticsLog.displayText))
                .font(.system(.body, design: .monospaced))
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 320)
    }

    /// Copies the accumulated log text to the global pasteboard for easy sharing.
    private func copyLogToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsLog.text, forType: .string)
    }

    /// Presents a save panel so the user can persist the log out to disk as `wet-log.txt`.
    private func saveLog() {
        let panel = NSSavePanel()
        panel.title = String(localized: "wet.diagnostics.save.title", locale: locale)
        panel.prompt = String(localized: "wet.diagnostics.save.prompt", locale: locale)
        panel.nameFieldStringValue = "wet-log.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? diagnosticsLog.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
