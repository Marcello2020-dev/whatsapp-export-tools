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

#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif

#if canImport(LinkPresentation)
@preconcurrency import LinkPresentation
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

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

public enum WAExportError: Error, LocalizedError {
    case outputAlreadyExists(urls: [URL])

    public var errorDescription: String? {
        switch self {
        case .outputAlreadyExists(let urls):
            if urls.isEmpty { return "Output files already exist." }
            if urls.count == 1 { return "Output file already exists: \(urls[0].lastPathComponent)" }
            return "Output files already exist: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))"
        }
    }
}

struct SidecarValidationError: Error, LocalizedError, Sendable {
    let duplicateFolders: [String]

    var errorDescription: String? {
        "Sidecar enthält doppelte Ordner: \(duplicateFolders.joined(separator: ", "))"
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

    // Date formatters (stable)
    nonisolated private static let isoDTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    nonisolated private static let exportDTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    // File-name friendly stamps (Finder style): dots in dates, no seconds, no colon.
    nonisolated private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        // No seconds; avoid ':' in filenames.
        f.dateFormat = "yyyy.MM.dd HH.mm"
        return f
    }()

    nonisolated private static let fileDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

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

    nonisolated private static let attachmentIndexLock = NSLock()
    nonisolated(unsafe) private static var attachmentIndexCache: [String: [String: URL]] = [:]

