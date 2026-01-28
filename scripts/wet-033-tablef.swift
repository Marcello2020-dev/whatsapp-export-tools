import Foundation

@main
struct WET033TableFRunner {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("WET-033 TABLEF: FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private struct VerificationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func run() async throws {
        let fm = FileManager.default
        let fixtureRoot = envURL(key: "WET_033_FIXTURE_ROOT", fallback: "_local/fixtures/wet-031")
        let chatURL = fixtureRoot.appendingPathComponent("_chat.txt")
        let outRoot = envURL(key: "WET_033_OUT_ROOT", fallback: "_local/out/wet-033")

        if fm.fileExists(atPath: outRoot.path) {
            try fm.removeItem(at: outRoot)
        }
        try fm.createDirectory(at: outRoot, withIntermediateDirectories: true)

        let noSidecarDir = outRoot.appendingPathComponent("nosidecar", isDirectory: true)
        let sidecarDir = outRoot.appendingPathComponent("sidecar", isDirectory: true)

        try await runCase(
            label: "nosidecar",
            chatURL: chatURL,
            outDir: noSidecarDir,
            exportSortedAttachments: false
        )

        try await runCase(
            label: "sidecar",
            chatURL: chatURL,
            outDir: sidecarDir,
            exportSortedAttachments: true
        )

        print("WET-033 TABLEF: PASS")
    }

    private static func runCase(
        label: String,
        chatURL: URL,
        outDir: URL,
        exportSortedAttachments: Bool
    ) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outDir.path) {
            try fm.removeItem(at: outDir)
        }
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let result = try await WhatsAppExportService.exportMulti(
            chatURL: chatURL,
            outDir: outDir,
            meNameOverride: "Me",
            participantNameOverrides: [:],
            variants: [.embedAll, .thumbnailsOnly, .textOnly],
            exportSortedAttachments: exportSortedAttachments,
            allowOverwrite: true
        )

        let baseName = try inferBaseName(from: result.primaryHTML)
        try verifyArtifacts(outDir: outDir, baseName: baseName, exportSortedAttachments: exportSortedAttachments)
        try verifyThumbRules(outDir: outDir, baseName: baseName, exportSortedAttachments: exportSortedAttachments)
        try verifyNoSuffixArtifacts(outDir: outDir)
        try verifyPerf(label: label, expectedThumbs: 2)

        print("WET-033 TABLEF: case=\(label) PASS")
    }

    private static func inferBaseName(from primaryHTML: URL) throws -> String {
        let name = primaryHTML.lastPathComponent
        let suffixes = ["-max.html", "-mid.html", "-min.html"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        if name.hasSuffix(".html") {
            return String(name.dropLast(".html".count))
        }
        throw VerificationError(message: "Unable to infer base name from \(name)")
    }

    private static func verifyArtifacts(outDir: URL, baseName: String, exportSortedAttachments: Bool) throws {
        let fm = FileManager.default
        let expected: [String] = {
            var names = [
                "\(baseName)-max.html",
                "\(baseName)-mid.html",
                "\(baseName)-min.html",
                "\(baseName).md"
            ]
            if exportSortedAttachments {
                names.append("\(baseName)-sdc.html")
                names.append(baseName)
            }
            return names
        }()

        for name in expected {
            let url = outDir.appendingPathComponent(name)
            var isDir = ObjCBool(false)
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !exists {
                throw VerificationError(message: "Missing expected artifact: \(name)")
            }
            if name == baseName, !isDir.boolValue {
                throw VerificationError(message: "Expected sidecar folder to be a directory: \(name)")
            }
        }
    }

    private static func verifyThumbRules(outDir: URL, baseName: String, exportSortedAttachments: Bool) throws {
        let fm = FileManager.default
        let compactHTML = outDir.appendingPathComponent("\(baseName)-mid.html")
        let compact = (try? String(contentsOf: compactHTML, encoding: .utf8)) ?? ""

        if exportSortedAttachments {
            let thumbsDir = outDir.appendingPathComponent(baseName, isDirectory: true)
                .appendingPathComponent("_thumbs", isDirectory: true)
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: thumbsDir.path, isDirectory: &isDir), isDir.boolValue else {
                throw VerificationError(message: "Sidecar _thumbs missing in sidecar run")
            }
            let files = (try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil)) ?? []
            if files.isEmpty {
                throw VerificationError(message: "Sidecar _thumbs is empty")
            }
            if !compact.contains("_thumbs/") {
                throw VerificationError(message: "Compact HTML does not reference _thumbs in sidecar run")
            }
            if compact.contains("data:image/jpeg") {
                throw VerificationError(message: "Compact HTML embeds thumbnails instead of referencing _thumbs in sidecar run")
            }
        } else {
            let thumbsDir = outDir.appendingPathComponent("_thumbs", isDirectory: true)
            if fm.fileExists(atPath: thumbsDir.path) {
                throw VerificationError(message: "Unexpected _thumbs published in no-sidecar run")
            }
            if compact.contains("_thumbs/") {
                throw VerificationError(message: "Compact HTML references _thumbs in no-sidecar run")
            }
            if !compact.contains("data:image/jpeg") {
                throw VerificationError(message: "Compact HTML missing embedded thumbnails in no-sidecar run")
            }
        }
    }

    private static func verifyNoSuffixArtifacts(outDir: URL) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if suffixBaseNameIfPresent(name) != nil {
                throw VerificationError(message: "Suffix artifact detected: \(name)")
            }
        }
    }

    private static func suffixBaseNameIfPresent(_ name: String) -> String? {
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

    private static func verifyPerf(label: String, expectedThumbs: Int) throws {
        let perf = WhatsAppExportService.perfSnapshot()
        if perf.thumbStoreGenerated > expectedThumbs {
            throw VerificationError(message: "\(label): thumbStoreGenerated \(perf.thumbStoreGenerated) exceeds expected \(expectedThumbs)")
        }
    }

    private static func envURL(key: String, fallback: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[key], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(fallback, isDirectory: true)
    }
}
