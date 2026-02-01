import Foundation

enum WETOutputNaming {
    nonisolated static let sidecarToken = "Sidecar"
    nonisolated static let maxHTMLToken = "MaxHTML"
    nonisolated static let midHTMLToken = "MidHTML"
    nonisolated static let mailHTMLToken = "mailHTML"

    nonisolated static let sourcesFolderName = "Sources"
    nonisolated static let legacyRawFolderName = "__raw"

    nonisolated static func htmlVariantSuffix(for rawValue: String) -> String {
        switch rawValue {
        case "embedAll": return "-\(maxHTMLToken)"
        case "thumbnailsOnly": return "-\(midHTMLToken)"
        case "textOnly": return "-\(mailHTMLToken)"
        default: return "-\(rawValue)"
        }
    }

    nonisolated static func legacyHTMLVariantSuffix(for rawValue: String) -> String {
        switch rawValue {
        case "embedAll": return "-max"
        case "thumbnailsOnly": return "-mid"
        case "textOnly": return "-min"
        default: return "-\(rawValue)"
        }
    }

    nonisolated static func htmlVariantSuffix(for variant: HTMLVariant) -> String {
        htmlVariantSuffix(for: variant.rawValue)
    }

    nonisolated static func htmlVariantFilename(baseName: String, variant: HTMLVariant) -> String {
        "\(baseName)\(htmlVariantSuffix(for: variant)).html"
    }

    nonisolated static func htmlVariantFilename(baseName: String, rawValue: String) -> String {
        "\(baseName)\(htmlVariantSuffix(for: rawValue)).html"
    }

    nonisolated static func legacyHTMLVariantSuffix(for variant: HTMLVariant) -> String {
        legacyHTMLVariantSuffix(for: variant.rawValue)
    }

    nonisolated static func legacyHTMLVariantFilename(baseName: String, variant: HTMLVariant) -> String {
        "\(baseName)\(legacyHTMLVariantSuffix(for: variant)).html"
    }

    nonisolated static func legacyHTMLVariantFilename(baseName: String, rawValue: String) -> String {
        "\(baseName)\(legacyHTMLVariantSuffix(for: rawValue)).html"
    }

    nonisolated static func markdownFilename(baseName: String) -> String {
        "\(baseName).md"
    }

    nonisolated static func sidecarBaseName(baseName: String) -> String {
        "\(baseName)-\(sidecarToken)"
    }

    nonisolated static func sidecarHTMLFilename(baseName: String) -> String {
        "\(sidecarBaseName(baseName: baseName)).html"
    }

    nonisolated static func sidecarFolderName(baseName: String) -> String {
        sidecarBaseName(baseName: baseName)
    }

    nonisolated static func legacySidecarHTMLFilename(baseName: String) -> String {
        "\(baseName)-sdc.html"
    }

    nonisolated static func legacySidecarFolderName(baseName: String) -> String {
        baseName
    }

    nonisolated static func legacyHTMLVariantSuffixes() -> [String] {
        ["-max", "-mid", "-min"]
    }
}