    nonisolated static func resetAttachmentIndexCache() {
        attachmentIndexLock.lock()
        attachmentIndexCache.removeAll(keepingCapacity: true)
        attachmentIndexLock.unlock()
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
    // Public API
    // ---------------------------

    /// Returns unique participant names detected in the chat export (excluding obvious system markers).
    /// Used by the GUI to ask the user who "me" is when --me is not provided.
    public static func participants(chatURL: URL) throws -> [String] {

        let chatPath = chatURL.standardizedFileURL
        let msgs = try parseMessages(chatPath)

        // Preserve first-seen order
        var uniq: [String] = []
        for m in msgs {
            let a = normalizedParticipantIdentifier(m.author)
            if a.isEmpty { continue }
            if isSystemAuthor(a) { continue }
            if !uniq.contains(a) { uniq.append(a) }
        }

        let filtered = uniq.filter { !isSystemAuthor($0) }
        return filtered.isEmpty ? uniq : filtered
    }

    /// Best-effort detection of the exporter ("Ich"-Perspektive) from the chat text.
    /// Returns nil if no reliable signal is found.
    public static func detectMeName(chatURL: URL) throws -> String? {
        let chatPath = chatURL.standardizedFileURL
        let msgs = try parseMessages(chatPath)
        return inferMeName(messages: msgs)
    }

    /// Compare the original WhatsApp export folder (and sibling zip, if present) with the sidecar copies.
    /// Returns which originals are byte-identical and can be safely deleted.
    public nonisolated static func verifySidecarCopies(
        originalExportDir: URL,
        sidecarBaseDir: URL
    ) -> SidecarVerificationResult {
        let originalDir = originalExportDir.standardizedFileURL
        let baseDir = sidecarBaseDir.standardizedFileURL
        let copiedDir = baseDir.appendingPathComponent(originalDir.lastPathComponent, isDirectory: true)

        let exportDirMatches = directoriesEqual(src: originalDir, dst: copiedDir)

        let originalZip = pickSiblingZipURL(sourceDir: originalDir)
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

        let authors = msgs.map { $0.author }.filter { !_normSpace($0).isEmpty }
        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                // If the UI selected a phone-number identity, map it to the overridden display name (if provided),
                // otherwise normalize its representation.
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        // Use the chat export file's creation date/time for the filename stamp.
        // (The HTML header continues to use the file mtime as the export timestamp.)
        let chatFileAttrs = (try? FileManager.default.attributesOfItem(atPath: chatPath.path)) ?? [:]
        let chatCreatedAt = (chatFileAttrs[.creationDate] as? Date)
            ?? (chatFileAttrs[.modificationDate] as? Date)
            ?? Date()

        // Output filename parts (Finder-friendly, human-readable)
        let uniqAuthors = Array(Set(authors.map { _normSpace($0) }))
            .filter { !$0.isEmpty && !isSystemAuthor($0) }
            .sorted()

        let meNorm = _normSpace(meName).lowercased()
        let partners = uniqAuthors.filter { _normSpace($0).lowercased() != meNorm }

        // File-name conversation label should include BOTH chat partners (me + others).
        // For group chats, include up to 3 others and append a “+N weitere” suffix.
        let convoPart: String = {
            if partners.isEmpty {
                return "\(meName) ↔ Unbekannt"
            }
            if partners.count == 1 {
                return "\(meName) ↔ \(partners[0])"
            }
            if partners.count <= 3 {
                return "\(meName) ↔ \(partners.joined(separator: ", "))"
            }
            return "\(meName) ↔ \(partners.prefix(3).joined(separator: ", ")) +\(partners.count - 3) weitere"
        }()

        let periodPart: String = {
            guard let minD = msgs.min(by: { $0.ts < $1.ts })?.ts,
                  let maxD = msgs.max(by: { $0.ts < $1.ts })?.ts else {
                return "Keine Nachrichten"
            }
            let start = fileDateOnlyFormatter.string(from: minD)
            let end = fileDateOnlyFormatter.string(from: maxD)
            return "\(start) bis \(end)"
        }()

        let createdStamp = fileStampFormatter.string(from: chatCreatedAt)

        let baseRaw = "WhatsApp Chat · \(convoPart) · \(periodPart) · Chat.txt erstellt \(createdStamp)"
        let base = safeFinderFilename(baseRaw)

        let fm = FileManager.default
        try fm.createDirectory(at: outPath, withIntermediateDirectories: true)
        try cleanupTemporaryExportFolders(in: outPath)

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

        let stagingDir = try createStagingDirectory(in: outPath)
        var didRemoveStaging = false
        defer {
            if !didRemoveStaging {
                try? fm.removeItem(at: stagingDir)
            }
            try? cleanupTemporaryExportFolders(in: outPath)
        }

        let stagedHTML = stagingDir.appendingPathComponent("\(base).html")
        let stagedMD = stagingDir.appendingPathComponent("\(base).md")
        let stagedSidecarHTML = stagingDir.appendingPathComponent("\(base)-sdc.html")
        let stagedSidecarDir = stagingDir.appendingPathComponent(base, isDirectory: true)

        try await renderHTML(
            msgs: msgs,
            chatURL: chatPath,
            outHTML: stagedHTML,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly,
            perfLabel: "HTML"
        )

        try renderMD(
            msgs: msgs,
            chatURL: chatPath,
            outMD: stagedMD,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly
        )

        var didSidecar = false
        if exportSortedAttachments {
            let sidecarOriginalDir = try exportSortedAttachmentsFolder(
                chatURL: chatPath,
                messages: msgs,
                outDir: stagingDir,
                folderName: base
            )
            let sidecarBaseDir = sidecarOriginalDir.deletingLastPathComponent()

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

        if allowOverwrite {
            let deleteTargets = [outHTML, outMD, sidecarHTML, sortedFolderURL]
                + HTMLVariant.allCases.map { outPath.appendingPathComponent("\(base)\($0.filenameSuffix).html") }
            for u in deleteTargets where fm.fileExists(atPath: u.path) {
                try fm.removeItem(at: u)
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
                if !allowOverwrite, fm.fileExists(atPath: dst.path) {
                    throw OutputCollisionError(url: dst)
                }
                try fm.moveItem(at: src, to: dst)
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

        let authors = msgs.map { $0.author }.filter { !_normSpace($0).isEmpty }
        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        let chatFileAttrs = (try? FileManager.default.attributesOfItem(atPath: chatPath.path)) ?? [:]
        let chatCreatedAt = (chatFileAttrs[.creationDate] as? Date)
            ?? (chatFileAttrs[.modificationDate] as? Date)
            ?? Date()

        let uniqAuthors = Array(Set(authors.map { _normSpace($0) }))
            .filter { !$0.isEmpty && !isSystemAuthor($0) }
            .sorted()

        let meNorm = _normSpace(meName).lowercased()
        let partners = uniqAuthors.filter { _normSpace($0).lowercased() != meNorm }

        let convoPart: String = {
            if partners.isEmpty {
                return "\(meName) ↔ Unbekannt"
            }
            if partners.count == 1 {
                return "\(meName) ↔ \(partners[0])"
            }
            if partners.count <= 3 {
                return "\(meName) ↔ \(partners.joined(separator: ", "))"
            }
            return "\(meName) ↔ \(partners.prefix(3).joined(separator: ", ")) +\(partners.count - 3) weitere"
        }()

        let periodPart: String = {
            guard let minD = msgs.min(by: { $0.ts < $1.ts })?.ts,
                  let maxD = msgs.max(by: { $0.ts < $1.ts })?.ts else {
                return "Keine Nachrichten"
            }
            let start = fileDateOnlyFormatter.string(from: minD)
            let end = fileDateOnlyFormatter.string(from: maxD)
            return "\(start) bis \(end)"
        }()

        let createdStamp = fileStampFormatter.string(from: chatCreatedAt)
        let baseRaw = "WhatsApp Chat · \(convoPart) · \(periodPart) · Chat.txt erstellt \(createdStamp)"
        return safeFinderFilename(baseRaw)
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

        let authors = msgs.map { $0.author }.filter { !_normSpace($0).isEmpty }
        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        let chatFileAttrs = (try? FileManager.default.attributesOfItem(atPath: chatPath.path)) ?? [:]
        let chatCreatedAt = (chatFileAttrs[.creationDate] as? Date)
            ?? (chatFileAttrs[.modificationDate] as? Date)
            ?? Date()

        let uniqAuthors = Array(Set(authors.map { _normSpace($0) }))
            .filter { !$0.isEmpty && !isSystemAuthor($0) }
            .sorted()

        let meNorm = _normSpace(meName).lowercased()
        let partners = uniqAuthors.filter { _normSpace($0).lowercased() != meNorm }

        let convoPart: String = {
            if partners.isEmpty {
                return "\(meName) ↔ Unbekannt"
            }
            if partners.count == 1 {
                return "\(meName) ↔ \(partners[0])"
            }
            if partners.count <= 3 {
                return "\(meName) ↔ \(partners.joined(separator: ", "))"
            }
            return "\(meName) ↔ \(partners.prefix(3).joined(separator: ", ")) +\(partners.count - 3) weitere"
        }()

        let periodPart: String = {
            guard let minD = msgs.min(by: { $0.ts < $1.ts })?.ts,
                  let maxD = msgs.max(by: { $0.ts < $1.ts })?.ts else {
                return "Keine Nachrichten"
            }
            let start = fileDateOnlyFormatter.string(from: minD)
            let end = fileDateOnlyFormatter.string(from: maxD)
            return "\(start) bis \(end)"
        }()

        let createdStamp = fileStampFormatter.string(from: chatCreatedAt)
        let baseRaw = "WhatsApp Chat · \(convoPart) · \(periodPart) · Chat.txt erstellt \(createdStamp)"
        let base = safeFinderFilename(baseRaw)

        return PreparedExport(messages: msgs, meName: meName, baseName: base, chatURL: chatPath)
    }

    nonisolated static func renderHTMLPrepared(
        prepared: PreparedExport,
        outDir: URL,
        fileSuffix: String,
        enablePreviews: Bool,
        embedAttachments: Bool,
        embedAttachmentThumbnailsOnly: Bool,
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
            perfLabel: perfLabel
        )

        return outHTML
    }

    nonisolated static func renderMarkdown(
        prepared: PreparedExport,
        outDir: URL
    ) throws -> URL {
        resetStagedAttachmentCache()

        let outPath = outDir.standardizedFileURL
        let outMD = outPath.appendingPathComponent("\(prepared.baseName).md")

        try renderMD(
            msgs: prepared.messages,
            chatURL: prepared.chatURL,
            outMD: outMD,
            meName: prepared.meName,
            enablePreviews: true,
            embedAttachments: false,
            embedAttachmentThumbnailsOnly: false
        )

        return outMD
    }

    nonisolated static func renderSidecar(
        prepared: PreparedExport,
        outDir: URL
    ) async throws -> URL {
        resetStagedAttachmentCache()

        let outPath = outDir.standardizedFileURL
        let sidecarOriginalDir = try exportSortedAttachmentsFolder(
            chatURL: prepared.chatURL,
            messages: prepared.messages,
            outDir: outPath,
            folderName: prepared.baseName
        )
        let sidecarBaseDir = sidecarOriginalDir.deletingLastPathComponent()

        let sidecarChatURL = sidecarOriginalDir.appendingPathComponent(prepared.chatURL.lastPathComponent)
        let sidecarHTML = outPath.appendingPathComponent("\(prepared.baseName)-sdc.html")

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
            perfLabel: "Sidecar"
        )

        return sidecarHTML
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

        let authors = msgs.map { $0.author }.filter { !_normSpace($0).isEmpty }

        let meName = {
            let oRaw = _normSpace(meNameOverride ?? "")
            if !oRaw.isEmpty {
                return applyParticipantOverride(oRaw, lookup: participantLookup)
            }
            return chooseMeName(messages: msgs)
        }()

        // Use creation date for filename stamp
        let chatFileAttrs = (try? FileManager.default.attributesOfItem(atPath: chatPath.path)) ?? [:]
        let chatCreatedAt = (chatFileAttrs[.creationDate] as? Date)
            ?? (chatFileAttrs[.modificationDate] as? Date)
            ?? Date()

        // Build filename parts (wie in export(...))
        let uniqAuthors = Array(Set(authors.map { _normSpace($0) }))
            .filter { !$0.isEmpty && !isSystemAuthor($0) }
            .sorted()

        let meNorm = _normSpace(meName).lowercased()
        let partners = uniqAuthors.filter { _normSpace($0).lowercased() != meNorm }

        let convoPart: String = {
            if partners.isEmpty {
                return "\(meName) ↔ Unbekannt"
            }
            if partners.count == 1 {
                return "\(meName) ↔ \(partners[0])"
            }
            if partners.count <= 3 {
                return "\(meName) ↔ \(partners.joined(separator: ", "))"
            }
            return "\(meName) ↔ \(partners.prefix(3).joined(separator: ", ")) +\(partners.count - 3) weitere"
        }()

        let periodPart: String = {
            guard let minD = msgs.min(by: { $0.ts < $1.ts })?.ts,
                  let maxD = msgs.max(by: { $0.ts < $1.ts })?.ts else {
                return "Keine Nachrichten"
            }
            let start = fileDateOnlyFormatter.string(from: minD)
            let end = fileDateOnlyFormatter.string(from: maxD)
            return "\(start) bis \(end)"
        }()

        let createdStamp = fileStampFormatter.string(from: chatCreatedAt)

        let baseRaw = "WhatsApp Chat · \(convoPart) · \(periodPart) · Chat.txt erstellt \(createdStamp)"
        let base = safeFinderFilename(baseRaw)

        let fm = FileManager.default
        try fm.createDirectory(at: outPath, withIntermediateDirectories: true)
        try cleanupTemporaryExportFolders(in: outPath)

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

        let stagingDir = try createStagingDirectory(in: outPath)
        var didRemoveStaging = false
        defer {
            if !didRemoveStaging {
                try? fm.removeItem(at: stagingDir)
            }
            try? cleanupTemporaryExportFolders(in: outPath)
        }

        var stagedHTMLByVariant: [HTMLVariant: URL] = [:]
        stagedHTMLByVariant.reserveCapacity(variants.count)
        for v in variants {
            stagedHTMLByVariant[v] = stagingDir.appendingPathComponent("\(base)\(v.filenameSuffix).html")
        }
        let stagedMD = stagingDir.appendingPathComponent("\(base).md")
        let stagedSidecarHTML = stagingDir.appendingPathComponent("\(base)-sdc.html")
        let stagedSidecarDir = stagingDir.appendingPathComponent(base, isDirectory: true)

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
                perfLabel: v.perfLabel
            )
        }

        // Render one Markdown (portable)
        try renderMD(
            msgs: msgs,
            chatURL: chatPath,
            outMD: stagedMD,
            meName: meName,
            enablePreviews: true,
            embedAttachments: false,
            embedAttachmentThumbnailsOnly: false
        )

        var didSidecar = false
        if exportSortedAttachments {
            let sidecarOriginalDir = try exportSortedAttachmentsFolder(
                chatURL: chatPath,
                messages: msgs,
                outDir: stagingDir,
                folderName: base
            )
            let sidecarBaseDir = sidecarOriginalDir.deletingLastPathComponent()

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

        if allowOverwrite {
            let deleteTargets = [outMD, sidecarHTML, sortedFolderURL]
                + HTMLVariant.allCases.map { outPath.appendingPathComponent("\(base)\($0.filenameSuffix).html") }
            for u in deleteTargets where fm.fileExists(atPath: u.path) {
                try fm.removeItem(at: u)
            }
        }

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

        var moved: [URL] = []
        do {
            for (src, dst) in moveItems {
                if !allowOverwrite, fm.fileExists(atPath: dst.path) {
                    throw OutputCollisionError(url: dst)
                }
                try fm.moveItem(at: src, to: dst)
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
            if !trimmed.isEmpty {
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
            return r.location == 0 && r.length == ns.length
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
        // Disallowed on macOS: "/" and ":".
        var x = s
            .replacingOccurrences(of: "/", with: " ")
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

    nonisolated private static func isoDateOnly(_ d: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: d)
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
        return Calendar(identifier: .gregorian).date(from: dc)
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

    // Parse WhatsApp export lines into message records.
    nonisolated private static func parseMessages(_ chatURL: URL) throws -> [WAMessage] {
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

        let raw = s.components(separatedBy: .newlines)

        var msgs: [WAMessage] = []
        var lastIndex: Int? = nil

        for origLine in raw {
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

    // ---------------------------
    // Sorted attachments folder (standalone export)
    // ---------------------------

    private enum SortedAttachmentBucket: String {
        case images
        case videos
        case audios
        case documents
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

    nonisolated private static func attachmentIndex(for sourceDir: URL) -> [String: URL] {
        let fm = FileManager.default
        let base = sourceDir.standardizedFileURL
        let key = base.path

        attachmentIndexLock.lock()
        if let cached = attachmentIndexCache[key] {
            attachmentIndexLock.unlock()
            return cached
        }
        attachmentIndexLock.unlock()

        let buildStart = ProcessInfo.processInfo.systemUptime
        var index: [String: URL] = [:]
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
                if index[name] == nil {
                    index[name] = u
                }
            }
        }
        let buildDuration = ProcessInfo.processInfo.systemUptime - buildStart
        recordAttachmentIndexBuild(duration: buildDuration, fileCount: fileCount)

        attachmentIndexLock.lock()
        attachmentIndexCache[key] = index
        attachmentIndexLock.unlock()

        return index
    }

    nonisolated private static func resolveAttachmentURL(fileName: String, sourceDir: URL) -> URL? {
        let fm = FileManager.default

        // 1) Most common: attachment is next to the chat.txt
        let direct = sourceDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) { return direct }

        // 2) Common alternative: inside a "Media" folder
        let media = sourceDir.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(fileName)
        if fm.fileExists(atPath: media.path) { return media }

        // 3) Last resort: resolve via cached index (avoids per-attachment recursion).
        let index = attachmentIndex(for: sourceDir)
        if let hit = index[fileName], fm.fileExists(atPath: hit.path) {
            return hit
        }

        return nil
    }

    nonisolated private static func exportSortedAttachmentsFolder(
        chatURL: URL,
        messages: [WAMessage],
        outDir: URL,
        folderName: String
    ) throws -> URL {
        let fm = FileManager.default

        let baseFolderURL = outDir.appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: baseFolderURL.path) {
            throw OutputCollisionError(url: baseFolderURL)
        }
        try fm.createDirectory(at: baseFolderURL, withIntermediateDirectories: true)

        // Additionally copy the original WhatsApp export folder (the folder that contains chat.txt)
        // into the sorted attachments folder, preserving the original folder name.
        // Example: <out>/<folderName>/<OriginalExportFolderName>/chat.txt
        let sourceDir = chatURL.deletingLastPathComponent().standardizedFileURL
        let originalFolderName = sourceDir.lastPathComponent
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
            destParentDir: baseFolderURL
        )

        let imagesDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.images.rawValue, isDirectory: true)
        let videosDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.videos.rawValue, isDirectory: true)
        let audiosDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.audios.rawValue, isDirectory: true)
        let docsDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.documents.rawValue, isDirectory: true)

