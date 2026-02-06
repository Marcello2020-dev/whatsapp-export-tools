import Foundation

/// Central naming scheme for generated exports so every artifact uses a stable suffix/token.
enum WETOutputNaming {
    /// Token appended to base names for the sidecar directory.
    nonisolated static let sidecarToken = "Sidecar"
    /// Token used for the "max" HTML variant.
    nonisolated static let maxHTMLToken = "MaxHTML"
    /// Token used for the "compact" HTML variant.
    nonisolated static let midHTMLToken = "MidHTML"
    /// Token used for the text-only HTML variant (email-friendly).
    nonisolated static let mailHTMLToken = "mailHTML"

    /// Constant names for generated sibling folders.
    nonisolated static let sourcesFolderName = "Sources"
    nonisolated static let legacyRawFolderName = "__raw"

    /// Returns the output suffix used for a vanity raw variant string (e.g., embedAll, thumbnailsOnly).
    nonisolated static func htmlVariantSuffix(for rawValue: String) -> String {
        switch rawValue {
        case "embedAll": return "-\(maxHTMLToken)"
        case "thumbnailsOnly": return "-\(midHTMLToken)"
        case "textOnly": return "-\(mailHTMLToken)"
        default: return "-\(rawValue)"
        }
    }

    /// Legacy suffixes used by previous WET releases.
    nonisolated static func legacyHTMLVariantSuffix(for rawValue: String) -> String {
        switch rawValue {
        case "embedAll": return "-max"
        case "thumbnailsOnly": return "-mid"
        case "textOnly": return "-min"
        default: return "-\(rawValue)"
        }
    }

    /// Suffix helper that consumes a strongly typed `HTMLVariant`.
    nonisolated static func htmlVariantSuffix(for variant: HTMLVariant) -> String {
        htmlVariantSuffix(for: variant.rawValue)
    }

    /// Constructs the HTML filename for a base export name plus a variant suffix.
    nonisolated static func htmlVariantFilename(baseName: String, variant: HTMLVariant) -> String {
        "\(baseName)\(htmlVariantSuffix(for: variant)).html"
    }

    /// Same as above but takes a raw string variant (used for backwards compatibility).
    nonisolated static func htmlVariantFilename(baseName: String, rawValue: String) -> String {
        "\(baseName)\(htmlVariantSuffix(for: rawValue)).html"
    }

    /// Returns the legacy suffix string for the provided variant case.
    nonisolated static func legacyHTMLVariantSuffix(for variant: HTMLVariant) -> String {
        legacyHTMLVariantSuffix(for: variant.rawValue)
    }

    /// Legacy HTML filenames matching the old suffix set.
    nonisolated static func legacyHTMLVariantFilename(baseName: String, variant: HTMLVariant) -> String {
        "\(baseName)\(legacyHTMLVariantSuffix(for: variant)).html"
    }

    /// Legacy HTML filenames from string variants.
    nonisolated static func legacyHTMLVariantFilename(baseName: String, rawValue: String) -> String {
        "\(baseName)\(legacyHTMLVariantSuffix(for: rawValue)).html"
    }

    /// Markdown export uses `.md`.
    nonisolated static func markdownFilename(baseName: String) -> String {
        "\(baseName).md"
    }

    /// Helper for the base name of the sidecar directory.
    nonisolated static func sidecarBaseName(baseName: String) -> String {
        "\(baseName)-\(sidecarToken)"
    }

    /// HTML filename inside the sidecar folder.
    nonisolated static func sidecarHTMLFilename(baseName: String) -> String {
        "\(sidecarBaseName(baseName: baseName)).html"
    }

    /// Folder name used for the sidecar bundle.
    nonisolated static func sidecarFolderName(baseName: String) -> String {
        sidecarBaseName(baseName: baseName)
    }

    /// Legacy sidecar HTML (old naming scheme).
    nonisolated static func legacySidecarHTMLFilename(baseName: String) -> String {
        "\(baseName)-sdc.html"
    }

    /// Legacy sidecar folder naming.
    nonisolated static func legacySidecarFolderName(baseName: String) -> String {
        baseName
    }

    /// Convenience list of the legacy suffix strings for detection purposes.
    nonisolated static func legacyHTMLVariantSuffixes() -> [String] {
        ["-max", "-mid", "-min"]
    }
}
