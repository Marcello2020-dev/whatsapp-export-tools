import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticsLogView: View {
    static let windowID = "diagnostics-log"
    static let windowTitle = "Diagnostics Log"

    @EnvironmentObject private var diagnosticsLog: DiagnosticsLogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Copy Log") {
                    copyLogToPasteboard()
                }
                .buttonStyle(.bordered)

                Button("Save Log…") {
                    saveLog()
                }
                .buttonStyle(.bordered)

                Button("Clear Log") {
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
        panel.title = "Save Log"
        panel.prompt = "Save"
        panel.nameFieldStringValue = "wet-log.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? diagnosticsLog.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
