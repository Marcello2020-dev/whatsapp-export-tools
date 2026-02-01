import Foundation

enum WETPartnerNaming {
    struct NormalizationResult: Equatable {
        let original: String
        let normalized: String

        var didChange: Bool {
            original != normalized
        }
    }

    static func normalizedPartnerFolderName(_ raw: String, maxLen: Int = 120) -> String {
        normalizePartnerFolderName(raw, maxLen: maxLen).normalized
    }

    static func normalizePartnerFolderName(_ raw: String, maxLen: Int = 120) -> NormalizationResult {
        let collapsed = normalizedWhitespace(raw)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(separator: " ")
        let dedupedTokens: [Substring]

        if tokens.count >= 2 {
            let last = tokens[tokens.count - 1]
            let prev = tokens[tokens.count - 2]
            if String(last).caseInsensitiveCompare(String(prev)) == .orderedSame {
                dedupedTokens = Array(tokens.dropLast())
            } else {
                dedupedTokens = Array(tokens)
            }
        } else {
            dedupedTokens = Array(tokens)
        }

        let rejoined = dedupedTokens.joined(separator: " ")
        let normalized = safeFolderName(rejoined, maxLen: maxLen)
        return NormalizationResult(original: trimmed, normalized: normalized)
    }

    static func safeFolderName(_ s: String, maxLen: Int = 120) -> String {
        var x = s.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        let filteredScalars = x.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        x = String(String.UnicodeScalarView(filteredScalars))
        x = x.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        x = x.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        if x.isEmpty { x = "WhatsApp Chat" }
        if x.count > maxLen {
            x = String(x.prefix(maxLen)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        return x
    }

    private static func normalizedWhitespace(_ raw: String) -> String {
        let filteredScalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(filteredScalars))
        let normalized = cleaned.precomposedStringWithCanonicalMapping
        return normalized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