        // Build: filename -> earliest timestamp
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

        // If there are no attachments, keep the bucket folders absent.
        if earliestDateByFile.isEmpty { return originalCopyDir }

        var ensuredBuckets = Set<SortedAttachmentBucket>()
        var bucketsWithContent = Set<SortedAttachmentBucket>()

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        // Filename prefix: YYYY MM DD HH MM SS (spaces, no dashes)
        df.dateFormat = "yyyy MM dd HH mm ss"

        let chatSourceDir = chatURL.deletingLastPathComponent()

        for (fn, ts) in earliestDateByFile.sorted(by: { $0.key < $1.key }) {
            guard let src = resolveAttachmentURL(fileName: fn, sourceDir: chatSourceDir) else {
                continue
            }

            let bucket = bucketForExtension(src.pathExtension)
            let dstFolder: URL = {
                switch bucket {
                case .images: return imagesDir
                case .videos: return videosDir
                case .audios: return audiosDir
                case .documents: return docsDir
                }
            }()

            if ensuredBuckets.insert(bucket).inserted {
                try fm.createDirectory(at: dstFolder, withIntermediateDirectories: true)
            }

            let prefix = df.string(from: ts)
            let dstName = "\(prefix) \(fn)"
            let dst = dstFolder.appendingPathComponent(dstName)
            if fm.fileExists(atPath: dst.path) {
                throw OutputCollisionError(url: dst)
            }

            do {
                try fm.copyItem(at: src, to: dst)
                syncFileSystemTimestamps(from: src, to: dst)
                bucketsWithContent.insert(bucket)
            } catch {
                // keep export resilient
            }
        }

