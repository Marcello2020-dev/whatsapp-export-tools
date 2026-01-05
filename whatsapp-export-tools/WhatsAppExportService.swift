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

// MARK: - Service

public enum WhatsAppExportService {

    // ---------------------------
    // Constants / Regex
    // ---------------------------

    private static let systemAuthor = "System"

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

    private static let nowStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    // Cache for previews
    private actor PreviewCache {
        private var dict: [String: WAPreview] = [:]
        func get(_ url: String) -> WAPreview? { dict[url] }
        func set(_ url: String, _ val: WAPreview) { dict[url] = val }
    }

    private static let previewCache = PreviewCache()

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
            let a = _normSpace(m.author)
            if a.isEmpty { continue }
            if a.lowercased() == systemAuthor.lowercased() { continue }
            if !uniq.contains(a) { uniq.append(a) }
        }

        // Apply the same system-marker filtering as chooseMeName
        let systemMarkers: Set<String> = [
            "system",
            "whatsapp",
            "messages to this chat are now secured",
            "nachrichten und anrufe sind ende-zu-ende-verschlüsselt",
        ]

        let filtered = uniq.filter { !systemMarkers.contains(_normSpace($0).lowercased()) }
        return filtered.isEmpty ? uniq : filtered
    }
    
    /// 1:1-Export: parses chat, decides me-name, renders HTML+MD, writes files.
    /// Returns URLs of written HTML/MD.
    public static func export(
        chatURL: URL,
        outDir: URL,
        meNameOverride: String?,
        enablePreviews: Bool,
        embedAttachments: Bool
    ) async throws -> (html: URL, md: URL) {

        let chatPath = chatURL.standardizedFileURL
        let outPath = outDir.standardizedFileURL

        let msgs = try parseMessages(chatPath)

        let authors = msgs.map { $0.author }.filter { !_normSpace($0).isEmpty }
        let meName = {
            let o = _normSpace(meNameOverride ?? "")
            if !o.isEmpty { return o }
            return chooseMeName(authors: authors)
        }()

        let now = Date()

        // Output filename parts (Python main)
        let uniqAuthors = Array(Set(authors.map { _normSpace($0) }))
            .filter { !$0.isEmpty && $0 != systemAuthor }
            .sorted()

        let meNorm = _normSpace(meName)
        let partners = uniqAuthors.filter { _normSpace($0) != meNorm }

        let partnersPart: String = {
            if partners.isEmpty { return "UNKNOWN" }
            if partners.count <= 3 { return partners.joined(separator: "+") }
            return partners.prefix(3).joined(separator: "+") + "+\(partners.count - 3)more"
        }()

        let periodPart: String = {
            guard let minD = msgs.min(by: { $0.ts < $1.ts })?.ts,
                  let maxD = msgs.max(by: { $0.ts < $1.ts })?.ts else {
                return "NO_MESSAGES"
            }
            let start = isoDateOnly(minD)
            let end = isoDateOnly(maxD)
            return "\(start)_to_\(end)"
        }()

        let base = [
            safeFilenameStem("WHATSAPP_CHAT"),
            safeFilenameStem(partnersPart),
            periodPart,
            nowStampFormatter.string(from: now),
        ].joined(separator: "_")

        let outHTML = outPath.appendingPathComponent("\(base).html")
        let outMD = outPath.appendingPathComponent("\(base).md")

        try await renderHTML(
            msgs: msgs,
            chatURL: chatPath,
            outHTML: outHTML,
            meName: meName,
            enablePreviews: enablePreviews,
            embedAttachments: embedAttachments
        )

        try renderMD(
            msgs: msgs,
            chatURL: chatPath,
            outMD: outMD,
            meName: meName,
            embedAttachments: embedAttachments
        )

        return (outHTML, outMD)
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

        let systemMarkers: Set<String> = [
            "system",
            "whatsapp",
            "messages to this chat are now secured",
            "nachrichten und anrufe sind ende-zu-ende-verschlüsselt",
        ]

        let filtered = uniq.filter { !systemMarkers.contains(_normSpace($0).lowercased()) }
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

        // Video
        if n.hasSuffix(".mp4") { return "video/mp4" }
        if n.hasSuffix(".m4v") { return "video/x-m4v" }
        if n.hasSuffix(".mov") { return "video/quicktime" }

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
        return s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
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

        do {
            try ensureDirectory(attachmentsDir)

            var dest = attachmentsDir.appendingPathComponent(src.lastPathComponent)
            dest = uniqueDestinationURL(dest)

            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: src, to: dest)
            }

            let rel = "attachments/\(urlPathEscapeComponent(dest.lastPathComponent))"
            return (relHref: rel, stagedURL: dest)
        } catch {
            // If staging fails, fall back to using the original absolute file URL.
            return (relHref: src.absoluteURL.absoluteString, stagedURL: src)
        }
    }

    // ---------------------------
    // Attachment previews (PDF/DOCX thumbnails via Quick Look)
    // ---------------------------

    #if canImport(QuickLookThumbnailing) && canImport(AppKit)
    private static func thumbnailPNGDataURL(for fileURL: URL, maxPixel: CGFloat = 900) async -> String? {
        let size = CGSize(width: maxPixel, height: maxPixel)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

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
            }
        }
    }
    #endif

    private static func attachmentPreviewDataURL(_ url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()

        // True images: embed as-is.
        if ["jpg","jpeg","png","gif","webp"].contains(ext) {
            return fileToDataURL(url)
        }

        // PDF/DOCX/DOC/MP4/MOV/M4V: generate a thumbnail via Quick Look.
        if ["pdf","docx","doc","mp4","mov","m4v"].contains(ext) {
            #if canImport(QuickLookThumbnailing) && canImport(AppKit)
            return await thumbnailPNGDataURL(for: url)
            #else
            return nil
            #endif
        }

        return nil
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

    #if canImport(LinkPresentation) && canImport(AppKit)

    private static func nsImageToPNGData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func loadNSImage(from provider: NSItemProvider) async throws -> NSImage {
        try await withCheckedThrowingContinuation { cont in
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

        // Fallback: load as NSImage and re-encode PNG
        let img = try await loadNSImage(from: provider)
        if let png = nsImageToPNGData(img) {
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
        #if canImport(LinkPresentation) && canImport(AppKit)
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

    // ---------------------------
    // Render HTML (1:1 layout + CSS)
    // ---------------------------

    private static func renderHTML(
        msgs: [WAMessage],
        chatURL: URL,
        outHTML: URL,
        meName: String,
        enablePreviews: Bool,
        embedAttachments: Bool
    ) async throws {

        // participants -> title_names
        var authors: [String] = []
        for m in msgs {
            let a = _normSpace(m.author)
            if !a.isEmpty && !authors.contains(a) { authors.append(a) }
        }
        let others = authors.filter { $0 != meName }
        let titleNames: String = {
            if others.count == 1 { return "\(meName) ↔ \(others[0])" }
            if others.count > 1 { return "\(meName) ↔ \(others.joined(separator: ", "))" }
            return "\(meName) ↔ Chat"
        }()

        // export time = file mtime
        let mtime: Date = (try? FileManager.default.attributesOfItem(atPath: chatURL.path)[.modificationDate] as? Date) ?? Date()

        // CSS exactly from Python
        let css = #"""
        :root{
          --bg:#e5ddd5;
          --bubble-me:#DCF8C6;
          --bubble-other:#EAF7E0; /* a bit lighter green */
          --text:#111;
          --muted:#666;
          --shadow: 0 1px 0 rgba(0,0,0,.06);
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
        .bubble{
          max-width: 78%;
          min-width: 220px;
          padding: 10px 12px 8px;
          border-radius: 18px;
          box-shadow: var(--shadow);
          position:relative;
          overflow:hidden;
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
          text-align: right;
          font-size: 14px;
          color: #444;
          opacity: .9;
          line-height: 1.1;
        }
        .media{
          margin-top: 10px;
          border-radius: 14px;
          overflow:hidden;
          background: rgba(255,255,255,.35);
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
        .media a{display:block;}
        .fileline a{color:#2a5db0;text-decoration:none;}
        .fileline a:hover{text-decoration:underline;}
        .preview{
          margin-top: 10px;
          border-radius: 14px;
          overflow:hidden;
          background: rgba(255,255,255,.55);
          border: 1px solid rgba(0,0,0,.06);
        }
        .preview a{color: inherit; text-decoration:none; display:block;}
        .preview .pimg img{width:100%;height:auto;display:block;}
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
        parts.append("<style>\n\(cssIndented)\n    </style></head><body><div class='wrap'>")

        parts.append("<div class='header'>")
        parts.append("<p class='h-title'>WhatsApp Chat<br>\(htmlEscape(titleNames))</p>")
        parts.append("<p class='h-meta'>Quelle: \(htmlEscape(chatURL.lastPathComponent))<br>"
                     + "Export: \(htmlEscape(exportDTFormatter.string(from: mtime)))<br>"
                     + "Nachrichten: \(msgs.count)</p>")
        parts.append("</div>")

        var lastDayKey: String? = nil
        let exportAttachmentsDir = outHTML.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)

        for m in msgs {
            let dayKey = isoDateOnly(m.ts)
            if lastDayKey != dayKey {
                let wd = weekdayDE[weekdayIndexMonday0(m.ts)] ?? ""
                parts.append("<div class='day'><span>\(htmlEscape("\(wd), \(fmtDateFull(m.ts))"))</span></div>")
                lastDayKey = dayKey
            }

            let author = _normSpace(m.author).isEmpty ? "Unbekannt" : _normSpace(m.author)
            let isMe = (author == meName)
            let rowCls = isMe ? "me" : "other"
            let bubCls = isMe ? "me" : "other"

            let textRaw = m.text
            let attachments = findAttachments(textRaw)
            let textWoAttach = stripAttachmentMarkers(textRaw)

            let textHTML = textWoAttach.isEmpty ? "" : htmlEscapeKeepNewlines(textWoAttach)

            let urls = extractURLs(textWoAttach)
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

                // Mode A: embed everything directly into the HTML (single-file export).
                if embedAttachments {
                    if ["mp4", "mov", "m4v"].contains(ext) {
                        let mime = guessMime(fromName: fn)
                        let poster = await attachmentPreviewDataURL(p)

                        var posterAttr = ""
                        if let poster {
                            posterAttr = " poster='\(poster)'"
                        }

                        if let dataURL = fileToDataURL(p) {
                            mediaBlocks.append(
                                "<div class='media'><video controls preload='metadata' playsinline\(posterAttr)><source src='\(htmlEscape(dataURL))' type='\(htmlEscape(mime))'>Dein Browser kann dieses Video nicht abspielen.</video></div>"
                            )
                        }
                        mediaBlocks.append("<div class='fileline'>🎬 \(htmlEscape(fn))</div>")
                        continue
                    }

                    if let dataURL = await attachmentPreviewDataURL(p) {
                        mediaBlocks.append("<div class='media'><img alt='' src='\(dataURL)'></div>")
                        mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
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
                    mediaBlocks.append(
                        "<div class='fileline'>🎬 <a href='\(htmlEscape(href))' target='_blank' rel='noopener' download>\(htmlEscape(fn))</a></div>"
                    )
                    continue
                }

                if let dataURL = await attachmentPreviewDataURL(stagedURL ?? p) {
                    if let href {
                        mediaBlocks.append(
                            "<div class='media'><a href='\(htmlEscape(href))' target='_blank' rel='noopener'><img alt='' src='\(dataURL)'></a></div>"
                        )
                        mediaBlocks.append(
                            "<div class='fileline'>📎 <a href='\(htmlEscape(href))' target='_blank' rel='noopener'>\(htmlEscape(fn))</a></div>"
                        )
                    } else {
                        mediaBlocks.append("<div class='media'><img alt='' src='\(dataURL)'></div>")
                        mediaBlocks.append("<div class='fileline'>📎 \(htmlEscape(fn))</div>")
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

            // show all urls as lines
            var linkLines = ""
            if !urls.isEmpty {
                let lines = urls.map {
                    "<a href='\(htmlEscape($0))' target='_blank' rel='noopener'>\(htmlEscape($0))</a>"
                }.joined(separator: "<br>")
                linkLines = "<div class='linkline'>\(lines)</div>"
            }

            parts.append("<div class='row \(rowCls)'>")
            parts.append("<div class='bubble \(bubCls)'>")
            parts.append("<div class='name'>\(htmlEscape(author))</div>")
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
        embedAttachments: Bool
    ) throws {

        var authors: [String] = []
        for m in msgs {
            let a = _normSpace(m.author)
            if !a.isEmpty && !authors.contains(a) { authors.append(a) }
        }

        let others = authors.filter { $0 != meName }
        let titleNames: String = {
            if others.count == 1 { return "\(meName) ↔ \(others[0])" }
            if others.count > 1 { return "\(meName) ↔ \(others.joined(separator: ", "))" }
            return "\(meName) ↔ Chat"
        }()

        let mtime: Date = (try? FileManager.default.attributesOfItem(atPath: chatURL.path)[.modificationDate] as? Date) ?? Date()

        var lines: [String] = []
        lines.append("# WhatsApp Chat: \(titleNames)")
        lines.append("")
        // Python writes full chat_path object; in Swift we mirror with full path.
        lines.append("- Quelle: \(chatURL.path)")
        lines.append("- Export (file mtime): \(exportDTFormatter.string(from: mtime))")
        lines.append("- Nachrichten: \(msgs.count)")
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
            let attachments = findAttachments(textRaw)
            let textWoAttach = stripAttachmentMarkers(textRaw)

            lines.append("**\(author)**  ")
            lines.append("*\(tsLine)*  ")
            if !textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(textWoAttach.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let urls = extractURLs(textWoAttach)
            if !urls.isEmpty {
                for u in urls { lines.append("- \(u)") }
            }

            for fn in attachments {
                let p = chatURL.deletingLastPathComponent().appendingPathComponent(fn).standardizedFileURL

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
                } else if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") || n.hasSuffix(".png") || n.hasSuffix(".gif") || n.hasSuffix(".webp") {
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
}
