//
//  WhatsAppExportService.swift
//  whatsapp-export-tools
//
//  Created by Marcel Mißbach on 04.01.26.
//

import Foundation
@preconcurrency import Dispatch


#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(LinkPresentation)
@preconcurrency import LinkPresentation
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Time Policy (Deterministic)

enum TimePolicy {
    nonisolated static let canonicalTimeZone: TimeZone =
        TimeZone(identifier: "Europe/Berlin") ?? TimeZone(secondsFromGMT: 0)!
    nonisolated static let canonicalLocale = Locale(identifier: "en_US_POSIX")
    nonisolated static let canonicalCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = canonicalTimeZone
        return cal
    }()

    nonisolated static let exportStampParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = canonicalLocale
        f.timeZone = canonicalTimeZone
        f.dateFormat = "yyyy.MM.dd HH.mm"
        return f
    }()

    nonisolated static let isoDTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = canonicalLocale
        f.timeZone = canonicalTimeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    nonisolated static let exportDTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = canonicalLocale
        f.timeZone = canonicalTimeZone
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    nonisolated static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = canonicalLocale
        f.timeZone = canonicalTimeZone
        // No seconds; avoid ':' in filenames.
        f.dateFormat = "yyyy.MM.dd HH.mm"
        return f
    }()

    nonisolated static let fileDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = canonicalLocale
        f.timeZone = canonicalTimeZone
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    nonisolated static func iso8601WithOffsetString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = canonicalTimeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    nonisolated private static let exportCreatedStampRe = try! NSRegularExpression(
        pattern: #"Chat\.txt created (\d{4}\.\d{2}\.\d{2} \d{2}\.\d{2})"#,
        options: []
    )

    nonisolated static func exportCreatedDateFromFolderName(_ folderName: String) -> Date? {
        let ns = folderName as NSString
        guard let m = exportCreatedStampRe.firstMatch(
            in: folderName,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let stamp = ns.substring(with: m.range(at: 1))
        return exportStampParser.date(from: stamp)
    }

    nonisolated static func dateFromMSDOSTimestamp(date: UInt16, time: UInt16) -> Date? {
        let seconds = Int(time & 0x1F) * 2
        let minutes = Int((time >> 5) & 0x3F)
        let hours = Int((time >> 11) & 0x1F)

        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = Int((date >> 9) & 0x7F) + 1980

        guard day > 0, month > 0 else { return nil }

        var dc = DateComponents()
        dc.year = year
        dc.month = month
        dc.day = day
        dc.hour = hours
        dc.minute = minutes
        dc.second = seconds
        dc.timeZone = canonicalTimeZone
        return canonicalCalendar.date(from: dc)
    }
}

// MARK: - Models

public struct WAMessage: Sendable {
    public var ts: Date
    public var author: String
    public var text: String
}

public struct WAPreview: Sendable {
    public var url: String
    public var title: String
    public var description: String
    public var imageDataURL: String?
}

public enum WAParticipantChatKind: String, Sendable {
    case oneToOne
    case group
    case unknown
}

public enum WAParticipantDetectionConfidence: String, Sendable {
    case high
    case medium
    case low
}

public struct WAParticipantDetectionEvidence: Sendable {
    public let source: String
    public let excerpt: String
}

public struct WAParticipantDetectionResult: Sendable {
    public let chatKind: WAParticipantChatKind
    public let chatTitleCandidate: String?
    public let otherPartyCandidate: String?
    public let exporterSelfCandidate: String?
    public let confidence: WAParticipantDetectionConfidence
    public let evidence: [WAParticipantDetectionEvidence]
}

public struct WAMediaCounts: Sendable {
    public let images: Int
    public let videos: Int
    public let audios: Int
    public let documents: Int

    public static let zero = WAMediaCounts(images: 0, videos: 0, audios: 0, documents: 0)

    public var total: Int {
        images + videos + audios + documents
    }
}

public struct WAParticipantDetectionSnapshot: Sendable {
    public let participants: [String]
    public let detection: WAParticipantDetectionResult
    public let dateRange: ClosedRange<Date>?
    public let mediaCounts: WAMediaCounts
}

public struct WAInputSnapshot: Sendable {
    public let inputURL: URL
    public let chatURL: URL
    public let exportDir: URL
    public let tempWorkspaceURL: URL?
    public let provenance: WETSourceProvenance
}

public enum WETInputKind: Sendable {
    case folder
    case zip
}

public struct WETSourceProvenance: Sendable {
    public let inputKind: WETInputKind
    public let detectedFolderURL: URL
    public let originalZipURL: URL?
    public let detectedPartnerRaw: String
    public let overridePartnerRaw: String?
}

public enum WAInputError: Error, LocalizedError {
    case unsupportedInput(url: URL)
    case transcriptNotFound(url: URL)
    case ambiguousTranscript(urls: [URL])
    case zipExtractionFailed(url: URL, reason: String)
    case tempWorkspaceCreateFailed(url: URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let url):
            return "Unsupported input. Please select a WhatsApp export folder, ZIP, or Chat.txt/_chat.txt. (\(url.lastPathComponent))"
        case .transcriptNotFound(let url):
            return "Chat.txt or _chat.txt not found in input: \(url.lastPathComponent)"
        case .ambiguousTranscript(let urls):
            return "Multiple transcript candidates found: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))"
        case .zipExtractionFailed(let url, let reason):
            return "ZIP extraction failed for \(url.lastPathComponent): \(reason)"
        case .tempWorkspaceCreateFailed(let url, let underlying):
            return "Could not create temp workspace \(url.lastPathComponent): \(underlying.localizedDescription)"
        }
    }
}

public enum WAExportError: Error, LocalizedError {
    case outputAlreadyExists(urls: [URL])
    case suffixArtifactsFound(names: [String])

    public var errorDescription: String? {
        switch self {
        case .outputAlreadyExists(let urls):
            if urls.isEmpty { return "Output files already exist." }
            if urls.count == 1 { return "Output file already exists: \(urls[0].lastPathComponent)" }
            return "Output files already exist: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))"
        case .suffixArtifactsFound(let names):
            let joined = names.isEmpty ? "unknown artifacts" : names.joined(separator: ", ")
            return "Suffix artifacts detected (clean required): \(joined)"
        }
    }
}

struct SidecarValidationError: Error, LocalizedError, Sendable {
    let suffixArtifacts: [String]

    var errorDescription: String? {
        let joined = suffixArtifacts.joined(separator: ", ")
        return "Sidecar contains forbidden suffix artifacts: \(joined)"
    }
}

struct TemporaryExportFolderCleanupError: Error, LocalizedError, Sendable {
    let failedFolders: [String]

    var errorDescription: String? {
        "Konnte temporäre Export-Ordner nicht entfernen: \(failedFolders.joined(separator: ", "))"
    }
}

struct OutputCollisionError: Error, LocalizedError, Sendable {
    let url: URL

    var errorDescription: String? {
        "Ziel existiert bereits (keine Suffixe erlaubt): \(url.lastPathComponent)"
    }
}

struct StagingDirectoryCreationError: Error, LocalizedError, Sendable {
    let url: URL
    let underlying: Error

    var errorDescription: String? {
        "Konnte temporären Export-Ordner nicht anlegen: \(url.lastPathComponent)"
    }
}

public enum HTMLVariant: String, CaseIterable, Hashable, Sendable {
    case embedAll        // größte Datei
    case thumbnailsOnly  // mittel
    case textOnly        // kleinste Datei

    nonisolated public var filenameSuffix: String {
        switch self {
        case .embedAll: return "-max"
        case .thumbnailsOnly: return "-mid"
        case .textOnly: return "-min"
        }
    }

    // Vorgabe: Previews nur bei textOnly aus.
    nonisolated public var enablePreviews: Bool {
        switch self {
        case .textOnly: return false
        case .embedAll, .thumbnailsOnly: return true
        }
    }

    nonisolated public var embedAttachments: Bool {
        switch self {
        case .textOnly: return false
        case .embedAll, .thumbnailsOnly: return true
        }
    }

    nonisolated public var embedAttachmentThumbnailsOnly: Bool {
        switch self {
        case .embedAll: return false
        case .thumbnailsOnly: return true
        case .textOnly: return false
        }
    }

    nonisolated public var perfLabel: String {
        switch self {
        case .embedAll: return "Max"
        case .thumbnailsOnly: return "Kompakt"
        case .textOnly: return "E-Mail"
        }
    }
}

public struct ExportMultiResult: Sendable {
    public let htmlByVariant: [HTMLVariant: URL]
    public let md: URL

    public var primaryHTML: URL {
        if let u = htmlByVariant[.embedAll] { return u }
        if let u = htmlByVariant[.thumbnailsOnly] { return u }
        return htmlByVariant.values.sorted { $0.lastPathComponent < $1.lastPathComponent }.first!
    }
}

public struct SidecarVerificationResult: Sendable {
    public let originalExportDir: URL
    public let copiedExportDir: URL
    public let originalZip: URL?
    public let copiedZip: URL?
    public let exportDirMatches: Bool
    public let zipMatches: Bool?

    public var deletableOriginals: [URL] {
        var out: [URL] = []
        if exportDirMatches { out.append(originalExportDir) }
        if let z = originalZip, zipMatches == true { out.append(z) }
        return out
    }
}


// MARK: - Service

public enum WhatsAppExportService {

    // ---------------------------
    // Constants / Regex
    // ---------------------------

    nonisolated private static let systemAuthor = "System"

    nonisolated private static let attachmentRelBaseDir: URL? = nil

    // Shared system markers (used for participant filtering, title building, and me-name selection)
    nonisolated private static let systemMarkers: Set<String> = [
        "system",
        "whatsapp",
        "messages to this chat are now secured",
        "nachrichten und anrufe sind ende-zu-ende-verschlüsselt",
    ]

    nonisolated private static func isSystemAuthor(_ name: String) -> Bool {
        let low = _normSpace(name).lowercased()
        if low.isEmpty { return true }
        if low == systemAuthor.lowercased() { return true }
        return systemMarkers.contains(low)
    }