        let bucketDirs: [SortedAttachmentBucket: URL] = [
            .images: imagesDir,
            .videos: videosDir,
            .audios: audiosDir,
            .documents: docsDir
        ]
        for bucket in ensuredBuckets where !bucketsWithContent.contains(bucket) {
            if let dir = bucketDirs[bucket], isDirectoryEmpty(dir) {
                try? fm.removeItem(at: dir)
            }
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
            do {
                try ensureDirectory(previewsDir)
                try decoded.data.write(to: dest, options: .atomic)
            } catch {
                return nil
            }
        }

        return relativeHref(for: dest, relativeTo: baseDir)
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
    // Attachment previews (PDF/DOCX thumbnails via Quick Look)
    // ---------------------------

#if canImport(QuickLookThumbnailing)
nonisolated private static func thumbnailPNGDataURL(for fileURL: URL, maxPixel: CGFloat = 900) async -> String? {
    let src = fileURL.standardizedFileURL
    let key = "\(src.path)||\(maxPixel)"
    if let cached = thumbnailPNGCacheGet(key) {
        recordThumbPNG(duration: 0, cacheHit: true)
        return cached
    }

    let start = ProcessInfo.processInfo.systemUptime
    let size = CGSize(width: maxPixel, height: maxPixel)
    #if canImport(AppKit)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    #elseif canImport(UIKit)
        let scale = UIScreen.main.scale
    #else
        let scale: CGFloat = 2.0
    #endif

    let req = QLThumbnailGenerator.Request(
        fileAt: fileURL,
        size: size,
        scale: scale,
        representationTypes: .thumbnail
    )

    let dataURL: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
            guard err == nil, let rep else {
                cont.resume(returning: nil)
                return
            }

            let cg = rep.cgImage

            #if canImport(AppKit)
            let nsImage = NSImage(cgImage: cg, size: size)
            guard
                let tiff = nsImage.tiffRepresentation,
                let bmp = NSBitmapImageRep(data: tiff),
                let png = bmp.representation(using: .png, properties: [:])
            else {
                cont.resume(returning: nil)
                return
            }
            cont.resume(returning: "data:image/png;base64,\(png.base64EncodedString())")

            #elseif canImport(UIKit)
            let uiImage = UIImage(cgImage: cg)
            guard let png = uiImage.pngData() else {
                cont.resume(returning: nil)
                return
            }
            cont.resume(returning: "data:image/png;base64,\(png.base64EncodedString())")

            #else
            cont.resume(returning: nil)
            #endif
        }
    }

    let elapsed = ProcessInfo.processInfo.systemUptime - start
    recordThumbPNG(duration: elapsed, cacheHit: false)

    if let dataURL {
        thumbnailPNGCacheSet(key, dataURL)
    }

    return dataURL
}
#endif

