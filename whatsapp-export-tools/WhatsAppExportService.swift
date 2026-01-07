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

// MARK: - Models (Python: @dataclass Message / Preview)

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

public enum HTMLVariant: String, CaseIterable, Hashable, Sendable {
    case embedAll        // größte Datei
    case thumbnailsOnly  // mittel
    case textOnly        // kleinste Datei

    public var filenameSuffix: String {
        switch self {
        case .embedAll: return "__max"
        case .thumbnailsOnly: return "__mid"
        case .textOnly: return "__min"
        }
    }

    // Vorgabe: Previews nur bei textOnly aus.
    public var enablePreviews: Bool {
        switch self {
        case .textOnly: return false
        case .embedAll, .thumbnailsOnly: return true
        }
    }

    public var embedAttachments: Bool {
        switch self {
        case .textOnly: return false
        case .embedAll, .thumbnailsOnly: return true
        }
    }

    public var embedAttachmentThumbnailsOnly: Bool {
        switch self {
        case .embedAll: return false
        case .thumbnailsOnly: return true
        case .textOnly: return false
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


// MARK: - Service

public enum WhatsAppExportService {

    // ---------------------------
    // Constants / Regex
    // ---------------------------

    private static let systemAuthor = "System"

    // Shared system markers (used for participant filtering, title building, and me-name selection)
    private static let systemMarkers: Set<String> = [
        "system",
        "whatsapp",
        "messages to this chat are now secured",
        "nachrichten und anrufe sind ende-zu-ende-verschlüsselt",
    ]

    private static func isSystemAuthor(_ name: String) -> Bool {
        let low = _normSpace(name).lowercased()
        if low.isEmpty { return true }
        if low == systemAuthor.lowercased() { return true }
        return systemMarkers.contains(low)
    }

    private static func isSystemMessage(authorRaw: String, text: String) -> Bool {
        // Prefer author-based detection.
        if isSystemAuthor(authorRaw) { return true }

        // Some exports put WhatsApp notices into the message body (or the author field may be empty/"Unbekannt").
        let lowText = _normSpace(text).lowercased()
        if lowText.isEmpty { return false }

        // Exact markers (when the whole line matches a known WhatsApp/system notice).
        if systemMarkers.contains(lowText) { return true }

        // Fuzzy markers (when the notice is longer / localized / contains extra words).
        let needles: [String] = [
            "ende-zu-ende-verschlüsselt",
            "end-to-end encrypted",
            "sicherheitsnummer",
            "security code",
            "hat sich geändert",
            "changed",
            " ist ein neuer kontakt",
            " is a new contact",
        ]
        return needles.contains(where: { lowText.contains($0) })
    }

    // Python:
    // _pat_iso = r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s+([^:]+?):\s*(.*)$"
    private static let patISO = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s+([^:]+?):\s*(.*)$"#,
        options: []
    )

    // Python:
    // _pat_de = r"^(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\s+-\s+([^:]+?):\s*(.*)$"
    private static let patDE = try! NSRegularExpression(
        pattern: #"^(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\s+-\s+([^:]+?):\s*(.*)$"#,
        options: []
    )

    // Python:
    // _pat_bracket = r"^\[(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\]\s+([^:]+?):\s*(.*)$"
    private static let patBracket = try! NSRegularExpression(
        pattern: #"^\[(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\]\s+([^:]+?):\s*(.*)$"#,
        options: []
    )

    // URLs
    // Python: _url_re = r"(https?://[^\s<>\]]+)"
    private static let urlRe = try! NSRegularExpression(
        pattern: #"(https?://[^\s<>\]]+)"#,
        options: [.caseInsensitive]
    )

    // Attachments
    // Python: _attach_re = r"<\s*Anhang:\s*([^>]+?)\s*>"
    private static let attachRe = try! NSRegularExpression(
        pattern: #"<\s*Anhang:\s*([^>]+?)\s*>"#,
        options: [.caseInsensitive]
    )

    // Link preview meta parsing (1:1 Regex-Ansatz)
    private static let metaTagRe = try! NSRegularExpression(
        pattern: #"<meta\s+[^>]*?>"#,
        options: [.caseInsensitive]
    )
    private static let metaAttrRe = try! NSRegularExpression(
        pattern: #"(\w+)\s*=\s*(".*?"|'.*?'|[^\s>]+)"#,
        options: []
    )
    private static let titleTagRe = try! NSRegularExpression(
        pattern: #"<title>(.*?)</title>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    // Weekday mapping (Python WEEKDAY_DE: Monday=0 ... Sunday=6)
    private static let weekdayDE: [Int: String] = [
        0: "Montag",
        1: "Dienstag",
        2: "Mittwoch",
        3: "Donnerstag",
        4: "Freitag",
        5: "Samstag",
        6: "Sonntag",
    ]

    // Date formatters (stable)
    private static let isoDTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let exportDTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    // File-name friendly stamps (Finder style): dots in dates, no seconds, no colon.
    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        // No seconds; avoid ':' in filenames.
        f.dateFormat = "yyyy.MM.dd HH.mm"
        return f
    }()

    private static let fileDateOnlyFormatter: DateFormatter = {
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

    private static let previewCache = PreviewCache()

    // Cache for staged attachments (source path -> (relHref, stagedURL)) to avoid duplicate copies.
    private static let stagedAttachmentLock = NSLock()
    private static var stagedAttachmentMap: [String: (relHref: String, stagedURL: URL)] = [:]
    
    private static func resetStagedAttachmentCache() {
        stagedAttachmentLock.lock()
        stagedAttachmentMap.removeAll(keepingCapacity: true)
        stagedAttachmentLock.unlock()
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

    /// 1:1-Export: parses chat, decides me-name, renders HTML+MD, writes files.
    /// Returns URLs of written HTML/MD.
    public static func export(
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
            return chooseMeName(authors: authors)
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

        let outHTML = outPath.appendingPathComponent("\(base).html")
        let outMD = outPath.appendingPathComponent("\(base).md")
        let sortedFolderURL = outPath.appendingPathComponent(base, isDirectory: true)

        // If outputs already exist, ask the GUI to confirm replacement.
        let fm = FileManager.default
        var existing: [URL] = []
        if fm.fileExists(atPath: outHTML.path) { existing.append(outHTML) }
        if fm.fileExists(atPath: outMD.path) { existing.append(outMD) }
        if exportSortedAttachments && fm.fileExists(atPath: sortedFolderURL.path) { existing.append(sortedFolderURL) }

        if !existing.isEmpty {
            if allowOverwrite {
                // Remove old outputs so the subsequent atomic writes cannot collide.
                for u in existing {
                    try? fm.removeItem(at: u)
                }
            } else {
                throw WAExportError.outputAlreadyExists(urls: existing)
            }
        }

        try await renderHTML(
            msgs: msgs,
            chatURL: chatPath,
            outHTML: outHTML,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly
        )

        try renderMD(
            msgs: msgs,
            chatURL: chatPath,
            outMD: outMD,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments,
            embedAttachmentThumbnailsOnly: embedAttachmentThumbnailsOnly
        )

        if exportSortedAttachments {
            try exportSortedAttachmentsFolder(
                chatURL: chatPath,
                messages: msgs,
                outDir: outPath,
                folderName: base,
                allowOverwrite: allowOverwrite
            )
        }

        return (outHTML, outMD)
    }
    
    /// Multi-Export: erzeugt alle HTML-Varianten (__max/__mid/__min) + eine MD-Datei.
    public static func exportMulti(
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
            return chooseMeName(authors: authors)
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

        // Output URLs
        var htmlByVariant: [HTMLVariant: URL] = [:]
        htmlByVariant.reserveCapacity(variants.count)

        for v in variants {
            let u = outPath.appendingPathComponent("\(base)\(v.filenameSuffix).html")
            htmlByVariant[v] = u
        }

        // Empfehlung: Markdown immer „portable“ mit attachments/ Links
        let outMD = outPath.appendingPathComponent("\(base).md")

        // Sorted attachments folder (optional)
        let sortedFolderURL = outPath.appendingPathComponent(base, isDirectory: true)

        // Existence check (wie in export(...), aber für alle Varianten)
        let fm = FileManager.default
        var existing: [URL] = []

        for (_, u) in htmlByVariant {
            if fm.fileExists(atPath: u.path) { existing.append(u) }
        }
        if fm.fileExists(atPath: outMD.path) { existing.append(outMD) }
        if exportSortedAttachments && fm.fileExists(atPath: sortedFolderURL.path) { existing.append(sortedFolderURL) }

        if !existing.isEmpty {
            if allowOverwrite {
                for u in existing { try? fm.removeItem(at: u) }
            } else {
                throw WAExportError.outputAlreadyExists(urls: existing)
            }
        }

        // Render all HTML variants
        for v in variants {
            guard let outHTML = htmlByVariant[v] else { continue }
            try await renderHTML(
                msgs: msgs,
                chatURL: chatPath,
                outHTML: outHTML,
                meName: meName,
                enablePreviews: v.enablePreviews,
                embedAttachments: v.embedAttachments,
                embedAttachmentThumbnailsOnly: v.embedAttachmentThumbnailsOnly
            )
        }

        // Render one Markdown (portable)
        try renderMD(
            msgs: msgs,
            chatURL: chatPath,
            outMD: outMD,
            meName: meName,
            enablePreviews: true,
            embedAttachments: false,
            embedAttachmentThumbnailsOnly: false
        )

        if exportSortedAttachments {
            try exportSortedAttachmentsFolder(
                chatURL: chatPath,
                messages: msgs,
                outDir: outPath,
                folderName: base,
                allowOverwrite: allowOverwrite
            )
        }

        return ExportMultiResult(htmlByVariant: htmlByVariant, md: outMD)
    }

    // ---------------------------
    // Helpers: normalize / url
    // ---------------------------

    // Python _norm_space
    private static func _normSpace(_ s: String) -> String {
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
    private static func isPhoneCandidate(_ s: String) -> Bool {
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
    private static func normalizePhoneKey(_ s: String) -> String {
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
    private static func normalizedParticipantIdentifier(_ s: String) -> String {
        let x = _normSpace(s)
        if !isPhoneCandidate(x) { return x }
        let k = normalizePhoneKey(x)
        return k.isEmpty ? x : k
    }

    /// Builds a lookup map that supports both raw keys and normalized phone keys.
    /// Values are trimmed and empty values are ignored.
    private static func buildParticipantOverrideLookup(_ overrides: [String: String]) -> [String: String] {
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
    private static func applyParticipantOverride(_ author: String, lookup: [String: String]) -> String {
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

    private static func stripBOMAndBidi(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{202A}", with: "")
            .replacingOccurrences(of: "\u{202B}", with: "")
            .replacingOccurrences(of: "\u{202C}", with: "")
    }

    // Python extract_urls
    private static func extractURLs(_ text: String) -> [String] {
        let ns = text as NSString
        let matches = urlRe.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var urls: [String] = []
        let rstripSet = CharacterSet(charactersIn: ").,;:!?]\"'")
        for m in matches {
            let raw = ns.substring(with: m.range(at: 1))
            let trimmed = raw.trimmingCharacters(in: rstripSet)
            urls.append(trimmed)
        }
        // unique stable
        var seen = Set<String>()
        var out: [String] = []
        for u in urls where !seen.contains(u) {
            seen.insert(u)
            out.append(u)
        }
        return out
    }

    // True if the message text consists only of one or more URLs (plus whitespace/newlines).
    // Used to avoid duplicating gigantic raw URLs in the bubble text when we already show previews/link lines.
    private static func isURLOnlyText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        let rstripSet = CharacterSet(charactersIn: ").,;:!?]\"')")
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return false }

        for t0 in tokens {
            let t1 = String(t0).trimmingCharacters(in: rstripSet)
            let low = t1.lowercased()
            if !(low.hasPrefix("http://") || low.hasPrefix("https://")) { return false }
            if URL(string: t1) == nil { return false }
        }
        return true
    }

    // Produces a compact, human-friendly display string for a URL.
    // The href remains the original URL; this only affects what is shown in the UI/PDF.
    private static func displayURL(_ urlString: String, maxLen: Int = 90) -> String {
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

    // Python is_youtube_url
    private static func youtubeVideoID(from urlString: String) -> String? {
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

    // Python safe_filename_stem
    private static func safeFilenameStem(_ stem: String) -> String {
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
    private static func safeFinderFilename(_ s: String, maxLen: Int = 200) -> String {
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

    private static func isoDateOnly(_ d: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // ---------------------------
    // Parsing WhatsApp exports
    // ---------------------------

    // Python parse_dt_de
    private static func parseDT_DE(date: String, hm: String, sec: String?) -> Date? {
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

    private static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        var g: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            g.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return g
    }

    // Python parse_messages
    private static func parseMessages(_ chatURL: URL) throws -> [WAMessage] {
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

    // Python choose_me_name (ohne interaktive stdin-Logik in GUI-Service)
    private static func chooseMeName(authors: [String]) -> String {
        var uniq: [String] = []
        for a in authors {
            let a2 = _normSpace(a)
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

    private static func findAttachments(_ text: String) -> [String] {
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

    private static func bucketForExtension(_ ext: String) -> SortedAttachmentBucket {
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

    private static func resolveAttachmentURL(fileName: String, sourceDir: URL) -> URL? {
        let fm = FileManager.default

        // 1) Most common: attachment is next to the chat.txt
        let direct = sourceDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) { return direct }

        // 2) Common alternative: inside a "Media" folder
        let media = sourceDir.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(fileName)
        if fm.fileExists(atPath: media.path) { return media }

        // 3) Last resort: search recursively for a matching lastPathComponent (can be slower)
        if let en = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let u as URL in en {
                if u.lastPathComponent == fileName {
                    return u
                }
            }
        }

        return nil
    }

    private static func exportSortedAttachmentsFolder(
        chatURL: URL,
        messages: [WAMessage],
        outDir: URL,
        folderName: String,
        allowOverwrite: Bool
    ) throws {
        let fm = FileManager.default

        let baseFolderURL = outDir.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: baseFolderURL, withIntermediateDirectories: true)

        // Additionally copy the original WhatsApp export folder (the folder that contains chat.txt)
        // into the sorted attachments folder, preserving the original folder name.
        // Example: <out>/<folderName>/<OriginalExportFolderName>/chat.txt
        let sourceDir = chatURL.deletingLastPathComponent().standardizedFileURL
        let originalFolderName = sourceDir.lastPathComponent
        let originalCopyDir = baseFolderURL.appendingPathComponent(originalFolderName, isDirectory: true)
        try fm.createDirectory(at: originalCopyDir, withIntermediateDirectories: true)

        // Copy recursively, but avoid recursion if the chosen output directory is inside the source directory.
        // (e.g. user selects the same folder or a subfolder as output)
        let outDirPath = outDir.standardizedFileURL.path
        let baseFolderPath = baseFolderURL.standardizedFileURL.path
        try copyDirectoryPreservingStructure(
            from: sourceDir,
            to: originalCopyDir,
            skippingPathPrefixes: [outDirPath, baseFolderPath]
        )
        
        try copySiblingZipIfPresent(
            sourceDir: sourceDir,
            destParentDir: baseFolderURL,
            allowOverwrite: allowOverwrite
        )

        let imagesDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.images.rawValue, isDirectory: true)
        let videosDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.videos.rawValue, isDirectory: true)
        let audiosDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.audios.rawValue, isDirectory: true)
        let docsDir = baseFolderURL.appendingPathComponent(SortedAttachmentBucket.documents.rawValue, isDirectory: true)

        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: audiosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)

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

        // Always create the folder structure so the user sees it even if nothing could be copied.
        if earliestDateByFile.isEmpty {
            return
        }

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

            let prefix = df.string(from: ts)
            let dstName = "\(prefix) \(fn)"
            var dst = dstFolder.appendingPathComponent(dstName)
            dst = uniqueDestinationURL(dst)

            // Copy (no overwrite expected because folder is removed when allowOverwrite=true)
            if !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.copyItem(at: src, to: dst)
                    syncFileSystemTimestamps(from: src, to: dst)
                } catch {
                    // keep export resilient
                }
            }
        }
    }

    private static func stripAttachmentMarkers(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let stripped = attachRe.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func guessMime(fromName name: String) -> String {
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

    private static func fileToDataURL(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = guessMime(fromName: url.lastPathComponent)
        let b64 = data.base64EncodedString()
        return "data:\(mime);base64,\(b64)"
    }

    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func urlPathEscapeComponent(_ s: String) -> String {
        // Encode a single path component for safe use in href/src.
        // Keep it conservative to work well across Safari/Chrome/Edge.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func uniqueDestinationURL(_ dest: URL) -> URL {
        // If a file already exists, create a non-colliding name like "name (2).ext".
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) { return dest }

        let ext = dest.pathExtension
        let base = dest.deletingPathExtension().lastPathComponent
        let dir = dest.deletingLastPathComponent()

        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    /// Copies a local attachment into the export folder (./attachments) and returns a relative href.
    /// This makes the exported HTML/MD portable across macOS/Windows and browsers.
    private static func stageAttachmentForExport(source: URL, attachmentsDir: URL) -> (relHref: String, stagedURL: URL)? {
        let fm = FileManager.default
        let src = source.standardizedFileURL
        guard fm.fileExists(atPath: src.path) else { return nil }

        // Dedupe: if we already staged this exact source path, return the same staged reference.
        stagedAttachmentLock.lock()
        if let cached = stagedAttachmentMap[src.path] {
            stagedAttachmentLock.unlock()
            return (relHref: cached.relHref, stagedURL: cached.stagedURL)
        }
        stagedAttachmentLock.unlock()

        do {
            try ensureDirectory(attachmentsDir)

            var dest = attachmentsDir.appendingPathComponent(src.lastPathComponent)
            dest = uniqueDestinationURL(dest)

            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: src, to: dest)
            }

            let rel = "attachments/\(urlPathEscapeComponent(dest.lastPathComponent))"

            stagedAttachmentLock.lock()
            stagedAttachmentMap[src.path] = (relHref: rel, stagedURL: dest)
            stagedAttachmentLock.unlock()

            return (relHref: rel, stagedURL: dest)
        } catch {
            // If staging fails, fall back to using the original absolute file URL.
            let rel = src.absoluteURL.absoluteString

            stagedAttachmentLock.lock()
            stagedAttachmentMap[src.path] = (relHref: rel, stagedURL: src)
            stagedAttachmentLock.unlock()

            return (relHref: rel, stagedURL: src)
        }
    }


    // ---------------------------
    // Attachment previews (PDF/DOCX thumbnails via Quick Look)
    // ---------------------------

#if canImport(QuickLookThumbnailing)
private static func thumbnailPNGDataURL(for fileURL: URL, maxPixel: CGFloat = 900) async -> String? {
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

    return await withCheckedContinuation { cont in
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
}
#endif

#if canImport(QuickLookThumbnailing)
private static func thumbnailJPEGData(for fileURL: URL, maxPixel: CGFloat = 900, quality: CGFloat = 0.72) async -> Data? {
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

    return await withCheckedContinuation { cont in
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
}
#endif

private static func stageThumbnailForExport(source: URL, thumbsDir: URL) async -> String? {
    let fm = FileManager.default
    let src = source.standardizedFileURL
    guard fm.fileExists(atPath: src.path) else { return nil }

    do {
        try ensureDirectory(thumbsDir)

        // Prefer a .jpg thumbnail to keep size down.
        let baseName = src.deletingPathExtension().lastPathComponent
        var dest = thumbsDir.appendingPathComponent(baseName).appendingPathExtension("jpg")
        dest = uniqueDestinationURL(dest)

        // If a thumbnail already exists (same chosen dest), reuse it.
        if fm.fileExists(atPath: dest.path) {
            return "attachments/_thumbs/\(urlPathEscapeComponent(dest.lastPathComponent))"
        }

        #if canImport(QuickLookThumbnailing)
        if let jpg = await thumbnailJPEGData(for: src, maxPixel: 900, quality: 0.72) {
            try jpg.write(to: dest, options: .atomic)
            return "attachments/_thumbs/\(urlPathEscapeComponent(dest.lastPathComponent))"
        }
        #endif

        // No thumbnail available.
        return nil
    } catch {
        return nil
    }
}

    private static func attachmentPreviewDataURL(_ url: URL) async -> String? {
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

    private static func attachmentThumbnailDataURL(_ url: URL) async -> String? {
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

    private static func attachmentEmoji(forExtension ext: String) -> String {
        let e = ext.lowercased()
        if ["mp4","mov","m4v"].contains(e) { return "🎬" }
        if ["mp3","m4a","aac","wav","ogg","opus","flac","caf","aiff","aif","amr"].contains(e) { return "🎧" }
        if ["jpg","jpeg","png","gif","webp","heic","heif"].contains(e) { return "🖼️" }
        return "📎"
    }

    // ---------------------------
    // Link previews: Google Maps helpers
    // ---------------------------

    private static func isGoogleMapsCoordinateURL(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        if !host.contains("google.") { return false }
        if !u.path.lowercased().contains("/maps") { return false }
        return googleMapsLatLon(u) != nil
    }

    private static func googleMapsLatLon(_ u: URL) -> (Double, Double)? {
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

    private static func googleMapsCoordinateTitle(lat: Double, lon: Double) -> String {
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

            // Return literal characters. htmlEscape() will then match Python's html.escape(...)
            // (apostrophe -> &#x27;, quote -> &quot;).
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
    private static func buildPreviewViaLinkPresentation(_ urlString: String) async -> WAPreview? {
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

    private static func httpGet(_ url: String, timeout: TimeInterval = 15) async throws -> (Data, String) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (WhatsAppExportTools/1.0)", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)

        // Match urllib.request behavior: non-2xx => throw (HTTPError in Python).
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        return (data, ct)
    }

    private static func resolveURL(base: String, maybe: String) -> String {
        // Python: urllib.parse.urljoin
        guard let b = URL(string: base) else { return maybe }
        return URL(string: maybe, relativeTo: b)?.absoluteURL.absoluteString ?? maybe
    }

    private static func parseMeta(_ htmlBytes: Data) -> [String: String] {
        // Python: decode up to 800_000 chars
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

    private static func downloadImageAsDataURL(_ imgURL: String, timeout: TimeInterval = 15, maxBytes: Int = 2_500_000) async -> String? {
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

    private static func buildPreview(_ url: String) async -> WAPreview? {
        if let cached = await previewCache.get(url) { return cached }

        // Google Maps: avoid consent/interstitial pages and keep output stable.
        // For coordinate links like .../maps/search/?api=1&query=52.508450,13.372972
        // synthesize the title Google typically returns (Python then HTML-escapes it).
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

    private static func weekdayIndexMonday0(_ date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let w = cal.component(.weekday, from: date) // Sunday=1 ... Saturday=7
        return (w + 5) % 7 // Monday=0 ... Sunday=6
    }

    private static func fmtDateFull(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }

    private static func fmtTime(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func htmlEscape(_ s: String) -> String {
        var x = s
        x = x.replacingOccurrences(of: "&", with: "&amp;")
        x = x.replacingOccurrences(of: "<", with: "&lt;")
        x = x.replacingOccurrences(of: ">", with: "&gt;")
        x = x.replacingOccurrences(of: "\"", with: "&quot;")
        x = x.replacingOccurrences(of: "'", with: "&#x27;")
        return x
    }

    private static func htmlUnescape(_ s: String) -> String {
        // Minimal unescape used for <title> fallback
        var x = s
        x = x.replacingOccurrences(of: "&lt;", with: "<")
        x = x.replacingOccurrences(of: "&gt;", with: ">")
        x = x.replacingOccurrences(of: "&quot;", with: "\"")
        x = x.replacingOccurrences(of: "&#x27;", with: "'")
        x = x.replacingOccurrences(of: "&amp;", with: "&")
        return x
    }

    private static func htmlEscapeKeepNewlines(_ s: String) -> String {
        // Python: "<br>".join(html.escape(s).splitlines())
        let esc = htmlEscape(s)
        return esc.components(separatedBy: .newlines).joined(separator: "<br>")
    }

    // Escapes text as HTML and (optionally) turns http(s) URLs into clickable <a> links.
    // Keeps original newlines by converting them to <br> (same behavior as htmlEscapeKeepNewlines).
    private static func htmlEscapeAndLinkifyKeepNewlines(_ s: String, linkify: Bool) -> String {
        if !linkify {
            return htmlEscapeKeepNewlines(s)
        }

        let rstripSet = CharacterSet(charactersIn: ").,;:!?]\"'")

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
            let matches = urlRe.matches(in: line, options: [], range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                outLines.append(htmlEscape(line))
                continue
            }

            var out = ""
            var cursor = 0

            for m in matches {
                let r = m.range(at: 1)
                if r.location == NSNotFound || r.length == 0 { continue }

                // Append text before the URL
                if r.location > cursor {
                    let before = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                    out += htmlEscape(before)
                }

                let rawURL = ns.substring(with: r)
                let (core, trailing) = splitURLTrailingPunct(rawURL)

                if !core.isEmpty {
                    let href = htmlEscape(core)
                    let shown = htmlEscape(core)
                    out += "<a href='\(href)' target='_blank' rel='noopener'>\(shown)</a>"
                } else {
                    out += htmlEscape(rawURL)
                }

                if !trailing.isEmpty {
                    out += htmlEscape(trailing)
                }

                cursor = r.location + r.length
            }

            // Append remainder
            if cursor < ns.length {
                let rest = ns.substring(from: cursor)
                out += htmlEscape(rest)
            }

            outLines.append(out)
        }

        return outLines.joined(separator: "<br>")
    }

    // ---------------------------
    // Render HTML (1:1 layout + CSS)
    // ---------------------------

    private static func renderHTML(
        msgs: [WAMessage],
        chatURL: URL,
        outHTML: URL,
        meName: String,
        enablePreviews: Bool,
        embedAttachments: Bool,
        embedAttachmentThumbnailsOnly: Bool
    ) async throws {

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

        // CSS exactly from Python
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

        // Python emits the <style> block with a newline after <style> and 4-space indentation.
        // To keep the CSS source readable in Swift while matching Python byte-for-byte, we add
        // a 4-space prefix to every CSS line at output time.
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
        let exportAttachmentsDir = outHTML.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)

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
            let attachments = (embedAttachments || embedAttachmentThumbnailsOnly) ? findAttachments(textRaw) : []
            let textWoAttach = stripAttachmentMarkers(textRaw)

            let isSystemMsg = isSystemMessage(authorRaw: authorRaw, text: textWoAttach)

            let isMe = (!isSystemMsg) && (authorRaw.lowercased() == _normSpace(meName).lowercased())
            let rowCls: String = isSystemMsg ? "system" : (isMe ? "me" : "other")
            let bubCls: String = isSystemMsg ? "system" : (isMe ? "me" : "other")

            let trimmedText = textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines)
            // Minimal mode (no previews): do not extract URLs for link lines/previews, and do not treat
            // URL-only messages as empty bubble text.
            let urls = enablePreviews ? extractURLs(trimmedText) : []
            let urlOnly = enablePreviews ? isURLOnlyText(trimmedText) : false

            // If the message is just a URL (or a list of URLs), avoid printing the raw URL(s) again as bubble text.
            let textHTML: String = {
                if urlOnly { return "" }
                if trimmedText.isEmpty { return "" }
                // In the smallest variant (previews disabled), URLs should still be real clickable links.
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
                            imgBlock = "<div class='pimg'><img alt='' src='\(img)'></div>"
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
                let p = chatURL.deletingLastPathComponent().appendingPathComponent(fn).standardizedFileURL
                let ext = p.pathExtension.lowercased()

                if embedAttachmentThumbnailsOnly {
                    // Thumbnails-only mode must produce a standalone HTML (no ./attachments folder):
                    // - Do NOT stage/copy attachments to disk.
                    // - Embed ONLY a lightweight thumbnail as a data: URL.
                    // - Do NOT wrap thumbnails in <a href=...> and do NOT print any file link/text line.

                    var thumbDataURL: String? = nil

                    #if canImport(QuickLookThumbnailing)
                    // Prefer JPEG thumbnails to keep the HTML smaller than PNG.
                    if let jpg = await thumbnailJPEGData(for: p, maxPixel: 900, quality: 0.72) {
                        thumbDataURL = "data:image/jpeg;base64,\(jpg.base64EncodedString())"
                    }
                    #endif

                    if thumbDataURL == nil {
                        // Fallback (still standalone): Quick Look PNG thumbnail (or nil if unavailable).
                        thumbDataURL = await attachmentThumbnailDataURL(p)
                    }

                    if let thumbDataURL {
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
                            mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\\(embedId)')\">Datei speichern</a></div>")
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
                        mediaBlocks.append("<div class='fileline'>⬇︎ <a href='javascript:void(0)' onclick=\"return waDownloadEmbed('\\(embedId)')\">Datei speichern</a></div>")
                    } else {
                        mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
                    }
                    continue
                }

                // Mode B (default): stage attachments into ./attachments for portable HTML/MD.
                let staged = stageAttachmentForExport(source: p, attachmentsDir: exportAttachmentsDir)
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

        try parts.joined().write(to: outHTML, atomically: true, encoding: .utf8)
    }

    // ---------------------------
    // Render Markdown (1:1)
    // ---------------------------

    private static func renderMD(
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

        // message count (exclude WhatsApp system messages)
        let messageCount: Int = msgs.reduce(0) { acc, m in
            let authorNorm = _normSpace(m.author)
            let textWoAttach = stripAttachmentMarkers(m.text)
            return acc + (isSystemMessage(authorRaw: authorNorm, text: textWoAttach) ? 0 : 1)
        }

        var lines: [String] = []
        lines.append("# WhatsApp Chat: \(titleNames)")
        lines.append("")
        // Python writes full chat_path object; in Swift we mirror with full path.
        lines.append("- Quelle: \(chatURL.path)")
        lines.append("- Export (file mtime): \(exportDTFormatter.string(from: mtime))")
        lines.append("- Nachrichten: \(messageCount)")
        lines.append("")

        var lastDayKey: String? = nil
        let exportAttachmentsDir: URL? = embedAttachments
            ? nil
            : outMD.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)

        for m in msgs {
            let dayKey = isoDateOnly(m.ts)
            if lastDayKey != dayKey {
                let wd = weekdayDE[weekdayIndexMonday0(m.ts)] ?? ""
                lines.append("## \(wd), \(fmtDateFull(m.ts))")
                lines.append("")
                lastDayKey = dayKey
            }

            let author = _normSpace(m.author).isEmpty ? "Unbekannt" : _normSpace(m.author)
            let tsLine = "\(fmtTime(m.ts)) / \(fmtDateFull(m.ts))"

            let textRaw = m.text
            // Minimal mode (no attachments): only include attachments for full-embed or thumbnails-only.
            let attachments = (embedAttachments || embedAttachmentThumbnailsOnly) ? findAttachments(textRaw) : []
            let textWoAttach = stripAttachmentMarkers(textRaw)

            lines.append("**\(author)**  ")
            lines.append("*\(tsLine)*  ")
            if !textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let urls = enablePreviews ? extractURLs(textWoAttach) : []
            if !urls.isEmpty {
                for u in urls { lines.append("- \(u)") }
            }

            for fn in attachments {
                let p = chatURL.deletingLastPathComponent().appendingPathComponent(fn).standardizedFileURL

                // Thumbnails-only mode: do not link to the full attachment in Markdown.
                if embedAttachmentThumbnailsOnly {
                    let n = fn.lowercased()
                    if n.hasSuffix(".mp4") || n.hasSuffix(".mov") || n.hasSuffix(".m4v") {
                        lines.append("- 🎬 \(fn)")
                    } else if n.hasSuffix(".mp3") || n.hasSuffix(".m4a") || n.hasSuffix(".aac") || n.hasSuffix(".wav") || n.hasSuffix(".ogg") || n.hasSuffix(".opus") || n.hasSuffix(".flac") || n.hasSuffix(".caf") || n.hasSuffix(".aiff") || n.hasSuffix(".aif") || n.hasSuffix(".amr") {
                        lines.append("- 🎧 \(fn)")
                    } else if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") || n.hasSuffix(".png") || n.hasSuffix(".gif") || n.hasSuffix(".webp") || n.hasSuffix(".heic") || n.hasSuffix(".heif") {
                        lines.append("- 🖼️ \(fn)")
                    } else {
                        lines.append("- 📎 \(fn)")
                    }
                    continue
                }

                let href: String? = {
                    if embedAttachments {
                        // No staging in embed mode; keep the markdown portable by avoiding a new attachments/ folder.
                        // If the file exists, link to the original file URL.
                        return FileManager.default.fileExists(atPath: p.path) ? p.absoluteURL.absoluteString : nil
                    }
                    guard let dir = exportAttachmentsDir else { return nil }
                    return stageAttachmentForExport(source: p, attachmentsDir: dir)?.relHref
                }()

                let n = fn.lowercased()
                if n.hasSuffix(".mp4") || n.hasSuffix(".mov") || n.hasSuffix(".m4v") {
                    if let href {
                        lines.append("- 🎬 [\(fn)](\(href))")
                    } else {
                        lines.append("- 🎬 \(fn)")
                    }
                } else if n.hasSuffix(".mp3") || n.hasSuffix(".m4a") || n.hasSuffix(".aac") || n.hasSuffix(".wav") || n.hasSuffix(".ogg") || n.hasSuffix(".opus") || n.hasSuffix(".flac") || n.hasSuffix(".caf") || n.hasSuffix(".aiff") || n.hasSuffix(".aif") || n.hasSuffix(".amr") {
                    if let href {
                        lines.append("- 🎧 [\(fn)](\(href))")
                    } else {
                        lines.append("- 🎧 \(fn)")
                    }
                } else if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") || n.hasSuffix(".png") || n.hasSuffix(".gif") || n.hasSuffix(".webp") || n.hasSuffix(".heic") || n.hasSuffix(".heif") {
                    if let href {
                        lines.append("- 🖼️ [\(fn)](\(href))")
                    } else {
                        lines.append("- 🖼️ \(fn)")
                    }
                } else {
                    if let href {
                        lines.append("- 📎 [\(fn)](\(href))")
                    } else {
                        lines.append("- 📎 \(fn)")
                    }
                }
            }
            lines.append("")
        }

        try lines.joined(separator: "\n").write(to: outMD, atomically: true, encoding: .utf8)
    }
    /// Best-effort: make dest carry the same filesystem timestamps as source.
    /// We intentionally do not throw if the filesystem refuses to set attributes.
    private static func syncFileSystemTimestamps(from source: URL, to dest: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return }

        var newAttrs: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] as? Date { newAttrs[.creationDate] = c }
        if let m = attrs[.modificationDate] as? Date { newAttrs[.modificationDate] = m }

        if !newAttrs.isEmpty {
            try? fm.setAttributes(newAttrs, ofItemAtPath: dest.path)
        }
    }

    private static func copyDirectoryPreservingStructure(
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
                if !fm.fileExists(atPath: dst.path) {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: u, to: dst)

                    // Ensure copied files carry original creation/modification timestamps.
                    syncFileSystemTimestamps(from: u, to: dst)
                }
            }
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
    private static func copySiblingZipIfPresent(
        sourceDir: URL,
        destParentDir: URL,
        allowOverwrite: Bool
    ) throws {
        let fm = FileManager.default

        let parent = sourceDir.deletingLastPathComponent()
        let folderName = sourceDir.lastPathComponent.lowercased()

        // Candidate zips in the parent directory
        let candidates: [URL]
        do {
            let items = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            candidates = items
                .filter { $0.pathExtension.lowercased() == "zip" }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return // best-effort: treat as no zip
        }

        if candidates.isEmpty { return }

        // Prefer a zip that matches the extracted folder name (common pattern).
        let picked: URL? = candidates.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == folderName })
            ?? candidates.first(where: { $0.lastPathComponent.lowercased().contains(folderName) })
            ?? candidates.first(where: { $0.lastPathComponent.lowercased().contains("whatsapp") })
            ?? candidates.first

        guard let zipURL = picked else { return }

        try ensureDirectory(destParentDir)

        let dest = destParentDir.appendingPathComponent(zipURL.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            if allowOverwrite {
                try? fm.removeItem(at: dest)
            } else {
                return
            }
        }

        do {
            try fm.copyItem(at: zipURL, to: dest)
            syncFileSystemTimestamps(from: zipURL, to: dest)
        } catch {
            // best-effort: ignore copy errors
        }
    }
    
    private static func withHTMLSuffix(_ htmlURL: URL, suffix: String) -> URL {
        let ext = htmlURL.pathExtension
        let base = htmlURL.deletingPathExtension().lastPathComponent
        let dir = htmlURL.deletingLastPathComponent()
        let newName = base + suffix + "." + ext
        return dir.appendingPathComponent(newName, isDirectory: false)
    }
}