    nonisolated private static let systemTextRegexes: [NSRegularExpression] = [
        // Deleted messages
        try! NSRegularExpression(pattern: #"^du hast (diese|eine) nachricht gelöscht\.?$"#),
        try! NSRegularExpression(pattern: #"^diese nachricht wurde gelöscht\.?$"#),
        try! NSRegularExpression(pattern: #"^you deleted (this|a) message\.?$"#),
        try! NSRegularExpression(pattern: #"^this message was deleted\.?$"#),

        // Block/unblock contact
        try! NSRegularExpression(pattern: #"^du hast diesen kontakt (blockiert|freigegeben)\.?$"#),
        try! NSRegularExpression(pattern: #"^you (blocked|unblocked) this contact\.?$"#),

        // Security code changed (DE)
        try! NSRegularExpression(pattern: #"^dein sicherheitscode für .+ hat sich geändert\.?$"#),

        // Contact cards
        try! NSRegularExpression(pattern: #"^.+ (ist ein kontakt|ist ein neuer kontakt|is a contact|is a new contact)\.?$"#),

        // Calls
        try! NSRegularExpression(pattern: #"^(verpasster|verpasste) (sprachanruf|videoanruf)e?\.?$"#),
        try! NSRegularExpression(pattern: #"^(sprachanruf|videoanruf)\.?$"#),
        try! NSRegularExpression(pattern: #"^(missed )?(voice|video) call(, \d{1,2}:\d{2})?\.?$"#),

        // Group actions (DE)
        try! NSRegularExpression(pattern: #"^.+ hat .+ hinzugefügt\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat .+ entfernt\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat .+ aus der gruppe entfernt\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat die gruppe verlassen\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat die gruppe erstellt\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ ist der gruppe beigetreten\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ ist der gruppe über den einladungslink beigetreten\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ ist über den einladungslink beigetreten\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat den gruppennamen geändert\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat den gruppenbetreff geändert\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat das gruppenbild geändert\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat die gruppenbeschreibung geändert\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat die gruppeninfo geändert\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat die gruppeneinstellungen geändert\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ hat .+ zum admin gemacht\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ ist jetzt admin\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ ist kein admin mehr\.?$"#),
        try! NSRegularExpression(pattern: #"^du wurdest .+ hinzugefügt\.?$"#),
        try! NSRegularExpression(pattern: #"^du wurdest .+ entfernt\.?$"#),
        try! NSRegularExpression(pattern: #"^du bist jetzt admin\.?$"#),
        try! NSRegularExpression(pattern: #"^du bist kein admin mehr\.?$"#),

        // Group actions (EN)
        try! NSRegularExpression(pattern: #"^.+ added .+\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ removed .+\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ left\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ joined using (this|the) group['’]s invite link\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ created (the )?group\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ changed (the )?group (subject|name|description|icon|settings|info)\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ changed this group['’]s (subject|name|description|icon|settings|info)\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ made .+ admin\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ is now an admin\.?$"#),
        try! NSRegularExpression(pattern: #"^.+ is no longer an admin\.?$"#),
        try! NSRegularExpression(pattern: #"^you were added.*$"#),
        try! NSRegularExpression(pattern: #"^you were removed.*$"#),
        try! NSRegularExpression(pattern: #"^you left\.?$"#),
    ]

    struct PreparedExport: Sendable {
        let messages: [WAMessage]
        let meName: String
        let baseName: String
        let chatURL: URL
    }

    nonisolated private static func matchesAnyRegex(_ text: String, patterns: [NSRegularExpression]) -> Bool {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for re in patterns {
            if re.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    nonisolated private static func isSystemMessage(authorRaw: String, text: String) -> Bool {
        // Prefer author-based detection.
        if isSystemAuthor(authorRaw) { return true }

        // Some exports put WhatsApp notices into the message body (or the author field may be empty/"Unbekannt").
        let lowText = normalizedSystemText(text)
        if lowText.isEmpty { return false }

        // Exact markers (when the whole line matches a known WhatsApp/system notice).
        if systemMarkers.contains(lowText) { return true }

        // Strong keyword pairs (avoid overly-broad matches).
        if lowText.contains("ende-zu-ende-verschlüsselt") || lowText.contains("end-to-end encrypted") {
            return true
        }
        if lowText.contains("sicherheitsnummer") && (lowText.contains("geändert") || lowText.contains("changed")) {
            return true
        }
        if lowText.contains("security code") && lowText.contains("changed") {
            return true
        }
        if lowText.contains("telefonnummer") && (lowText.contains("geändert") || lowText.contains("changed")) {
            return true
        }
        if lowText.contains("phone number") && lowText.contains("changed") {
            return true
        }
        if lowText.contains("disappearing messages") || lowText.contains("selbstlöschende nachrichten") {
            return true
        }

        // Pattern-based detection (covers group actions, contact cards, block/unblock, deletions, calls, etc.)
        return matchesAnyRegex(lowText, patterns: systemTextRegexes)
    }

    // ISO-style timestamp + author + text.
    nonisolated private static let patISO = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s+([^:]+?):\s*(.*)$"#,
        options: []
    )

    // German-style export timestamp + author + text.
    nonisolated private static let patDE = try! NSRegularExpression(
        pattern: #"^(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\s+-\s+([^:]+?):\s*(.*)$"#,
        options: []
    )

    // Bracketed timestamp format (often used in exports).
    nonisolated private static let patBracket = try! NSRegularExpression(
        pattern: #"^\[(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\]\s+([^:]+?):\s*(.*)$"#,
        options: []
    )

    // Timestamp-like prefix (used to reject implausible header/container candidates).
    nonisolated private static let patTimestampPrefix = try! NSRegularExpression(
        pattern: #"^\s*(?:\[\s*)?\d{1,4}[./-]\d{1,2}[./-]\d{2,4}(?:[,\]]\s*)?(?:\d{1,2}:\d{2})?"#,
        options: []
    )

    // URLs
    // URL pattern for link extraction.
    nonisolated private static let urlRe = try! NSRegularExpression(
        pattern: #"(https?://[^\s<>\]]+)"#,
        options: [.caseInsensitive]
    )
    nonisolated private static let bareDomainRe = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w@])((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,})(?![\w])"#,
        options: []
    )
    nonisolated private static let markdownLinkRe = try! NSRegularExpression(
        pattern: #"\[[^\]]+\]\([^)]+\)"#,
        options: []
    )
    nonisolated private static let anchorTagRe = try! NSRegularExpression(
        pattern: #"<a\s[^>]*>.*?</a>"#,
        options: [.caseInsensitive]
    )

    nonisolated private static let bareDomainAllowedTLDs: Set<String> = [
        "com", "net", "org", "info", "io", "app", "dev", "edu", "gov", "biz", "xyz", "me", "co"
    ]

    nonisolated private static func isValidBareDomain(_ token: String) -> Bool {
        let t = token.lowercased()
        guard t.contains(".") else { return false }
        if t.hasPrefix(".") || t.hasSuffix(".") { return false }
        if t.hasPrefix("-") || t.hasSuffix("-") { return false }
        if t.contains("..") { return false }

        let labels = t.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count >= 2 else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            if label.hasPrefix("-") || label.hasSuffix("-") { return false }
            for ch in label {
                guard ch.isASCII else { return false }
                if !(ch.isLetter || ch.isNumber || ch == "-") { return false }
            }
        }

        let tld = String(labels.last ?? "")
        if tld.hasPrefix("xn--") { return true }
        if tld.count == 2 { return true }
        return bareDomainAllowedTLDs.contains(tld)
    }

    // Attachments
    // Attachment markers like "<Anhang: filename>".
    nonisolated private static let attachRe = try! NSRegularExpression(
        pattern: #"<\s*Anhang:\s*([^>]+?)\s*>"#,
        options: [.caseInsensitive]
    )

    // Link preview meta parsing (1:1 Regex-Ansatz)
    nonisolated private static let metaTagRe = try! NSRegularExpression(
        pattern: #"<meta\s+[^>]*?>"#,
        options: [.caseInsensitive]
    )
    nonisolated private static let metaAttrRe = try! NSRegularExpression(
        pattern: #"(\w+)\s*=\s*(".*?"|'.*?'|[^\s>]+)"#,
        options: []
    )
    nonisolated private static let titleTagRe = try! NSRegularExpression(
        pattern: #"<title>(.*?)</title>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    // Weekday mapping (Monday=0 ... Sunday=6).
    nonisolated private static let weekdayDE: [Int: String] = [
        0: "Montag",
        1: "Dienstag",
        2: "Mittwoch",
        3: "Donnerstag",
        4: "Freitag",
        5: "Samstag",
        6: "Sonntag",
    ]

    // Date formatters (stable, deterministic)
    nonisolated private static let canonicalTimeZone: TimeZone = TimePolicy.canonicalTimeZone
    nonisolated private static let canonicalLocale = TimePolicy.canonicalLocale
    nonisolated private static let canonicalCalendar: Calendar = TimePolicy.canonicalCalendar
    nonisolated private static let exportStampParser: DateFormatter = TimePolicy.exportStampParser

    // Date formatters (stable)
    nonisolated private static let isoDTFormatter: DateFormatter = TimePolicy.isoDTFormatter
    nonisolated private static let exportDTFormatter: DateFormatter = TimePolicy.exportDTFormatter

    // File-name friendly stamps (Finder style): dots in dates, no seconds, no colon.
    nonisolated private static let fileStampFormatter: DateFormatter = TimePolicy.fileStampFormatter
    nonisolated private static let fileDateOnlyFormatter: DateFormatter = TimePolicy.fileDateOnlyFormatter

    nonisolated private static func iso8601WithOffsetString(_ date: Date) -> String {
        TimePolicy.iso8601WithOffsetString(date)
    }

    // Cache for previews
    private actor PreviewCache {
        private var dict: [String: WAPreview] = [:]
        func get(_ url: String) -> WAPreview? { dict[url] }
        func set(_ url: String, _ val: WAPreview) { dict[url] = val }
    }

    nonisolated private static let previewCache = PreviewCache()

    // Cache for staged attachments (source path -> (relHref, stagedURL)) to avoid duplicate copies.
    nonisolated private static let stagedAttachmentLock = NSLock()
    nonisolated(unsafe) private static var stagedAttachmentMap: [String: (relHref: String, stagedURL: URL)] = [:]
    
    nonisolated private static func resetStagedAttachmentCache() {
        stagedAttachmentLock.lock()
        stagedAttachmentMap.removeAll(keepingCapacity: true)
        stagedAttachmentLock.unlock()
    }

    nonisolated private static let attachmentIndexCondition = NSCondition()
    nonisolated(unsafe) private static var attachmentIndexSnapshot: AttachmentIndexSnapshot? = nil
    nonisolated(unsafe) private static var attachmentIndexBuildInProgress: Bool = false

    nonisolated static func resetAttachmentIndexCache() {
        attachmentIndexCondition.lock()
        attachmentIndexSnapshot = nil
        attachmentIndexBuildInProgress = false
        attachmentIndexCondition.broadcast()
        attachmentIndexCondition.unlock()
    }

    nonisolated private static let thumbnailJPEGCacheLock = NSLock()
    nonisolated(unsafe) private static var thumbnailJPEGCache: [String: Data] = [:]
    nonisolated private static let thumbnailPNGCacheLock = NSLock()
    nonisolated(unsafe) private static var thumbnailPNGCache: [String: String] = [:]
    nonisolated private static let inlineThumbCacheLock = NSLock()
    nonisolated(unsafe) private static var inlineThumbCache: [String: String] = [:]

    nonisolated private static func thumbnailJPEGCacheGet(_ key: String) -> Data? {
        thumbnailJPEGCacheLock.lock()
        defer { thumbnailJPEGCacheLock.unlock() }
        return thumbnailJPEGCache[key]
    }

    nonisolated private static func thumbnailJPEGCacheSet(_ key: String, _ value: Data) {
        thumbnailJPEGCacheLock.lock()
        thumbnailJPEGCache[key] = value
        thumbnailJPEGCacheLock.unlock()
    }

    nonisolated private static func thumbnailPNGCacheGet(_ key: String) -> String? {
        thumbnailPNGCacheLock.lock()
        defer { thumbnailPNGCacheLock.unlock() }
        return thumbnailPNGCache[key]
    }

    nonisolated private static func thumbnailPNGCacheSet(_ key: String, _ value: String) {
        thumbnailPNGCacheLock.lock()
        thumbnailPNGCache[key] = value
        thumbnailPNGCacheLock.unlock()
    }

    nonisolated private static func inlineThumbCacheGet(_ key: String) -> String? {
        inlineThumbCacheLock.lock()
        defer { inlineThumbCacheLock.unlock() }
        return inlineThumbCache[key]
    }

    nonisolated private static func inlineThumbCacheSet(_ key: String, _ value: String) {
        inlineThumbCacheLock.lock()
        inlineThumbCache[key] = value
        inlineThumbCacheLock.unlock()
    }

    nonisolated private static let thumbVersion: Int = 2
    nonisolated private static let thumbMaxPixel: CGFloat = 512
    nonisolated private static let thumbJPEGQuality: CGFloat = 0.74

    nonisolated private static func thumbnailCacheKey(
        for url: URL,
        maxPixel: CGFloat,
        quality: CGFloat? = nil
    ) -> String {
        let src = url.standardizedFileURL
        let attrs = (try? FileManager.default.attributesOfItem(atPath: src.path)) ?? [:]
        let size = attrs[.size] as? UInt64 ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let q = quality.map { "|q=\($0)" } ?? ""
        return "\(src.path)|\(size)|\(mtime)|v\(thumbVersion)|px=\(Int(maxPixel))\(q)"
    }

    nonisolated private static func thumbnailCacheFilename(
        for url: URL,
        maxPixel: CGFloat,
        quality: CGFloat
    ) -> String {
        let key = thumbnailStableKey(for: url, maxPixel: maxPixel, quality: quality)
        let hash = stableHashHex(key)
        return "thumb_\(hash).jpg"
    }

    nonisolated private static func thumbnailStableKey(
        for url: URL,
        maxPixel: CGFloat,
        quality: CGFloat
    ) -> String {
        let src = url.standardizedFileURL
        let attrs = (try? FileManager.default.attributesOfItem(atPath: src.path)) ?? [:]
        let size = attrs[.size] as? UInt64 ?? 0
        let prefixHash = filePrefixHash(src, maxBytes: 256 * 1024)
        let q = Int((quality * 1000).rounded())
        return "\(prefixHash)|\(size)|v\(thumbVersion)|px=\(Int(maxPixel))|q=\(q)"
    }

    nonisolated private static func filePrefixHash(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "0"
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return fnv1a64Hex(data)
    }

    nonisolated static func resetThumbnailCaches() {
        thumbnailJPEGCacheLock.lock()
        thumbnailJPEGCache.removeAll(keepingCapacity: true)
        thumbnailJPEGCacheLock.unlock()

        thumbnailPNGCacheLock.lock()
        thumbnailPNGCache.removeAll(keepingCapacity: true)
        thumbnailPNGCacheLock.unlock()

        inlineThumbCacheLock.lock()
        inlineThumbCache.removeAll(keepingCapacity: true)
        inlineThumbCacheLock.unlock()
    }

    nonisolated private struct PerfStore {
        var attachmentIndexBuildCount = 0
        var attachmentIndexBuildFiles = 0
        var attachmentIndexBuildTime: TimeInterval = 0

        var thumbJPEGCacheHits = 0
        var thumbJPEGMisses = 0
        var thumbJPEGTime: TimeInterval = 0

        var thumbPNGCacheHits = 0
        var thumbPNGMisses = 0
        var thumbPNGTime: TimeInterval = 0

        var inlineThumbCacheHits = 0
        var inlineThumbMisses = 0
        var inlineThumbTime: TimeInterval = 0

        var thumbStoreRequested = 0
        var thumbStoreReused = 0
        var thumbStoreGenerated = 0
        var thumbStoreTime: TimeInterval = 0

        var htmlRenderTimeByLabel: [String: TimeInterval] = [:]
        var htmlWriteTimeByLabel: [String: TimeInterval] = [:]
        var htmlWriteBytesByLabel: [String: Int] = [:]

        var publishTimeByLabel: [String: TimeInterval] = [:]
        var artifactDurationByLabel: [String: TimeInterval] = [:]
    }

    nonisolated struct PerfSnapshot: Sendable {
        let attachmentIndexBuildCount: Int
        let attachmentIndexBuildFiles: Int
        let attachmentIndexBuildTime: TimeInterval

        let thumbJPEGCacheHits: Int
        let thumbJPEGMisses: Int
        let thumbJPEGTime: TimeInterval

        let thumbPNGCacheHits: Int
        let thumbPNGMisses: Int
        let thumbPNGTime: TimeInterval

        let inlineThumbCacheHits: Int
        let inlineThumbMisses: Int
        let inlineThumbTime: TimeInterval

        let thumbStoreRequested: Int
        let thumbStoreReused: Int
        let thumbStoreGenerated: Int
        let thumbStoreTime: TimeInterval

        let htmlRenderTimeByLabel: [String: TimeInterval]
        let htmlWriteTimeByLabel: [String: TimeInterval]
        let htmlWriteBytesByLabel: [String: Int]

        let publishTimeByLabel: [String: TimeInterval]
        let artifactDurationByLabel: [String: TimeInterval]
    }

    nonisolated private static let perfLock = NSLock()
    nonisolated(unsafe) private static var perfStore = PerfStore()

    nonisolated private static func perfRecord(_ update: (inout PerfStore) -> Void) {
        #if DEBUG
        perfLock.lock()
        update(&perfStore)
        perfLock.unlock()
        #else
        _ = update
        #endif
    }

    nonisolated static func resetPerfMetrics() {
        perfLock.lock()
        perfStore = PerfStore()
        perfLock.unlock()
    }

    nonisolated static func perfSnapshot() -> PerfSnapshot {
        perfLock.lock()
        let store = perfStore
        perfLock.unlock()
        return PerfSnapshot(
            attachmentIndexBuildCount: store.attachmentIndexBuildCount,
            attachmentIndexBuildFiles: store.attachmentIndexBuildFiles,
            attachmentIndexBuildTime: store.attachmentIndexBuildTime,
            thumbJPEGCacheHits: store.thumbJPEGCacheHits,
            thumbJPEGMisses: store.thumbJPEGMisses,
            thumbJPEGTime: store.thumbJPEGTime,
            thumbPNGCacheHits: store.thumbPNGCacheHits,
            thumbPNGMisses: store.thumbPNGMisses,
            thumbPNGTime: store.thumbPNGTime,
            inlineThumbCacheHits: store.inlineThumbCacheHits,
            inlineThumbMisses: store.inlineThumbMisses,
            inlineThumbTime: store.inlineThumbTime,
            thumbStoreRequested: store.thumbStoreRequested,
            thumbStoreReused: store.thumbStoreReused,
            thumbStoreGenerated: store.thumbStoreGenerated,
            thumbStoreTime: store.thumbStoreTime,
            htmlRenderTimeByLabel: store.htmlRenderTimeByLabel,
            htmlWriteTimeByLabel: store.htmlWriteTimeByLabel,
            htmlWriteBytesByLabel: store.htmlWriteBytesByLabel,
            publishTimeByLabel: store.publishTimeByLabel,
            artifactDurationByLabel: store.artifactDurationByLabel
        )
    }

    nonisolated private static func recordAttachmentIndexBuild(duration: TimeInterval, fileCount: Int) {
        perfRecord { store in
            store.attachmentIndexBuildCount += 1
            store.attachmentIndexBuildFiles += fileCount
            store.attachmentIndexBuildTime += duration
        }
    }

    nonisolated private static func recordThumbJPEG(duration: TimeInterval, cacheHit: Bool) {
        perfRecord { store in
            if cacheHit {
                store.thumbJPEGCacheHits += 1
            } else {
                store.thumbJPEGMisses += 1
                store.thumbJPEGTime += duration
            }
        }
    }

    nonisolated private static func recordThumbPNG(duration: TimeInterval, cacheHit: Bool) {
        perfRecord { store in
            if cacheHit {
                store.thumbPNGCacheHits += 1
            } else {
                store.thumbPNGMisses += 1
                store.thumbPNGTime += duration
            }
        }
    }

    nonisolated private static func recordInlineThumb(duration: TimeInterval, cacheHit: Bool) {
        perfRecord { store in
            if cacheHit {
                store.inlineThumbCacheHits += 1
            } else {
                store.inlineThumbMisses += 1
                store.inlineThumbTime += duration
            }
        }
    }

    nonisolated private static func recordThumbStoreRequested() {
        perfRecord { store in
            store.thumbStoreRequested += 1
        }
    }

    nonisolated private static func recordThumbStoreReused() {
        perfRecord { store in
            store.thumbStoreReused += 1
        }
    }

    nonisolated private static func recordThumbStoreGenerated(duration: TimeInterval) {
        perfRecord { store in
            store.thumbStoreGenerated += 1
            store.thumbStoreTime += duration
        }
    }

    nonisolated private static func recordHTMLRender(label: String, duration: TimeInterval) {
        perfRecord { store in
            store.htmlRenderTimeByLabel[label, default: 0] += duration
        }
    }

    nonisolated private static func recordHTMLWrite(label: String, duration: TimeInterval, bytes: Int) {
        perfRecord { store in
            store.htmlWriteTimeByLabel[label, default: 0] += duration
            store.htmlWriteBytesByLabel[label, default: 0] += bytes
        }
    }

    nonisolated static func recordPublishDuration(label: String, duration: TimeInterval) {
        perfRecord { store in
            store.publishTimeByLabel[label, default: 0] += duration
        }
    }

    nonisolated static func recordArtifactDuration(label: String, duration: TimeInterval) {
        perfRecord { store in
            store.artifactDurationByLabel[label, default: 0] += duration
        }
    }

    // ---------------------------
    // Shared ThumbnailStore (D2)
    // ---------------------------

    final actor ThumbnailStore {
        private struct ThumbResult {
            let fileURL: URL?
            let generated: Bool
            let duration: TimeInterval
        }

        private let entries: [AttachmentCanonicalEntry]
        private let entriesByName: [String: AttachmentCanonicalEntry]
        private let thumbsDir: URL
        private let allowWrite: Bool
        private let limiter: AsyncLimiter

        private var inFlight: [String: Task<ThumbResult?, Never>] = [:]
        private var dataCache: [String: Data] = [:]
        private var dataURLCache: [String: String] = [:]
        private var hrefCache: [String: String] = [:]

        init(entries: [AttachmentCanonicalEntry], thumbsDir: URL, allowWrite: Bool) {
            self.entries = entries
            var map: [String: AttachmentCanonicalEntry] = [:]
            for entry in entries where map[entry.fileName] == nil {
                map[entry.fileName] = entry
            }
            self.entriesByName = map
            self.thumbsDir = thumbsDir.standardizedFileURL
            self.allowWrite = allowWrite
            let cap = max(1, min(wetConcurrencyCaps.io, 4))
            self.limiter = AsyncLimiter(cap)
        }

        func precomputeAll() async {
            let targets = entries.filter { Self.isThumbnailCandidateExtension($0.sourceURL.pathExtension) }
            guard !targets.isEmpty else { return }
            if ProcessInfo.processInfo.environment["WET_PERF"] == "1" {
                let cap = max(1, min(wetConcurrencyCaps.io, 4))
                print("WET-PERF: thumbs cap=\(cap) jobs=\(targets.count)")
            }
            await withTaskGroup(of: Void.self) { group in
                for entry in targets {
                    group.addTask {
                        _ = await self.ensureThumbnailFile(for: entry)
                    }
                }
            }
        }

        func thumbnailDataURL(fileName: String, allowOriginalFallback: Bool = false) async -> String? {
            guard let entry = entriesByName[fileName] else { return nil }
            let key = entry.canonicalRelPath
            if let cached = dataURLCache[key] {
                return cached
            }

            if let data = await thumbnailData(for: entry) {
                let dataURL = "data:image/jpeg;base64,\(data.base64EncodedString())"
                dataURLCache[key] = dataURL
                return dataURL
            }

            if allowOriginalFallback, Self.isImageExtension(entry.sourceURL.pathExtension) {
                if let dataURL = WhatsAppExportService.fileToDataURL(entry.sourceURL) {
                    dataURLCache[key] = dataURL
                    return dataURL
                }
            }

            return nil
        }

        func thumbnailHref(fileName: String, relativeTo baseDir: URL?) async -> String? {
            guard let entry = entriesByName[fileName] else { return nil }
            let key = entry.canonicalRelPath + "||" + (baseDir?.standardizedFileURL.path ?? "")
            if let cached = hrefCache[key] { return cached }
            guard let fileURL = await ensureThumbnailFile(for: entry) else { return nil }
            let href = WhatsAppExportService.relativeHref(for: fileURL, relativeTo: baseDir)
            hrefCache[key] = href
            return href
        }

        private func thumbnailData(for entry: AttachmentCanonicalEntry) async -> Data? {
            let key = entry.canonicalRelPath
            if let cached = dataCache[key] {
                return cached
            }
            guard let fileURL = await ensureThumbnailFile(for: entry) else { return nil }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            dataCache[key] = data
            return data
        }

        private func ensureThumbnailFile(for entry: AttachmentCanonicalEntry) async -> URL? {
            WhatsAppExportService.recordThumbStoreRequested()
            guard Self.isThumbnailCandidateExtension(entry.sourceURL.pathExtension) else { return nil }
            let key = entry.canonicalRelPath
            let dest = thumbFileURL(for: key)

            if Self.isValidThumbFile(dest) {
                WhatsAppExportService.recordThumbStoreReused()
                return dest
            }

            guard allowWrite else { return nil }

            if let existing = inFlight[key] {
                return (await existing.value)?.fileURL
            }

            let src = entry.sourceURL
            let destURL = dest
            let allowWrite = self.allowWrite
            let limiter = self.limiter

            let task = Task { () -> ThumbResult? in
                guard allowWrite else { return nil }
                return await limiter.withPermit {
                    if Self.isValidThumbFile(destURL) {
                        return ThumbResult(fileURL: destURL, generated: false, duration: 0)
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    guard let jpg = await WhatsAppExportService.thumbnailJPEGData(
                        for: src,
                        maxPixel: thumbMaxPixel,
                        quality: thumbJPEGQuality
                    ) else {
                        return nil
                    }
                    do {
                        try WhatsAppExportService.ensureDirectory(destURL.deletingLastPathComponent())
                        try WhatsAppExportService.writeExclusiveData(jpg, to: destURL)
                    } catch {
                        // Best-effort write; fallback to reuse if file exists.
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    if Self.isValidThumbFile(destURL) {
                        return ThumbResult(fileURL: destURL, generated: true, duration: elapsed)
                    }
                    return nil
                }
            }

            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil

            if let result, let fileURL = result.fileURL {
                if result.generated {
                    WhatsAppExportService.recordThumbStoreGenerated(duration: result.duration)
                } else {
                    WhatsAppExportService.recordThumbStoreReused()
                }
                return fileURL
            }

            return nil
        }

        private nonisolated static func isValidThumbFile(_ url: URL) -> Bool {
            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true else { return false }
            return (rv?.fileSize ?? 0) > 0
        }

        private func thumbFileURL(for canonicalRelPath: String) -> URL {
            let fileName = Self.thumbnailStoreFilename(for: canonicalRelPath)
            return thumbsDir.appendingPathComponent(fileName)
        }

        private static func thumbnailStoreFilename(for canonicalRelPath: String) -> String {
            let q = Int((thumbJPEGQuality * 1000).rounded())
            let key = "\(canonicalRelPath)|v\(thumbVersion)|px=\(Int(thumbMaxPixel))|q=\(q)"
            let hash = stableHashHex(key)
            return "thumb_\(hash).jpg"
        }

        private static func isThumbnailCandidateExtension(_ ext: String) -> Bool {
            let e = ext.lowercased()
            if ["jpg","jpeg","png","gif","webp","heic","heif","tif","tiff","bmp"].contains(e) { return true }
            if ["mp4","mov","m4v"].contains(e) { return true }
            if e == "pdf" { return true }
            return false
        }

        private static func isImageExtension(_ ext: String) -> Bool {
            let e = ext.lowercased()
            return ["jpg","jpeg","png","gif","webp","heic","heif","tif","tiff","bmp"].contains(e)
        }
    }

    // ---------------------------
    // Public API
    // ---------------------------

    /// Resolve a user-selected input (folder, ZIP, or Chat.txt) into a transcript URL.
    public static func resolveInputSnapshot(
        inputURL: URL,
        detectedPartnerRaw: String? = nil,
        overridePartnerRaw: String? = nil
    ) throws -> WAInputSnapshot {
        let fm = FileManager.default
        let input = inputURL.standardizedFileURL
        let detectedRaw = detectedPartnerRaw ?? ""
        let values = try input.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let (chatURL, exportDir) = try resolveTranscript(in: input)
            let provenance = WETSourceProvenance(
                inputKind: .folder,
                detectedFolderURL: exportDir,
                originalZipURL: pickSiblingZipURL(sourceDir: exportDir),
                detectedPartnerRaw: detectedRaw,
                overridePartnerRaw: overridePartnerRaw
            )
            return WAInputSnapshot(
                inputURL: input,
                chatURL: chatURL,
                exportDir: exportDir,
                tempWorkspaceURL: nil,
                provenance: provenance
            )
        }

        if input.pathExtension.lowercased() == "zip" {
            let workspace = deterministicInputWorkspace(for: input)
            do {
                try recreateDirectory(workspace)
            } catch {
                throw WAInputError.tempWorkspaceCreateFailed(url: workspace, underlying: error)
            }
            do {
                try extractZip(at: input, to: workspace)
                let effectiveRoot = try effectiveZipExtractionRoot(
                    workspace: workspace,
                    zipURL: input,
                    detectedPartnerRaw: detectedRaw,
                    overridePartnerRaw: overridePartnerRaw
                )
                let (chatURL, exportDir) = try resolveTranscript(in: effectiveRoot)
                let provenance = WETSourceProvenance(
                    inputKind: .zip,
                    detectedFolderURL: exportDir,
                    originalZipURL: input,
                    detectedPartnerRaw: detectedRaw,
                    overridePartnerRaw: overridePartnerRaw
                )
                return WAInputSnapshot(
                    inputURL: input,
                    chatURL: chatURL,
                    exportDir: exportDir,
                    tempWorkspaceURL: workspace,
                    provenance: provenance
                )
            } catch let error as WAInputError {
                try? fm.removeItem(at: workspace)
                throw error
            } catch {
                try? fm.removeItem(at: workspace)
                throw WAInputError.zipExtractionFailed(url: input, reason: error.localizedDescription)
            }
        }

        let lowerName = input.lastPathComponent.lowercased()
        if lowerName == "chat.txt" || lowerName == "_chat.txt" {
            let exportDir = input.deletingLastPathComponent()
            let provenance = WETSourceProvenance(
                inputKind: .folder,
                detectedFolderURL: exportDir,
                originalZipURL: pickSiblingZipURL(sourceDir: exportDir),
                detectedPartnerRaw: detectedRaw,
                overridePartnerRaw: overridePartnerRaw
            )
            return WAInputSnapshot(
                inputURL: input,
                chatURL: input,
                exportDir: exportDir,
                tempWorkspaceURL: nil,
                provenance: provenance
            )
        }

        throw WAInputError.unsupportedInput(url: input)
    }

    /// Returns unique participant names detected in the chat export (excluding obvious system markers).
    /// Used by the GUI to ask the user who "me" is when --me is not provided.
    public static func participants(chatURL: URL) throws -> [String] {

        let chatPath = chatURL.standardizedFileURL
        let msgs = try parseMessages(chatPath)
        return participants(from: msgs)
    }

    /// Best-effort detection of the exporter ("Ich"-Perspektive) from the chat text.
    /// Returns nil if no reliable signal is found.
    public static func detectMeName(chatURL: URL) throws -> String? {
        let chatPath = chatURL.standardizedFileURL
        let msgs = try parseMessages(chatPath)
        return inferMeName(messages: msgs)
    }

    /// Best-effort participant detection snapshot (participants + evidence + summary data).
    public static func participantDetectionSnapshot(
        chatURL: URL,
        provenance: WETSourceProvenance
    ) throws -> WAParticipantDetectionSnapshot {
        let chatPath = chatURL.standardizedFileURL
        let lines = try loadChatLines(chatPath)
        let msgs = parseMessages(lines)

        let participantsRaw = participants(from: msgs)
        let participants = participantsRaw.map { safeFinderFilename($0) }
        let dateRange = messageDateRange(messages: msgs)
        let mediaCounts = messageMediaCounts(messages: msgs)

        let headerCandidateRaw = headerTitleCandidate(lines: lines)
        let headerCandidate = headerCandidateRaw.map { safeFinderFilename($0) }

        let containerRaw = containerNameCandidates(provenance: provenance)
        let selectedContainerRaw = containerRaw.selected.flatMap { stripChatPrefix($0) }
        let topLevelContainerRaw = containerRaw.topLevel.flatMap { stripChatPrefix($0) }

        let selectedContainer = selectedContainerRaw.map { safeFinderFilename($0) }
        let topLevelContainer = topLevelContainerRaw.map { safeFinderFilename($0) }

        let topLevelDecision = containerCandidateDecision(topLevelContainerRaw)
        let selectedDecision = containerCandidateDecision(selectedContainerRaw)

        let topLevelContainerCandidateRaw = topLevelDecision.candidate
        let selectedContainerCandidateRaw = selectedDecision.candidate
        let topLevelContainerCandidate = topLevelContainerCandidateRaw.map { safeFinderFilename($0) }
        let selectedContainerCandidate = selectedContainerCandidateRaw.map { safeFinderFilename($0) }

        var rejectedCandidates: [(source: String, reason: String)] = []
        var rejectionKeys: Set<String> = []
        let rejectCandidate: (String, String) -> Void = { source, reason in
            let key = "\(source)|\(reason)"
            if rejectionKeys.insert(key).inserted {
                rejectedCandidates.append((source: source, reason: reason))
            }
        }
        if let reason = topLevelDecision.rejection { rejectCandidate("container:top-level", reason) }
        if let reason = selectedDecision.rejection { rejectCandidate("container:selected", reason) }

        let selectedKey = normalizedKey(normalizedParticipantIdentifier(selectedContainerCandidateRaw ?? ""))
        let topLevelKey = normalizedKey(normalizedParticipantIdentifier(topLevelContainerCandidateRaw ?? ""))
        let containerConflict = !selectedKey.isEmpty && !topLevelKey.isEmpty && selectedKey != topLevelKey

        let participantKey: (String) -> String = { normalizedKey(normalizedParticipantIdentifier($0)) }
        var participantByKey: [String: String] = [:]
        for (idx, raw) in participantsRaw.enumerated() {
            let key = participantKey(raw)
            if key.isEmpty { continue }
            if participantByKey[key] == nil {
                participantByKey[key] = participants[idx]
            }
        }

        let resolveCandidate: (String) -> String = { raw in
            let key = participantKey(raw)
            if let match = participantByKey[key] {
                return match
            }
            return safeFinderFilename(raw)
        }

        let selfEvidence = inferMeNameEvidence(messages: msgs)
        let exporterSelfCandidate: String? = {
            guard let raw = selfEvidence?.name else { return nil }
            if let match = participantByKey[participantKey(raw)] {
                return match
            }
            return resolveCandidate(raw)
        }()

        let otherEvidence = inferOtherPartyNameEvidence(messages: msgs)

        let selfKey = exporterSelfCandidate.map { participantKey($0) } ?? ""
        let selfLooseKey = exporterSelfCandidate.map { normalizedPersonKey($0) } ?? ""
        let hasSelf = !selfKey.isEmpty
        let isSelfCandidate: (String) -> Bool = { candidate in
            guard hasSelf else { return false }
            return participantKey(candidate) == selfKey
        }
        let isSelfLikeCandidate: (String) -> Bool = { candidate in
            guard !selfLooseKey.isEmpty else { return false }
            let key = normalizedPersonKey(candidate)
            return !key.isEmpty && key == selfLooseKey
        }

        var otherPartyCandidate: String? = nil
        var otherPartySource: String? = nil
        var selfExclusionSources: [String] = []

        let considerCandidate: (String?, String) -> Void = { rawCandidate, source in
            guard otherPartyCandidate == nil else { return }
            guard let rawCandidate else { return }
            let candidate = resolveCandidate(rawCandidate)
            if isSelfCandidate(candidate) || isSelfLikeCandidate(candidate) {
                if hasSelf {
                    selfExclusionSources.append(source)
                }
                rejectCandidate(source, "self")
                return
            }
            otherPartyCandidate = candidate
            otherPartySource = source
        }

        // Priority order: header -> system (other) -> container (top-level, selected) -> sender tokens
        considerCandidate(headerCandidateRaw, "header")
        considerCandidate(otherEvidence?.name, "system:other")
        considerCandidate(topLevelContainerCandidateRaw, "container:top-level")
        considerCandidate(selectedContainerCandidateRaw, "container:selected")

        if otherPartyCandidate == nil, hasSelf {
            let senderOthers = participantsRaw.filter {
                participantKey($0) != selfKey && !isSelfLikeCandidate($0)
            }
            if senderOthers.count == 1 {
                otherPartyCandidate = resolveCandidate(senderOthers[0])
                otherPartySource = "sender-tokens"
            }
        }

        let groupSignal = participantsRaw.count > 2 || selfEvidence?.tag == "me_group_action_marker"
        let chatKind: WAParticipantChatKind = {
            if groupSignal { return .group }
            if otherPartyCandidate != nil { return .oneToOne }
            if participantsRaw.count == 2 { return .oneToOne }
            return .unknown
        }()

        var chatTitleCandidate: String? = nil
        var chatTitleSource: String? = nil
        let titleOptions: [(candidate: String?, source: String)] = [
            (headerCandidate, "header"),
            (topLevelContainerCandidate, "container:top-level"),
            (selectedContainerCandidate, "container:selected"),
        ]

        switch chatKind {
        case .group:
            for (candidate, source) in titleOptions {
                guard let candidate else { continue }
                chatTitleCandidate = candidate
                chatTitleSource = source
                break
            }
        case .oneToOne:
            for (candidate, source) in titleOptions {
                guard let candidate else { continue }
                if isSelfCandidate(candidate) || isSelfLikeCandidate(candidate) {
                    rejectCandidate(source, "self")
                    continue
                }
                chatTitleCandidate = candidate
                chatTitleSource = source
                break
            }
            if chatTitleCandidate == nil, let otherPartyCandidate {
                chatTitleCandidate = otherPartyCandidate
                chatTitleSource = otherPartySource ?? "sender-tokens"
            }
        case .unknown:
            for (candidate, source) in titleOptions {
                guard let candidate else { continue }
                chatTitleCandidate = candidate
                chatTitleSource = source
                break
            }
        }

        var confidence: WAParticipantDetectionConfidence = .low
        let hasHeader = headerCandidate != nil
        let hasSystem = selfEvidence != nil || otherEvidence != nil
        let hasSenderTokens = !participantsRaw.isEmpty
        if hasHeader || hasSystem { confidence = .medium }
        if hasHeader && (hasSystem || hasSenderTokens) { confidence = .high }
        if !hasHeader && hasSystem && hasSenderTokens { confidence = .high }
        if containerConflict && !(hasHeader || hasSystem) {
            if confidence == .high { confidence = .medium }
        }

        var evidence: [WAParticipantDetectionEvidence] = []
        if let headerCandidate {
            evidence.append(WAParticipantDetectionEvidence(source: "header", excerpt: headerCandidate))
        }
        if let selfEvidence {
            evidence.append(WAParticipantDetectionEvidence(source: "system", excerpt: selfEvidence.tag))
        }
        if let otherEvidence {
            evidence.append(WAParticipantDetectionEvidence(source: "system:other", excerpt: otherEvidence.tag))
        }
        if let topLevelContainer {
            evidence.append(WAParticipantDetectionEvidence(source: "container:top-level", excerpt: topLevelContainer))
        }
        if let selectedContainer, normalizedKey(selectedContainer) != normalizedKey(topLevelContainer ?? "") {
            evidence.append(WAParticipantDetectionEvidence(source: "container:selected", excerpt: selectedContainer))
        }
        if !participantsRaw.isEmpty {
            evidence.append(WAParticipantDetectionEvidence(source: "sender-tokens", excerpt: "unique=\(participantsRaw.count)"))
        }

        var nonPhoneAlternatives: [(candidate: String, source: String)] = []
        let appendNonPhone: (String?, String) -> Void = { rawCandidate, source in
            guard let rawCandidate else { return }
            let candidate = resolveCandidate(rawCandidate)
            if isPhoneCandidate(candidate) { return }
            if isSelfCandidate(candidate) || isSelfLikeCandidate(candidate) { return }
            if nonPhoneAlternatives.contains(where: { normalizedKey($0.candidate) == normalizedKey(candidate) }) { return }
            nonPhoneAlternatives.append((candidate: candidate, source: source))
        }

        appendNonPhone(headerCandidateRaw, "header")
        appendNonPhone(otherEvidence?.name, "system:other")
        appendNonPhone(topLevelContainerCandidateRaw, "container:top-level")
        appendNonPhone(selectedContainerCandidateRaw, "container:selected")
        if hasSelf {
            for raw in participantsRaw where participantKey(raw) != selfKey {
                appendNonPhone(raw, "sender-tokens")
            }
        }

        var phoneOverrideSource: String? = nil
        let otherPartyCandidateFinal: String? = {
            if chatKind == .group { return nil }
            guard var candidate = otherPartyCandidate else { return nil }
            if isPhoneCandidate(candidate) {
                let replacement = nonPhoneAlternatives.first(where: { $0.source.hasPrefix("container:") })
                    ?? nonPhoneAlternatives.first
                if let replacement,
                   !(isSelfCandidate(replacement.candidate) || isSelfLikeCandidate(replacement.candidate)) {
                    candidate = replacement.candidate
                    phoneOverrideSource = replacement.source
                    return candidate
                }
            }
            return candidate
        }()
        var otherPartySourceFinal = otherPartySource
        if let phoneOverrideSource {
            otherPartySourceFinal = phoneOverrideSource
        }

        if !selfExclusionSources.isEmpty {
            let summary = selfExclusionSources.sorted().joined(separator: ", ")
            evidence.append(WAParticipantDetectionEvidence(source: "policy:self-exclusion", excerpt: summary))
        }

        if chatKind != .group,
           !hasSelf,
           otherPartyCandidateFinal == nil,
           (headerCandidate != nil || topLevelContainerCandidate != nil || selectedContainerCandidate != nil || !participantsRaw.isEmpty) {
            evidence.append(WAParticipantDetectionEvidence(source: "policy:ambiguous-other", excerpt: "self-unknown"))
        }
        if let phoneOverrideSource {
            evidence.append(WAParticipantDetectionEvidence(source: "policy:phone-suppressed", excerpt: phoneOverrideSource))
        }

        var chatTitleCandidateFinal = chatTitleCandidate
        var chatTitleSourceFinal = chatTitleSource
        if let candidate = chatTitleCandidateFinal,
           isPhoneCandidate(candidate),
           let otherPartyCandidateFinal,
           !isPhoneCandidate(otherPartyCandidateFinal) {
            chatTitleCandidateFinal = otherPartyCandidateFinal
            chatTitleSourceFinal = otherPartySourceFinal ?? "policy:phone-suppressed"
        }

        if chatTitleCandidateFinal == nil && otherPartyCandidateFinal == nil {
            let fallback = safeFinderFilename(fallbackChatIdentifier(from: chatURL))
            chatTitleCandidateFinal = fallback
            chatTitleSourceFinal = "fallback"
            evidence.append(WAParticipantDetectionEvidence(source: "fallback", excerpt: fallback))
        }

        if chatKind == .oneToOne && otherPartyCandidateFinal == nil {
            confidence = .low
        }

        if !rejectedCandidates.isEmpty {
            for rejection in rejectedCandidates {
                evidence.append(WAParticipantDetectionEvidence(source: "reject:\(rejection.source)", excerpt: rejection.reason))
            }
        }

        let winningSource: String? = {
            switch chatKind {
            case .oneToOne:
                if otherPartyCandidateFinal != nil {
                    return otherPartySourceFinal ?? chatTitleSourceFinal
                }
                return chatTitleSourceFinal
            case .group:
                return chatTitleSourceFinal
            case .unknown:
                return chatTitleSourceFinal ?? otherPartySourceFinal
            }
        }()

        if let winningSource {
            evidence.append(WAParticipantDetectionEvidence(source: "decision:winner", excerpt: winningSource))
        }
        evidence.append(WAParticipantDetectionEvidence(source: "decision:confidence", excerpt: confidence.rawValue))

        let detection = WAParticipantDetectionResult(
            chatKind: chatKind,
            chatTitleCandidate: chatTitleCandidateFinal,
            otherPartyCandidate: otherPartyCandidateFinal,
            exporterSelfCandidate: exporterSelfCandidate,
            confidence: confidence,
            evidence: evidence
        )

        return WAParticipantDetectionSnapshot(
            participants: participants,
            detection: detection,
            dateRange: dateRange,
            mediaCounts: mediaCounts
        )
    }

    nonisolated private static func participants(from messages: [WAMessage]) -> [String] {
        // Preserve first-seen order
        var uniq: [String] = []
        for m in messages {
            let a = normalizedParticipantIdentifier(m.author)
            if a.isEmpty { continue }
            if isSystemAuthor(a) { continue }
            if !uniq.contains(a) { uniq.append(a) }
        }

        let filtered = uniq.filter { !isSystemAuthor($0) }
        return filtered.isEmpty ? uniq : filtered
    }

    nonisolated private static func messageDateRange(messages: [WAMessage]) -> ClosedRange<Date>? {
        var minDate: Date? = nil
        var maxDate: Date? = nil
        for m in messages {
            if let currentMin = minDate {
                if m.ts < currentMin { minDate = m.ts }
            } else {
                minDate = m.ts
            }
            if let currentMax = maxDate {
                if m.ts > currentMax { maxDate = m.ts }
            } else {
                maxDate = m.ts
            }
        }
        if let minDate, let maxDate {
            return minDate...maxDate
        }
        return nil
    }

    nonisolated private static func messageMediaCounts(messages: [WAMessage]) -> WAMediaCounts {
        var images = 0
        var videos = 0
        var audios = 0
        var documents = 0

        for m in messages {
            let attachments = findAttachments(m.text)
            if attachments.isEmpty { continue }
            for fn in attachments {
                let ext = URL(fileURLWithPath: fn).pathExtension
                switch bucketForExtension(ext) {
                case .images: images += 1
                case .videos: videos += 1
                case .audios: audios += 1
                case .documents: documents += 1
                }
            }
        }

        return WAMediaCounts(images: images, videos: videos, audios: audios, documents: documents)
    }

    nonisolated private static func headerTitleCandidate(lines: [String], limit: Int = 120) -> String? {
        var checked = 0
        for line in lines {
            if checked >= limit { break }
            checked += 1

            let stripped = _normSpace(stripBOMAndBidi(line))
            if stripped.isEmpty { continue }
            if isMessageLine(stripped) { continue }
            if isSystemMessage(authorRaw: "header", text: stripped) { continue }

            guard let candidate = stripExplicitChatPrefix(stripped) else { continue }
            let cleaned = _normSpace(candidate).precomposedStringWithCanonicalMapping
            if cleaned.isEmpty { continue }
            return cleaned
        }
        return nil
    }

    nonisolated private static func containerNameCandidates(
        provenance: WETSourceProvenance
    ) -> (selected: String?, topLevel: String?) {
        let topLevel = provenance.detectedFolderURL.lastPathComponent
        switch provenance.inputKind {
        case .folder:
            return (selected: topLevel, topLevel: topLevel)
        case .zip:
            let selected = provenance.originalZipURL?.deletingPathExtension().lastPathComponent
            return (selected: selected, topLevel: topLevel)
        }
    }

    nonisolated private static func inferOtherPartyNameEvidence(messages: [WAMessage]) -> (name: String, tag: String)? {
        var candidates: Set<String> = []
        var deletedByOther: [String: Int] = [:]

        for m in messages {
            let author = normalizedParticipantIdentifier(m.author)
            if author.isEmpty { continue }
            if isSystemAuthor(author) { continue }
            candidates.insert(author)

            let text = normalizedSystemText(m.text)
            if text.isEmpty { continue }
            if containsAny(text, otherDeletedMarkers) {
                deletedByOther[author, default: 0] += 1
            }
        }

        if candidates.count == 2, deletedByOther.count == 1, let other = deletedByOther.keys.first {
            return (name: other, tag: "other_deleted_marker")
        }

        return nil
    }

    nonisolated private static func inferMeNameEvidence(messages: [WAMessage]) -> (name: String, tag: String)? {
        var candidates: Set<String> = []
        var deletedByMe: [String: Int] = [:]
        var groupActionsByMe: [String: Int] = [:]
        var deletedByOther: [String: Int] = [:]

        for m in messages {
            let author = normalizedParticipantIdentifier(m.author)
            if author.isEmpty { continue }
            if isSystemAuthor(author) { continue }
            candidates.insert(author)

            let text = normalizedSystemText(m.text)
            if text.isEmpty { continue }

            if containsAny(text, meDeletedMarkers) {
                deletedByMe[author, default: 0] += 1
                continue
            }
            if containsAny(text, meGroupActionMarkers) {
                groupActionsByMe[author, default: 0] += 1
                continue
            }
            if containsAny(text, otherDeletedMarkers) {
                deletedByOther[author, default: 0] += 1
            }
        }

        if deletedByMe.count == 1, let me = deletedByMe.keys.first {
            return (name: me, tag: "me_deleted_marker")
        }

        if deletedByMe.count > 1 {
            return nil
        }

        if groupActionsByMe.count == 1, let me = groupActionsByMe.keys.first {
            return (name: me, tag: "me_group_action_marker")
        }

        if groupActionsByMe.count > 1 {
            return nil
        }

        if candidates.count == 2, deletedByOther.count == 1 {
            let notMe = deletedByOther.keys.first!
            if let me = candidates.first(where: { $0 != notMe }) {
                return (name: me, tag: "other_deleted_marker")
            }
        }

        return nil
    }

    /// Compare the original WhatsApp export folder (and sibling zip, if present) with the sidecar copies.
    /// Returns which originals are byte-identical and can be safely deleted.
    public nonisolated static func verifySidecarCopies(
        originalExportDir: URL,
        sidecarBaseDir: URL,
        detectedPartnerRaw: String,
        overridePartnerRaw: String? = nil,
        originalZipURL: URL? = nil
    ) -> SidecarVerificationResult {
        let originalDir = originalExportDir.standardizedFileURL
        let baseDir = sidecarBaseDir.standardizedFileURL
        let originalNameBefore: String
        if let originalZipURL {
            originalNameBefore = originalZipURL.deletingPathExtension().lastPathComponent
        } else {
            originalNameBefore = originalDir.lastPathComponent
        }
        let originalNameAfter = applyPartnerOverrideToName(
            originalName: originalNameBefore,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw
        )
        let copiedDir = baseDir.appendingPathComponent(originalNameAfter, isDirectory: true)

        let exportDirMatches = directoriesEqual(src: originalDir, dst: copiedDir)

        let originalZip = originalZipURL ?? pickSiblingZipURL(sourceDir: originalDir)
        var copiedZip: URL? = nil
        var zipMatches: Bool? = nil

        if let zip = originalZip {
            copiedZip = baseDir.appendingPathComponent(zip.lastPathComponent)
            if let copiedZip, FileManager.default.fileExists(atPath: copiedZip.path) {
                zipMatches = filesEqual(zip, copiedZip)
            } else {
                zipMatches = false
            }
        }

        return SidecarVerificationResult(
            originalExportDir: originalDir,
            copiedExportDir: copiedDir,
            originalZip: originalZip,
            copiedZip: copiedZip,
            exportDirMatches: exportDirMatches,
            zipMatches: zipMatches
        )
    }

    /// 1:1-Export: parses chat, decides me-name, renders HTML+MD, writes files.
    /// Returns URLs of written HTML/MD.
    nonisolated public static func export(
        chatURL: URL,
        outDir: URL,
        meNameOverride: String?,
        participantNameOverrides: [String: String] = [:],
        enablePreviews: Bool,
        embedAttachments: Bool,
        embedAttachmentThumbnailsOnly: Bool = false,
        exportSortedAttachments: Bool = false,
        allowOverwrite: Bool = false
    ) async throws -> (html: URL, md: URL) {

        // Wichtig: staged-Map zurücksetzen (sonst können alte relHref-Ziele „kleben bleiben“)
        resetStagedAttachmentCache()
        resetAttachmentIndexCache()
        resetThumbnailCaches()
        resetPerfMetrics()

        let chatPath = chatURL.standardizedFileURL
        let outPath = outDir.standardizedFileURL

        var msgs = try parseMessages(chatPath)

        // Apply participant name overrides (GUI: phone number -> display name),
        // and normalize phone number representations for stable output.
        let participantLookup = buildParticipantOverrideLookup(participantNameOverrides)
        for i in msgs.indices {
            let a = msgs[i].author
            if isSystemAuthor(a) { continue }
            msgs[i].author = applyParticipantOverride(a, lookup: participantLookup)
        }

        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                // If the UI selected a phone-number identity, map it to the overridden display name (if provided),
                // otherwise normalize its representation.
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        let base = composeExportBaseName(
            messages: msgs,
            chatURL: chatPath,
            meName: meName
        )

        let wantsThumbs = exportSortedAttachments || embedAttachments || embedAttachmentThumbnailsOnly
        var attachmentEntries: [AttachmentCanonicalEntry] = []
        if wantsThumbs && hasAnyAttachmentMarkers(messages: msgs) {
            attachmentEntries = buildAttachmentCanonicalEntries(
                messages: msgs,
                chatSourceDir: chatPath.deletingLastPathComponent()
            )
        }

        // D1 Attachment index (run-wide, at most once) if attachments are referenced.
        if hasAnyAttachmentMarkers(messages: msgs) {
            prewarmAttachmentIndex(for: chatPath.deletingLastPathComponent())
        }

        let fm = FileManager.default

        let outHTML = outPath.appendingPathComponent("\(base).html")
        let outMD = outPath.appendingPathComponent("\(base).md")
        let sidecarHTML = outPath.appendingPathComponent("\(base)-sdc.html")
        let sortedFolderURL = outPath.appendingPathComponent(base, isDirectory: true)

        let existingNames: Set<String> = (try? fm.contentsOfDirectory(
            at: outPath,
            includingPropertiesForKeys: nil,
            options: []
        ))?.map(\.lastPathComponent).reduce(into: Set<String>()) { $0.insert($1) } ?? []

        var existing: [URL] = []
        if existingNames.contains(outHTML.lastPathComponent) { existing.append(outHTML) }
        if existingNames.contains(outMD.lastPathComponent) { existing.append(outMD) }
        if existingNames.contains(sidecarHTML.lastPathComponent) { existing.append(sidecarHTML) }
        if existingNames.contains(sortedFolderURL.lastPathComponent) { existing.append(sortedFolderURL) }
        for variant in HTMLVariant.allCases {
            let name = "\(base)\(variant.filenameSuffix).html"
            if existingNames.contains(name) {
                existing.append(outPath.appendingPathComponent(name))
            }
        }

        if !existing.isEmpty, !allowOverwrite {
            throw WAExportError.outputAlreadyExists(urls: existing)
        }

        let stagingBase = try localStagingBaseDirectory()
        let stagingDir = try createStagingDirectory(in: stagingBase)
        var didRemoveStaging = false
        var tempThumbsRoot: URL? = nil
        defer {
            if let tempThumbsRoot, fm.fileExists(atPath: tempThumbsRoot.path) {
                try? fm.removeItem(at: tempThumbsRoot)
            }
            if !didRemoveStaging {
                try? fm.removeItem(at: stagingDir)
            }
        }

        let stagedHTML = stagingDir.appendingPathComponent("\(base).html")
        let stagedMD = stagingDir.appendingPathComponent("\(base).md")
        let stagedSidecarHTML = stagingDir.appendingPathComponent("\(base)-sdc.html")
        let stagedSidecarDir = stagingDir.appendingPathComponent(base, isDirectory: true)

        var thumbnailStore: ThumbnailStore? = nil
        if wantsThumbs, !exportSortedAttachments, !attachmentEntries.isEmpty {
            let tempRoot = temporaryThumbsWorkspace(baseName: base, chatURL: chatPath, stagingBase: stagingBase)
            tempThumbsRoot = tempRoot
            if fm.fileExists(atPath: tempRoot.path) {
                try? fm.removeItem(at: tempRoot)
            }
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let tempThumbsDir = tempRoot.appendingPathComponent("_thumbs", isDirectory: true)
            let writeStore = ThumbnailStore(entries: attachmentEntries, thumbsDir: tempThumbsDir, allowWrite: true)
            await writeStore.precomputeAll()
            thumbnailStore = ThumbnailStore(entries: attachmentEntries, thumbsDir: tempThumbsDir, allowWrite: false)
        }

        var sidecarOriginalDir: URL? = nil
        var sidecarBaseDir: URL? = nil
        if exportSortedAttachments {
            let originalDir = try await exportSortedAttachmentsFolder(
                chatURL: chatPath,
                messages: msgs,
                outDir: stagingDir,
                folderName: base,
                detectedPartnerRaw: "",
                overridePartnerRaw: nil,
                originalZipURL: nil,
                attachmentEntries: attachmentEntries
            )
            sidecarOriginalDir = originalDir
            sidecarBaseDir = originalDir.deletingLastPathComponent()
        }

        var didSidecar = false
        if exportSortedAttachments {
            guard let sidecarOriginalDir, let sidecarBaseDir else {
                throw NSError(domain: "WETExport", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Sidecar directory missing"
                ])
            }

            var sidecarThumbStore: ThumbnailStore? = nil
            if wantsThumbs, !attachmentEntries.isEmpty {
                let thumbsDir = sidecarBaseDir.appendingPathComponent("_thumbs", isDirectory: true)
                let store = ThumbnailStore(entries: attachmentEntries, thumbsDir: thumbsDir, allowWrite: true)
                await store.precomputeAll()
                sidecarThumbStore = store
                thumbnailStore = ThumbnailStore(entries: attachmentEntries, thumbsDir: thumbsDir, allowWrite: false)
            }

            // Sidecar HTML: renders like -max but references media in the sidecar folder via relative links.
            let sidecarChatURL = sidecarOriginalDir.appendingPathComponent(chatPath.lastPathComponent)
            // Write sidecar HTML next to the other outputs (root of outDir) and name it consistently.

            try await renderHTML(
                msgs: msgs,
                chatURL: sidecarChatURL,
                outHTML: stagedSidecarHTML,
                meName: meName,
                enablePreviews: true,
                // Sidecar must stay small: do NOT embed media as data-URLs; reference files in the copied export folder.
                embedAttachments: false,
                embedAttachmentThumbnailsOnly: false,
                attachmentRelBaseDir: stagingDir,
                disableThumbStaging: false,
                externalAttachments: true,
                externalPreviews: true,
                externalAssetsDir: sidecarBaseDir,
                thumbnailStore: sidecarThumbStore,
                perfLabel: "Sidecar"
            )

            try validateSidecarLayout(sidecarBaseDir: sidecarBaseDir)
            normalizeOriginalCopyTimestamps(
                sourceDir: chatPath.deletingLastPathComponent(),
                destDir: sidecarOriginalDir,
                skippingPathPrefixes: [
                    outPath.standardizedFileURL.path,
                    sidecarBaseDir.standardizedFileURL.path
                ]
            )
            let mismatches = sampleTimestampMismatches(
                sourceDir: chatPath.deletingLastPathComponent(),
                destDir: sidecarOriginalDir,
                maxFiles: 3,
                maxDirs: 3,
                skippingPathPrefixes: [
                    outPath.standardizedFileURL.path,
                    sidecarBaseDir.standardizedFileURL.path
                ]
            )
            if !mismatches.isEmpty {
                print("WARN: Zeitstempelabweichung bei \(mismatches.count) Element(en).")
            }
            didSidecar = true
        }

        try await renderHTML(
            msgs: msgs,
            chatURL: chatPath,
            outHTML: stagedHTML,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly,
            thumbnailStore: thumbnailStore,
            perfLabel: "HTML"
        )

        let mdChatURL = sidecarOriginalDir?.appendingPathComponent(chatPath.lastPathComponent) ?? chatPath
        let mdAttachmentRelBaseDir: URL? = sidecarOriginalDir != nil ? stagingDir : nil

        try renderMD(
            msgs: msgs,
            chatURL: mdChatURL,
            outMD: stagedMD,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly,
            attachmentRelBaseDir: mdAttachmentRelBaseDir
        )

        func publishMove(_ src: URL, _ dst: URL) throws {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) {
                if allowOverwrite {
                    let isDir = (try? dst.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let backup = dst
                        .deletingLastPathComponent()
                        .appendingPathComponent(".wa_backup_\(UUID().uuidString)", isDirectory: isDir)
                    try fm.moveItem(at: dst, to: backup)
                    do {
                        try fm.moveItem(at: src, to: dst)
                        try? fm.removeItem(at: backup)
                    } catch {
                        if fm.fileExists(atPath: backup.path) {
                            try? fm.moveItem(at: backup, to: dst)
                        }
                        throw error
                    }
                } else {
                    throw OutputCollisionError(url: dst)
                }
            } else {
                try fm.moveItem(at: src, to: dst)
            }
        }

        var moveItems: [(src: URL, dst: URL)] = [
            (stagedHTML, outHTML),
            (stagedMD, outMD)
        ]
        if didSidecar {
            moveItems.append((stagedSidecarHTML, sidecarHTML))
            moveItems.append((stagedSidecarDir, sortedFolderURL))
        }

        var moved: [URL] = []
        do {
            for (src, dst) in moveItems {
                try publishMove(src, dst)
                moved.append(dst)
            }
        } catch {
            for u in moved { try? fm.removeItem(at: u) }
            throw error
        }

        try? fm.removeItem(at: stagingDir)
        didRemoveStaging = true

        return (outHTML, outMD)
    }

    /// Computes the base output filename (without extension) for the given chat export.
    nonisolated public static func computeOutputBaseName(
        chatURL: URL,
        meNameOverride: String?,
        participantNameOverrides: [String: String] = [:]
    ) throws -> String {
        let chatPath = chatURL.standardizedFileURL

        var msgs = try parseMessages(chatPath)

        let participantLookup = buildParticipantOverrideLookup(participantNameOverrides)
        for i in msgs.indices {
            let a = msgs[i].author
            if isSystemAuthor(a) { continue }
            msgs[i].author = applyParticipantOverride(a, lookup: participantLookup)
        }

        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        let base = composeExportBaseName(messages: msgs, chatURL: chatPath, meName: meName)
        return base
    }

    nonisolated static func prepareExport(
        chatURL: URL,
        meNameOverride: String?,
        participantNameOverrides: [String: String] = [:]
    ) throws -> PreparedExport {
        let chatPath = chatURL.standardizedFileURL

        var msgs = try parseMessages(chatPath)

        let participantLookup = buildParticipantOverrideLookup(participantNameOverrides)
        for i in msgs.indices {
            let a = msgs[i].author
            if isSystemAuthor(a) { continue }
            msgs[i].author = applyParticipantOverride(a, lookup: participantLookup)
        }

        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        let base = composeExportBaseName(messages: msgs, chatURL: chatPath, meName: meName)

        return PreparedExport(messages: msgs, meName: meName, baseName: base, chatURL: chatPath)
    }

    nonisolated static func expectedAttachmentCount(prepared: PreparedExport) -> Int {
        let sourceDir = prepared.chatURL.deletingLastPathComponent()
        var seen: Set<String> = []
        var count = 0
        for m in prepared.messages {
            let fns = findAttachments(m.text)
            if fns.isEmpty { continue }
            for fn in fns where seen.insert(fn).inserted {
                if resolveAttachmentURL(fileName: fn, sourceDir: sourceDir) != nil {
                    count += 1
                }
            }
        }
        return count
    }

    nonisolated static func hasAnyAttachmentMarkers(messages: [WAMessage]) -> Bool {
        for m in messages {
            if !findAttachments(m.text).isEmpty { return true }
        }
        return false
    }

    nonisolated static func renderHTMLPrepared(
        prepared: PreparedExport,
        outDir: URL,
        fileSuffix: String,
        enablePreviews: Bool,
        embedAttachments: Bool,
        embedAttachmentThumbnailsOnly: Bool,
        thumbnailStore: ThumbnailStore? = nil,
        perfLabel: String? = nil
    ) async throws -> URL {
        resetStagedAttachmentCache()

        let outPath = outDir.standardizedFileURL
        let outHTML = outPath.appendingPathComponent("\(prepared.baseName)\(fileSuffix).html")

        try await renderHTML(
            msgs: prepared.messages,
            chatURL: prepared.chatURL,
            outHTML: outHTML,
            meName: prepared.meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly,
            thumbnailStore: thumbnailStore,
            perfLabel: perfLabel
        )

        return outHTML
    }

    nonisolated static func renderMarkdown(
        prepared: PreparedExport,
        outDir: URL,
        chatURLOverride: URL? = nil,
        attachmentRelBaseDir: URL? = nil
    ) throws -> URL {
        resetStagedAttachmentCache()

        let outPath = outDir.standardizedFileURL
        let outMD = outPath.appendingPathComponent("\(prepared.baseName).md")
        let chatURL = chatURLOverride ?? prepared.chatURL

        try renderMD(
            msgs: prepared.messages,
            chatURL: chatURL,
            outMD: outMD,
            meName: prepared.meName,
            enablePreviews: true,
            embedAttachments: false,
            embedAttachmentThumbnailsOnly: false,
            attachmentRelBaseDir: attachmentRelBaseDir
        )

        return outMD
    }

    nonisolated static func renderSidecar(
        prepared: PreparedExport,
        outDir: URL,
        allowStagingOverwrite: Bool = false,
        detectedPartnerRaw: String,
        overridePartnerRaw: String? = nil,
        originalZipURL: URL? = nil,
        attachmentEntries: [AttachmentCanonicalEntry] = []
    ) async throws -> (sidecarBaseDir: URL?, sidecarHTML: URL, expectedAttachments: Int) {
        resetStagedAttachmentCache()

        let fm = FileManager.default
        let sidecarDebugEnabled = ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1"
        let expectedAttachments = expectedAttachmentCount(prepared: prepared)
        let outPath = outDir.standardizedFileURL
        let sidecarHTML = outPath.appendingPathComponent("\(prepared.baseName)-sdc.html")

        if expectedAttachments == 0 {
            try await renderHTML(
                msgs: prepared.messages,
                chatURL: prepared.chatURL,
                outHTML: sidecarHTML,
                meName: prepared.meName,
                enablePreviews: true,
                embedAttachments: false,
                embedAttachmentThumbnailsOnly: false,
                perfLabel: "Sidecar"
            )
            return (sidecarBaseDir: nil, sidecarHTML: sidecarHTML, expectedAttachments: expectedAttachments)
        }

        let stagingBaseDir = outPath.appendingPathComponent(prepared.baseName, isDirectory: true)
        if allowStagingOverwrite && expectedAttachments > 0, fm.fileExists(atPath: stagingBaseDir.path) {
            if sidecarDebugEnabled {
                print("DEBUG: SIDE: removing staged sidecar dir before render: \(stagingBaseDir.path)")
            }
            try? fm.removeItem(at: stagingBaseDir)
        }

        let effectiveEntries = attachmentEntries.isEmpty
            ? buildAttachmentCanonicalEntries(
                messages: prepared.messages,
                chatSourceDir: prepared.chatURL.deletingLastPathComponent()
            )
            : attachmentEntries

        let sidecarOriginalDir = try await exportSortedAttachmentsFolder(
            chatURL: prepared.chatURL,
            messages: prepared.messages,
            outDir: outPath,
            folderName: prepared.baseName,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw,
            originalZipURL: originalZipURL,
            attachmentEntries: effectiveEntries
        )
        let sidecarBaseDir = sidecarOriginalDir.deletingLastPathComponent()
        let sidecarChatURL = sidecarOriginalDir.appendingPathComponent(prepared.chatURL.lastPathComponent)

        var thumbStore: ThumbnailStore? = nil
        if !effectiveEntries.isEmpty {
            let thumbsDir = sidecarBaseDir.appendingPathComponent("_thumbs", isDirectory: true)
            let store = ThumbnailStore(entries: effectiveEntries, thumbsDir: thumbsDir, allowWrite: true)
            await store.precomputeAll()
            thumbStore = store
        }

        try await renderHTML(
            msgs: prepared.messages,
            chatURL: sidecarChatURL,
            outHTML: sidecarHTML,
            meName: prepared.meName,
            enablePreviews: true,
            embedAttachments: false,
            embedAttachmentThumbnailsOnly: false,
            attachmentRelBaseDir: outPath,
            disableThumbStaging: false,
            externalAttachments: true,
            externalPreviews: true,
            externalAssetsDir: sidecarBaseDir,
            thumbnailStore: thumbStore,
            perfLabel: "Sidecar"
        )

        if isDirectoryEmptyFirstLevel(sidecarBaseDir), sidecarDebugEnabled {
            print("DEBUG: SIDE: sidecar base dir empty after render; keeping for validation")
        }

        return (sidecarBaseDir: sidecarBaseDir, sidecarHTML: sidecarHTML, expectedAttachments: expectedAttachments)
    }
    
    /// Multi-Export: erzeugt alle HTML-Varianten (-max/-mid/-min) + eine MD-Datei.
    nonisolated public static func exportMulti(
        chatURL: URL,
        outDir: URL,
        meNameOverride: String?,
        participantNameOverrides: [String: String] = [:],
        variants: [HTMLVariant] = HTMLVariant.allCases,
        exportSortedAttachments: Bool = false,
        allowOverwrite: Bool = false
    ) async throws -> ExportMultiResult {

        // Wichtig: staged-Map zurücksetzen (sonst können alte relHref-Ziele „kleben bleiben“)
        resetStagedAttachmentCache()
        resetAttachmentIndexCache()
        resetThumbnailCaches()
        resetPerfMetrics()

        let chatPath = chatURL.standardizedFileURL
        let outPath = outDir.standardizedFileURL

        var msgs = try parseMessages(chatPath)

        // Apply participant overrides (phone normalization etc.)
        let participantLookup = buildParticipantOverrideLookup(participantNameOverrides)
        for i in msgs.indices {
            let a = msgs[i].author
            if isSystemAuthor(a) { continue }
            msgs[i].author = applyParticipantOverride(a, lookup: participantLookup)
        }

        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        let base = composeExportBaseName(messages: msgs, chatURL: chatPath, meName: meName)

        let wantsThumbs = exportSortedAttachments
            || variants.contains(where: { $0 == .embedAll || $0 == .thumbnailsOnly })
        var attachmentEntries: [AttachmentCanonicalEntry] = []
        if wantsThumbs && hasAnyAttachmentMarkers(messages: msgs) {
            attachmentEntries = buildAttachmentCanonicalEntries(
                messages: msgs,
                chatSourceDir: chatPath.deletingLastPathComponent()
            )
        }

        // D1 Attachment index (run-wide, at most once) if attachments are referenced.
        if hasAnyAttachmentMarkers(messages: msgs) {
            prewarmAttachmentIndex(for: chatPath.deletingLastPathComponent())
        }

        let fm = FileManager.default

        // Output URLs
        var htmlByVariant: [HTMLVariant: URL] = [:]
        htmlByVariant.reserveCapacity(variants.count)

        for v in variants {
            let u = outPath.appendingPathComponent("\(base)\(v.filenameSuffix).html")
            htmlByVariant[v] = u
        }

        // Empfehlung: Markdown immer „portable“ mit attachments/ Links
        let outMD = outPath.appendingPathComponent("\(base).md")
        let sidecarHTML = outPath.appendingPathComponent("\(base)-sdc.html")
        let sortedFolderURL = outPath.appendingPathComponent(base, isDirectory: true)

        let existingNames: Set<String> = (try? fm.contentsOfDirectory(
            at: outPath,
            includingPropertiesForKeys: nil,
            options: []
        ))?.map(\.lastPathComponent).reduce(into: Set<String>()) { $0.insert($1) } ?? []

        var existing: [URL] = []
        for v in HTMLVariant.allCases {
            let name = "\(base)\(v.filenameSuffix).html"
            if existingNames.contains(name) {
                existing.append(outPath.appendingPathComponent(name))
            }
        }
        if existingNames.contains(outMD.lastPathComponent) { existing.append(outMD) }
        if existingNames.contains(sidecarHTML.lastPathComponent) { existing.append(sidecarHTML) }
        if existingNames.contains(sortedFolderURL.lastPathComponent) { existing.append(sortedFolderURL) }

        if !existing.isEmpty, !allowOverwrite {
            throw WAExportError.outputAlreadyExists(urls: existing)
        }

        let stagingBase = try localStagingBaseDirectory()
        let stagingDir = try createStagingDirectory(in: stagingBase)
        var didRemoveStaging = false
        var tempThumbsRoot: URL? = nil
        defer {
            if let tempThumbsRoot, fm.fileExists(atPath: tempThumbsRoot.path) {
                try? fm.removeItem(at: tempThumbsRoot)
            }
            if !didRemoveStaging {
                try? fm.removeItem(at: stagingDir)
            }
        }

        var stagedHTMLByVariant: [HTMLVariant: URL] = [:]
        stagedHTMLByVariant.reserveCapacity(variants.count)
        for v in variants {
            stagedHTMLByVariant[v] = stagingDir.appendingPathComponent("\(base)\(v.filenameSuffix).html")
        }
        let stagedMD = stagingDir.appendingPathComponent("\(base).md")
        let stagedSidecarHTML = stagingDir.appendingPathComponent("\(base)-sdc.html")
        let stagedSidecarDir = stagingDir.appendingPathComponent(base, isDirectory: true)

        var thumbnailStore: ThumbnailStore? = nil
        if wantsThumbs, !exportSortedAttachments, !attachmentEntries.isEmpty {
            let tempRoot = temporaryThumbsWorkspace(baseName: base, chatURL: chatPath, stagingBase: stagingBase)
            tempThumbsRoot = tempRoot
            if fm.fileExists(atPath: tempRoot.path) {
                try? fm.removeItem(at: tempRoot)
            }
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let tempThumbsDir = tempRoot.appendingPathComponent("_thumbs", isDirectory: true)
            let writeStore = ThumbnailStore(entries: attachmentEntries, thumbsDir: tempThumbsDir, allowWrite: true)
            await writeStore.precomputeAll()
            thumbnailStore = ThumbnailStore(entries: attachmentEntries, thumbsDir: tempThumbsDir, allowWrite: false)
        }

        var sidecarOriginalDir: URL? = nil
        var sidecarBaseDir: URL? = nil
        if exportSortedAttachments {
            let originalDir = try await exportSortedAttachmentsFolder(
                chatURL: chatPath,
                messages: msgs,
                outDir: stagingDir,
                folderName: base,
                detectedPartnerRaw: "",
                overridePartnerRaw: nil,
                attachmentEntries: attachmentEntries
            )
            sidecarOriginalDir = originalDir
            sidecarBaseDir = originalDir.deletingLastPathComponent()
        }

        var didSidecar = false
        if exportSortedAttachments {
            guard let sidecarOriginalDir, let sidecarBaseDir else {
                throw NSError(domain: "WETExport", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Sidecar directory missing"
                ])
            }

            var sidecarThumbStore: ThumbnailStore? = nil
            if wantsThumbs, !attachmentEntries.isEmpty {
                let thumbsDir = sidecarBaseDir.appendingPathComponent("_thumbs", isDirectory: true)
                let store = ThumbnailStore(entries: attachmentEntries, thumbsDir: thumbsDir, allowWrite: true)
                await store.precomputeAll()
                sidecarThumbStore = store
                thumbnailStore = ThumbnailStore(entries: attachmentEntries, thumbsDir: thumbsDir, allowWrite: false)
            }

            // Sidecar HTML: renders like -max but references media in the sidecar folder via relative links.
            let sidecarChatURL = sidecarOriginalDir.appendingPathComponent(chatPath.lastPathComponent)
            // Write sidecar HTML next to the other outputs (root of outDir) and name it consistently.

            try await renderHTML(
                msgs: msgs,
                chatURL: sidecarChatURL,
                outHTML: stagedSidecarHTML,
                meName: meName,
                enablePreviews: true,
                // Sidecar must stay small: do NOT embed media as data-URLs; reference files in the copied export folder.
                embedAttachments: false,
                embedAttachmentThumbnailsOnly: false,
                attachmentRelBaseDir: stagingDir,
                disableThumbStaging: false,
                externalAttachments: true,
                externalPreviews: true,
                externalAssetsDir: sidecarBaseDir,
                thumbnailStore: sidecarThumbStore,
                perfLabel: "Sidecar"
            )

            try validateSidecarLayout(sidecarBaseDir: sidecarBaseDir)
            normalizeOriginalCopyTimestamps(
                sourceDir: chatPath.deletingLastPathComponent(),
                destDir: sidecarOriginalDir,
                skippingPathPrefixes: [
                    outPath.standardizedFileURL.path,
                    sidecarBaseDir.standardizedFileURL.path
                ]
            )
            let mismatches = sampleTimestampMismatches(
                sourceDir: chatPath.deletingLastPathComponent(),
                destDir: sidecarOriginalDir,
                maxFiles: 3,
                maxDirs: 3,
                skippingPathPrefixes: [
                    outPath.standardizedFileURL.path,
                    sidecarBaseDir.standardizedFileURL.path
                ]
            )
            if !mismatches.isEmpty {
                print("WARN: Zeitstempelabweichung bei \(mismatches.count) Element(en).")
            }
            didSidecar = true
        }

        // Render all HTML variants
        for v in variants {
            guard let outHTML = stagedHTMLByVariant[v] else { continue }
            try await renderHTML(
                msgs: msgs,
                chatURL: chatPath,
                outHTML: outHTML,
                meName: meName,
                enablePreviews: v.enablePreviews,
                embedAttachments: v.embedAttachments,
                embedAttachmentThumbnailsOnly: v.embedAttachmentThumbnailsOnly,
                thumbnailStore: thumbnailStore,
                perfLabel: v.perfLabel
            )
        }

        // Render one Markdown (portable)
        let mdChatURL = sidecarOriginalDir?.appendingPathComponent(chatPath.lastPathComponent) ?? chatPath
        let mdAttachmentRelBaseDir: URL? = sidecarOriginalDir != nil ? stagingDir : nil
        try renderMD(
            msgs: msgs,
            chatURL: mdChatURL,
            outMD: stagedMD,
            meName: meName,
            enablePreviews: true,
            embedAttachments: false,
            embedAttachmentThumbnailsOnly: false,
            attachmentRelBaseDir: mdAttachmentRelBaseDir
        )

        var moveItems: [(src: URL, dst: URL)] = []
        for v in variants {
            if let src = stagedHTMLByVariant[v], let dst = htmlByVariant[v] {
                moveItems.append((src, dst))
            }
        }
        moveItems.append((stagedMD, outMD))
        if didSidecar {
            moveItems.append((stagedSidecarHTML, sidecarHTML))
            moveItems.append((stagedSidecarDir, sortedFolderURL))
        }

        func publishMove(_ src: URL, _ dst: URL) throws {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) {
                if allowOverwrite {
                    let isDir = (try? dst.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let backup = dst
                        .deletingLastPathComponent()
                        .appendingPathComponent(".wa_backup_\(UUID().uuidString)", isDirectory: isDir)
                    try fm.moveItem(at: dst, to: backup)
                    do {
                        try fm.moveItem(at: src, to: dst)
                        try? fm.removeItem(at: backup)
                    } catch {
                        if fm.fileExists(atPath: backup.path) {
                            try? fm.moveItem(at: backup, to: dst)
                        }
                        throw error
                    }
                } else {
                    throw OutputCollisionError(url: dst)
                }
            } else {
                try fm.moveItem(at: src, to: dst)
            }
        }

        var moved: [URL] = []
        do {
            for (src, dst) in moveItems {
                try publishMove(src, dst)
                moved.append(dst)
            }
        } catch {
            for u in moved { try? fm.removeItem(at: u) }
            throw error
        }

        try? fm.removeItem(at: stagingDir)
        didRemoveStaging = true

        return ExportMultiResult(htmlByVariant: htmlByVariant, md: outMD)
    }

    // ---------------------------
    // Helpers: normalize / url
    // ---------------------------

    // Normalize whitespace and strip direction marks.
    nonisolated private static func _normSpace(_ s: String) -> String {
        var x = s.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // direction marks
        x = x
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{202A}", with: "")
            .replacingOccurrences(of: "\u{202B}", with: "")
            .replacingOccurrences(of: "\u{202C}", with: "")
        // collapse whitespace
        x = x.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return x
    }

    nonisolated private static func normalizedKey(_ s: String) -> String {
        _normSpace(s).precomposedStringWithCanonicalMapping.lowercased()
    }

    // Looser normalization for matching names that differ only in punctuation/spacing.
    nonisolated private static func normalizedPersonKey(_ s: String) -> String {
        let x = _normSpace(s).precomposedStringWithCanonicalMapping.lowercased()
        if x.isEmpty { return "" }
        let filtered = x.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        return String(String.UnicodeScalarView(filtered))
    }
    
    // ---------------------------
    // Helpers: participant overrides (phone normalization)
    // ---------------------------

    /// Heuristic check whether a string looks like a phone-number participant label.
    /// WhatsApp exports often use formats like "+49 171 1234567", "+491711234567", "0171 1234567".
    nonisolated private static func isPhoneCandidate(_ s: String) -> Bool {
        let x = _normSpace(s)
        if x.isEmpty { return false }

        // Require a minimum amount of digits to avoid false positives.
        let digitCount = x.unicodeScalars.reduce(into: 0) { acc, u in
            if CharacterSet.decimalDigits.contains(u) { acc += 1 }
        }
        if digitCount < 6 { return false }

        // Only allow typical phone number characters.
        for ch in x {
            if ch.isNumber { continue }
            if ch == "+" || ch == " " || ch == "-" || ch == "(" || ch == ")" { continue }
            return false
        }
        return true
    }

    /// Normalizes a phone-like participant string into a stable lookup key:
    /// - removes spaces and punctuation
    /// - keeps leading '+' if present
    /// - converts leading "00" to '+'
    nonisolated private static func normalizePhoneKey(_ s: String) -> String {
        let x = _normSpace(s)
        if x.isEmpty { return "" }

        var out = ""
        out.reserveCapacity(x.count)

        for ch in x {
            if ch.isNumber {
                out.append(ch)
                continue
            }
            if ch == "+" && out.isEmpty {
                out.append(ch)
                continue
            }
        }

        if out.hasPrefix("00") {
            out = "+" + String(out.dropFirst(2))
        }

        return out
    }

    /// Normalizes participant identifiers so phone numbers are represented consistently.
    /// If the string is not a phone candidate, it is returned unchanged (normalized whitespace only).
    nonisolated private static func normalizedParticipantIdentifier(_ s: String) -> String {
        let x = _normSpace(s)
        if !isPhoneCandidate(x) { return x }
        let k = normalizePhoneKey(x)
        return k.isEmpty ? x : k
    }

    /// Builds a lookup map that supports both raw keys and normalized phone keys.
    /// Values are trimmed and empty values are ignored.
    nonisolated private static func buildParticipantOverrideLookup(_ overrides: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        map.reserveCapacity(overrides.count * 2)

        for (k0, v0) in overrides {
            let k = _normSpace(k0)
            let v = _normSpace(v0)
            if k.isEmpty || v.isEmpty { continue }

            // Direct key.
            map[k] = v

            // Normalized phone-key (if applicable).
            if isPhoneCandidate(k) {
                let pk = normalizePhoneKey(k)
                if !pk.isEmpty {
                    map[pk] = v
                }
            }
        }

        return map
    }

    /// Resolves a participant display name using the provided overrides and phone normalization rules.
    nonisolated public static func resolvedParticipantDisplayName(
        _ name: String,
        overrides: [String: String]
    ) -> String {
        let lookup = buildParticipantOverrideLookup(overrides)
        return applyParticipantOverride(name, lookup: lookup)
    }

    /// Applies participant overrides to an author label.
    /// - If an override exists (raw or normalized phone key), return the override name.
    /// - Otherwise, if it is phone-like, return the normalized phone representation.
    /// - Otherwise, return the original author (normalized whitespace only).
    nonisolated private static func applyParticipantOverride(_ author: String, lookup: [String: String]) -> String {
        let a = _normSpace(author)
        if a.isEmpty { return author }

        if let v = lookup[a], !v.isEmpty { return v }

        if isPhoneCandidate(a) {
            let pk = normalizePhoneKey(a)
            if let v = lookup[pk], !v.isEmpty { return v }
            if !pk.isEmpty { return pk }
        }

        return a
    }

    nonisolated private static func stripBOMAndBidi(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{202A}", with: "")
            .replacingOccurrences(of: "\u{202B}", with: "")
            .replacingOccurrences(of: "\u{202C}", with: "")
    }

    // Extract distinct URLs from a text blob.
    nonisolated private static func extractURLs(_ text: String) -> [String] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let rstripSet = CharacterSet(charactersIn: ").,;:!?]}'\"")

        let protectedRanges: [NSRange] = {
            var ranges: [NSRange] = []
            for re in [markdownLinkRe, anchorTagRe] {
                let matches = re.matches(in: text, options: [], range: fullRange)
                for m in matches where m.range.length > 0 {
                    ranges.append(m.range)
                }
            }
            return ranges
        }()

        func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
            for r in ranges where NSIntersectionRange(range, r).length > 0 {
                return true
            }
            return false
        }

        struct PreviewMatch {
            let range: NSRange
            let target: String
        }

        let httpMatches = urlRe.matches(in: text, options: [], range: fullRange)
        let httpRanges: [NSRange] = httpMatches.compactMap { match in
            let r = match.range(at: 1)
            return (r.location == NSNotFound || r.length == 0) ? nil : r
        }

        var candidates: [PreviewMatch] = []
        for r in httpRanges where !intersects(r, protectedRanges) {
            let raw = ns.substring(with: r)
            let trimmed = raw.trimmingCharacters(in: rstripSet)
            if !trimmed.isEmpty {
                candidates.append(PreviewMatch(range: r, target: trimmed))
            }
        }

        let bareMatches = bareDomainRe.matches(in: text, options: [], range: fullRange)
        for m in bareMatches {
            let r = m.range(at: 1)
            if r.location == NSNotFound || r.length == 0 { continue }
            if intersects(r, protectedRanges) || intersects(r, httpRanges) { continue }
            let raw = ns.substring(with: r)
            let trimmed = raw.trimmingCharacters(in: rstripSet)
            if !trimmed.isEmpty, isValidBareDomain(trimmed) {
                let target = "https://" + trimmed
                candidates.append(PreviewMatch(range: r, target: target))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length > rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }

        var out: [String] = []
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.target).inserted {
            out.append(candidate.target)
        }

        return out
    }

    // True if the message text consists only of one or more URLs (plus whitespace/newlines).
    // Used to avoid duplicating gigantic raw URLs in the bubble text when we already show previews/link lines.
    nonisolated private static func isURLOnlyText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        let rstripSet = CharacterSet(charactersIn: ").,;:!?]}'\"")
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return false }

        func isBareDomainToken(_ token: String) -> Bool {
            let ns = token as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = bareDomainRe.firstMatch(in: token, options: [], range: range) else {
                return false
            }
            let r = match.range(at: 1)
            guard r.location == 0 && r.length == ns.length else { return false }
            return isValidBareDomain(token)
        }

        for t0 in tokens {
            let t1 = String(t0).trimmingCharacters(in: rstripSet)
            let low = t1.lowercased()
            if low.hasPrefix("http://") || low.hasPrefix("https://") {
                if URL(string: t1) == nil { return false }
                continue
            }
            if isBareDomainToken(t1) { continue }
            return false
        }
        return true
    }

    // Produces a compact, human-friendly display string for a URL.
    // The href remains the original URL; this only affects what is shown in the UI/PDF.
    nonisolated private static func displayURL(_ urlString: String, maxLen: Int = 90) -> String {
        func shorten(_ s: String) -> String {
            if s.count <= maxLen { return s }
            return String(s.prefix(max(0, maxLen - 1))) + "…"
        }

        guard let u = URL(string: urlString), let host = u.host?.lowercased() else {
            return shorten(urlString)
        }

        // Apple Maps tends to have very long query strings; show a stable, compact label.
        if host == "maps.apple.com" {
            var coordPart: String? = nil
            if let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                let items = comps.queryItems ?? []
                if let v = items.first(where: { ["ll","q"].contains($0.name.lowercased()) })?.value {
                    // Keep only a short coordinate-ish part if present.
                    let candidate = v.replacingOccurrences(of: "+", with: " ")
                    if candidate.contains(",") {
                        coordPart = candidate
                    }
                }
            }
            let base = "maps.apple.com · Apple Maps"
            if let coordPart, !coordPart.isEmpty {
                return shorten(base + " · " + coordPart)
            }
            return shorten(base)
        }

        let path = u.path
        let hostPlusPath: String = {
            if path.isEmpty || path == "/" { return host }
            return host + path
        }()

        return shorten(hostPlusPath)
    }

    // Extract YouTube video ID from a URL (if present).
    nonisolated private static func youtubeVideoID(from urlString: String) -> String? {
        guard let u = URL(string: urlString), let host = u.host?.lowercased() else { return nil }
        let path = u.path

        if host.hasSuffix("youtu.be") {
            let vid = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first
            return vid.map(String.init)
        }

        if host.contains("youtube.com") || host == "m.youtube.com" {
            if let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                let q = comps.queryItems ?? []
                if let v = q.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
            }
            if path.hasPrefix("/shorts/") {
                let parts = path.split(separator: "/")
                if parts.count >= 2 { return String(parts[1]) }
            }
        }
        return nil
    }

    // Produce a filesystem-safe ASCII stem (used for stable attachment names).
    nonisolated private static func safeFilenameStem(_ stem: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var out = ""
        for ch in stem.unicodeScalars {
            out.append(allowed.contains(ch) ? Character(ch) : "_")
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "WHATSAPP_CHAT" : out
    }
    
    // Produces a human-readable, Finder-friendly filename (keeps spaces and Unicode),
    // while removing characters that are problematic in paths.
    nonisolated private static func safeFinderFilename(_ s: String, maxLen: Int = 200) -> String {
        var x = s.precomposedStringWithCanonicalMapping

        // Disallowed on macOS: "/" and ":".
        x = x.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        // Remove control characters
        let filteredScalars = x.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        x = String(String.UnicodeScalarView(filteredScalars))

        // Normalize whitespace
        x = _normSpace(x)

        // Avoid leading/trailing dots/spaces
        x = x.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        if x.isEmpty { x = "WhatsApp Chat" }

        // Length cap (extension is added later)
        if x.count > maxLen {
            x = String(x.prefix(maxLen)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }

        return x
    }

    nonisolated private static let chatTitlePrefixes: [String] = [
        "WhatsApp Chat - ",
        "WhatsApp Chat – ",
        "WhatsApp Chat — ",
        "WhatsApp Chat with ",
        "WhatsApp Chat mit ",
        "WhatsApp-Chat - ",
        "WhatsApp-Chat – ",
        "WhatsApp-Chat — ",
        "WhatsApp-Chat with ",
        "WhatsApp-Chat mit "
    ]

    nonisolated private static func stripChatPrefix(_ raw: String) -> String? {
        let cleaned = _normSpace(raw)
        if cleaned.isEmpty { return nil }

        let lower = cleaned.lowercased()
        let genericNames = [
            "whatsapp chat",
            "whatsapp-chat"
        ]
        if genericNames.contains(lower) { return nil }

        for prefix in chatTitlePrefixes {
            if lower.hasPrefix(prefix.lowercased()) {
                let suffix = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return suffix.isEmpty ? nil : suffix
            }
        }

        return cleaned
    }

    // Like stripChatPrefix, but only returns a value if an explicit WhatsApp header/title prefix is present.
    nonisolated private static func stripExplicitChatPrefix(_ raw: String) -> String? {
        let cleaned = _normSpace(raw)
        if cleaned.isEmpty { return nil }

        let lower = cleaned.lowercased()
        for prefix in chatTitlePrefixes {
            if lower.hasPrefix(prefix.lowercased()) {
                let suffix = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return suffix.isEmpty ? nil : suffix
            }
        }

        return nil
    }

    nonisolated private static func containsURLLikeText(_ text: String) -> Bool {
        !extractURLs(text).isEmpty
    }

    nonisolated private static func hasTimestampPrefix(_ text: String) -> Bool {
        match(patTimestampPrefix, text) != nil
    }

    nonisolated private static func isNameLikeCandidate(_ text: String) -> Bool {
        let cleaned = _normSpace(text).precomposedStringWithCanonicalMapping
        if cleaned.isEmpty { return false }

        var letterCount = 0
        let allowedPunct = CharacterSet(charactersIn: "-'’·.")
        for scalar in cleaned.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letterCount += 1
                continue
            }
            if CharacterSet.nonBaseCharacters.contains(scalar) { continue }
            if CharacterSet.whitespaces.contains(scalar) { continue }
            if allowedPunct.contains(scalar) { continue }
            return false
        }
        return letterCount > 0
    }

    nonisolated private static func containerCandidateDecision(_ raw: String?) -> (candidate: String?, rejection: String?) {
        guard let raw else { return (nil, nil) }
        if raw.contains(where: \.isNewline) { return (nil, "newline") }

        let cleaned = _normSpace(raw).precomposedStringWithCanonicalMapping
        if cleaned.isEmpty { return (nil, "empty") }
        if containsURLLikeText(cleaned) { return (nil, "url") }
        if hasTimestampPrefix(cleaned) { return (nil, "timestamp") }
        if cleaned.count > 80 { return (nil, "length>80") }

        let punctCount = cleaned.unicodeScalars.filter { scalar in
            ".?!".unicodeScalars.contains(scalar)
        }.count
        if punctCount >= 2 { return (nil, "punctuation") }

        if isPhoneCandidate(cleaned) { return (cleaned, nil) }
        guard isNameLikeCandidate(cleaned) else { return (nil, "non-name") }
        return (cleaned, nil)
    }

    nonisolated static func applyPartnerOverrideToName(
        originalName: String,
        detectedPartnerRaw: String,
        overridePartnerRaw: String?
    ) -> String {
        let overrideTrimmed = _normSpace(overridePartnerRaw ?? "")
        if overrideTrimmed.isEmpty { return safeFinderFilename(originalName) }

        if let replaced = replaceTokenIfPresent(
            originalName: originalName,
            tokenDetectedRaw: detectedPartnerRaw,
            tokenOverrideRaw: overrideTrimmed
        ) {
            return replaced
        }

        if let phoneToken = firstPhoneCandidate(in: originalName),
           let replaced = replaceTokenIfPresent(
               originalName: originalName,
               tokenDetectedRaw: phoneToken,
               tokenOverrideRaw: overrideTrimmed
           ) {
            return replaced
        }

        return safeFinderFilename(originalName)
    }

    nonisolated private static func replaceTokenIfPresent(
        originalName: String,
        tokenDetectedRaw: String,
        tokenOverrideRaw: String
    ) -> String? {
        let detectedTrimmed = _normSpace(tokenDetectedRaw)
        if detectedTrimmed.isEmpty { return nil }

        let tokenDetected = safeFinderFilename(detectedTrimmed)
        let tokenOverride = safeFinderFilename(_normSpace(tokenOverrideRaw))
        if tokenDetected.isEmpty || tokenOverride.isEmpty { return nil }
        if tokenDetected == tokenOverride { return nil }

        if originalName == tokenDetected { return safeFinderFilename(tokenOverride) }

        func isBoundaryChar(_ ch: Character) -> Bool {
            if ch == "·" { return true }
            for scalar in ch.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            }
            return false
        }

        var ranges: [Range<String.Index>] = []
        var searchRange = originalName.startIndex..<originalName.endIndex
        while let r = originalName.range(of: tokenDetected, options: [], range: searchRange) {
            let leftOK: Bool = {
                if r.lowerBound == originalName.startIndex { return true }
                let ch = originalName[originalName.index(before: r.lowerBound)]
                return isBoundaryChar(ch)
            }()
            let rightOK: Bool = {
                if r.upperBound == originalName.endIndex { return true }
                let ch = originalName[r.upperBound]
                return isBoundaryChar(ch)
            }()
            if leftOK && rightOK {
                ranges.append(r)
            }
            searchRange = r.upperBound..<originalName.endIndex
        }

        guard !ranges.isEmpty else { return nil }

        var result = originalName
        for r in ranges.reversed() {
            result.replaceSubrange(r, with: tokenOverride)
        }
        return safeFinderFilename(result)
    }

    nonisolated private static func firstPhoneCandidate(in name: String) -> String? {
        var best: String? = nil
        var current = ""

        func flushCurrent() {
            guard !current.isEmpty else { return }
            var trimmed = _normSpace(current)
            trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if isPhoneCandidate(trimmed) {
                if best == nil || trimmed.count > (best?.count ?? 0) {
                    best = trimmed
                }
            }
            current = ""
        }

        for ch in name {
            if ch.isNumber || ch == "+" || ch == " " || ch == "-" || ch == "(" || ch == ")" {
                current.append(ch)
            } else {
                flushCurrent()
            }
        }
        flushCurrent()

        return best
    }

    nonisolated private static func stableHashHex(_ s: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    nonisolated private static func deterministicInputWorkspace(for zipURL: URL) -> URL {
        let fm = FileManager.default
        let base: URL = {
            if let override = ProcessInfo.processInfo.environment["WET_TMPDIR"], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
                    .appendingPathComponent("wa_export_input", isDirectory: true)
            }
            return fm.temporaryDirectory.appendingPathComponent("wa_export_input", isDirectory: true)
        }()
        let attrs = (try? fm.attributesOfItem(atPath: zipURL.path)) ?? [:]
        let size = attrs[.size] as? UInt64 ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(zipURL.path)|\(size)|\(mtime)"
        let hash = stableHashHex(key)
        return base.appendingPathComponent(".wa_zip_\(hash)", isDirectory: true)
    }

    nonisolated private static func effectiveZipExtractionRoot(
        workspace: URL,
        zipURL: URL,
        detectedPartnerRaw: String?,
        overridePartnerRaw: String?
    ) throws -> URL {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let filtered = entries.filter { url in
            let name = url.lastPathComponent
            if name == "__MACOSX" || name == ".DS_Store" { return false }
            if name.hasPrefix(".") { return false }
            return true
        }

        var directories: [URL] = []
        var others: [URL] = []
        for url in filtered {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if rv?.isDirectory == true {
                directories.append(url)
            } else {
                others.append(url)
            }
        }

        if directories.count == 1 && others.isEmpty {
            return directories[0]
        }

        let wrapperName = safeFinderFilename(zipURL.deletingPathExtension().lastPathComponent)
        let wrapperDir = workspace.appendingPathComponent(wrapperName, isDirectory: true)
        if !fm.fileExists(atPath: wrapperDir.path) {
            try fm.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        }

        for url in filtered {
            if url.standardizedFileURL == wrapperDir.standardizedFileURL {
                continue
            }
            let dest = wrapperDir.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: dest)
        }

        return wrapperDir
    }

    nonisolated private static func recreateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private enum ZipTimestampSource: String {
        case dos
        case utCentral
        case ntfsCentral
        case utLocal
        case ntfsLocal
    }

    private struct ZipTimestampEntry {
        let path: String
        let date: Date
        let source: ZipTimestampSource
    }

    private enum ZipTimestampError: Error {
        case eocdNotFound
        case zip64Unsupported
    }

    nonisolated private static func normalizeZipEntryTimestamps(zipURL: URL, destDir: URL) {
        let debugEnabled = ProcessInfo.processInfo.environment["WET_DEBUG"] == "1"
        do {
            let entries = try readZipEntryTimestamps(zipURL: zipURL)
            guard !entries.isEmpty else { return }

            let fm = FileManager.default
            let root = destDir.standardizedFileURL
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

            func normalizedZipPathKey(_ path: String) -> String {
                var p = path.replacingOccurrences(of: "\\", with: "/")
                if p.hasPrefix("./") { p.removeFirst(2) }
                if p.hasPrefix("/") { p.removeFirst() }
                if p.hasSuffix("/") { p.removeLast() }
                return p.precomposedStringWithCanonicalMapping.lowercased()
            }

            var fallbackIndex: [String: URL]? = nil
            var fallbackAmbiguous = Set<String>()
            var baseIndex: [String: URL]? = nil
            var baseAmbiguous = Set<String>()

            func buildFallbackIndex() {
                var relIndex: [String: URL] = [:]
                var relAmb: Set<String> = []
                var baseIdx: [String: URL] = [:]
                var baseAmb: Set<String> = []

                guard let en = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    fallbackIndex = [:]
                    baseIndex = [:]
                    fallbackAmbiguous = []
                    baseAmbiguous = []
                    return
                }

                for case let u as URL in en {
                    let fullPath = u.standardizedFileURL.path
                    guard fullPath.hasPrefix(rootPath) else { continue }
                    var rel = String(fullPath.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    if rel.isEmpty { continue }

                    let relKey = normalizedZipPathKey(rel)
                    if let _ = relIndex[relKey] {
                        relAmb.insert(relKey)
                        relIndex.removeValue(forKey: relKey)
                    } else {
                        relIndex[relKey] = u
                    }

                    let baseKey = normalizedZipPathKey(u.lastPathComponent)
                    if let _ = baseIdx[baseKey] {
                        baseAmb.insert(baseKey)
                        baseIdx.removeValue(forKey: baseKey)
                    } else {
                        baseIdx[baseKey] = u
                    }
                }

                fallbackIndex = relIndex
                fallbackAmbiguous = relAmb
                baseIndex = baseIdx
                baseAmbiguous = baseAmb
            }

            func fallbackURL(for rel: String) -> URL? {
                if fallbackIndex == nil { buildFallbackIndex() }
                let relKey = normalizedZipPathKey(rel)
                if !fallbackAmbiguous.contains(relKey), let hit = fallbackIndex?[relKey] {
                    return hit
                }
                let baseKey = normalizedZipPathKey((rel as NSString).lastPathComponent)
                if !baseAmbiguous.contains(baseKey), let hit = baseIndex?[baseKey] {
                    return hit
                }
                return nil
            }

            func adjustedDate(for entry: ZipTimestampEntry, existingMTime: Date?) -> (Date, Bool) {
                guard entry.source == .dos, let existingMTime else { return (entry.date, false) }
                let offset = TimePolicy.canonicalTimeZone.secondsFromGMT(for: entry.date)
                if offset == 0 { return (entry.date, false) }
                let delta = Int((entry.date.timeIntervalSince1970 - existingMTime.timeIntervalSince1970).rounded())
                if abs(delta) == abs(offset) {
                    return (existingMTime, true)
                }
                return (entry.date, false)
            }

            for entry in entries {
                var rel = entry.path.replacingOccurrences(of: "\\", with: "/")
                if rel.hasPrefix("./") { rel.removeFirst(2) }
                if rel.hasPrefix("/") { rel.removeFirst() }
                if rel.hasSuffix("/") { rel.removeLast() }
                if rel.isEmpty { continue }

                let candidate = URL(fileURLWithPath: rel, relativeTo: root).standardizedFileURL
                let candidatePath = candidate.path
                guard candidatePath.hasPrefix(rootPath) else { continue }
                let target: URL = {
                    if fm.fileExists(atPath: candidatePath) { return candidate }
                    if let fallback = fallbackURL(for: rel) { return fallback.standardizedFileURL }
                    return candidate
                }()
                let targetPath = target.path
                guard targetPath.hasPrefix(rootPath), fm.fileExists(atPath: targetPath) else { continue }

                let existingMTime = (try? fm.attributesOfItem(atPath: targetPath))?[.modificationDate] as? Date
                let (appliedDate, didAdjust) = adjustedDate(for: entry, existingMTime: existingMTime)
                do {
                    try fm.setAttributes([.creationDate: appliedDate, .modificationDate: appliedDate], ofItemAtPath: targetPath)
                } catch {
                    try? fm.setAttributes([.modificationDate: appliedDate], ofItemAtPath: targetPath)
                }
                if debugEnabled, targetPath.lowercased().hasSuffix(".pdf") {
                    let epoch = Int(appliedDate.timeIntervalSince1970.rounded())
                    let source = didAdjust ? "\(entry.source.rawValue)+adj" : entry.source.rawValue
                    print("WET-DBG: ZIP PDF mtime epoch=\(epoch) source=\(source) path=\(targetPath)")
                }
            }
        } catch {
            if debugEnabled {
                print("WET-DBG: ZIP timestamp normalization skipped: \(error)")
            }
        }
    }

    nonisolated private static func readZipEntryTimestamps(zipURL: URL) throws -> [ZipTimestampEntry] {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { return [] }

        let maxComment: UInt64 = 0xFFFF
        let eocdSize: UInt64 = 22
        let tailSize = min(fileSize, eocdSize + maxComment)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()

        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocdIndex: Int? = nil
        if tail.count >= 4 {
            for i in stride(from: tail.count - 4, through: 0, by: -1) {
                if tail[i] == sig[0],
                   tail[i + 1] == sig[1],
                   tail[i + 2] == sig[2],
                   tail[i + 3] == sig[3] {
                    eocdIndex = i
                    break
                }
            }
        }
        guard let eocdIndex else { throw ZipTimestampError.eocdNotFound }

        func readU16(_ data: Data, _ offset: Int) -> UInt16 {
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1]) << 8
            return b0 | b1
        }

        func readU32(_ data: Data, _ offset: Int) -> UInt32 {
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1]) << 8
            let b2 = UInt32(data[offset + 2]) << 16
            let b3 = UInt32(data[offset + 3]) << 24
            return b0 | b1 | b2 | b3
        }

        func readU64(_ data: Data, _ offset: Int) -> UInt64 {
            var out: UInt64 = 0
            for i in 0..<8 {
                out |= UInt64(data[offset + i]) << UInt64(i * 8)
            }
            return out
        }

        let totalEntries = readU16(tail, eocdIndex + 10)
        let cdSize = readU32(tail, eocdIndex + 12)
        let cdOffset = readU32(tail, eocdIndex + 16)

        if totalEntries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            throw ZipTimestampError.zip64Unsupported
        }

        try handle.seek(toOffset: UInt64(cdOffset))
        let cdData = try handle.read(upToCount: Int(cdSize)) ?? Data()

        func parseExtendedTimestamp(_ data: Data) -> Date? {
            guard data.count >= 5 else { return nil }
            let flags = data[0]
            guard (flags & 0x01) != 0 else { return nil }
            let epoch = readU32(data, 1)
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }

        func parseNTFSTimestamp(_ data: Data) -> Date? {
            guard data.count >= 4 else { return nil }
            var offset = 4
            while offset + 4 <= data.count {
                let tag = readU16(data, offset)
                let size = Int(readU16(data, offset + 2))
                offset += 4
                if offset + size > data.count { break }
                if tag == 0x0001, size >= 24 {
                    let fileTime = readU64(data, offset)
                    let unixEpoch: UInt64 = 116444736000000000
                    if fileTime >= unixEpoch {
                        let interval = Double(fileTime - unixEpoch) / 10_000_000
                        return Date(timeIntervalSince1970: interval)
                    }
                }
                offset += size
            }
            return nil
        }

        func parseExtraTimestamp(
            _ data: Data,
            utSource: ZipTimestampSource,
            ntfsSource: ZipTimestampSource
        ) -> (Date, ZipTimestampSource)? {
            var idx = 0
            while idx + 4 <= data.count {
                let headerID = readU16(data, idx)
                let dataSize = Int(readU16(data, idx + 2))
                idx += 4
                if idx + dataSize > data.count { break }
                let field = data.subdata(in: idx..<(idx + dataSize))
                if headerID == 0x5455, let date = parseExtendedTimestamp(field) {
                    return (date, utSource)
                }
                if headerID == 0x000a, let date = parseNTFSTimestamp(field) {
                    return (date, ntfsSource)
                }
                idx += dataSize
            }
            return nil
        }

        func readLocalExtraField(offset: UInt32) -> Data? {
            if offset == 0xFFFFFFFF { return nil }
            let start = UInt64(offset)
            if start + 30 > fileSize { return nil }
            do {
                try handle.seek(toOffset: start)
                let header = try handle.read(upToCount: 30) ?? Data()
                guard header.count >= 30, readU32(header, 0) == 0x04034b50 else { return nil }
                let nameLen = Int(readU16(header, 26))
                let extraLen = Int(readU16(header, 28))
                if nameLen > 0 {
                    _ = try handle.read(upToCount: nameLen)
                }
                guard extraLen > 0 else { return nil }
                return try handle.read(upToCount: extraLen) ?? Data()
            } catch {
                return nil
            }
        }

        var entries: [ZipTimestampEntry] = []
        entries.reserveCapacity(Int(totalEntries))

        var offset = 0
        while offset + 46 <= cdData.count {
            if readU32(cdData, offset) != 0x02014b50 { break }

            let flags = readU16(cdData, offset + 8)
            let modTime = readU16(cdData, offset + 12)
            let modDate = readU16(cdData, offset + 14)
            let nameLen = Int(readU16(cdData, offset + 28))
            let extraLen = Int(readU16(cdData, offset + 30))
            let commentLen = Int(readU16(cdData, offset + 32))
            let localHeaderOffset = readU32(cdData, offset + 42)

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cdData.count else { break }

            let nameData = cdData.subdata(in: nameStart..<nameEnd)
            let isUTF8 = (flags & 0x0800) != 0
            let name: String = {
                if isUTF8, let decoded = String(data: nameData, encoding: .utf8) {
                    return decoded
                }
                let dosEncoding = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)
                    )
                )
                if let dos = String(data: nameData, encoding: dosEncoding) {
                    return dos
                }
                if let latin = String(data: nameData, encoding: .isoLatin1) {
                    return latin
                }
                return String(decoding: nameData, as: UTF8.self)
            }()

            let extraStart = nameEnd
            let extraEnd = extraStart + extraLen
            var chosen: (Date, ZipTimestampSource)? = nil
            if extraLen > 0, extraEnd <= cdData.count {
                let extraData = cdData.subdata(in: extraStart..<extraEnd)
                chosen = parseExtraTimestamp(extraData, utSource: .utCentral, ntfsSource: .ntfsCentral)
            }
            if chosen == nil, let localExtra = readLocalExtraField(offset: localHeaderOffset) {
                chosen = parseExtraTimestamp(localExtra, utSource: .utLocal, ntfsSource: .ntfsLocal)
            }
            if let chosen {
                entries.append(ZipTimestampEntry(path: name, date: chosen.0, source: chosen.1))
            } else if let date = TimePolicy.dateFromMSDOSTimestamp(date: modDate, time: modTime) {
                entries.append(ZipTimestampEntry(path: name, date: date, source: .dos))
            }

            offset = nameEnd + extraLen + commentLen
        }

        return entries
    }

    nonisolated private static func extractZip(at zipURL: URL, to destDir: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, destDir.path]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw WAInputError.zipExtractionFailed(url: zipURL, reason: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        normalizeZipEntryTimestamps(zipURL: zipURL, destDir: destDir)
    }

    nonisolated private static func resolveTranscript(in dir: URL) throws -> (chatURL: URL, exportDir: URL) {
        let fm = FileManager.default
        let root = dir.standardizedFileURL
        let candidates = ["Chat.txt", "_chat.txt"]

        for name in candidates {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return (url, root)
            }
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WAInputError.transcriptNotFound(url: root)
        }

        var matches: [URL] = []
        var exportDirs: [URL] = []
        for url in entries {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard rv?.isDirectory == true else { continue }
            for name in candidates {
                let candidate = url.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    matches.append(candidate)
                    exportDirs.append(url)
                }
            }
        }

        if matches.count == 1, let chatURL = matches.first, let exportDir = exportDirs.first {
            return (chatURL, exportDir)
        }
        if matches.count > 1 {
            throw WAInputError.ambiguousTranscript(urls: matches)
        }

        throw WAInputError.transcriptNotFound(url: root)
    }

