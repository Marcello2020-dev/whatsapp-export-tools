import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticsLogView: View {
    static let windowID = "diagnostics-log"

    @EnvironmentObject private var diagnosticsLog: DiagnosticsLogStore

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

    private func copyLogToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsLog.text, forType: .string)
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.title = String(localized: "wet.diagnostics.save.title")
        panel.prompt = String(localized: "wet.diagnostics.save.prompt")
        panel.nameFieldStringValue = "wet-log.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? diagnosticsLog.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
