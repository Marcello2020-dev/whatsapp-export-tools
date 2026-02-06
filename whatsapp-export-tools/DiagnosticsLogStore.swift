import SwiftUI
import Combine

/// Stores the streaming debug log for the UI and exposes it reactively to the console view.
@MainActor
final class DiagnosticsLogStore: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var lines: [String] = []

    private static let padLinesPerSide: Int = 1

    var displayText: String {
        let pad = String(repeating: "\n", count: Self.padLinesPerSide)
        if text.isEmpty {
            return pad + pad
        }
        return pad + text + pad
    }

    /// Adds a chunk of log output (split by newline) while keeping both `text` and `lines` in sync.
    func append(_ s: String) {
        let pieces = s.split(whereSeparator: \.isNewline).map(String.init)
        if pieces.isEmpty { return }
        lines.append(contentsOf: pieces)
        let chunk = pieces.joined(separator: "\n")
        if text.isEmpty {
            text = chunk
        } else {
            text.append("\n")
            text.append(chunk)
        }
    }

    /// Resets the captured log so the console view shows a blank slate without reallocating capacity.
    func clear() {
        lines.removeAll(keepingCapacity: true)
        text = ""
    }
}