    // Normalize participant labels for filenames (NFC + space collapse).
    nonisolated private static func normalizedParticipantLabel(_ s: String) -> String {
        _normSpace(s.precomposedStringWithCanonicalMapping)
    }

    // Prefer export folder/zip stem as a fallback chat identifier.
    nonisolated private static func fallbackChatIdentifier(from chatURL: URL) -> String {
        let folderName = normalizedParticipantLabel(chatURL.deletingLastPathComponent().lastPathComponent)
        if folderName.isEmpty { return "WhatsApp Chat" }

        let prefixes = [
            "WhatsApp Chat - ",
            "WhatsApp Chat – ",
            "WhatsApp Chat — ",
            "WhatsApp Chat with ",
            "WhatsApp Chat mit ",
            "WhatsApp-Chat - ",
            "WhatsApp-Chat – ",
            "WhatsApp-Chat — ",
            "WhatsApp-Chat with ",
            "WhatsApp-Chat mit "
        ]

        for prefix in prefixes {
            if folderName.lowercased().hasPrefix(prefix.lowercased()) {
                let trimmed = normalizedParticipantLabel(String(folderName.dropFirst(prefix.count)))
                if !trimmed.isEmpty { return trimmed }
            }
        }

        return folderName
    }

    nonisolated private static func exportDateRangeLabel(messages: [WAMessage]) -> String {
        guard let minD = messages.min(by: { $0.ts < $1.ts })?.ts,
              let maxD = messages.max(by: { $0.ts < $1.ts })?.ts else {
            return "No messages"
        }
        let start = fileDateOnlyFormatter.string(from: minD)
        let end = fileDateOnlyFormatter.string(from: maxD)
        return "\(start) to \(end)"
    }