#if canImport(QuickLookThumbnailing)
nonisolated private static func thumbnailJPEGData(for fileURL: URL, maxPixel: CGFloat = 900, quality: CGFloat = 0.72) async -> Data? {
    let src = fileURL.standardizedFileURL
    let key = "\(src.path)||\(maxPixel)||\(quality)"
    if let cached = thumbnailJPEGCacheGet(key) {
        recordThumbJPEG(duration: 0, cacheHit: true)
        return cached
    }

    let start = ProcessInfo.processInfo.systemUptime
    let size = CGSize(width: maxPixel, height: maxPixel)
    #if canImport(AppKit)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    #elseif canImport(UIKit)
        let scale = UIScreen.main.scale
    #else
        let scale: CGFloat = 2.0
    #endif

    let req = QLThumbnailGenerator.Request(
        fileAt: fileURL,
        size: size,
        scale: scale,
        representationTypes: .thumbnail
    )

    let data: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
            guard err == nil, let rep else {
                cont.resume(returning: nil)
                return
            }

            let cg = rep.cgImage

            #if canImport(AppKit)
            let nsImage = NSImage(cgImage: cg, size: size)
            guard
                let tiff = nsImage.tiffRepresentation,
                let bmp = NSBitmapImageRep(data: tiff),
                let jpg = bmp.representation(using: .jpeg, properties: [.compressionFactor: quality])
            else {
                cont.resume(returning: nil)
                return
            }
            cont.resume(returning: jpg)

            #elseif canImport(UIKit)
            let uiImage = UIImage(cgImage: cg)
            cont.resume(returning: uiImage.jpegData(compressionQuality: quality))

            #else
            cont.resume(returning: nil)
            #endif
        }
    }

    let elapsed = ProcessInfo.processInfo.systemUptime - start
    recordThumbJPEG(duration: elapsed, cacheHit: false)

    if let data {
        thumbnailJPEGCacheSet(key, data)
    }

    return data
}
#endif

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
        let baseName = src.deletingPathExtension().lastPathComponent
        let dest = thumbsDir.appendingPathComponent(baseName).appendingPathExtension("jpg")

        // If a thumbnail already exists, reuse it.
        if fm.fileExists(atPath: dest.path) {
            return relativeHref(for: dest, relativeTo: baseDir)
        }

        #if canImport(QuickLookThumbnailing)
        if let jpg = await thumbnailJPEGData(for: src, maxPixel: 900, quality: 0.72) {
            try ensureDirectory(thumbsDir)
            try jpg.write(to: dest, options: .atomic)
            return relativeHref(for: dest, relativeTo: baseDir)
        }
        #endif

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

        #if canImport(QuickLookThumbnailing)
        if let jpg = await thumbnailJPEGData(for: src, maxPixel: 900, quality: 0.72) {
            dataURL = "data:image/jpeg;base64,\(jpg.base64EncodedString())"
        }
        #endif

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

        // PDF/DOCX/DOC/MP4/MOV/M4V: generate a thumbnail via Quick Look.
        if ["pdf","docx","doc","mp4","mov","m4v"].contains(ext) {
            #if canImport(QuickLookThumbnailing)
            return await thumbnailPNGDataURL(for: url)
            #else
            return nil
            #endif
        }

        return nil
    }

    nonisolated private static func attachmentThumbnailDataURL(_ url: URL) async -> String? {
        // Goal: always produce a lightweight thumbnail image (PNG) when possible.
        // - Images: prefer QuickLook thumbnail so we do not embed the full photo bytes.
        // - PDF/DOCX/Video: QuickLook thumbnail.
        // Fallback: for images only, embed the original if QuickLook is unavailable.
        let ext = url.pathExtension.lowercased()

        #if canImport(QuickLookThumbnailing)
        // QuickLook can thumbnail images too; this keeps the HTML small.
        if let thumb = await thumbnailPNGDataURL(for: url) {
            return thumb
        }
        #endif

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

    nonisolated private static func downloadImageAsDataURL(_ imgURL: String, timeout: TimeInterval = 15, maxBytes: Int = 2_500_000) async -> String? {
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

            return "data:\(mime);base64,\(data.base64EncodedString())"
        } catch {
            return nil
        }
    }

    nonisolated private static func buildPreview(_ url: String) async -> WAPreview? {
        if let cached = await previewCache.get(url) { return cached }

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
            await previewCache.set(url, prev)
            return prev
        }

        // YouTube special
        if let vid = youtubeVideoID(from: url) {
            let thumb = "https://img.youtube.com/vi/\(vid)/hqdefault.jpg"
            let imgData = await downloadImageAsDataURL(thumb)
            let prev = WAPreview(url: url, title: "YouTube", description: "", imageDataURL: imgData)
            await previewCache.set(url, prev)
            return prev
        }

        // Prefer native LinkPresentation when available (often provides a real preview image).
        #if canImport(LinkPresentation)
        if let lp = await buildPreviewViaLinkPresentation(url) {
            await previewCache.set(url, lp)
            return lp
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
                imgDataURL = await downloadImageAsDataURL(imgResolved)
            }

            let prev = WAPreview(url: url, title: title, description: desc, imageDataURL: imgDataURL)
            await previewCache.set(url, prev)
            return prev
        } catch {
            return nil
        }
    }

    // ---------------------------
    // Rendering helpers
    // ---------------------------

    nonisolated private static func weekdayIndexMonday0(_ date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let w = cal.component(.weekday, from: date) // Sunday=1 ... Saturday=7
        return (w + 5) % 7 // Monday=0 ... Sunday=6
    }

    nonisolated private static func fmtDateFull(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }

    nonisolated private static func fmtTime(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
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
                linkMatches.append(LinkMatch(range: r, kind: .bare))
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
        perfLabel: String? = nil
    ) async throws {

        let renderStart = ProcessInfo.processInfo.systemUptime

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

        // export time = file mtime
        let mtime: Date = (try? FileManager.default.attributesOfItem(atPath: chatURL.path)[.modificationDate] as? Date) ?? Date()

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
                     + "Export: \(htmlEscape(exportDTFormatter.string(from: mtime)))<br>"
                     + "Nachrichten: \(messageCount)</p>")
        parts.append("</div>")

        var lastDayKey: String? = nil
        let chatDir = chatURL.deletingLastPathComponent().standardizedFileURL
        let externalAssetsRoot = externalAssetsDir?.standardizedFileURL
        let externalThumbsDir = externalAssetsRoot?.appendingPathComponent("_thumbs", isDirectory: true)
        let externalPreviewsDir = externalAssetsRoot?.appendingPathComponent("_previews", isDirectory: true)

        var embedCounter = 0
        for m in msgs {
            let dayKey = isoDateOnly(m.ts)
            if lastDayKey != dayKey {
                let wd = weekdayDE[weekdayIndexMonday0(m.ts)] ?? ""
                parts.append("<div class='day'><span>\(htmlEscape("\(wd), \(fmtDateFull(m.ts))"))</span></div>")
                lastDayKey = dayKey
            }

            let authorRaw = _normSpace(m.author)
            let author = authorRaw.isEmpty ? "Unbekannt" : authorRaw

            let textRaw = m.text
            // Minimal mode (no attachments): only include attachments when we either embed full files
            // or explicitly render thumbnails-only.
            let shouldRenderAttachments = embedAttachments || embedAttachmentThumbnailsOnly || externalAttachments
            let attachments = shouldRenderAttachments ? findAttachments(textRaw) : []
            let textWoAttach = stripAttachmentMarkers(textRaw)
            let attachmentsAll = findAttachments(textRaw)

            let isSystemMsg = isSystemMessage(authorRaw: authorRaw, text: textWoAttach)

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
                    if let prev = await buildPreview(u) {
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

            // attachments: images embedded; PDFs/DOCX get a QuickLook thumbnail; otherwise show filename.
            // Make previews + filenames clickable to the local file (file://...) when it exists.
            var mediaBlocks: [String] = []
            for fn in attachments {
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

                    if let thumbDataURL = await inlineThumbnailDataURL(p) {
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
                        let poster = await attachmentPreviewDataURL(p)

                        if let fmData = try? Data(contentsOf: p) {
                            embedCounter += 1
                            let embedId = "wa-embed-\(embedCounter)"
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
                            let embedId = "wa-embed-\(embedCounter)"
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
                        let previewDataURL = await attachmentPreviewDataURL(p)
                        let fileData = try? Data(contentsOf: p)
                        if let previewDataURL, let fileData {
                            embedCounter += 1
                            let embedId = "wa-embed-\(embedCounter)"
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
                            let embedId = "wa-embed-\(embedCounter)"
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
                            let embedId = "wa-embed-\(embedCounter)"
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
                        let embedId = "wa-embed-\(embedCounter)"
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
                        if !disableThumbStaging, let thumbsDir = externalThumbsDir {
                            if let poster = await stageThumbnailForExport(source: p, thumbsDir: thumbsDir, relativeTo: attachmentRelBaseDir) {
                                posterAttr = " poster='\(htmlEscape(poster))'"
                            }
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
                        if !disableThumbStaging, let thumbsDir = externalThumbsDir {
                            thumbHref = await stageThumbnailForExport(source: p, thumbsDir: thumbsDir, relativeTo: attachmentRelBaseDir)
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
                    let poster = await attachmentPreviewDataURL(stagedURL ?? p) // Quick Look thumbnail when available

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

                if let dataURL = await attachmentPreviewDataURL(stagedURL ?? p) {
                    let isImage = ["jpg","jpeg","png","gif","webp","heic","heif"].contains(ext)

                    if let href {
                        mediaBlocks.append(
                            "<div class='media\(isImage ? " media-img" : "")'><a href='\(htmlEscape(href))' target='_blank' rel='noopener'><img alt='' src='\(dataURL)'></a></div>"
                        )
                        if !isImage {
                            mediaBlocks.append(
                                "<div class='fileline'>📎 <a href='\(htmlEscape(href))' target='_blank' rel='noopener'>\(htmlEscape(fn))</a></div>"
                            )
                        }
                    } else {
                        mediaBlocks.append("<div class='media\(isImage ? " media-img" : "")'><img alt='' src='\(dataURL)'></div>")
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

            parts.append("<div class='row \(rowCls)'>")
            let hasMedia = (!previewHTML.isEmpty) || (!mediaBlocks.isEmpty)
            let bubbleExtra = hasMedia ? " has-media" : ""
            parts.append("<div class='bubble \(bubCls)\(bubbleExtra)'>")
            if !isSystemMsg {
                parts.append("<div class='name'>\(htmlEscape(author))</div>")
            }
            if !textHTML.isEmpty { parts.append("<div class='text'>\(textHTML)</div>") }
            if !previewHTML.isEmpty { parts.append(previewHTML) }
            if !linkLines.isEmpty { parts.append(linkLines) }
            if !mediaBlocks.isEmpty { parts.append(contentsOf: mediaBlocks) }
            parts.append("<div class='meta'>\(htmlEscape(fmtTime(m.ts)))<br>\(htmlEscape(fmtDateFull(m.ts)))</div>")
            parts.append("</div></div>")
        }

        parts.append("</div></body></html>")
        let html = parts.joined()
        let renderDuration = ProcessInfo.processInfo.systemUptime - renderStart
        if let perfLabel {
            recordHTMLRender(label: perfLabel, duration: renderDuration)
        }

        let writeStart = ProcessInfo.processInfo.systemUptime
        try html.write(to: outHTML, atomically: true, encoding: .utf8)
        let writeDuration = ProcessInfo.processInfo.systemUptime - writeStart
        if let perfLabel {
            recordHTMLWrite(label: perfLabel, duration: writeDuration, bytes: html.utf8.count)
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
        embedAttachmentThumbnailsOnly: Bool
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

        let mtime: Date = (try? FileManager.default.attributesOfItem(atPath: chatURL.path)[.modificationDate] as? Date) ?? Date()

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
        out.append("- Export: \(exportDTFormatter.string(from: mtime))")
        out.append("- Nachrichten: \(messageCount)")
        out.append("")

        var lastDayKey: String? = nil
        let sourceDir = chatURL.deletingLastPathComponent().standardizedFileURL
        for m in msgs {
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

    nonisolated private static func isDirectoryEmpty(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return true
        }
        return contents.isEmpty
    }

    nonisolated static func cleanupTemporaryExportFolders(in dir: URL) throws {
        let fm = FileManager.default
        let base = dir.standardizedFileURL
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

    nonisolated private static func duplicateBaseNameIfNeeded(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastSpace = trimmed.lastIndex(of: " ") else { return nil }
        let suffix = trimmed[trimmed.index(after: lastSpace)...]
        guard let num = Int(suffix), num >= 2 else { return nil }
        let base = String(trimmed[..<lastSpace])
        return base.isEmpty ? nil : base
    }

    nonisolated static func validateSidecarLayout(sidecarBaseDir: URL) throws {
        let fm = FileManager.default
        let base = sidecarBaseDir.standardizedFileURL
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

        let knownBuckets = ["images", "videos", "audios", "documents", "_thumbs", "_previews"]
        for name in knownBuckets {
            if let url = dirURLs[name], isDirectoryEmpty(url) {
                try? fm.removeItem(at: url)
                dirURLs.removeValue(forKey: name)
            }
        }

        let dirNames = Set(dirURLs.keys)
        var duplicates: [String] = []
        for name in dirNames {
            guard let baseName = duplicateBaseNameIfNeeded(name) else { continue }
            guard dirNames.contains(baseName) else { continue }
            duplicates.append(name)
        }

        if !duplicates.isEmpty {
            throw SidecarValidationError(duplicateFolders: duplicates.sorted())
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

                // Ensure copied files carry original creation/modification timestamps.
                syncFileSystemTimestamps(from: u, to: dst)
                filePairs.append((src: u, dst: dst))
            }
        }

        // Re-apply file timestamps at the end to avoid any later touches.
        for pair in filePairs {
            syncFileSystemTimestamps(from: pair.src, to: pair.dst)
        }

        // Apply directory timestamps bottom-up (deepest paths first), root last.
        let sorted = dirPairs.sorted {
            $0.dst.standardizedFileURL.path.count > $1.dst.standardizedFileURL.path.count
        }
        for pair in sorted {
            syncFileSystemTimestamps(from: pair.src, to: pair.dst)
        }
    }
    
    /// Copies a sibling .zip next to the WhatsApp export folder into the sorted export folder.
    /// WhatsApp exports are often shared as "<ExportFolder>.zip" alongside the extracted folder.
    /// Best-effort: if no reasonable zip is found, this is a no-op.
    nonisolated private static func copySiblingZipIfPresent(
        sourceDir: URL,
        destParentDir: URL
    ) throws {
        let fm = FileManager.default

        guard let zipURL = pickSiblingZipURL(sourceDir: sourceDir) else { return }

        try ensureDirectory(destParentDir)

        let dest = destParentDir.appendingPathComponent(zipURL.lastPathComponent)
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
