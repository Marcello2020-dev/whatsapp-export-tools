import SwiftUI
import Combine

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

    func clear() {
        lines.removeAll(keepingCapacity: true)
        text = ""
    }
}