    nonisolated private static func exportCreatedDate(
        chatURL: URL
    ) -> Date? {
        let chatFileAttrs = (try? FileManager.default.attributesOfItem(atPath: chatURL.path)) ?? [:]
        if let c = chatFileAttrs[.creationDate] as? Date { return c }
        if let m = chatFileAttrs[.modificationDate] as? Date { return m }
        return nil
    }

    nonisolated private static func exportCreatedStamp(for chatURL: URL) -> String {
        if let createdAt = exportCreatedDate(chatURL: chatURL) {
            return fileStampFormatter.string(from: createdAt)
        }
        return "unknown"
    }

    nonisolated private static func exportCreatedDateFromFolderName(_ folderName: String) -> Date? {
        TimePolicy.exportCreatedDateFromFolderName(folderName)
    }

    nonisolated private static func exportParticipantsLabel(
        messages: [WAMessage],
        meName: String,
        chatURL: URL
    ) -> String {
        let authors = messages.map { $0.author }.filter { !normalizedParticipantLabel($0).isEmpty }
        let uniqAuthors = Array(Set(authors.map { normalizedParticipantLabel($0) }))
            .filter { !$0.isEmpty && !isSystemAuthor($0) }
            .sorted()

        let meNorm = normalizedParticipantLabel(meName)
        let partners = uniqAuthors.filter { normalizedParticipantLabel($0).lowercased() != meNorm.lowercased() }
        let fallback = fallbackChatIdentifier(from: chatURL)

        if partners.isEmpty {
            if meNorm.isEmpty { return fallback }
            return fallback.isEmpty ? meNorm : "\(meNorm) ↔ \(fallback)"
        }

        if partners.count == 1 {
            let other = partners[0]
            if meNorm.isEmpty { return other }
            return "\(meNorm) ↔ \(other)"
        }

        // Group-style label: prefer folder/group identifier over enumerating everyone.
        let groupLabel = fallback.isEmpty ? partners.joined(separator: ", ") : fallback
        if meNorm.isEmpty { return groupLabel }
        return "\(meNorm) ↔ \(groupLabel)"
    }

    nonisolated private static func composeExportBaseName(
        messages: [WAMessage],
        chatURL: URL,
        meName: String
    ) -> String {
        let convoPart = exportParticipantsLabel(messages: messages, meName: meName, chatURL: chatURL)
        let periodPart = exportDateRangeLabel(messages: messages)
        let createdStamp = exportCreatedStamp(for: chatURL)
        let baseRaw = "WhatsApp Chat · \(convoPart) · \(periodPart) · Chat.txt created \(createdStamp)"
        return safeFinderFilename(baseRaw)
    }

