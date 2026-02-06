import SwiftUI

/// Dedicated help window for Chat Export Studio, opened from the app menu.
struct WETHelpView: View {
    static let windowID = "wet-help"

    @Environment(\.locale) private var locale
    @Environment(\.openWindow) private var openWindow

    private var isGerman: Bool {
        locale.identifier.lowercased().hasPrefix("de")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(isGerman ? "Chat Export Studio Hilfe" : "Chat Export Studio Help")
                    .font(.title2.weight(.semibold))

                section(
                    titleDE: "Schnellstart",
                    titleEN: "Quick Start",
                    linesDE: [
                        "1. Chat-Quelle wählen (Ordner, ZIP oder Chat.txt/_chat.txt).",
                        "2. Zielordner wählen.",
                        "3. Export-Varianten auswählen und Export starten."
                    ],
                    linesEN: [
                        "1. Select a chat source (folder, ZIP, or Chat.txt/_chat.txt).",
                        "2. Select the output directory.",
                        "3. Choose export variants and start export."
                    ]
                )

                section(
                    titleDE: "Eingaben und Quellen",
                    titleEN: "Inputs and Sources",
                    linesDE: [
                        "Bei Ordner-Runs kann eine passende Original-ZIP als Source mitgesichert werden (falls autorisiert).",
                        "Der Sources-Ordner dient der Nachvollziehbarkeit und Replay-Läufen.",
                        "Fehlende Medien in einer alleinstehenden _chat.txt sind erlaubt; der Export bleibt textbasiert."
                    ],
                    linesEN: [
                        "For folder runs, a matching original ZIP can be copied into Sources (if authorized).",
                        "The Sources folder is used for traceability and replay runs.",
                        "A standalone _chat.txt without media is valid; export remains text-based."
                    ]
                )

                section(
                    titleDE: "Output-Optionen",
                    titleEN: "Output Options",
                    linesDE: [
                        "MaxHTML: größte HTML mit eingebetteten Medien.",
                        "Compact/MidHTML: eingebettete Thumbnails, kleinere Ausgabe.",
                        "mailHTML: textnahe, leichte HTML-Variante.",
                        "Markdown und Sidecar können zusätzlich erzeugt werden."
                    ],
                    linesEN: [
                        "MaxHTML: largest HTML with embedded media.",
                        "Compact/MidHTML: embedded thumbnails, smaller output.",
                        "mailHTML: lightweight text-focused HTML variant.",
                        "Markdown and Sidecar can be generated in addition."
                    ]
                )

                section(
                    titleDE: "Originale loeschen",
                    titleEN: "Delete Originals",
                    linesDE: [
                        "Löschen wird erst am Ende angeboten.",
                        "Voraussetzung: Quellen wurden erfolgreich in Sources kopiert.",
                        "Timestamp-Abweichungen (z.B. +3600s bei ZIP) blockieren den Gate nicht, Byte-Mismatch hingegen schon."
                    ],
                    linesEN: [
                        "Deletion is only offered at the very end of the run.",
                        "Requirement: source data was copied successfully into Sources.",
                        "Timestamp drift (for example +3600s from ZIP extraction) does not block the gate, byte mismatch does."
                    ]
                )

                Divider()

                HStack(spacing: 10) {
                    Button(isGerman ? "Diagnose-Log öffnen" : "Open Diagnostics Log") {
                        openWindow(id: DiagnosticsLogView.windowID)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(
                        isGerman
                        ? "Bei Problemen bitte zuerst das Diagnose-Log prüfen."
                        : "For troubleshooting, check the diagnostics log first."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func section(
        titleDE: String,
        titleEN: String,
        linesDE: [String],
        linesEN: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isGerman ? titleDE : titleEN)
                .font(.headline)
            ForEach(isGerman ? linesDE : linesEN, id: \.self) { line in
                Text("- \(line)")
                    .font(.callout)
            }
        }
    }
}