    nonisolated private static func isoDateOnly(_ d: Date) -> String {
        let c = canonicalCalendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // ---------------------------
    // Parsing WhatsApp exports
    // ---------------------------

    // Parse "dd.MM.yyyy, HH:mm(:ss)" timestamps used in WhatsApp exports.
    nonisolated private static func parseDT_DE(date: String, hm: String, sec: String?) -> Date? {
        let parts = date.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let day = Int(parts[0]) ?? 0
        let month = Int(parts[1]) ?? 0
        var year = Int(parts[2]) ?? 0
        if year < 100 { year += 2000 }

        let hmParts = hm.split(separator: ":")
        guard hmParts.count == 2 else { return nil }
        let hh = Int(hmParts[0]) ?? 0
        let mm = Int(hmParts[1]) ?? 0
        let ss = Int(sec ?? "") ?? 0

        var dc = DateComponents()
        dc.year = year
        dc.month = month
        dc.day = day
        dc.hour = hh
        dc.minute = mm
        dc.second = ss
        dc.timeZone = canonicalTimeZone
        return canonicalCalendar.date(from: dc)
    }

    nonisolated private static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        var g: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            g.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return g
    }

    nonisolated private static func loadChatLines(_ chatURL: URL) throws -> [String] {
        let s: String
        do {
            s = try String(contentsOf: chatURL, encoding: .utf8)
        } catch {
            // Fallbacks for common WhatsApp exports
            if let s16 = try? String(contentsOf: chatURL, encoding: .utf16) {
                s = s16
            } else if let sLatin = try? String(contentsOf: chatURL, encoding: .isoLatin1) {
                s = sLatin
            } else {
                throw error
            }
        }
        return s.components(separatedBy: .newlines)
    }

    nonisolated private static func isMessageLine(_ line: String) -> Bool {
        if match(patISO, line) != nil { return true }
        if match(patDE, line) != nil { return true }
        if match(patBracket, line) != nil { return true }
        return false
    }

    // Parse WhatsApp export lines into message records.
    nonisolated private static func parseMessages(_ chatURL: URL) throws -> [WAMessage] {
        let lines = try loadChatLines(chatURL)
        return parseMessages(lines)
    }

    // Parse WhatsApp export lines into message records.
    nonisolated private static func parseMessages(_ lines: [String]) -> [WAMessage] {
        var msgs: [WAMessage] = []
        var lastIndex: Int? = nil

        for origLine in lines {
            var line = origLine
            if !line.isEmpty { line = stripBOMAndBidi(line) }

            if line.isEmpty {
                if let i = lastIndex {
                    msgs[i].text += "\n"
                }
                continue
            }

            if let g = match(patISO, line) {
                let d = g[0], t = g[1], authorRaw = g[2], text = g[3]
                guard let ts = isoDTFormatter.date(from: "\(d) \(t)") else {
                    // If the timestamp cannot be parsed, treat the line as a continuation to avoid corrupting chronology.
                    if let i = lastIndex { msgs[i].text += "\n" + line }
                    continue
                }
                let author = _normSpace(authorRaw)
                msgs.append(WAMessage(ts: ts, author: author, text: text))
                lastIndex = msgs.count - 1
                continue
            }

            if let g = match(patDE, line) {
                let d = g[0], hm = g[1], sec = g[2].isEmpty ? nil : g[2], authorRaw = g[3], text = g[4]
                guard let ts = parseDT_DE(date: d, hm: hm, sec: sec) else {
                    // If the timestamp cannot be parsed, treat the line as a continuation to avoid corrupting chronology.
                    if let i = lastIndex { msgs[i].text += "\n" + line }
                    continue
                }
                let author = _normSpace(authorRaw)
                msgs.append(WAMessage(ts: ts, author: author, text: text))
                lastIndex = msgs.count - 1
                continue
            }

            if let g = match(patBracket, line) {
                let d = g[0], hm = g[1], sec = g[2].isEmpty ? nil : g[2], authorRaw = g[3], text = g[4]
                guard let ts = parseDT_DE(date: d, hm: hm, sec: sec) else {
                    // If the timestamp cannot be parsed, treat the line as a continuation to avoid corrupting chronology.
                    if let i = lastIndex { msgs[i].text += "\n" + line }
                    continue
                }
                let author = _normSpace(authorRaw)
                msgs.append(WAMessage(ts: ts, author: author, text: text))
                lastIndex = msgs.count - 1
                continue
            }

            // continuation
            if let i = lastIndex {
                msgs[i].text += "\n" + line
            } else {
                // stray -> ignore
            }
        }

        return msgs
    }

    // ---------------------------
    // "Ich"-Perspektive selection (non-interactive)
    // ---------------------------

    nonisolated private static let meDeletedMarkers: [String] = [
        "du hast diese nachricht gelöscht",
        "du hast eine nachricht gelöscht",
        "you deleted this message",
        "you deleted a message",
    ]

    nonisolated private static let meGroupActionMarkers: [String] = [
        "du hast die gruppe erstellt",
        "du hast diese gruppe erstellt",
        "du hast den gruppenbetreff geändert",
        "du hast den gruppennamen geändert",
        "du hast die gruppenbeschreibung geändert",
        "du hast das gruppenbild geändert",
        "du hast die gruppe verlassen",
        "du hast diese gruppe verlassen",
        "you created group",
        "you created the group",
        "you changed the group subject",
        "you changed the group name",
        "you changed the group description",
        "you changed this group's description",
        "you changed the group icon",
        "you changed this group's icon",
        "you left the group",
    ]

    nonisolated private static let otherDeletedMarkers: [String] = [
        "diese nachricht wurde gelöscht",
        "this message was deleted",
    ]

    nonisolated private static func normalizedSystemText(_ text: String) -> String {
        let stripped = stripBOMAndBidi(text)
        return _normSpace(stripped).lowercased()
    }

    nonisolated private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles where haystack.contains(n) { return true }
        return false
    }

    nonisolated private static func inferMeName(messages: [WAMessage]) -> String? {
        var candidates: Set<String> = []
        var deletedByMe: [String: Int] = [:]
        var groupActionsByMe: [String: Int] = [:]
        var deletedByOther: [String: Int] = [:]

        for m in messages {
            let author = normalizedParticipantIdentifier(m.author)
            if author.isEmpty { continue }
            if isSystemAuthor(author) { continue }
            candidates.insert(author)

            let text = normalizedSystemText(m.text)
            if text.isEmpty { continue }

            if containsAny(text, meDeletedMarkers) {
                deletedByMe[author, default: 0] += 1
                continue
            }
            if containsAny(text, meGroupActionMarkers) {
                groupActionsByMe[author, default: 0] += 1
                continue
            }
            if containsAny(text, otherDeletedMarkers) {
                deletedByOther[author, default: 0] += 1
            }
        }

        if deletedByMe.count == 1, let me = deletedByMe.keys.first {
            return me
        }

        if deletedByMe.count > 1 {
            return nil
        }

        if groupActionsByMe.count == 1, let me = groupActionsByMe.keys.first {
            return me
        }

        if groupActionsByMe.count > 1 {
            return nil
        }

        if candidates.count == 2, deletedByOther.count == 1 {
            let notMe = deletedByOther.keys.first!
            return candidates.first(where: { $0 != notMe })
        }

        return nil
    }

    // Pick a default local participant name (GUI can override this later).
    nonisolated private static func chooseMeName(messages: [WAMessage]) -> String {
        if let guessed = inferMeName(messages: messages) {
            return guessed
        }

        var uniq: [String] = []
        for m in messages {
            let a2 = normalizedParticipantIdentifier(m.author)
            if a2.isEmpty { continue }
            if !uniq.contains(a2) { uniq.append(a2) }
        }

        let filtered = uniq.filter { !isSystemAuthor($0) }
        if !filtered.isEmpty { uniq = filtered }

        if uniq.isEmpty { return "Ich" }
        return uniq[0] // GUI kann später eine Auswahl anbieten; 1:1 Default = erstes Element
    }

    // ---------------------------
    // Attachment handling
    // ---------------------------

    nonisolated private static func findAttachments(_ text: String) -> [String] {
        let ns = text as NSString
        let matches = attachRe.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private struct AttachmentIndexSnapshot: Sendable {
        let relPathByName: [String: String]
    }

    nonisolated private static func relativePath(from baseDir: URL, to fileURL: URL) -> String? {
        let base = baseDir.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        let rel = String(full.dropFirst(prefix.count))
        return rel.isEmpty ? nil : rel
    }

    // ---------------------------
    // Sorted attachments folder (standalone export)
    // ---------------------------

    enum SortedAttachmentBucket: String {
        case images
        case videos
        case audios
        case documents
    }

    struct AttachmentCanonicalEntry: Sendable {
        let fileName: String
        let sourceURL: URL
        let bucket: SortedAttachmentBucket
        let destName: String
        let canonicalRelPath: String
    }

    nonisolated private static func bucketForExtension(_ ext: String) -> SortedAttachmentBucket {
        let e = ext.lowercased()
        switch e {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp":
            return .images
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "3gp":
            return .videos
        case "m4a", "mp3", "wav", "aac", "caf", "ogg", "opus", "flac", "amr", "aiff", "aif":
            return .audios
        default:
            return .documents
        }
    }

    nonisolated static func buildAttachmentCanonicalEntries(
        messages: [WAMessage],
        chatSourceDir: URL
    ) -> [AttachmentCanonicalEntry] {
        var earliestDateByFile: [String: Date] = [:]
        earliestDateByFile.reserveCapacity(64)

        for m in messages {
            let fns = findAttachments(m.text)
            if fns.isEmpty { continue }
            for fn in fns {
                if let existing = earliestDateByFile[fn] {
                    if m.ts < existing { earliestDateByFile[fn] = m.ts }
                } else {
                    earliestDateByFile[fn] = m.ts
                }
            }
        }

        if earliestDateByFile.isEmpty { return [] }

        let df = DateFormatter()
        df.locale = canonicalLocale
        df.timeZone = canonicalTimeZone
        df.dateFormat = "yyyy MM dd HH mm ss"

        let ordered = earliestDateByFile.sorted(by: { $0.key < $1.key })
        var entries: [AttachmentCanonicalEntry] = []
        entries.reserveCapacity(ordered.count)

        let chatDir = chatSourceDir.standardizedFileURL

        for (fn, ts) in ordered {
            guard let src = resolveAttachmentURL(fileName: fn, sourceDir: chatDir) else {
                continue
            }
            let bucket = bucketForExtension(src.pathExtension)
            let prefix = df.string(from: ts)
            let destName = "\(prefix) \(fn)"
            let canonicalRelPath = "\(bucket.rawValue)/\(destName)"
            entries.append(AttachmentCanonicalEntry(
                fileName: fn,
                sourceURL: src,
                bucket: bucket,
                destName: destName,
                canonicalRelPath: canonicalRelPath
            ))
        }

        return entries
    }

    nonisolated private static func buildAttachmentIndexSnapshot(for sourceDir: URL) -> AttachmentIndexSnapshot {
        let fm = FileManager.default
        let base = sourceDir.standardizedFileURL

        let buildStart = ProcessInfo.processInfo.systemUptime
        var index: [String: String] = [:]
        var fileCount = 0
        if let en = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let u as URL in en {
                let rv = try? u.resourceValues(forKeys: [.isRegularFileKey])
                if rv?.isRegularFile != true { continue }
                fileCount += 1
                let name = u.lastPathComponent
                if index[name] == nil, let rel = relativePath(from: base, to: u) {
                    index[name] = rel
                }
            }
        }
        let buildDuration = ProcessInfo.processInfo.systemUptime - buildStart
        recordAttachmentIndexBuild(duration: buildDuration, fileCount: fileCount)
        return AttachmentIndexSnapshot(relPathByName: index)
    }

    nonisolated private static func attachmentIndexSnapshot(for sourceDir: URL) -> AttachmentIndexSnapshot {
        attachmentIndexCondition.lock()
        if let cached = attachmentIndexSnapshot {
            attachmentIndexCondition.unlock()
            return cached
        }
        if attachmentIndexBuildInProgress {
            while attachmentIndexSnapshot == nil {
                attachmentIndexCondition.wait()
            }
            let cached = attachmentIndexSnapshot!
            attachmentIndexCondition.unlock()
            return cached
        }
        attachmentIndexBuildInProgress = true
        attachmentIndexCondition.unlock()

        let snapshot = buildAttachmentIndexSnapshot(for: sourceDir)

        attachmentIndexCondition.lock()
        if attachmentIndexSnapshot == nil {
            attachmentIndexSnapshot = snapshot
        }
        attachmentIndexBuildInProgress = false
        attachmentIndexCondition.broadcast()
        let cached = attachmentIndexSnapshot ?? snapshot
        attachmentIndexCondition.unlock()
        return cached
    }

    nonisolated static func prewarmAttachmentIndex(for sourceDir: URL) {
        _ = attachmentIndexSnapshot(for: sourceDir)
    }

    nonisolated private static func resolveAttachmentURL(fileName: String, sourceDir: URL) -> URL? {
        let fm = FileManager.default
        let base = sourceDir.standardizedFileURL

        // 1) Most common: attachment is next to the chat.txt
        let direct = base.appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) { return direct }

        // 2) Common alternative: inside a "Media" folder
        let media = base.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(fileName)
        if fm.fileExists(atPath: media.path) { return media }

        // 3) Last resort: resolve via cached index (avoids per-attachment recursion).
        let index = attachmentIndexSnapshot(for: base)
        if let rel = index.relPathByName[fileName] {
            let candidate = base.appendingPathComponent(rel)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    nonisolated private static func exportSortedAttachmentsFolder(
        chatURL: URL,
        messages: [WAMessage],
        outDir: URL,
        folderName: String,
        detectedPartnerRaw: String,
        overridePartnerRaw: String? = nil,
        originalZipURL: URL? = nil,
        attachmentEntries: [AttachmentCanonicalEntry]? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        let sidecarDebugEnabled = ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1"

        struct SidecarMediaCounts {
            var images: Int = 0
            var videos: Int = 0
            var audios: Int = 0
            var documents: Int = 0
        }

        let baseFolderURL = outDir.appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: baseFolderURL.path) {
            throw OutputCollisionError(url: baseFolderURL)
        }
        try fm.createDirectory(at: baseFolderURL, withIntermediateDirectories: true)
        if sidecarDebugEnabled {
            print("DEBUG: SIDE: created sidecar base dir: \(baseFolderURL.path)")
        }

        let sentinelURL = baseFolderURL.appendingPathComponent("media-index.json")
        func writeSidecarSentinel(_ counts: SidecarMediaCounts) throws {
            let json = """
            {
              "schemaVersion": 1,
              "mediaCounts": {
                "images": \(counts.images),
                "videos": \(counts.videos),
                "audios": \(counts.audios),
                "documents": \(counts.documents)
              }
            }
            """
            try json.write(to: sentinelURL, atomically: true, encoding: .utf8)
        }

        var mediaCounts = SidecarMediaCounts()
        try writeSidecarSentinel(mediaCounts)

        // Additionally copy the original WhatsApp export folder (the folder that contains chat.txt)
        // into the sorted attachments folder, preserving the original folder name.
        // Example: <out>/<folderName>/<OriginalExportFolderName>/chat.txt
        let sourceDir = chatURL.deletingLastPathComponent().standardizedFileURL
        let originalNameBefore: String
        if let originalZipURL {
            originalNameBefore = originalZipURL.deletingPathExtension().lastPathComponent
        } else {
            originalNameBefore = sourceDir.lastPathComponent
        }
        let originalFolderName = applyPartnerOverrideToName(
            originalName: originalNameBefore,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw
        )
        let originalCopyDir = baseFolderURL.appendingPathComponent(originalFolderName, isDirectory: true)
        if fm.fileExists(atPath: originalCopyDir.path) {
            throw OutputCollisionError(url: originalCopyDir)
        }
        try fm.createDirectory(at: originalCopyDir, withIntermediateDirectories: true)

        // Copy recursively, but avoid recursion if the chosen output directory is inside the source directory.
        // (e.g. user selects the same folder or a subfolder as output)
        let outDirPath = outDir.standardizedFileURL.path
        let baseFolderPath = baseFolderURL.standardizedFileURL.path
        var skipPrefixes = [outDirPath, baseFolderPath]
        if outDir.lastPathComponent.hasPrefix(".wa_export_tmp_") {
            let parent = outDir.deletingLastPathComponent().standardizedFileURL.path
            skipPrefixes.append(parent)
        }
        try copyDirectoryPreservingStructure(
            from: sourceDir,
            to: originalCopyDir,
            skippingPathPrefixes: skipPrefixes
        )
        
        try copySiblingZipIfPresent(
            sourceDir: sourceDir,
            destParentDir: baseFolderURL,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw,
            originalZipURL: originalZipURL
        )

        let imagesDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.images.rawValue, isDirectory: true)
        let videosDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.videos.rawValue, isDirectory: true)
        let audiosDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.audios.rawValue, isDirectory: true)
        let docsDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.documents.rawValue, isDirectory: true)

        let chatSourceDir = chatURL.deletingLastPathComponent()
        let entries = attachmentEntries ?? buildAttachmentCanonicalEntries(
            messages: messages,
            chatSourceDir: chatSourceDir
        )

        // If there are no attachments, keep the bucket folders absent.
        if entries.isEmpty { return originalCopyDir }

        var bucketsWithContent = Set<SortedAttachmentBucket>()

        struct SidecarAttachmentJob {
            let src: URL
            let dst: URL
            let bucket: SortedAttachmentBucket
        }

        var jobs: [SidecarAttachmentJob] = []
        jobs.reserveCapacity(entries.count)
        var dstSeen = Set<String>()

        for entry in entries {
            try Task.checkCancellation()
            let src = entry.sourceURL
            let bucket = entry.bucket
            let dstFolder: URL = {
                switch bucket {
                case .images: return imagesDir
                case .videos: return videosDir
                case .audios: return audiosDir
                case .documents: return docsDir
                }
            }()
            let dst = dstFolder.appendingPathComponent(entry.destName)
            if !dstSeen.insert(dst.path).inserted {
                throw OutputCollisionError(url: dst)
            }

            jobs.append(SidecarAttachmentJob(src: src, dst: dst, bucket: bucket))
        }

        let bucketsToCreate = Set(jobs.map(\.bucket))
        for bucket in bucketsToCreate {
            let dstFolder: URL = {
                switch bucket {
                case .images: return imagesDir
                case .videos: return videosDir
                case .audios: return audiosDir
                case .documents: return docsDir
                }
            }()
            try fm.createDirectory(at: dstFolder, withIntermediateDirectories: true)
        }

        let caps = wetConcurrencyCaps
        if sidecarDebugEnabled {
            print("WET-DBG: CONCURRENCY: sidecar attachments cap=\(caps.io) jobs=\(jobs.count)")
        }
        let limiter = AsyncLimiter(caps.io)
        var results = Array<SortedAttachmentBucket?>(repeating: nil, count: jobs.count)

        try await withThrowingTaskGroup(of: (Int, SortedAttachmentBucket?).self) { group in
            for (idx, job) in jobs.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return try await limiter.withPermit {
                        try Task.checkCancellation()
                        let fm = FileManager.default
                        if fm.fileExists(atPath: job.dst.path) {
                            throw OutputCollisionError(url: job.dst)
                        }
                        do {
                            try fm.copyItem(at: job.src, to: job.dst)
                            syncFileSystemTimestamps(from: job.src, to: job.dst)
                            return (idx, job.bucket)
                        } catch {
                            return (idx, nil)
                        }
                    }
                }
            }

            for try await (idx, bucket) in group {
                results[idx] = bucket
            }
        }

        for bucket in results.compactMap({ $0 }) {
            bucketsWithContent.insert(bucket)
            switch bucket {
            case .images:
                mediaCounts.images += 1
            case .videos:
                mediaCounts.videos += 1
            case .audios:
                mediaCounts.audios += 1
            case .documents:
                mediaCounts.documents += 1
            }
        }

        let bucketDirs: [SortedAttachmentBucket: URL] = [
            .images: imagesDir,
            .videos: videosDir,
            .audios: audiosDir,
            .documents: docsDir
        ]
        for bucket in bucketsToCreate where !bucketsWithContent.contains(bucket) {
            if let dir = bucketDirs[bucket], isDirectoryEmptyRecursive(dir) {
                if sidecarDebugEnabled {
                    print("WET-DBG: removeItem: \(dir.path)")
                }
                try? fm.removeItem(at: dir)
            }
        }

        try writeSidecarSentinel(mediaCounts)

        if isDirectoryEmptyFirstLevel(baseFolderURL) {
            if sidecarDebugEnabled {
                print("DEBUG: SIDE: base dir empty after staging; re-seeding sentinel/original copy")
            }
            if !fm.fileExists(atPath: baseFolderURL.path) {
                try fm.createDirectory(at: baseFolderURL, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: sentinelURL.path) {
                try writeSidecarSentinel(mediaCounts)
            }
            if !fm.fileExists(atPath: originalCopyDir.path) {
                try fm.createDirectory(at: originalCopyDir, withIntermediateDirectories: true)
            }
        }

        let thumbsDir = baseFolderURL.appendingPathComponent("_thumbs", isDirectory: true)
        if fm.fileExists(atPath: thumbsDir.path), isDirectoryEmptyRecursive(thumbsDir) {
            if sidecarDebugEnabled {
                print("WET-DBG: removeItem: \(thumbsDir.path)")
            }
            try? fm.removeItem(at: thumbsDir)
        }

        return originalCopyDir
    }

    nonisolated private static func stripAttachmentMarkers(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let stripped = attachRe.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// For text-only exports, keep chat bubbles non-empty when the original message only contained attachments.
    /// Returns a human-readable placeholder containing the original filenames (as referenced in the WhatsApp export).
    nonisolated private static func attachmentPlaceholderText(forAttachments fns: [String]) -> String {
        guard !fns.isEmpty else { return "" }

        func kindLabel(for fn: String) -> String {
            let ext = (fn as NSString).pathExtension.lowercased()
            if ["jpg","jpeg","png","gif","webp","heic","heif","tiff","tif","bmp"].contains(ext) { return "Bild" }
            if ["mp4","mov","m4v","mkv","webm","avi","3gp"].contains(ext) { return "Video" }
            if ["m4a","mp3","wav","aac","caf","ogg","opus","flac","amr","aiff","aif"].contains(ext) { return "Audio" }
            return "Dokument"
        }

        var lines: [String] = []
        lines.reserveCapacity(fns.count)

        for fn in fns {
            let ext = (fn as NSString).pathExtension
            let emoji = attachmentEmoji(forExtension: ext)
            lines.append("\(emoji) \(kindLabel(for: fn)): \(fn)")
        }

        return lines.joined(separator: "\n")
    }

    private actor AsyncLimiter {
        private var available: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(_ maxConcurrent: Int) {
            self.available = max(1, maxConcurrent)
        }

        func acquire() async {
            if available > 0 {
                available -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                available += 1
            } else {
                let next = waiters.removeFirst()
                next.resume()
            }
        }

        func withPermit<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
            await acquire()
            defer { release() }
            return try await work()
        }
    }

    nonisolated private static var wetConcurrencyCaps: (cpu: Int, io: Int) {
        let env = ProcessInfo.processInfo.environment
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let cpuDefault = max(2, cores)
        let ioDefault = min(max(2, cores), 8)
        let cpuOverride = env["WET_MAX_CPU"].flatMap { Int($0) }
        let ioOverride = env["WET_MAX_IO"].flatMap { Int($0) }
        let cpu = max(1, cpuOverride ?? cpuDefault)
        let io = max(1, ioOverride ?? ioDefault)
        return (cpu: cpu, io: io)
    }

    nonisolated static func concurrencyCaps() -> (cpu: Int, io: Int) {
        wetConcurrencyCaps
    }

    nonisolated private static func guessMime(fromName name: String) -> String {
        let n = name.lowercased()
        if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") { return "image/jpeg" }
        if n.hasSuffix(".png") { return "image/png" }
        if n.hasSuffix(".gif") { return "image/gif" }
        if n.hasSuffix(".webp") { return "image/webp" }
        if n.hasSuffix(".heic") { return "image/heic" }
        if n.hasSuffix(".heif") { return "image/heif" }

        // Video
        if n.hasSuffix(".mp4") { return "video/mp4" }
        if n.hasSuffix(".m4v") { return "video/x-m4v" }
        if n.hasSuffix(".mov") { return "video/quicktime" }

        // Audio
        if n.hasSuffix(".mp3") { return "audio/mpeg" }
        if n.hasSuffix(".m4a") { return "audio/mp4" }
        if n.hasSuffix(".aac") { return "audio/aac" }
        if n.hasSuffix(".wav") { return "audio/wav" }
        if n.hasSuffix(".ogg") { return "audio/ogg" }
        if n.hasSuffix(".opus") { return "audio/ogg" }   // Opus is typically in OGG container
        if n.hasSuffix(".flac") { return "audio/flac" }
        if n.hasSuffix(".caf") { return "audio/x-caf" }
        if n.hasSuffix(".aiff") || n.hasSuffix(".aif") { return "audio/aiff" }
        if n.hasSuffix(".amr") { return "audio/amr" }

        // Documents
        if n.hasSuffix(".pdf") { return "application/pdf" }
        if n.hasSuffix(".doc") { return "application/msword" }
        if n.hasSuffix(".docx") { return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }

        return "application/octet-stream"
    }

    nonisolated private static func fileToDataURL(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = guessMime(fromName: url.lastPathComponent)
        let b64 = data.base64EncodedString()
        return "data:\(mime);base64,\(b64)"
    }

    nonisolated private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    nonisolated private static func urlPathEscapeComponent(_ s: String) -> String {
        // Encode a single path component for safe use in href/src.
        // Keep it conservative to work well across Safari/Chrome/Edge.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    nonisolated private static func escapeRelPath(_ rel: String) -> String {
        // Escape each component individually so slashes stay as separators.
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.map { urlPathEscapeComponent($0) }.joined(separator: "/")
    }

    nonisolated private static func relativeHref(for file: URL, relativeTo baseDir: URL?) -> String {
        let src = file.standardizedFileURL
        guard let basePath = baseDir?.standardizedFileURL.path, !basePath.isEmpty else {
            return src.absoluteURL.absoluteString
        }

        let prefix = basePath.hasSuffix("/") ? basePath : (basePath + "/")
        if src.path.hasPrefix(prefix) {
            let rel = String(src.path.dropFirst(prefix.count))
            return escapeRelPath(rel)
        }

        return src.absoluteURL.absoluteString
    }

    nonisolated private static func decodeDataURL(_ s: String) -> (data: Data, mime: String)? {
        guard s.hasPrefix("data:") else { return nil }
        guard let comma = s.firstIndex(of: ",") else { return nil }

        let meta = String(s[s.index(s.startIndex, offsetBy: 5)..<comma])
        let dataPart = String(s[s.index(after: comma)...])

        let metaParts = meta.split(separator: ";")
        let mime = metaParts.first.map(String.init) ?? "application/octet-stream"
        let isBase64 = metaParts.contains { String($0).lowercased() == "base64" }
        guard isBase64, let data = Data(base64Encoded: dataPart) else { return nil }

        return (data: data, mime: mime)
    }

    nonisolated private static func fileExtension(forMime mime: String) -> String {
        let m = mime.lowercased()
        if m.contains("png") { return "png" }
        if m.contains("jpeg") || m.contains("jpg") { return "jpg" }
        if m.contains("gif") { return "gif" }
        if m.contains("webp") { return "webp" }
        if m.contains("heic") { return "heic" }
        return "bin"
    }

    nonisolated private static func fnv1a64Hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in data {
            hash ^= UInt64(b)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    nonisolated private static func stagePreviewImageDataURL(
        _ dataURL: String,
        previewsDir: URL,
        relativeTo baseDir: URL?
    ) -> String? {
        guard let decoded = decodeDataURL(dataURL) else { return nil }

        let ext = fileExtension(forMime: decoded.mime)
        let hash = fnv1a64Hex(decoded.data)
        let dest = previewsDir.appendingPathComponent("preview_\(hash)").appendingPathExtension(ext)

        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) {
            var lastError: Error?
            for attempt in 0..<2 {
                do {
                    try writeExclusiveData(decoded.data, to: dest)
                    if previewDebugEnabled() {
                        previewDebugLog("stage preview hash=\(hash) bytes=\(decoded.data.count) dest=\(dest.lastPathComponent)")
                    } else if ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1" {
                        print("WET-DBG: stage preview -> \(dest.path)")
                    }
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if previewDebugEnabled() {
                        previewDebugLog("stage preview retry=\(attempt + 1) hash=\(hash) error=\(error.localizedDescription)")
                    }
                }
            }
            if let lastError {
                if previewDebugEnabled() {
                    previewDebugLog("stage preview failed hash=\(hash) error=\(lastError.localizedDescription)")
                }
                return nil
            }
        }

        return relativeHref(for: dest, relativeTo: baseDir)
    }

    nonisolated private static func writeExclusiveData(_ data: Data, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            return
        }
        try ensureDirectory(dest.deletingLastPathComponent())
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent(".wa_tmp_\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)
            if fm.fileExists(atPath: dest.path) {
                return
            }
            throw error
        }
    }

    /// Returns an href for an attachment without staging/copying it into an extra output folder.
    ///
    /// - If `relativeTo` is provided and `source` is located under that directory, the returned href is a
    ///   relative path (URL-escaped per path component) so the exported HTML can reference media inside
    ///   a sidecar folder without creating a sibling `attachments/` folder.
    /// - Otherwise, the returned href is a `file://` URL string to the original file.
    nonisolated private static func stageAttachmentForExport(
        source: URL,
        attachmentsDir _: URL,
        relativeTo baseDir: URL? = nil
    ) -> (relHref: String, stagedURL: URL)? {
        let fm = FileManager.default
        let src = source.standardizedFileURL
        guard fm.fileExists(atPath: src.path) else { return nil }

        let basePath = baseDir?.standardizedFileURL.path
        let cacheKey = src.path + "||" + (basePath ?? "")

        // Dedupe: if we already produced an href for this (source, base) pair, reuse it.
        stagedAttachmentLock.lock()
        if let cached = stagedAttachmentMap[cacheKey] {
            stagedAttachmentLock.unlock()
            return (relHref: cached.relHref, stagedURL: cached.stagedURL)
        }

        let href = relativeHref(for: src, relativeTo: baseDir)

        stagedAttachmentMap[cacheKey] = (relHref: href, stagedURL: src)
        stagedAttachmentLock.unlock()

        return (relHref: href, stagedURL: src)
    }


    // ---------------------------
    // Attachment previews (ImageIO/AVFoundation/PDFKit; no Quick Look)
    // ---------------------------

    nonisolated private static func thumbnailPNGDataURL(
        for fileURL: URL,
        maxPixel: CGFloat = thumbMaxPixel
    ) async -> String? {
        let src = fileURL.standardizedFileURL
        let key = thumbnailCacheKey(for: src, maxPixel: maxPixel)
        if let cached = thumbnailPNGCacheGet(key) {
            recordThumbPNG(duration: 0, cacheHit: true)
            return cached
        }

        let start = ProcessInfo.processInfo.systemUptime
        let data = await thumbnailImageData(for: src, maxPixel: maxPixel, format: .png)
        let dataURL = data.map { "data:image/png;base64,\($0.base64EncodedString())" }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        recordThumbPNG(duration: elapsed, cacheHit: false)
        if let dataURL {
            thumbnailPNGCacheSet(key, dataURL)
        }
        return dataURL
    }

    nonisolated private static func thumbnailJPEGData(
        for fileURL: URL,
        maxPixel: CGFloat = thumbMaxPixel,
        quality: CGFloat = thumbJPEGQuality
    ) async -> Data? {
        let src = fileURL.standardizedFileURL
        let key = thumbnailCacheKey(for: src, maxPixel: maxPixel, quality: quality)
        if let cached = thumbnailJPEGCacheGet(key) {
            recordThumbJPEG(duration: 0, cacheHit: true)
            return cached
        }

        let start = ProcessInfo.processInfo.systemUptime
        let data = await thumbnailImageData(for: src, maxPixel: maxPixel, format: .jpeg(quality))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        recordThumbJPEG(duration: elapsed, cacheHit: false)
        if let data {
            thumbnailJPEGCacheSet(key, data)
        }
        return data
    }

    private enum ThumbnailFormat {
        case png
        case jpeg(CGFloat)
    }

    nonisolated private static func thumbnailImageData(
        for fileURL: URL,
        maxPixel: CGFloat,
        format: ThumbnailFormat
    ) async -> Data? {
        guard let cg = await thumbnailCGImage(for: fileURL, maxPixel: maxPixel) else { return nil }
        switch format {
        case .png:
            return encodeThumbnail(cg, type: .png, quality: nil)
        case .jpeg(let quality):
            return encodeThumbnail(cg, type: .jpeg, quality: quality)
        }
    }

    nonisolated private static func thumbnailCGImage(
        for fileURL: URL,
        maxPixel: CGFloat
    ) async -> CGImage? {
        let ext = fileURL.pathExtension.lowercased()
        if ["jpg","jpeg","png","gif","webp","heic","heif","tif","tiff","bmp"].contains(ext) {
            return imageIOThumbnailCGImage(fileURL, maxPixel: maxPixel)
        }
        if ["mp4","mov","m4v"].contains(ext) {
            return await videoThumbnailCGImage(fileURL, maxPixel: maxPixel)
        }
        if ext == "pdf" {
            return await pdfThumbnailCGImage(fileURL, maxPixel: maxPixel)
        }
        if ["doc","docx"].contains(ext) {
            // Policy: no thumbnails for DOC/DOCX (avoid Quick Look bottleneck).
            return nil
        }
        return nil
    }

    nonisolated private static func imageIOThumbnailCGImage(
        _ fileURL: URL,
        maxPixel: CGFloat
    ) -> CGImage? {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        #else
        return nil
        #endif
    }

    nonisolated private static func videoThumbnailCGImage(
        _ fileURL: URL,
        maxPixel: CGFloat
    ) async -> CGImage? {
        #if canImport(AVFoundation)
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let time = CMTime(seconds: 0.0, preferredTimescale: 600)
            generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                cont.resume(returning: image)
            }
        }
        #else
        return nil
        #endif
    }

    nonisolated private static func pdfThumbnailCGImage(
        _ fileURL: URL,
        maxPixel: CGFloat
    ) async -> CGImage? {
        #if canImport(PDFKit)
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let doc = PDFDocument(url: fileURL),
                      let page = doc.page(at: 0) else {
                    cont.resume(returning: nil)
                    return
                }
                let bounds = page.bounds(for: .cropBox)
                let scale = maxPixel / max(bounds.width, bounds.height)
                let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                #if canImport(AppKit)
                let image = page.thumbnail(of: target, for: .cropBox)
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                cont.resume(returning: cg)
                #else
                cont.resume(returning: nil)
                #endif
            }
        }
        #else
        return nil
        #endif
    }

    nonisolated private static func encodeThumbnail(
        _ cg: CGImage,
        type: UTType,
        quality: CGFloat?
    ) -> Data? {
        #if canImport(ImageIO)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
        #else
        return nil
        #endif
    }

nonisolated private static func stageThumbnailForExport(
    source: URL,
    thumbsDir: URL,
    relativeTo baseDir: URL?
) async -> String? {
    let fm = FileManager.default
    let src = source.standardizedFileURL
    guard fm.fileExists(atPath: src.path) else { return nil }

    do {
        // Prefer a .jpg thumbnail to keep size down.
        // IMPORTANT: Use a deterministic destination name so repeated runs reuse the same file
        // instead of creating endless "(2)", "(3)", ... duplicates.
        let fileName = thumbnailCacheFilename(for: src, maxPixel: thumbMaxPixel, quality: thumbJPEGQuality)
        let dest = thumbsDir.appendingPathComponent(fileName)

        // If a thumbnail already exists, reuse it.
        if fm.fileExists(atPath: dest.path) {
            return relativeHref(for: dest, relativeTo: baseDir)
        }

    if let jpg = await thumbnailJPEGData(for: src, maxPixel: thumbMaxPixel, quality: thumbJPEGQuality) {
            try writeExclusiveData(jpg, to: dest)
            if ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1" {
                print("WET-DBG: stage thumb -> \(dest.path)")
            }
            return relativeHref(for: dest, relativeTo: baseDir)
        }

        // No thumbnail available.
        return nil
    } catch {
        return nil
    }
}

    nonisolated private static func inlineThumbnailDataURL(_ url: URL) async -> String? {
        let src = url.standardizedFileURL
        let key = src.path
        if let cached = inlineThumbCacheGet(key) {
            recordInlineThumb(duration: 0, cacheHit: true)
            return cached
        }

        let start = ProcessInfo.processInfo.systemUptime
        var dataURL: String? = nil

        if let jpg = await thumbnailJPEGData(for: src, maxPixel: thumbMaxPixel, quality: thumbJPEGQuality) {
            dataURL = "data:image/jpeg;base64,\(jpg.base64EncodedString())"
        }

        if dataURL == nil {
            dataURL = await attachmentThumbnailDataURL(src)
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - start
        recordInlineThumb(duration: elapsed, cacheHit: false)

        if let dataURL {
            inlineThumbCacheSet(key, dataURL)
        }

        return dataURL
    }

    nonisolated private static func attachmentPreviewDataURL(_ url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()

        // True images: embed as-is.
        if ["jpg","jpeg","png","gif","webp","heic","heif"].contains(ext) {
            return fileToDataURL(url)
        }

        // PDF/Video: generate a thumbnail via local renderers (no Quick Look).
        if ["pdf","mp4","mov","m4v"].contains(ext) {
            if let jpg = await thumbnailJPEGData(for: url, maxPixel: thumbMaxPixel, quality: thumbJPEGQuality) {
                return "data:image/jpeg;base64,\(jpg.base64EncodedString())"
            }
            return nil
        }

        // DOC/DOCX: explicit policy = no thumbnail.
        if ["doc","docx"].contains(ext) {
            return nil
        }

        return nil
    }

    nonisolated private static func attachmentThumbnailDataURL(_ url: URL) async -> String? {
        // Goal: always produce a lightweight thumbnail image (JPEG) when possible.
        // - Images/Video/PDF: local thumbnail generation (no Quick Look).
        // - DOC/DOCX: no thumbnails.
        // Fallback: for images only, embed the original if thumbnailing is unavailable.
        let ext = url.pathExtension.lowercased()

        if let jpg = await thumbnailJPEGData(for: url, maxPixel: thumbMaxPixel, quality: thumbJPEGQuality) {
            return "data:image/jpeg;base64,\(jpg.base64EncodedString())"
        }

        // Fallback: if we cannot thumbnail, only allow direct image embedding.
        if ["jpg","jpeg","png","gif","webp","heic","heif"].contains(ext) {
            return fileToDataURL(url)
        }

        return nil
    }

    nonisolated private static func attachmentEmoji(forExtension ext: String) -> String {
        let e = ext.lowercased()
        if ["mp4","mov","m4v"].contains(e) { return "🎬" }
        if ["mp3","m4a","aac","wav","ogg","opus","flac","caf","aiff","aif","amr"].contains(e) { return "🎧" }
        if ["jpg","jpeg","png","gif","webp","heic","heif"].contains(e) { return "🖼️" }
        return "📎"
    }

    // ---------------------------
    // Link previews: Google Maps helpers
    // ---------------------------

    nonisolated private static func isGoogleMapsCoordinateURL(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        if !host.contains("google.") { return false }
        if !u.path.lowercased().contains("/maps") { return false }
        return googleMapsLatLon(u) != nil
    }

    nonisolated private static func googleMapsLatLon(_ u: URL) -> (Double, Double)? {
        guard let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []

        // Common patterns:
        //  - /maps/search/?api=1&query=52.508450,13.372972
        //  - ...?q=52.508450,13.372972
        //  - ...?ll=52.508450,13.372972
        let keys = ["query", "q", "ll"]
        guard let raw = items.first(where: { keys.contains($0.name.lowercased()) })?.value else { return nil }

        let parts = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2 else { return nil }

        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.decimalSeparator = "."

        guard let latN = f.number(from: parts[0])?.doubleValue,
              let lonN = f.number(from: parts[1])?.doubleValue else { return nil }

        return (latN, lonN)
    }

    nonisolated private static func googleMapsCoordinateTitle(lat: Double, lon: Double) -> String {
        func dmsEntity(_ v: Double, pos: String, neg: String) -> String {
            let hemi = (v >= 0) ? pos : neg
            let a = abs(v)

            var deg = Int(floor(a))
            let minutesFull = (a - Double(deg)) * 60.0
            var min = Int(floor(minutesFull))
            var sec = (minutesFull - Double(min)) * 60.0

            sec = (sec * 10.0).rounded() / 10.0
            if sec >= 60.0 {
                sec -= 60.0
                min += 1
            }
            if min >= 60 {
                min -= 60
                deg += 1
            }

            // Return literal characters; htmlEscape() handles escaping consistently.
            let secStr = String(format: "%.1f", sec)
            return "\(deg)°\(min)'\(secStr)\"\(hemi)"
        }

        let latStr = dmsEntity(lat, pos: "N", neg: "S")
        let lonStr = dmsEntity(lon, pos: "E", neg: "W")
        return "\(latStr) \(lonStr)"
    }

    // ---------------------------
    // Link previews (native, LinkPresentation)
    // ---------------------------

    #if canImport(LinkPresentation)

    #if canImport(UIKit)
    private typealias WAPlatformImage = UIImage
    #elseif canImport(AppKit)
    private typealias WAPlatformImage = NSImage
    #endif

    private static func platformImageToPNGData(_ img: WAPlatformImage) -> Data? {
        #if canImport(UIKit)
        return img.pngData()
        #elseif canImport(AppKit)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    private static func loadPlatformImage(from provider: NSItemProvider) async throws -> WAPlatformImage {
        try await withCheckedThrowingContinuation { cont in
            #if canImport(UIKit)
            provider.loadObject(ofClass: UIImage.self) { obj, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                if let img = obj as? UIImage {
                    cont.resume(returning: img)
                    return
                }
                cont.resume(throwing: URLError(.cannotDecodeContentData))
            }
            #elseif canImport(AppKit)
            provider.loadObject(ofClass: NSImage.self) { obj, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                if let img = obj as? NSImage {
                    cont.resume(returning: img)
                    return
                }
                cont.resume(throwing: URLError(.cannotDecodeContentData))
            }
            #else
            cont.resume(throwing: URLError(.cannotDecodeContentData))
            #endif
        }
    }

    // Swift 6 (strict concurrency): LinkPresentation types are not Sendable.
    // Design: keep LinkPresentation objects inside a boxed class and ensure single completion via locking.
    // We start/cancel the provider on the main thread, but we complete the async continuation directly
    // from the provider callback (no MainActor annotations on the callback, avoiding Swift 6 actor loss errors).

    private final class WALPFetchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<LPLinkMetadata, Error>?
        private var provider: LPMetadataProvider?
        private var timeoutTask: Task<Void, Never>?

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func start(
            url: URL,
            timeoutSeconds: Double,
            continuation: CheckedContinuation<LPLinkMetadata, Error>
        ) {
            withLock {
                self.continuation = continuation
            }

            // Timeout via Task.sleep. If it fires, cancel the provider and finish with a timeout.
            let nanos = UInt64(max(0.0, timeoutSeconds) * 1_000_000_000)
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return // cancelled
                }
                self.cancelProviderOnMain()
                self.finish(.failure(URLError(.timedOut)))
            }

            // Create + start the provider on the MainActor (LPMetadataProvider is MainActor-isolated under Swift 6).
            Task { @MainActor [weak self] in
                guard let self else { return }

                let provider = LPMetadataProvider()
                self.withLock {
                    self.provider = provider
                }

                do {
                    // Use the async API to avoid Swift 6 concurrency diagnostics for the completion-handler variant.
                    let meta = try await provider.startFetchingMetadata(for: url)
                    self.finish(.success(meta))
                } catch {
                    self.finish(.failure(error))
                }
            }
        }

        func cancel() {
            cancelProviderOnMain()
            finish(.failure(CancellationError()))
        }

        private func cancelProviderOnMain() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let p: LPMetadataProvider? = self.withLock { self.provider }
                p?.cancel()
            }
        }

        private func finish(_ result: Result<LPLinkMetadata, Error>) {
            let cont: CheckedContinuation<LPLinkMetadata, Error>?

            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true

            timeoutTask?.cancel()
            timeoutTask = nil
            provider = nil

            cont = continuation
            continuation = nil
            lock.unlock()

            guard let cont else { return }
            switch result {
            case .success(let v):
                cont.resume(returning: v)
            case .failure(let e):
                cont.resume(throwing: e)
            }
        }
    }

    private static func fetchLPMetadata(_ url: URL, timeoutSeconds: Double = 10) async throws -> LPLinkMetadata {
        let box = WALPFetchBox()

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LPLinkMetadata, Error>) in
                    box.start(url: url, timeoutSeconds: timeoutSeconds, continuation: cont)
                }
            },
            onCancel: {
                // LPMetadataProvider.cancel() is MainActor-isolated under Swift 6; dispatch cancellation onto MainActor.
                Task { @MainActor in
                    box.cancel()
                }
            }
        )
    }

    private static func loadDataRepresentation(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                guard let data else {
                    cont.resume(throwing: URLError(.cannotDecodeContentData))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    private static func loadBestImageData(from provider: NSItemProvider) async throws -> (data: Data, mime: String) {
        #if canImport(UniformTypeIdentifiers)
        let candidates: [(String, String)] = [
            (UTType.png.identifier, "image/png"),
            (UTType.jpeg.identifier, "image/jpeg"),
            (UTType.image.identifier, "image/png")
        ]
        for (uti, mime) in candidates {
            if provider.hasItemConformingToTypeIdentifier(uti) {
                let data = try await loadDataRepresentation(from: provider, typeIdentifier: uti)
                return (data, mime)
            }
        }
        #endif

        // Fallback: load as platform image and re-encode PNG
        let img = try await loadPlatformImage(from: provider)
        if let png = platformImageToPNGData(img) {
            return (png, "image/png")
        }
        throw URLError(.cannotDecodeContentData)
    }

    /// Attempts to build a rich preview using macOS LinkPresentation (often yields a real preview image).
    nonisolated private static func buildPreviewViaLinkPresentation(_ urlString: String) async -> WAPreview? {
        guard let u = URL(string: urlString) else { return nil }
        do {
            let meta = try await fetchLPMetadata(u)

            let title = (meta.title ?? urlString).trimmingCharacters(in: .whitespacesAndNewlines)

            // LinkPresentation does not reliably provide a description. Keep it empty to avoid unstable output.
            let desc = ""

            var imageDataURL: String? = nil

            // Prefer the rich preview image; fall back to site/app icon.
            let providers = [meta.imageProvider, meta.iconProvider].compactMap { $0 }
            for p in providers {
                if let (data, mime) = try? await loadBestImageData(from: p) {
                    imageDataURL = "data:\(mime);base64,\(data.base64EncodedString())"
                    break
                }
            }

            return WAPreview(url: urlString, title: title, description: desc, imageDataURL: imageDataURL)
        } catch {
            return nil
        }
    }

#endif

    // ---------------------------
    // Link previews (online)
    // ---------------------------

    nonisolated private static func httpGet(_ url: String, timeout: TimeInterval = 15) async throws -> (Data, String) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (WhatsAppExportTools/1.0)", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)

        // Treat non-2xx responses as errors to keep preview behavior predictable.
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        return (data, ct)
    }

    nonisolated private static func resolveURL(base: String, maybe: String) -> String {
        // Resolve relative URLs against the base page.
        guard let b = URL(string: base) else { return maybe }
        return URL(string: maybe, relativeTo: b)?.absoluteURL.absoluteString ?? maybe
    }

    nonisolated private static func parseMeta(_ htmlBytes: Data) -> [String: String] {
        // Limit HTML parsing to a bounded prefix for performance/stability.
        let limited = htmlBytes.prefix(800_000)
        let s = String(data: limited, encoding: .utf8) ?? String(decoding: limited, as: UTF8.self)

        var out: [String: String] = [:]

        let ns = s as NSString
        let metaMatches = metaTagRe.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        for m in metaMatches {
            let tag = ns.substring(with: m.range)
            let tagNS = tag as NSString
            let attrMatches = metaAttrRe.matches(in: tag, options: [], range: NSRange(location: 0, length: tagNS.length))
            var attrs: [String: String] = [:]
            for am in attrMatches {
                let k = tagNS.substring(with: am.range(at: 1)).lowercased()
                var v = tagNS.substring(with: am.range(at: 2))
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines)
                attrs[k] = v
            }
            let prop = (attrs["property"] ?? "").lowercased()
            let name = (attrs["name"] ?? "").lowercased()
            let content = attrs["content"] ?? ""
            let key = prop.isEmpty ? name : prop
            if !key.isEmpty && !content.isEmpty {
                out[key] = content
            }
        }

        // title fallback
        if out["title"] == nil {
            if let tm = titleTagRe.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
                let rawTitle = ns.substring(with: tm.range(at: 1))
                out["title"] = htmlUnescape(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return out
    }

    private enum PreviewPolicy: String {
        case deterministic
        case full
    }

    nonisolated private static func previewPolicy() -> PreviewPolicy {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["WET_PREVIEW_POLICY"] ?? "deterministic").lowercased()
        if raw == "full" { return .full }
        return .deterministic
    }

    nonisolated private static func previewDebugEnabled() -> Bool {
        ProcessInfo.processInfo.environment["WET_PREVIEW_DEBUG"] == "1"
    }

    nonisolated private static func previewDebugLog(_ message: String) {
        guard previewDebugEnabled() else { return }
        print("WET-PREVIEW: \(message)")
    }

    nonisolated private static func normalizePreviewURLKey(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else {
            return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        comps.fragment = nil
        if let scheme = comps.scheme { comps.scheme = scheme.lowercased() }
        if let host = comps.host { comps.host = host.lowercased() }
        if comps.scheme == "http", comps.port == 80 { comps.port = nil }
        if comps.scheme == "https", comps.port == 443 { comps.port = nil }
        return comps.string ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func downloadImageAsDataURL(
        _ imgURL: String,
        timeout: TimeInterval = 15,
        maxBytes: Int = 2_500_000,
        policy: PreviewPolicy
    ) async -> String? {
        let attempts = policy == .deterministic ? 2 : 1
        for attempt in 0..<attempts {
            do {
                let (data, ct) = try await httpGet(imgURL, timeout: timeout)
                if data.count > maxBytes { return nil }

                var mime = ct.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
                if !mime.hasPrefix("image/") {
                    // guess from url path
                    let path = URL(string: imgURL)?.path ?? ""
                    mime = guessMime(fromName: path)
                    if !mime.hasPrefix("image/") { return nil }
                }

                if previewDebugEnabled() {
                    let hash = fnv1a64Hex(data)
                    previewDebugLog("image fetch ok url=\(imgURL) bytes=\(data.count) hash=\(hash)")
                }

                return "data:\(mime);base64,\(data.base64EncodedString())"
            } catch {
                if previewDebugEnabled() {
                    previewDebugLog("image fetch fail url=\(imgURL) attempt=\(attempt + 1)/\(attempts) error=\(error.localizedDescription)")
                }
                continue
            }
        }
        return nil
    }

    nonisolated private static func buildPreview(_ url: String) async -> WAPreview? {
        let urlKey = normalizePreviewURLKey(url)
        if let cached = await previewCache.get(urlKey) { return cached }
        let policy = previewPolicy()
        if previewDebugEnabled() {
            previewDebugLog("preview start url=\(urlKey) policy=\(policy.rawValue)")
        }

        // Google Maps: avoid consent/interstitial pages and keep output stable.
        // For coordinate links like .../maps/search/?api=1&query=52.508450,13.372972
        // Synthesize the title Google typically returns (title is HTML-escaped later).
        if let u = URL(string: url),
           isGoogleMapsCoordinateURL(u),
           let (lat, lon) = googleMapsLatLon(u) {

            let title = googleMapsCoordinateTitle(lat: lat, lon: lon)
            let prev = WAPreview(
                url: url,
                title: title,
                description: "Mit Google Maps lokale Anbieter suchen, Karten anzeigen und Routenpläne abrufen.",
                imageDataURL: nil
            )
            await previewCache.set(urlKey, prev)
            if previewDebugEnabled() {
                previewDebugLog("preview source=google_maps image=false")
            }
            return prev
        }

        // YouTube special
        if let vid = youtubeVideoID(from: url) {
            let thumb = "https://img.youtube.com/vi/\(vid)/hqdefault.jpg"
            let imgData = await downloadImageAsDataURL(thumb, policy: policy)
            let prev = WAPreview(url: url, title: "YouTube", description: "", imageDataURL: imgData)
            await previewCache.set(urlKey, prev)
            if previewDebugEnabled() {
                previewDebugLog("preview source=youtube image=\(imgData != nil)")
            }
            return prev
        }

        // Prefer native LinkPresentation when available (often provides a real preview image).
        #if canImport(LinkPresentation)
        if policy == .full {
            if let lp = await buildPreviewViaLinkPresentation(url) {
                await previewCache.set(urlKey, lp)
                if previewDebugEnabled() {
                    previewDebugLog("preview source=link_presentation image=\(lp.imageDataURL != nil)")
                }
                return lp
            }
        }
        #endif

        // Fallback: manual HTML meta parsing (og:title/og:image, etc.)
        do {
            let (htmlBytes, _) = try await httpGet(url)
            let meta = parseMeta(htmlBytes)
            let title = (meta["og:title"] ?? meta["title"] ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = (meta["og:description"] ?? meta["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let img = meta["og:image"] ?? meta["twitter:image"] ?? ""

            var imgDataURL: String? = nil
            if !img.isEmpty {
                let imgResolved = resolveURL(base: url, maybe: img)
                imgDataURL = await downloadImageAsDataURL(imgResolved, policy: policy)
            }

            let prev = WAPreview(url: url, title: title, description: desc, imageDataURL: imgDataURL)
            await previewCache.set(urlKey, prev)
            if previewDebugEnabled() {
                previewDebugLog("preview source=meta image=\(imgDataURL != nil)")
            }
            return prev
        } catch {
            if previewDebugEnabled() {
                previewDebugLog("preview source=meta failed error=\(error.localizedDescription)")
            }
            return nil
        }
    }

    // ---------------------------
    // Rendering helpers
    // ---------------------------

    nonisolated private static func weekdayIndexMonday0(_ date: Date) -> Int {
        let w = canonicalCalendar.component(.weekday, from: date) // Sunday=1 ... Saturday=7
        return (w + 5) % 7 // Monday=0 ... Sunday=6
    }

    nonisolated private static func fmtDateFull(_ date: Date) -> String {
        let c = canonicalCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }

    nonisolated private static func fmtTime(_ date: Date) -> String {
        let c = canonicalCalendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    nonisolated private static func htmlEscape(_ s: String) -> String {
        var x = s
        x = x.replacingOccurrences(of: "&", with: "&amp;")
        x = x.replacingOccurrences(of: "<", with: "&lt;")
        x = x.replacingOccurrences(of: ">", with: "&gt;")
        x = x.replacingOccurrences(of: "\"", with: "&quot;")
        x = x.replacingOccurrences(of: "'", with: "&#x27;")
        return x
    }

    nonisolated private static func htmlUnescape(_ s: String) -> String {
        // Minimal unescape used for <title> fallback
        var x = s
        x = x.replacingOccurrences(of: "&lt;", with: "<")
        x = x.replacingOccurrences(of: "&gt;", with: ">")
        x = x.replacingOccurrences(of: "&quot;", with: "\"")
        x = x.replacingOccurrences(of: "&#x27;", with: "'")
        x = x.replacingOccurrences(of: "&amp;", with: "&")
        return x
    }

    nonisolated private static func htmlEscapeKeepNewlines(_ s: String) -> String {
        // Convert newlines to <br> after escaping.
        let esc = htmlEscape(s)
        return esc.components(separatedBy: .newlines).joined(separator: "<br>")
    }

    // Escapes text as HTML and (optionally) turns http(s) URLs into clickable <a> links.
    // Keeps original newlines by converting them to <br> (same behavior as htmlEscapeKeepNewlines).
    nonisolated private static func htmlEscapeAndLinkifyKeepNewlines(_ s: String, linkify: Bool) -> String {
        let rstripSet = CharacterSet(charactersIn: ").,;:!?]}'\"")

        func splitURLTrailingPunct(_ raw: String) -> (core: String, trailing: String) {
            var core = raw
            var trailing = ""
            while let last = core.unicodeScalars.last, rstripSet.contains(last) {
                trailing.insert(Character(last), at: trailing.startIndex)
                core.removeLast()
            }
            return (core, trailing)
        }

        let lines = s.components(separatedBy: .newlines)
        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        for line in lines {
            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let protectedRanges: [NSRange] = {
                var ranges: [NSRange] = []
                for re in [markdownLinkRe, anchorTagRe] {
                    let matches = re.matches(in: line, options: [], range: fullRange)
                    for m in matches where m.range.length > 0 {
                        ranges.append(m.range)
                    }
                }
                return ranges
            }()

            let httpMatches = urlRe.matches(in: line, options: [], range: fullRange)
            let httpRanges: [NSRange] = httpMatches.compactMap { match in
                let r = match.range(at: 1)
                return (r.location == NSNotFound || r.length == 0) ? nil : r
            }

            func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
                for r in ranges where NSIntersectionRange(range, r).length > 0 {
                    return true
                }
                return false
            }

            enum LinkKind {
                case http
                case bare
            }

            struct LinkMatch {
                let range: NSRange
                let kind: LinkKind
            }

            var linkMatches: [LinkMatch] = []
            if linkify {
                for r in httpRanges where !intersects(r, protectedRanges) {
                    linkMatches.append(LinkMatch(range: r, kind: .http))
                }
            }

            let bareMatches = bareDomainRe.matches(in: line, options: [], range: fullRange)
            for match in bareMatches {
                let r = match.range(at: 1)
                if r.location == NSNotFound || r.length == 0 { continue }
                if intersects(r, protectedRanges) || intersects(r, httpRanges) { continue }
                let raw = ns.substring(with: r)
                let (core, _) = splitURLTrailingPunct(raw)
                if !core.isEmpty, isValidBareDomain(core) {
                    linkMatches.append(LinkMatch(range: r, kind: .bare))
                }
            }

            if linkMatches.isEmpty {
                outLines.append(htmlEscape(line))
                continue
            }

            linkMatches.sort { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length > rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

            var out = ""
            var cursor = 0

            for match in linkMatches {
                if match.range.location < cursor { continue }

                if match.range.location > cursor {
                    let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    out += htmlEscape(before)
                }

                let rawToken = ns.substring(with: match.range)
                let (core, trailing) = splitURLTrailingPunct(rawToken)

                if !core.isEmpty {
                    let hrefValue: String
                    switch match.kind {
                    case .http:
                        hrefValue = core
                    case .bare:
                        hrefValue = "https://" + core
                    }
                    let href = htmlEscape(hrefValue)
                    let shown = htmlEscape(core)
                    out += "<a href='\(href)' target='_blank' rel='noopener'>\(shown)</a>"
                } else {
                    out += htmlEscape(rawToken)
                }

                if !trailing.isEmpty {
                    out += htmlEscape(trailing)
                }

                cursor = match.range.location + match.range.length
            }

            if cursor < ns.length {
                let rest = ns.substring(from: cursor)
                out += htmlEscape(rest)
            }

            outLines.append(out)
        }

        return outLines.joined(separator: "<br>")
    }

    // Internal testing hook for deterministic linkify checks.
    nonisolated static func _linkifyHTMLForTesting(_ s: String, linkifyHTTP: Bool) -> String {
        htmlEscapeAndLinkifyKeepNewlines(s, linkify: linkifyHTTP)
    }

    nonisolated static func _previewTargetsForTesting(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return extractURLs(trimmed)
    }

    // ---------------------------
    // Render HTML (1:1 layout + CSS)
    // ---------------------------

    private struct BufferedFileWriter {
        private let handle: FileHandle
        private let flushThreshold: Int
        private var buffer = Data()
        private(set) var bytesWritten: Int = 0

        nonisolated init(url: URL, flushThresholdBytes: Int = 1_048_576) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
            fm.createFile(atPath: url.path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)
            self.flushThreshold = max(64 * 1024, flushThresholdBytes)
        }

        nonisolated mutating func append(_ string: String) throws {
            guard !string.isEmpty else { return }
            try append(Data(string.utf8))
        }

        nonisolated mutating func append(_ data: Data) throws {
            guard !data.isEmpty else { return }
            buffer.append(data)
            if buffer.count >= flushThreshold {
                try flush()
            }
        }

        nonisolated mutating func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            bytesWritten += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }

        nonisolated mutating func close() throws {
            try flush()
            try handle.close()
        }
    }

    nonisolated private static func renderHTML(
        msgs: [WAMessage],
        chatURL: URL,
        outHTML: URL,
        meName: String,
        enablePreviews: Bool,
        embedAttachments: Bool,
        embedAttachmentThumbnailsOnly: Bool,
        attachmentRelBaseDir: URL? = nil,
        disableThumbStaging: Bool = false,
        externalAttachments: Bool = false,
        externalPreviews: Bool = false,
        externalAssetsDir: URL? = nil,
        thumbnailStore: ThumbnailStore? = nil,
        perfLabel: String? = nil
    ) async throws {

        let renderStart = ProcessInfo.processInfo.systemUptime
        let perfEnabled = ProcessInfo.processInfo.environment["WET_PERF"] == "1"

        // participants -> title_names
        var authors: [String] = []
        for m in msgs {
            let a = _normSpace(m.author)
            if a.isEmpty { continue }
            if isSystemAuthor(a) { continue }
            if !authors.contains(a) { authors.append(a) }
        }
        let others = authors.filter { _normSpace($0).lowercased() != _normSpace(meName).lowercased() }
        let titleNames: String = {
            if others.count == 1 { return "\(meName) ↔ \(others[0])" }
            if others.count > 1 { return "\(meName) ↔ \(others.joined(separator: ", "))" }
            return "\(meName) ↔ Chat"
        }()

        // export time = transcript creation date (fallback: modification date)
        let exportCreatedAt = exportCreatedDate(chatURL: chatURL)
        let exportCreatedStr = exportCreatedAt.map { exportDTFormatter.string(from: $0) } ?? "(unknown)"

        // message count (exclude WhatsApp system messages)
        let messageCount: Int = msgs.reduce(0) { acc, m in
            let authorNorm = _normSpace(m.author)
            let textWoAttach = stripAttachmentMarkers(m.text)
            return acc + (isSystemMessage(authorRaw: authorNorm, text: textWoAttach) ? 0 : 1)
        }

        // CSS is intentionally kept stable to preserve HTML rendering.
        let css = #"""
        :root{
          --bg:#e5ddd5;
          --bubble-me:#DCF8C6;
          --bubble-other:#EAF7E0; /* a bit lighter green */
          --text:#111;
          --muted:#666;
          --shadow: 0 1px 0 rgba(0,0,0,.06);
          --media-max: 40vw; /* cap media (photos/videos/pdf/link previews) to ~40% viewport width */
        }
        html,body{height:100%;margin:0;padding:0;}
        body{
          font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
          background: var(--bg);
          color: var(--text);
          font-size: 18px;
          line-height: 1.35;
        }
        /* subtle pattern */
        body:before{
          content:"";
          position:fixed;inset:0;
          background:
            radial-gradient(circle at 10px 10px, rgba(255,255,255,.12) 2px, transparent 3px) 0 0/36px 36px,
            radial-gradient(circle at 28px 28px, rgba(0,0,0,.04) 2px, transparent 3px) 0 0/36px 36px;
          pointer-events:none;
          opacity:.8;
        }
        .wrap{max-width: 980px; margin: 0 auto; padding: 18px 12px 28px;}
        .header{
          background: rgba(255,255,255,.75);
          backdrop-filter: blur(6px);
          border-radius: 14px;
          padding: 14px 16px;
          box-shadow: var(--shadow);
          margin-bottom: 14px;
        }
        .h-title{font-weight:700; font-size: 24px; margin:0 0 6px;}
        .h-meta{margin:0; color: var(--muted); font-size: 15px; line-height:1.4;}
        .day{
          display:flex;
          justify-content:center;
          margin: 16px 0 10px;
        }
        .day > span{
          background: rgba(255,255,255,.65);
          color: #333;
          border-radius: 999px;
          padding: 6px 12px;
          font-size: 14px;
          box-shadow: var(--shadow);
        }
        .row{
          display:flex;
          margin: 10px 0;
          width:100%;
        }
        .row.me{justify-content:flex-end;}
        .row.other{justify-content:flex-start;}
        .row.system{justify-content:center;}
        .sys{
          display:flex;
          justify-content:center;
          margin: 10px 0;
        }
        .sys-line{
          background: rgba(0,0,0,.10);
          color: #333;
          border-radius: 999px;
          padding: 6px 10px;
          font-size: 12px;
          line-height: 1.25;
          text-align: center;
          max-width: 90%;
        }
        .bubble{
          max-width: 78%;
          min-width: 220px;
          padding: 10px 12px 8px;
          border-radius: 18px;
          box-shadow: var(--shadow);
          position:relative;
          overflow:hidden;
        }
        .bubble.system{
          background: rgba(0,0,0,.22);
          color: rgba(255,255,255,.95);
          font-size: 12px;
          line-height: 1.25;
          max-width: 90%;
          min-width: 0;
          padding: 8px 10px;
          text-align: center;
          box-shadow: none;
        }
        .bubble.has-media{
          /* Prevent media messages from shrinking to min-width; keep preview/media width consistent */
          width: min(78%, var(--media-max));
        }
        .bubble.me{background: var(--bubble-me);}
        .bubble.other{background: var(--bubble-other);}
        .name{
          font-weight: 700;
          margin: 0 0 8px;
          font-size: 18px;
          opacity: .9;
        }
        .text{white-space: normal; word-wrap: break-word;}
        .meta{
          margin-top: 10px;
          font-size: 14px;
          color: #444;
          opacity: .9;
          line-height: 1.1;
        }
        /* Timestamp alignment: left bubbles left-aligned, right bubbles right-aligned */
        .bubble.other .meta{ text-align: left; }
        .bubble.me .meta{ text-align: right; }
        .bubble.system .meta{
          margin-top: 6px;
          text-align: center;
          font-size: 10px;
          color: rgba(255,255,255,.85);
          opacity: .85;
          line-height: 1.05;
        }
        .media{
          margin-top: 10px;
          border-radius: 14px;
          overflow:hidden;
          background: rgba(255,255,255,.35);
          max-width: var(--media-max);
          width: 100%;
          margin-left: auto;
          margin-right: auto;
        }
        /* Photos: fill the media box width; allow taller images (e.g. phone screenshots) to grow in height. */
        .media.media-img img{
          max-height: none;
        }
        .media img{
          display:block;
          width:100%;
          height:auto;
        }
        .media video{
          display:block;
          width:100%;
          height:auto;
          background:#000;
        }
        .media audio{
          display:block;
          width:100%;
          height:auto;
        }
        .media a{display:block;}
        .fileline a{color:#2a5db0;text-decoration:none;}
        .fileline a:hover{text-decoration:underline;}
        .preview{
          margin-top: 10px;
          border-radius: 14px;
          overflow:hidden;
          background: rgba(255,255,255,.55);
          border: 1px solid rgba(0,0,0,.06);
          max-width: var(--media-max);
          width: 100%;
          margin-left: auto;
          margin-right: auto;
        }
        .preview a{color: inherit; text-decoration:none; display:block;}
        .preview .pimg img{width:100%;height:auto;display:block;max-height:none;}
        .preview .pbody{padding:10px 12px;}
        .preview .ptitle{font-weight:700; margin:0 0 4px; font-size: 16px;}
        .preview .pdesc{margin:0; color: var(--muted); font-size: 14px;}
        .linkline{margin-top:8px;font-size:15px;color:#2a5db0;word-break:break-all;}
        .fileline{margin-top:10px;font-size:15px;color:#2b2b2b;opacity:.85;word-break:break-all;}
        """#

        // Keep the <style> block formatted with a newline after <style> and 4-space indentation.
        // This keeps output deterministic while preserving readable source formatting.
        let cssIndented = "    " + css.replacingOccurrences(of: "\n", with: "\n    ")

        let headerHTML: String = {
            var parts: [String] = []
            parts.append("<!doctype html><html lang='de'><head><meta charset='utf-8'>")
            parts.append("<meta name='viewport' content='width=device-width, initial-scale=1'>")
            parts.append("<title>\(htmlEscape("WhatsApp Chat: " + titleNames))</title>")
            parts.append("<style>\n\(cssIndented)\n    </style>")
            // Insert the waOpenEmbed JS helper (in the <head>).
            parts.append("""
    <script>
    // Open embedded base64 file (avoids data: URLs in href, works in Safari).
    function waOpenEmbed(id){
      try{
        var el = document.getElementById(id);
        if(!el) return false;

        var b64 = (el.textContent || "").trim();
        if(!b64) return false;

        var mime = el.getAttribute('data-mime') || 'application/octet-stream';
        var name = el.getAttribute('data-name') || 'file';

        // base64 -> Uint8Array
        var bin = atob(b64);
        var len = bin.length;
        var bytes = new Uint8Array(len);
        for(var i=0;i<len;i++){ bytes[i] = bin.charCodeAt(i); }

        var blob = new Blob([bytes], {type: mime});
        var url = URL.createObjectURL(blob);

        // Prefer opening in a new tab; if blocked, fall back to same-tab navigation.
        var opened = null;
        try { opened = window.open(url, '_blank'); } catch(e) { opened = null; }
        if(!opened){
          window.location.href = url;
        }

        // Revoke later to allow the new tab to load.
        setTimeout(function(){ try{ URL.revokeObjectURL(url); }catch(e){} }, 60 * 1000);
        return false;
      } catch(e){
        return false;
      }
    }

    // Download embedded base64 file with original filename.
    function waDownloadEmbed(id){
      try{
        var el = document.getElementById(id);
        if(!el) return false;

        var b64 = (el.textContent || "").trim();
        if(!b64) return false;

        var mime = el.getAttribute('data-mime') || 'application/octet-stream';
        var name = el.getAttribute('data-name') || 'file';

        // base64 -> Uint8Array
        var bin = atob(b64);
        var len = bin.length;
        var bytes = new Uint8Array(len);
        for(var i=0;i<len;i++){ bytes[i] = bin.charCodeAt(i); }

        var blob = new Blob([bytes], {type: mime});
        var url = URL.createObjectURL(blob);

        var a = document.createElement('a');
        a.href = url;
        a.download = name;
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        setTimeout(function(){
          try{ document.body.removeChild(a); }catch(e){}
          try{ URL.revokeObjectURL(url); }catch(e){}
        }, 1000);

        return false;
      } catch(e){
        return false;
      }
    }
    
    // Create a Blob URL for an embedded base64 payload (used for inline audio/video players).
    function waCreateEmbedURL(id){
      try{
        var el = document.getElementById(id);
        if(!el) return null;

        var b64 = (el.textContent || "").trim();
        if(!b64) return null;

        var mime = el.getAttribute('data-mime') || 'application/octet-stream';

        // base64 -> Uint8Array
        var bin = atob(b64);
        var len = bin.length;
        var bytes = new Uint8Array(len);
        for(var i=0;i<len;i++){ bytes[i] = bin.charCodeAt(i); }

        var blob = new Blob([bytes], {type: mime});
        return URL.createObjectURL(blob);
      } catch(e){
        return null;
      }
    }

    // Initialize all embedded audio/video players by wiring their src to a Blob URL.
    // This keeps the export single-file while still giving a real mini-player.
    function waInitEmbedPlayers(){
      try{
        var nodes = document.querySelectorAll('audio[data-wa-embed],video[data-wa-embed]');
        for(var i=0;i<nodes.length;i++){
          var n = nodes[i];
          var id = n.getAttribute('data-wa-embed');
          if(!id) continue;
          var url = waCreateEmbedURL(id);
          if(url){
            n.src = url;
            // Revoke later to keep memory bounded
            setTimeout((function(u){
              return function(){ try{ URL.revokeObjectURL(u); }catch(e){} };
            })(url), 60 * 1000);
          }
        }
      } catch(e){
        // ignore
      }
    }

    document.addEventListener('DOMContentLoaded', waInitEmbedPlayers);
    
    </script>
    </head><body><div class='wrap'>
    """)

            parts.append("<div class='header'>")
            parts.append("<p class='h-title'>WhatsApp Chat<br>\(htmlEscape(titleNames))</p>")
            parts.append("<p class='h-meta'>Quelle: \(htmlEscape(chatURL.lastPathComponent))<br>"
                         + "Export: \(htmlEscape(exportCreatedStr))<br>"
                         + "Nachrichten: \(messageCount)</p>")
            parts.append("</div>")
            return parts.joined()
        }()

        let chatDir = chatURL.deletingLastPathComponent().standardizedFileURL
        let externalAssetsRoot = externalAssetsDir?.standardizedFileURL
        let externalPreviewsDir = externalAssetsRoot?.appendingPathComponent("_previews", isDirectory: true)
        if ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1", let externalAssetsRoot {
            print("WET-DBG: externalAssetsRoot: \(externalAssetsRoot.path)")
            if let externalPreviewsDir { print("WET-DBG: externalPreviewsDir: \(externalPreviewsDir.path)") }
        }

        let caps = wetConcurrencyCaps
        if perfEnabled {
            print("WET-PERF: render caps cpu=\(caps.cpu) io=\(caps.io)")
        }

        var previewByURL: [String: WAPreview] = [:]
        if enablePreviews {
            var previewTargets: [String] = []
            previewTargets.reserveCapacity(64)
            var seen = Set<String>()
            for m in msgs {
                let textWoAttach = stripAttachmentMarkers(m.text)
                let trimmedText = textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedText.isEmpty { continue }
                let urls = extractURLs(trimmedText)
                if urls.isEmpty { continue }
                for u in urls where seen.insert(u).inserted {
                    previewTargets.append(u)
                }
            }
            if !previewTargets.isEmpty {
                let previewCap = min(caps.cpu, 8)
                if perfEnabled {
                    print("WET-PERF: previews cap=\(previewCap) jobs=\(previewTargets.count)")
                }
                let limiter = AsyncLimiter(previewCap)
                var results = Array<WAPreview?>(repeating: nil, count: previewTargets.count)
                try await withThrowingTaskGroup(of: (Int, WAPreview?).self) { group in
                    for (idx, url) in previewTargets.enumerated() {
                        group.addTask {
                            try Task.checkCancellation()
                            return try await limiter.withPermit {
                                try Task.checkCancellation()
                                let prev = await buildPreview(url)
                                return (idx, prev)
                            }
                        }
                    }
                    for try await (idx, prev) in group {
                        results[idx] = prev
                    }
                }
                for (idx, prev) in results.enumerated() {
                    if let prev {
                        previewByURL[previewTargets[idx]] = prev
                    }
                }
            }
        }

        let previewByURLSnapshot = previewByURL
        let thumbnailStoreRef = thumbnailStore

        let dayHeaders: [String?] = {
            var headers = Array<String?>(repeating: nil, count: msgs.count)
            var lastDayKey: String? = nil
            for (idx, m) in msgs.enumerated() {
                let dayKey = isoDateOnly(m.ts)
                if lastDayKey != dayKey {
                    let wd = weekdayDE[weekdayIndexMonday0(m.ts)] ?? ""
                    headers[idx] = "<div class='day'><span>\(htmlEscape("\(wd), \(fmtDateFull(m.ts))"))</span></div>"
                    lastDayKey = dayKey
                }
            }
            return headers
        }()

        @Sendable func renderMessageHTML(index: Int, message: WAMessage) async throws -> String {
            var chunkParts: [String] = []
            if let dayHeader = dayHeaders[index] {
                chunkParts.append(dayHeader)
            }

            let authorRaw = _normSpace(message.author)
            let author = authorRaw.isEmpty ? "Unbekannt" : authorRaw

            let textRaw = message.text
            // Minimal mode (no attachments): only include attachments when we either embed full files
            // or explicitly render thumbnails-only.
            let shouldRenderAttachments = embedAttachments || embedAttachmentThumbnailsOnly || externalAttachments
            let attachments = shouldRenderAttachments ? findAttachments(textRaw) : []
            let textWoAttach = stripAttachmentMarkers(textRaw)
            let attachmentsAll = findAttachments(textRaw)

            let isSystemMsg = isSystemMessage(authorRaw: authorRaw, text: textWoAttach)

            if isSystemMsg {
                let sysText = stripBOMAndBidi(textWoAttach).trimmingCharacters(in: .whitespacesAndNewlines)
                let sysHTML = htmlEscapeKeepNewlines(sysText)
                chunkParts.append("<div class='sys'><span class='sys-line'>\(sysHTML)</span></div>")
                return chunkParts.joined()
            }

            let isMe = (!isSystemMsg) && (authorRaw.lowercased() == _normSpace(meName).lowercased())
            let rowCls: String = isSystemMsg ? "system" : (isMe ? "me" : "other")
            let bubCls: String = isSystemMsg ? "system" : (isMe ? "me" : "other")

            let trimmedText = textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines)
            let urls = enablePreviews ? extractURLs(trimmedText) : []
            let urlOnly = enablePreviews ? isURLOnlyText(trimmedText) : false

            let textHTML: String = {
                if urlOnly { return "" }

                // WICHTIG: Text-only Export soll Attachments sichtbar lassen
                if trimmedText.isEmpty, !embedAttachments, !embedAttachmentThumbnailsOnly, !externalAttachments, !attachmentsAll.isEmpty {
                    return htmlEscapeKeepNewlines(attachmentPlaceholderText(forAttachments: attachmentsAll))
                }

                if trimmedText.isEmpty { return "" }

                // In der kleinsten Variante (Previews aus) URLs klickbar machen
                return htmlEscapeAndLinkifyKeepNewlines(trimmedText, linkify: !enablePreviews)
            }()

            var previewHTML = ""

            if enablePreviews, !urls.isEmpty {
                let previewTargets: [String] = urls
                var blocks: [String] = []
                blocks.reserveCapacity(previewTargets.count)

                for u in previewTargets {
                    try Task.checkCancellation()
                    let prev: WAPreview?
                    if let cached = previewByURLSnapshot[u] {
                        prev = cached
                    } else {
                        prev = await buildPreview(u)
                    }
                    if let prev {
                        var imgBlock = ""
                        if let img = prev.imageDataURL {
                            if externalPreviews, let previewsDir = externalPreviewsDir {
                                if let href = stagePreviewImageDataURL(img, previewsDir: previewsDir, relativeTo: attachmentRelBaseDir) {
                                    imgBlock = "<div class='pimg'><img alt='' src='\(htmlEscape(href))'></div>"
                                } else {
                                    imgBlock = "<div class='pimg'><img alt='' src='\(img)'></div>"
                                }
                            } else {
                                imgBlock = "<div class='pimg'><img alt='' src='\(img)'></div>"
                            }
                        }
                        let ptitle = htmlEscape(prev.title.isEmpty ? u : prev.title)
                        let pdesc = htmlEscape(prev.description)
                        let block =
                            "<div class='preview'>"
                            + "<a href='\(htmlEscape(u))' target='_blank' rel='noopener'>"
                            + imgBlock
                            + "<div class='pbody'><p class='ptitle'>\(ptitle)</p>"
                            + (pdesc.isEmpty ? "" : "<p class='pdesc'>\(pdesc)</p>")
                            + "</div></a></div>"
                        blocks.append(block)
                    }
                }

                previewHTML = blocks.joined()
            }

            // attachments: images embedded; PDFs/videos get generated thumbs; DOC/DOCX use filename fallback.
            // Make previews + filenames clickable to the local file (file://...) when it exists.
            var mediaBlocks: [String] = []
            var embedCounter = 0
            for fn in attachments {
                try Task.checkCancellation()
                let direct = chatDir.appendingPathComponent(fn).standardizedFileURL
                let p = FileManager.default.fileExists(atPath: direct.path)
                    ? direct
                    : (resolveAttachmentURL(fileName: fn, sourceDir: chatDir) ?? direct)
                let ext = p.pathExtension.lowercased()

                if embedAttachmentThumbnailsOnly {
                    // Thumbnails-only mode must produce a standalone HTML (no ./attachments folder):
                    // - Do NOT stage/copy attachments to disk.
                    // - Embed ONLY a lightweight thumbnail as a data: URL.
                    // - Do NOT wrap thumbnails in <a href=...> and do NOT print any file link/text line.

                    if let thumbDataURL = await thumbnailStoreRef?.thumbnailDataURL(fileName: fn, allowOriginalFallback: true) {
                        let isImage = ["jpg","jpeg","png","gif","webp","heic","heif"].contains(ext)
                        mediaBlocks.append(
                            "<div class='media\(isImage ? " media-img" : "")'><img alt='' src='\(htmlEscape(thumbDataURL))'></div>"
                        )
                        continue
                    }

                    // Fallback (no thumbnail available): show a non-clickable filename line.
                    mediaBlocks.append("<div class='fileline'>\(attachmentEmoji(forExtension: ext)) \(htmlEscape(fn))</div>")
                    continue
                }

                // Mode A: embed everything directly into the HTML (single-file export).
                // Use waOpenEmbed for clickable links (no data: href).
                if embedAttachments {
                    // For video: store payload once (script) and show an inline player.
                    // Keep the download link (waDownloadEmbed) as requested.
                    if ["mp4", "mov", "m4v"].contains(ext) {
                        let mime = guessMime(fromName: fn)
                        let poster = await thumbnailStoreRef?.thumbnailDataURL(fileName: fn)

                        if let fmData = try? Data(contentsOf: p) {
                            embedCounter += 1
                            let embedId = "wa-embed-\(index)-\(embedCounter)"
                            let b64 = fmData.base64EncodedString()
                            let safeMime = htmlEscape(mime)
                            let safeName = htmlEscape(fn)

                            // Store raw bytes once; player loads via Blob URL created in JS.
                            mediaBlocks.append("<script id='\(embedId)' type='application/octet-stream' data-mime='\(safeMime)' data-name='\(safeName)'>\(b64)</script>")

                            var posterAttr = ""
                            if let poster {
                                posterAttr = " poster='\(htmlEscape(poster))'"
                            }

                            mediaBlocks.append(
                                "<div class='media'><video controls preload='metadata' playsinline data-wa-embed='\(embedId)'\(posterAttr)></video></div>"
                            )
                            mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\(embedId)')\">Video speichern</a></div>")
                        } else {
                            if let poster {
                                mediaBlocks.append("<div class='media'><img alt='' src='\(htmlEscape(poster))'></div>")
                            }
                            mediaBlocks.append("<div class='fileline'>🎬 \(htmlEscape(fn))</div>")
                        }
                        continue
                    }

                    // Audio: embed an inline mini player and keep a download link.
                    if ["mp3","m4a","aac","wav","ogg","opus","flac","caf","aiff","aif","amr"].contains(ext) {
                        let mime = guessMime(fromName: fn)

                        if let fmData = try? Data(contentsOf: p) {
                            embedCounter += 1
                            let embedId = "wa-embed-\(index)-\(embedCounter)"
                            let b64 = fmData.base64EncodedString()
                            let safeMime = htmlEscape(mime)
                            let safeName = htmlEscape(fn)

                            // Store raw bytes once; audio loads via Blob URL created in JS.
                            mediaBlocks.append("<script id='\(embedId)' type='application/octet-stream' data-mime='\(safeMime)' data-name='\(safeName)'>\(b64)</script>")

                            mediaBlocks.append(
                                "<div class='media'><audio controls preload='metadata' data-wa-embed='\(embedId)'></audio></div>"
                            )
                            mediaBlocks.append("<div class='fileline'>🎧 \(htmlEscape(fn))</div>")
                            mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\(embedId)')\">Audio speichern</a></div>")
                        } else {
                            mediaBlocks.append("<div class='fileline'>🎧 \(htmlEscape(fn))</div>")
                        }
                        continue
                    }

                    // For PDF/DOC/DOCX: preview thumbnail, clickable with waOpenEmbed.
                    if ["pdf", "doc", "docx"].contains(ext) {
                        let mime = guessMime(fromName: fn)
                        let previewDataURL = await thumbnailStoreRef?.thumbnailDataURL(fileName: fn)
                        let fileData = try? Data(contentsOf: p)
                        if let previewDataURL, let fileData {
                            embedCounter += 1
                            let embedId = "wa-embed-\(index)-\(embedCounter)"
                            let b64 = fileData.base64EncodedString()
                            let safeMime = htmlEscape(mime)
                            let safeName = htmlEscape(fn)
                            // Insert the hidden script tag before the clickable UI.
                            mediaBlocks.append("<script id='\(embedId)' type='application/octet-stream' data-mime='\(safeMime)' data-name='\(safeName)'>\(b64)</script>")
                            // Thumbnail preview wrapped in waOpenEmbed link.
                            mediaBlocks.append("<div class='media'><a href='javascript:void(0)' onclick=\"return waOpenEmbed('\(embedId)')\"><img alt='' src='\(previewDataURL)'></a></div>")
                            // Fileline link using waOpenEmbed.
                            mediaBlocks.append("<div class='fileline'>📎 <a href='javascript:void(0)' onclick=\"return waOpenEmbed('\(embedId)')\">\(htmlEscape(fn))</a></div>")
                            mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\(embedId)')\">Datei speichern</a></div>")
                        } else if let previewDataURL {
                            mediaBlocks.append("<div class='media'><img alt='' src='\(previewDataURL)'></div>")
                            mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
                        } else if let fileData {
                            embedCounter += 1
                            let embedId = "wa-embed-\(index)-\(embedCounter)"
                            let b64 = fileData.base64EncodedString()
                            let safeMime = htmlEscape(mime)
                            let safeName = htmlEscape(fn)
                            mediaBlocks.append("<script id='\(embedId)' type='application/octet-stream' data-mime='\(safeMime)' data-name='\(safeName)'>\(b64)</script>")
                            mediaBlocks.append("<div class='fileline'>📎 <a href='javascript:void(0)' onclick=\"return waOpenEmbed('\(embedId)')\">\(htmlEscape(fn))</a></div>")
                            mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\(embedId)')\">Datei speichern</a></div>")
                        } else {
                            mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
                        }
                        continue
                    }

                    // For image files (jpg/png/gif/webp/heic/heif): show as <img> and open via waOpenEmbed on click.
                    // (Avoids data: URLs in href which can lead to about:blank in Safari.)
                    if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"].contains(ext) {
                        let mime = guessMime(fromName: fn)
                        if let dataURL = fileToDataURL(p), let fileData = try? Data(contentsOf: p) {
                            embedCounter += 1
                            let embedId = "wa-embed-\(index)-\(embedCounter)"
                            let b64 = fileData.base64EncodedString()
                            let safeMime = htmlEscape(mime)
                            let safeName = htmlEscape(fn)

                            // Store raw bytes once; click opens blob via waOpenEmbed.
                            mediaBlocks.append("<script id='\(embedId)' type='application/octet-stream' data-mime='\(safeMime)' data-name='\(safeName)'>\(b64)</script>")

                            let safeSrc = htmlEscape(dataURL)
                            mediaBlocks.append("<div class='media media-img'><a href='javascript:void(0)' onclick=\"return waOpenEmbed('\(embedId)')\"><img alt='' src='\(safeSrc)'></a></div>")
                            mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\(embedId)')\">Bild speichern</a></div>")
                            // Kein Dateiname unter eingebetteten Bildern
                        } else if let dataURL = fileToDataURL(p) {
                            // Fallback: show image without click-to-open.
                            let safeSrc = htmlEscape(dataURL)
                            mediaBlocks.append("<div class='media media-img'><img alt='' src='\(safeSrc)'></div>")
                        } else {
                            // Nur wenn Einbettung fehlschlägt, den Dateinamen anzeigen
                            mediaBlocks.append("<div class='fileline'>🖼️ \(htmlEscape(fn))</div>")
                        }
                        continue
                    }

                    // All other files: show fileline, clickable if file exists.
                    let mime = guessMime(fromName: fn)
                    let fileData = try? Data(contentsOf: p)
                    if let fileData {
                        embedCounter += 1
                        let embedId = "wa-embed-\(index)-\(embedCounter)"
                        let b64 = fileData.base64EncodedString()
                        let safeMime = htmlEscape(mime)
                        let safeName = htmlEscape(fn)
                        mediaBlocks.append("<script id='\(embedId)' type='application/octet-stream' data-mime='\(safeMime)' data-name='\(safeName)'>\(b64)</script>")
                        mediaBlocks.append("<div class='fileline'>📎 <a href='javascript:void(0)' onclick=\"return waOpenEmbed('\(embedId)')\">\(htmlEscape(fn))</a></div>")
                        mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\(embedId)')\">Datei speichern</a></div>")
                    } else {
                        mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
                    }
                    continue
                }

                if externalAttachments {
                    let staged = stageAttachmentForExport(
                        source: p,
                        attachmentsDir: chatDir,
                        relativeTo: attachmentRelBaseDir
                    )
                    guard let href = staged?.relHref else {
                        mediaBlocks.append("<div class='fileline'>\(attachmentEmoji(forExtension: ext)) \(htmlEscape(fn))</div>")
                        continue
                    }
                    let safeHref = htmlEscape(href)

                    if ["mp4", "mov", "m4v"].contains(ext) {
                        let mime = guessMime(fromName: fn)
                        var posterAttr = ""
                        if !disableThumbStaging,
                           let poster = await thumbnailStoreRef?.thumbnailHref(fileName: fn, relativeTo: attachmentRelBaseDir) {
                            posterAttr = " poster='\(htmlEscape(poster))'"
                        }
                        mediaBlocks.append(
                            "<div class='media'><video controls preload='metadata' playsinline\(posterAttr)><source src='\(safeHref)' type='\(htmlEscape(mime))'>Dein Browser kann dieses Video nicht abspielen. <a href='\(safeHref)'>Video öffnen</a>.</video></div>"
                        )
                        mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(safeHref)' download>Video herunterladen</a></div>")
                        continue
                    }

                    if ["mp3","m4a","aac","wav","ogg","opus","flac","caf","aiff","aif","amr"].contains(ext) {
                        let mime = guessMime(fromName: fn)
                        mediaBlocks.append(
                            "<div class='media'><audio controls preload='metadata'><source src='\(safeHref)' type='\(htmlEscape(mime))'>Dein Browser kann dieses Audio nicht abspielen. <a href='\(safeHref)'>Audio öffnen</a>.</audio></div>"
                        )
                        mediaBlocks.append("<div class='fileline'>🎧 \(htmlEscape(fn))</div>")
                        mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(safeHref)' download>Audio herunterladen</a></div>")
                        continue
                    }

                    if ["pdf", "doc", "docx"].contains(ext) {
                        var thumbHref: String? = nil
                        if !disableThumbStaging {
                            thumbHref = await thumbnailStoreRef?.thumbnailHref(fileName: fn, relativeTo: attachmentRelBaseDir)
                        }
                        if let thumbHref {
                            mediaBlocks.append(
                                "<div class='media'><a href='\(safeHref)' target='_blank' rel='noopener'><img alt='' src='\(htmlEscape(thumbHref))'></a></div>"
                            )
                        }
                        mediaBlocks.append("<div class='fileline'>📎 <a href='\(safeHref)' target='_blank' rel='noopener'>\(htmlEscape(fn))</a></div>")
                        mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(safeHref)' download>Datei speichern</a></div>")
                        continue
                    }

                    if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"].contains(ext) {
                        mediaBlocks.append(
                            "<div class='media media-img'><a href='\(safeHref)' target='_blank' rel='noopener'><img alt='' src='\(safeHref)'></a></div>"
                        )
                        mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(safeHref)' download>Bild speichern</a></div>")
                        continue
                    }

                    mediaBlocks.append("<div class='fileline'>📎 <a href='\(safeHref)' target='_blank' rel='noopener'>\(htmlEscape(fn))</a></div>")
                    mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(safeHref)' download>Datei speichern</a></div>")
                    continue
                }

                // Mode B (default): stage attachments into ./attachments for portable HTML/MD.
                let staged = stageAttachmentForExport(
                    source: p,
                    attachmentsDir: chatDir,
                    relativeTo: attachmentRelBaseDir
                )
                let href = staged?.relHref
                let stagedURL = staged?.stagedURL

                // Video attachments: embed a small inline player in the HTML export.
                // Use a portable relative path (./attachments/...) when available.
                if ["mp4", "mov", "m4v"].contains(ext), let href {
                    let mime = guessMime(fromName: fn)
                    let poster = await thumbnailStoreRef?.thumbnailDataURL(fileName: fn)

                    var posterAttr = ""
                    if let poster {
                        posterAttr = " poster='\(poster)'"
                    }

                    mediaBlocks.append(
                        "<div class='media'><video controls preload='metadata' playsinline\(posterAttr)><source src='\(htmlEscape(href))' type='\(htmlEscape(mime))'>Dein Browser kann dieses Video nicht abspielen. <a href='\(htmlEscape(href))'>Video öffnen</a>.</video></div>"
                    )
                    mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(htmlEscape(href))' download>Video herunterladen</a></div>")
                    continue
                }

                // Audio attachments: embed an inline mini player + keep a download link.
                if ["mp3","m4a","aac","wav","ogg","opus","flac","caf","aiff","aif","amr"].contains(ext), let href {
                    let mime = guessMime(fromName: fn)
                    mediaBlocks.append(
                        "<div class='media'><audio controls preload='metadata'><source src='\(htmlEscape(href))' type='\(htmlEscape(mime))'>Dein Browser kann dieses Audio nicht abspielen. <a href='\(htmlEscape(href))'>Audio öffnen</a>.</audio></div>"
                    )
                    mediaBlocks.append("<div class='fileline'>⬇︎ <a href='\(htmlEscape(href))' download>Audio herunterladen</a></div>")
                    continue
                }

                var previewDataURL: String? = nil
                var isImage = false
                if ["jpg","jpeg","png","gif","webp","heic","heif"].contains(ext) {
                    previewDataURL = fileToDataURL(stagedURL ?? p)
                    isImage = true
                } else if ext == "pdf" {
                    previewDataURL = await thumbnailStoreRef?.thumbnailDataURL(fileName: fn)
                }

                if let previewDataURL {
                    if let href {
                        mediaBlocks.append(
                            "<div class='media\(isImage ? " media-img" : "")'><a href='\(htmlEscape(href))' target='_blank' rel='noopener'><img alt='' src='\(previewDataURL)'></a></div>"
                        )
                        if !isImage {
                            mediaBlocks.append(
                                "<div class='fileline'>📎 <a href='\(htmlEscape(href))' target='_blank' rel='noopener'>\(htmlEscape(fn))</a></div>"
                            )
                        }
                    } else {
                        mediaBlocks.append("<div class='media\(isImage ? " media-img" : "")'><img alt='' src='\(previewDataURL)'></div>")
                        if !isImage {
                            mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
                        }
                    }
                } else {
                    if let href {
                        mediaBlocks.append(
                            "<div class='fileline'>📎 <a href='\(htmlEscape(href))' target='_blank' rel='noopener'>\(htmlEscape(fn))</a></div>"
                        )
                    } else {
                        mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
                    }
                }
            }

            // show all urls as lines (only when previews/link-handling is enabled)
            var linkLines = ""
            if enablePreviews, !urls.isEmpty {
                let lines = urls.map { u in
                    let shown = htmlEscape(displayURL(u))
                    let full = htmlEscape(u)
                    return "<a href='\(full)' target='_blank' rel='noopener' title='\(full)'>\(shown)</a>"
                }.joined(separator: "<br>")
                linkLines = "<div class='linkline'>\(lines)</div>"
            }

            // For URL-only messages, the preview blocks already contain the clickable link.
            // Avoid duplicating a second huge link line when previews are present.
            if urlOnly && !previewHTML.isEmpty {
                linkLines = ""
            }

            chunkParts.append("<div class='row \(rowCls)'>")
            let hasMedia = (!previewHTML.isEmpty) || (!mediaBlocks.isEmpty)
            let bubbleExtra = hasMedia ? " has-media" : ""
            chunkParts.append("<div class='bubble \(bubCls)\(bubbleExtra)'>")
            if !isSystemMsg {
                chunkParts.append("<div class='name'>\(htmlEscape(author))</div>")
            }
            if !textHTML.isEmpty { chunkParts.append("<div class='text'>\(textHTML)</div>") }
            if !previewHTML.isEmpty { chunkParts.append(previewHTML) }
            if !linkLines.isEmpty { chunkParts.append(linkLines) }
            if !mediaBlocks.isEmpty { chunkParts.append(contentsOf: mediaBlocks) }
            chunkParts.append("<div class='meta'>\(htmlEscape(fmtTime(message.ts)))<br>\(htmlEscape(fmtDateFull(message.ts)))</div>")
            chunkParts.append("</div></div>")
            return chunkParts.joined()
        }

        let writeStart = ProcessInfo.processInfo.systemUptime
        let tempHTML = outHTML.appendingPathExtension("tmp")
        var writer = try BufferedFileWriter(url: tempHTML, flushThresholdBytes: 1_048_576)
        var didCloseWriter = false
        do {
            try writer.append(headerHTML)

            let chunkSize = msgs.count > 50_000 ? 2_000 : 1_000
            let ranges: [Range<Int>] = stride(from: 0, to: msgs.count, by: chunkSize).map { start in
                let end = min(start + chunkSize, msgs.count)
                return start..<end
            }
            if perfEnabled {
                print("WET-PERF: html chunks size=\(chunkSize) count=\(ranges.count)")
            }

            let renderLimiter = AsyncLimiter(min(caps.cpu, 8))
            var pending: [Int: Data] = [:]
            var nextIndex = 0
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (chunkIndex, range) in ranges.enumerated() {
                    group.addTask {
                        try Task.checkCancellation()
                        return try await renderLimiter.withPermit {
                            try Task.checkCancellation()
                            var chunkParts: [String] = []
                            chunkParts.reserveCapacity((range.count * 6) + 8)
                            for idx in range {
                                try Task.checkCancellation()
                                let html = try await renderMessageHTML(index: idx, message: msgs[idx])
                                chunkParts.append(html)
                            }
                            let chunkString = chunkParts.joined()
                            return (chunkIndex, Data(chunkString.utf8))
                        }
                    }
                }
                for try await (chunkIndex, chunkData) in group {
                    pending[chunkIndex] = chunkData
                    while let data = pending.removeValue(forKey: nextIndex) {
                        try Task.checkCancellation()
                        try writer.append(data)
                        nextIndex += 1
                    }
                }
            }

            try writer.append("</div></body></html>")
            try writer.close()
            didCloseWriter = true
        } catch {
            if !didCloseWriter {
                try? writer.close()
            }
            throw error
        }

        let renderDuration = ProcessInfo.processInfo.systemUptime - renderStart
        if let perfLabel {
            recordHTMLRender(label: perfLabel, duration: renderDuration)
        }

        let bytesWritten = writer.bytesWritten
        if FileManager.default.fileExists(atPath: outHTML.path) {
            try? FileManager.default.removeItem(at: outHTML)
        }
        try FileManager.default.moveItem(at: tempHTML, to: outHTML)
        let writeDuration = ProcessInfo.processInfo.systemUptime - writeStart
        if let perfLabel {
            recordHTMLWrite(label: perfLabel, duration: writeDuration, bytes: bytesWritten)
        }
    }

    // ---------------------------
    // Render Markdown (1:1)
    // ---------------------------

    nonisolated private static func renderMD(
        msgs: [WAMessage],
        chatURL: URL,
        outMD: URL,
        meName: String,
        enablePreviews: Bool,
        embedAttachments: Bool,
        embedAttachmentThumbnailsOnly: Bool,
        attachmentRelBaseDir: URL? = nil
    ) throws {

        var authors: [String] = []
        for m in msgs {
            let a = _normSpace(m.author)
            if a.isEmpty { continue }
            if isSystemAuthor(a) { continue }
            if !authors.contains(a) { authors.append(a) }
        }

        let others = authors.filter { _normSpace($0).lowercased() != _normSpace(meName).lowercased() }
        let titleNames: String = {
            if others.count == 1 { return "\(meName) ↔ \(others[0])" }
            if others.count > 1 { return "\(meName) ↔ \(others.joined(separator: ", "))" }
            return "\(meName) ↔ Chat"
        }()

        // export time = transcript creation date (fallback: modification date)
        let exportCreatedAt = exportCreatedDate(chatURL: chatURL)
        let exportCreatedStr = exportCreatedAt.map { iso8601WithOffsetString($0) } ?? "(unknown)"

        let messageCount: Int = msgs.reduce(0) { acc, m in
            let authorNorm = _normSpace(m.author)
            let textWoAttach = stripAttachmentMarkers(m.text)
            return acc + (isSystemMessage(authorRaw: authorNorm, text: textWoAttach) ? 0 : 1)
        }

        var out: [String] = []
        out.reserveCapacity(max(256, msgs.count * 3))

        out.append("# WhatsApp Chat")
        out.append("")
        out.append("**\(titleNames)**")
        out.append("")
        out.append("- Quelle: \(chatURL.lastPathComponent)")
        out.append("- Export: \(exportCreatedStr)")
        out.append("- Nachrichten: \(messageCount)")
        out.append("")

        var lastDayKey: String? = nil
        let sourceDir = chatURL.deletingLastPathComponent().standardizedFileURL
        for m in msgs {
            try Task.checkCancellation()
            let dayKey = isoDateOnly(m.ts)
            if lastDayKey != dayKey {
                let wd = weekdayDE[weekdayIndexMonday0(m.ts)] ?? ""
                out.append("## \(wd), \(fmtDateFull(m.ts))")
                out.append("")
                lastDayKey = dayKey
            }

            let authorRaw = _normSpace(m.author)
            let author = authorRaw.isEmpty ? "Unbekannt" : authorRaw

            let textRaw = m.text
            let attachmentsAll = findAttachments(textRaw)
            let textWoAttach = stripAttachmentMarkers(textRaw)

            let isSystemMsg = isSystemMessage(authorRaw: authorRaw, text: textWoAttach)
            let isMe = (!isSystemMsg) && (authorRaw.lowercased() == _normSpace(meName).lowercased())

            let trimmedText = textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSystemMsg {
                let sysText = stripBOMAndBidi(trimmedText)
                out.append("— \(sysText) —")
                out.append("")
                continue
            }

            // URLs: nur als extra Link-Liste, wenn enablePreviews=true (analog HTML)
            let urls = enablePreviews ? extractURLs(trimmedText) : []
            let urlOnly = enablePreviews ? isURLOnlyText(trimmedText) : false

            // Headerzeile pro Message
            if isSystemMsg {
                out.append("> **System** · \(fmtTime(m.ts)) · \(fmtDateFull(m.ts))")
            } else {
                let who = isMe ? "\(author) (Ich)" : author
                out.append("**\(who)** · \(fmtTime(m.ts)) · \(fmtDateFull(m.ts))")
            }

            // Text / Placeholder
            if !urlOnly {
                if trimmedText.isEmpty, !embedAttachments, !embedAttachmentThumbnailsOnly, !attachmentsAll.isEmpty {
                    out.append(attachmentPlaceholderText(forAttachments: attachmentsAll))
                } else if !trimmedText.isEmpty {
                    out.append(trimmedText)
                }
            }

            // Link lines (optional)
            if enablePreviews, !urls.isEmpty {
                out.append("")
                for u in urls {
                    // Markdown-friendly clickable link with compact display label
                    let shown = displayURL(u)
                    out.append("- [\(shown)](\(u))")
                }
            }

            // Attachments
            if !attachmentsAll.isEmpty {
                out.append("")
                for fn in attachmentsAll {
                    try Task.checkCancellation()
                    let ext = (fn as NSString).pathExtension.lowercased()
                    let emoji = attachmentEmoji(forExtension: ext)

                    if embedAttachmentThumbnailsOnly {
                        // MD: thumbnails-only macht als inline-thumb selten Sinn -> nur Textliste
                        out.append("- \(emoji) \(fn)")
                        continue
                    }

                    // Resolve file location (direct or Media/ or recursive)
                    guard let src = resolveAttachmentURL(fileName: fn, sourceDir: sourceDir) else {
                        out.append("- \(emoji) \(fn)")
                        continue
                    }

                    // Stage into ./attachments for portability (wie HTML default Mode B)
                    let staged = stageAttachmentForExport(
                        source: src,
                        attachmentsDir: chatURL.deletingLastPathComponent(),
                        relativeTo: attachmentRelBaseDir
                    )
                    let href = staged?.relHref ?? src.absoluteURL.absoluteString

                    // Images as inline preview, others as links
                    if ["jpg","jpeg","png","gif","webp","heic","heif"].contains(ext) {
                        out.append("![\(fn)](\(href))")
                    } else {
                        out.append("- [\(emoji) \(fn)](\(href))")
                    }
                }
            }

            out.append("") // blank line between messages
        }

        try out.joined(separator: "\n").write(to: outMD, atomically: true, encoding: .utf8)
    }
    /// Best-effort: make dest carry the same filesystem timestamps as source.
    /// We intentionally do not throw if the filesystem refuses to set attributes.
    nonisolated(unsafe) private static var didLogTimestampWarning = false
    nonisolated private static func syncFileSystemTimestamps(from source: URL, to dest: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return }

        var newAttrs: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] as? Date { newAttrs[.creationDate] = c }
        if let m = attrs[.modificationDate] as? Date { newAttrs[.modificationDate] = m }

        if ProcessInfo.processInfo.environment["WET_DEBUG"] == "1" {
            let srcExt = source.pathExtension.lowercased()
            let dstExt = dest.pathExtension.lowercased()
            if (srcExt == "pdf" || dstExt == "pdf"), let m = newAttrs[.modificationDate] as? Date {
                let epoch = Int(m.timeIntervalSince1970.rounded())
                print("WET-DBG: PDF mtime apply epoch=\(epoch) src=\(source.path) dst=\(dest.path)")
            }
        }

        if !newAttrs.isEmpty {
            do {
                try fm.setAttributes(newAttrs, ofItemAtPath: dest.path)
            } catch {
                if let m = newAttrs[.modificationDate] {
                    try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dest.path)
                }
                if !didLogTimestampWarning {
                    didLogTimestampWarning = true
                    print("WARN: Could not fully preserve file timestamps for copied originals.")
                }
            }
        }
    }

    nonisolated private static func isDirectoryEmptyFirstLevel(_ url: URL) -> Bool {
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return contents.isEmpty
        } catch {
            if ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1" {
                print("WET-DBG: isDirectoryEmptyFirstLevel failed for \(url.path): \(error)")
            }
            return false
        }
    }

    nonisolated private static func isDirectoryEmptyRecursive(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            if ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1" {
                print("WET-DBG: isDirectoryEmptyRecursive failed for \(url.path)")
            }
            return false
        }
        for case let entry as URL in en {
            // If we cannot query resource values for any entry, err on the side of "not empty".
            // This prevents accidental deletion of directories that are actually populated.
            guard let rv = try? entry.resourceValues(forKeys: [.isRegularFileKey]) else {
                if ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1" {
                    print("WET-DBG: isDirectoryEmptyRecursive: could not read resourceValues for \(entry.path)")
                }
                return false
            }
            if rv.isRegularFile == true {
                return false
            }
        }
        return true
    }

    nonisolated static func publishExternalAssetsIfPresent(
        stagingRoot: URL,
        exportDir: URL,
        allowOverwrite: Bool,
        debugEnabled: Bool = false,
        debugLog: @Sendable (String) -> Void
    ) throws -> [URL] {
        let fm = FileManager.default
        let staging = stagingRoot.standardizedFileURL
        let finalRoot = exportDir.standardizedFileURL

        func log(_ msg: String) {
            guard debugEnabled else { return }
            debugLog(msg)
        }

        func fileCount(_ dir: URL) -> Int {
            guard let en = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                return 0
            }
            var count = 0
            for case let entry as URL in en {
                let rv = try? entry.resourceValues(forKeys: [.isRegularFileKey])
                if rv?.isRegularFile == true {
                    count += 1
                }
            }
            return count
        }

        let candidates = ["_thumbs", "_previews"]
        var published: [URL] = []

        for name in candidates {
            let src = staging.appendingPathComponent(name, isDirectory: true)
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if isDirectoryEmptyRecursive(src) {
                log("EXTERNAL ASSETS: skip empty \(src.path)")
                continue
            }

            let dst = finalRoot.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: dst.path) {
                if allowOverwrite {
                    log("EXTERNAL ASSETS: replace \(src.path) -> \(dst.path)")
                    _ = try fm.replaceItemAt(dst, withItemAt: src, backupItemName: nil, options: [])
                } else {
                    log("EXTERNAL ASSETS: already exists, skip \(dst.path)")
                    continue
                }
            } else {
                log("EXTERNAL ASSETS: move \(src.path) -> \(dst.path)")
                try fm.moveItem(at: src, to: dst)
            }

            let count = fileCount(dst)
            log("EXTERNAL ASSETS FINAL: \(dst.lastPathComponent) fileCount=\(count) path=\(dst.path)")
            published.append(dst)
        }

        return published
    }

    nonisolated static func cleanupTemporaryExportFolders(in dir: URL) throws {
        let fm = FileManager.default
        let base = dir.standardizedFileURL
        let debugEnabled = ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1"
        guard let contents = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        var failed: [String] = []
        for u in contents where u.lastPathComponent.hasPrefix(".wa_export_tmp_") {
            do {
                if debugEnabled {
                    print("WET-DBG: removeItem: \(u.path)")
                }
                try fm.removeItem(at: u)
            } catch {
                failed.append(u.lastPathComponent)
            }
        }

        if !failed.isEmpty {
            throw TemporaryExportFolderCleanupError(failedFolders: failed.sorted())
        }
    }

    nonisolated static func createStagingDirectory(in dir: URL) throws -> URL {
        let fm = FileManager.default
        let base = dir.standardizedFileURL

        for _ in 0..<5 {
            let candidate = base.appendingPathComponent(".wa_export_tmp_\(UUID().uuidString)", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { continue }
            do {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                throw StagingDirectoryCreationError(url: candidate, underlying: error)
            }
        }

        let fallback = base.appendingPathComponent(".wa_export_tmp_\(UUID().uuidString)", isDirectory: true)
        throw StagingDirectoryCreationError(url: fallback, underlying: CocoaError(.fileWriteFileExists))
    }

    nonisolated static func localStagingBaseDirectory() throws -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["WET_TMPDIR"], !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            let base = root.appendingPathComponent("whatsapp-export-tools", isDirectory: true)
            if !fm.fileExists(atPath: base.path) {
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
            }
            return base.standardizedFileURL
        }
        let base = fm.temporaryDirectory.appendingPathComponent("whatsapp-export-tools", isDirectory: true)
        if !fm.fileExists(atPath: base.path) {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.standardizedFileURL
    }

    nonisolated static func temporaryThumbsWorkspace(
        baseName: String,
        chatURL: URL,
        stagingBase: URL
    ) -> URL {
        let base = stagingBase.standardizedFileURL
        let key = "\(baseName)|\(chatURL.standardizedFileURL.path)"
        let hash = stableHashHex(key)
        return base.appendingPathComponent(".wa_thumbs_\(hash)", isDirectory: true)
    }

    nonisolated static func isLikelyICloudBacked(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.contains("/Library/Mobile Documents/") || path.contains("/Library/Mobile Documents/com~apple~CloudDocs/") {
            return true
        }
        let desktop = home + "/Desktop"
        let documents = home + "/Documents"
        if path.hasPrefix(desktop) || path.hasPrefix(documents) {
            return true
        }
        return false
    }

    nonisolated private static func suffixBaseNameIfPresent(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func parseSuffixNumber(_ s: Substring) -> Int? {
            let digits = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let num = Int(digits), num >= 2 else { return nil }
            return num
        }

        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let base = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            if !base.isEmpty, parseSuffixNumber(inner) != nil {
                return String(base)
            }
        }

        if let lastSpace = trimmed.lastIndex(of: " ") {
            let base = trimmed[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = trimmed[trimmed.index(after: lastSpace)...]
            if !base.isEmpty, parseSuffixNumber(suffix) != nil {
                return String(base)
            }
        }

        return nil
    }

    nonisolated static func validateSidecarLayout(sidecarBaseDir: URL) throws {
        let fm = FileManager.default
        let base = sidecarBaseDir.standardizedFileURL
        let debugEnabled = ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1"
        guard let contents = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        try cleanupTemporaryExportFolders(in: base)

        var dirURLs: [String: URL] = [:]
        for u in contents {
            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey])
            if rv?.isDirectory == true {
                dirURLs[u.lastPathComponent] = u
            }
        }

        // Do not auto-delete _thumbs/_previews: they may be populated during rendering and must be published when present.
        let knownBuckets = ["images", "videos", "audios", "documents"]
        for name in knownBuckets {
            if let url = dirURLs[name], isDirectoryEmptyRecursive(url) {
                if debugEnabled {
                    print("WET-DBG: removeItem: \(url.path)")
                }
                try? fm.removeItem(at: url)
                dirURLs.removeValue(forKey: name)
            }
        }

        let transcriptCandidates = ["Chat.txt", "_chat.txt"]
        let originalFolderName: String? = dirURLs.first(where: { element in
            transcriptCandidates.contains { candidate in
                fm.fileExists(atPath: element.value.appendingPathComponent(candidate).path)
            }
        })?.key

        var suffixArtifacts: [String] = []
        for name in dirURLs.keys {
            if name == originalFolderName { continue }
            if suffixBaseNameIfPresent(name) != nil {
                suffixArtifacts.append(name)
            }
        }

        if !suffixArtifacts.isEmpty {
            throw SidecarValidationError(suffixArtifacts: suffixArtifacts.sorted())
        }
    }

    nonisolated private static func datesMatch(_ a: Date?, _ b: Date?, tolerance: TimeInterval = 1.0) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSinceReferenceDate - b.timeIntervalSinceReferenceDate) <= tolerance
    }

    nonisolated private static func timestampsMatch(_ src: [FileAttributeKey: Any]?, _ dst: [FileAttributeKey: Any]?) -> Bool {
        guard let src, let dst else { return false }
        let srcC = src[.creationDate] as? Date
        let dstC = dst[.creationDate] as? Date
        let srcM = src[.modificationDate] as? Date
        let dstM = dst[.modificationDate] as? Date
        return datesMatch(srcC, dstC) && datesMatch(srcM, dstM)
    }

    nonisolated static func normalizeOriginalCopyTimestamps(
        sourceDir: URL,
        destDir: URL,
        skippingPathPrefixes: [String]
    ) {
        let fm = FileManager.default
        let srcRoot = sourceDir.standardizedFileURL
        let dstRoot = destDir.standardizedFileURL
        guard fm.fileExists(atPath: srcRoot.path), fm.fileExists(atPath: dstRoot.path) else { return }

        var dirPairs: [(src: URL, dst: URL)] = [(srcRoot, dstRoot)]
        var filePairs: [(src: URL, dst: URL)] = []

        guard let en = fm.enumerator(
            at: srcRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        let srcBasePath = srcRoot.path
        let dstBasePath = dstRoot.path
        let skipPrefixes = skippingPathPrefixes.map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        }

        func shouldSkip(_ url: URL) -> Bool {
            let p = url.standardizedFileURL.path
            for pref in skipPrefixes {
                if !pref.isEmpty, p.hasPrefix(pref) { return true }
            }
            if p.hasPrefix(dstBasePath) { return true }
            return false
        }

        for case let u as URL in en {
            if shouldSkip(u) {
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    en.skipDescendants()
                }
                continue
            }

            let fullPath = u.standardizedFileURL.path
            guard fullPath.hasPrefix(srcBasePath) else { continue }

            var relPath = String(fullPath.dropFirst(srcBasePath.count))
            if relPath.hasPrefix("/") { relPath.removeFirst() }
            if relPath.isEmpty { continue }

            let dst = dstRoot.appendingPathComponent(relPath)
            guard fm.fileExists(atPath: dst.path) else { continue }

            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if rv?.isDirectory == true {
                dirPairs.append((src: u, dst: dst))
            } else if rv?.isRegularFile == true {
                filePairs.append((src: u, dst: dst))
            }
        }

        for pair in filePairs {
            syncFileSystemTimestamps(from: pair.src, to: pair.dst)
        }

        let sorted = dirPairs.sorted {
            $0.dst.standardizedFileURL.path.count > $1.dst.standardizedFileURL.path.count
        }
        for pair in sorted {
            syncFileSystemTimestamps(from: pair.src, to: pair.dst)
        }
    }

    nonisolated static func sampleTimestampMismatches(
        sourceDir: URL,
        destDir: URL,
        maxFiles: Int,
        maxDirs: Int,
        skippingPathPrefixes: [String] = []
    ) -> [String] {
        let fm = FileManager.default
        let srcRoot = sourceDir.standardizedFileURL
        let dstRoot = destDir.standardizedFileURL
        guard fm.fileExists(atPath: srcRoot.path), fm.fileExists(atPath: dstRoot.path) else { return [] }

        guard let en = fm.enumerator(
            at: srcRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let srcBasePath = srcRoot.path
        let dstBasePath = dstRoot.path
        let skipPrefixes = skippingPathPrefixes.map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        }

        func shouldSkip(_ url: URL) -> Bool {
            let p = url.standardizedFileURL.path
            for pref in skipPrefixes {
                if !pref.isEmpty, p.hasPrefix(pref) { return true }
            }
            if p.hasPrefix(dstBasePath) { return true }
            return false
        }

        var mismatches: [String] = []
        var fileCount = 0
        var dirCount = 0

        for case let u as URL in en {
            if shouldSkip(u) {
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    en.skipDescendants()
                }
                continue
            }

            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if rv?.isDirectory == true, dirCount >= maxDirs { continue }
            if rv?.isRegularFile == true, fileCount >= maxFiles { continue }

            let fullPath = u.standardizedFileURL.path
            guard fullPath.hasPrefix(srcBasePath) else { continue }

            var relPath = String(fullPath.dropFirst(srcBasePath.count))
            if relPath.hasPrefix("/") { relPath.removeFirst() }
            if relPath.isEmpty { continue }

            let dst = dstRoot.appendingPathComponent(relPath)
            guard fm.fileExists(atPath: dst.path) else { continue }

            let srcAttrs = try? fm.attributesOfItem(atPath: u.path)
            let dstAttrs = try? fm.attributesOfItem(atPath: dst.path)
            if !timestampsMatch(srcAttrs, dstAttrs) {
                mismatches.append(relPath)
            }

            if rv?.isDirectory == true { dirCount += 1 }
            if rv?.isRegularFile == true { fileCount += 1 }

            if fileCount >= maxFiles && dirCount >= maxDirs { break }
        }

        return mismatches
    }

    nonisolated private static func copyDirectoryPreservingStructure(
        from sourceDir: URL,
        to destDir: URL,
        skippingPathPrefixes: [String]
    ) throws {
        let fm = FileManager.default

        // Ensure destination exists.
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // We MUST apply directory timestamps only AFTER all children have been copied.
        // Otherwise, creating/copying files will update the directory modification date again.
        var dirPairs: [(src: URL, dst: URL)] = []
        dirPairs.append((src: sourceDir, dst: destDir))
        var filePairs: [(src: URL, dst: URL)] = []

        // Enumerate everything under the source directory.
        guard let en = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        let srcBasePath = sourceDir.standardizedFileURL.path
        let dstBasePath = destDir.standardizedFileURL.path

        func shouldSkip(_ url: URL) -> Bool {
            let p = url.standardizedFileURL.path

            // Skip if the enumerated path is under any excluded prefix (prevents copying the output into itself).
            for pref in skippingPathPrefixes {
                if !pref.isEmpty, p.hasPrefix(pref) { return true }
            }

            // Also skip if this is inside the destination itself (extra safety).
            if p.hasPrefix(dstBasePath) { return true }

            return false
        }

        for case let u as URL in en {
            try Task.checkCancellation()
            if shouldSkip(u) {
                // If this is a directory, skip its descendants to prevent deep recursion.
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    en.skipDescendants()
                }
                continue
            }

            // Compute relative path from sourceDir.
            let fullPath = u.standardizedFileURL.path
            guard fullPath.hasPrefix(srcBasePath) else { continue }

            var relPath = String(fullPath.dropFirst(srcBasePath.count))
            if relPath.hasPrefix("/") { relPath.removeFirst() }
            if relPath.isEmpty { continue }

            let dst = destDir.appendingPathComponent(relPath)

            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if rv?.isDirectory == true {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                dirPairs.append((src: u, dst: dst))
            } else if rv?.isRegularFile == true {
                if fm.fileExists(atPath: dst.path) {
                    throw OutputCollisionError(url: dst)
                }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: u, to: dst)
                filePairs.append((src: u, dst: dst))
            }
        }

        // Apply file timestamps at the end to avoid any later touches.
        for pair in filePairs {
            try Task.checkCancellation()
            syncFileSystemTimestamps(from: pair.src, to: pair.dst)
        }

        // Apply directory timestamps bottom-up (deepest paths first), root last.
        let sorted = dirPairs.sorted {
            $0.dst.standardizedFileURL.path.count > $1.dst.standardizedFileURL.path.count
        }
        for pair in sorted {
            try Task.checkCancellation()
            syncFileSystemTimestamps(from: pair.src, to: pair.dst)
        }
    }
    
    /// Copies a sibling .zip next to the WhatsApp export folder into the sorted export folder.
    /// WhatsApp exports are often shared as "<ExportFolder>.zip" alongside the extracted folder.
    /// Best-effort: if no reasonable zip is found, this is a no-op.
    nonisolated private static func copySiblingZipIfPresent(
        sourceDir: URL,
        destParentDir: URL,
        detectedPartnerRaw: String,
        overridePartnerRaw: String?,
        originalZipURL: URL? = nil
    ) throws {
        let fm = FileManager.default
        let debugEnabled = ProcessInfo.processInfo.environment["WET_SIDECAR_DEBUG"] == "1"

        let zipURL = originalZipURL ?? pickSiblingZipURL(sourceDir: sourceDir)
        guard let zipURL else { return }

        try ensureDirectory(destParentDir)

        let beforeBase = zipURL.deletingPathExtension().lastPathComponent
        let afterBase = applyPartnerOverrideToName(
            originalName: beforeBase,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw
        )
        let destName = "\(afterBase).zip"
        if debugEnabled {
            print("WET-DBG: SIDECAR ZIP NAME BEFORE: \"\(zipURL.lastPathComponent)\"")
            print("WET-DBG: SIDECAR ZIP NAME AFTER: \"\(destName)\"")
        }

        let dest = destParentDir.appendingPathComponent(destName)
        if fm.fileExists(atPath: dest.path) {
            throw OutputCollisionError(url: dest)
        }

        do {
            try fm.copyItem(at: zipURL, to: dest)
            syncFileSystemTimestamps(from: zipURL, to: dest)
        } catch {
            // best-effort: ignore copy errors
        }
    }

    nonisolated static func resolvedSidecarZipName(
        sourceDir: URL,
        detectedPartnerRaw: String,
        overridePartnerRaw: String?,
        originalZipURL: URL? = nil
    ) -> (before: String, after: String)? {
        let zipURL = originalZipURL ?? pickSiblingZipURL(sourceDir: sourceDir)
        guard let zipURL else { return nil }
        let before = zipURL.lastPathComponent
        let base = zipURL.deletingPathExtension().lastPathComponent
        let afterBase = applyPartnerOverrideToName(
            originalName: base,
            detectedPartnerRaw: detectedPartnerRaw,
            overridePartnerRaw: overridePartnerRaw
        )
        let ext = zipURL.pathExtension
        let after = ext.isEmpty ? afterBase : "\(afterBase).\(ext)"
        return (before, after)
    }

    private nonisolated static func pickSiblingZipURL(sourceDir: URL) -> URL? {
        let fm = FileManager.default
        let parent = sourceDir.deletingLastPathComponent()
        let folderName = sourceDir.lastPathComponent.lowercased()

        let candidates: [URL]
        do {
            let items = try fm.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            candidates = items
                .filter { $0.pathExtension.lowercased() == "zip" }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return nil
        }

        if candidates.isEmpty { return nil }

        return candidates.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == folderName })
            ?? candidates.first(where: { $0.lastPathComponent.lowercased().contains(folderName) })
            ?? candidates.first(where: { $0.lastPathComponent.lowercased().contains("whatsapp") })
            ?? candidates.first
    }

    private nonisolated static func filesEqual(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path) else { return false }

        guard
            let attrsA = try? fm.attributesOfItem(atPath: a.path),
            let attrsB = try? fm.attributesOfItem(atPath: b.path),
            let sizeA = attrsA[.size] as? NSNumber,
            let sizeB = attrsB[.size] as? NSNumber
        else {
            return false
        }

        if sizeA.uint64Value != sizeB.uint64Value { return false }
        if sizeA.uint64Value == 0 { return true }
        if let mA = attrsA[.modificationDate] as? Date,
           let mB = attrsB[.modificationDate] as? Date,
           datesMatch(mA, mB) {
            return true
        }

        do {
            let fhA = try FileHandle(forReadingFrom: a)
            let fhB = try FileHandle(forReadingFrom: b)
            defer {
                try? fhA.close()
                try? fhB.close()
            }

            let chunkSize = 1_048_576
            while true {
                let dataA = try fhA.read(upToCount: chunkSize) ?? Data()
                let dataB = try fhB.read(upToCount: chunkSize) ?? Data()
                if dataA != dataB { return false }
                if dataA.isEmpty { break }
            }
        } catch {
            return false
        }

        return true
    }

    private nonisolated static func listRegularFiles(in root: URL) -> [String: URL]? {
        let fm = FileManager.default
        let base = root.standardizedFileURL
        guard fm.fileExists(atPath: base.path) else { return nil }

        guard let en = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var out: [String: URL] = [:]
        for case let u as URL in en {
            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if rv?.isDirectory == true { continue }
            if rv?.isRegularFile != true { continue }

            let fullPath = u.standardizedFileURL.path
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard fullPath.hasPrefix(basePath) else { continue }

            var rel = String(fullPath.dropFirst(basePath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.isEmpty { continue }

            out[rel] = u
        }

        return out
    }

    private nonisolated static func directoriesEqual(src: URL, dst: URL) -> Bool {
        guard let srcFiles = listRegularFiles(in: src) else { return false }
        guard let dstFiles = listRegularFiles(in: dst) else { return false }

        if srcFiles.count != dstFiles.count { return false }

        for (rel, srcURL) in srcFiles {
            guard let dstURL = dstFiles[rel] else { return false }
            if !filesEqual(srcURL, dstURL) { return false }
        }

        return true
    }
    
    private static func withHTMLSuffix(_ htmlURL: URL, suffix: String) -> URL {
        let ext = htmlURL.pathExtension
        let base = htmlURL.deletingPathExtension().lastPathComponent
        let dir = htmlURL.deletingLastPathComponent()
        let newName = base + suffix + "." + ext
        return dir.appendingPathComponent(newName, isDirectory: false)
    }
}
