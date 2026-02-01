import Foundation
import AppKit

@MainActor
struct WETReplaceSelectionCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_REPLACE_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private struct FileInfo: Equatable {
        let mtime: Date
        let size: UInt64
    }

    private static func manifestTimestamp(_ date: Date) -> String {
        TimePolicy.iso8601WithOffsetString(date)
    }

    private static func run() {
        let root = fixtureRoot()
        let baseName = fixtureBaseName()

        do {
            try seedFixture(root: root, baseName: baseName)
        } catch {
            print("WET_REPLACE_CHECK: seed failed: \(error)")
            NSApp.terminate(nil)
            return
        }

        dumpManifest(label: "BEFORE", root: root)
        let before = snapshot(root: root, baseName: baseName)

        Thread.sleep(forTimeInterval: 1.1)

        do {
            try runReplace(root: root, baseName: baseName)
        } catch {
            print("WET_REPLACE_CHECK: replace failed: \(error)")
            NSApp.terminate(nil)
            return
        }

        dumpManifest(label: "AFTER", root: root)
        let after = snapshot(root: root, baseName: baseName)

        let failures = verify(before: before, after: after, baseName: baseName)
        if failures.isEmpty {
            print("WET_REPLACE_CHECK: PASS")
        } else {
            print("WET_REPLACE_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
    }

    private static func fixtureRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["WET_REPLACE_FIXTURE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("_local/fixtures/wet/synthetic/replace-selection-test/out", isDirectory: true)
    }

    private static func fixtureBaseName() -> String {
        if let override = ProcessInfo.processInfo.environment["WET_REPLACE_FIXTURE_BASE"], !override.isEmpty {
            return override
        }
        return "Chat_replace_selection_test"
    }

    private static func seedFixture(root: URL, baseName: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let sidecarDir = root.appendingPathComponent("\(baseName)-Sidecar", isDirectory: true)
        try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        let imagesDir = sidecarDir.appendingPathComponent("images", isDirectory: true)
        let videosDir = sidecarDir.appendingPathComponent("videos", isDirectory: true)
        let audiosDir = sidecarDir.appendingPathComponent("audios", isDirectory: true)
        let docsDir = sidecarDir.appendingPathComponent("documents", isDirectory: true)
        let thumbsDir = sidecarDir.appendingPathComponent("_thumbs", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: audiosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        let seedFiles: [(String, String)] = [
            ("\(baseName)-MaxHTML.html", "dummy max"),
            ("\(baseName)-MidHTML.html", "dummy mid"),
            ("\(baseName)-mailHTML.html", "dummy email"),
            ("\(baseName).md", "dummy md"),
            ("\(baseName)-Sidecar.html", "dummy sidecar html")
        ]
        for (name, content) in seedFiles {
            let url = root.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        let sidecarFile = imagesDir.appendingPathComponent("media_0001.jpg")
        try "dummy asset".write(to: sidecarFile, atomically: true, encoding: .utf8)
    }

    private static func runReplace(root: URL, baseName: String) throws {
        let fm = FileManager.default
        let variantSuffixes = ["-MaxHTML", "-MidHTML"]
        let deleteTargets = ContentView.replaceDeleteTargets(
            baseName: baseName,
            variantSuffixes: variantSuffixes,
            wantsMarkdown: false,
            wantsSidecar: false,
            wantsRawArchive: false,
            in: root
        )

        for url in deleteTargets {
            let target = url.standardizedFileURL
            guard ContentView.isSafeReplaceDeleteTarget(target, exportDir: root) else {
                throw NSError(domain: "WETReplaceCheck", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Unsafe delete target: \(target.path)"
                ])
            }
            guard fm.fileExists(atPath: target.path) else { continue }
            try fm.removeItem(at: target)
        }

        try "replaced max".write(
            to: root.appendingPathComponent("\(baseName)-MaxHTML.html"),
            atomically: true,
            encoding: .utf8
        )
        try "replaced mid".write(
            to: root.appendingPathComponent("\(baseName)-MidHTML.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func snapshot(root: URL, baseName: String) -> [String: FileInfo] {
        let files: [URL] = [
            root.appendingPathComponent("\(baseName)-MaxHTML.html"),
            root.appendingPathComponent("\(baseName)-MidHTML.html"),
            root.appendingPathComponent("\(baseName)-mailHTML.html"),
            root.appendingPathComponent("\(baseName).md"),
            root.appendingPathComponent("\(baseName)-Sidecar.html"),
            root.appendingPathComponent("\(baseName)-Sidecar/images/media_0001.jpg")
        ]

        var snapshot: [String: FileInfo] = [:]
        for url in files {
            if let info = fileInfo(at: url) {
                snapshot[url.path] = info
            }
        }
        return snapshot
    }

    private static func fileInfo(at url: URL) -> FileInfo? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? UInt64 else {
            return nil
        }
        return FileInfo(mtime: mtime, size: size)
    }

    private static func verify(before: [String: FileInfo], after: [String: FileInfo], baseName: String) -> [String] {
        var failures: [String] = []

        func expectReplaced(_ filename: String) {
            let path = fixtureRoot().appendingPathComponent(filename).path
            guard let beforeInfo = before[path] else {
                failures.append("\(filename): missing before")
                return
            }
            guard let afterInfo = after[path] else {
                failures.append("\(filename): missing after")
                return
            }
            if beforeInfo == afterInfo {
                failures.append("\(filename): not replaced")
            }
        }

        func expectPreserved(_ filename: String) {
            let path = fixtureRoot().appendingPathComponent(filename).path
            guard let beforeInfo = before[path] else {
                failures.append("\(filename): missing before")
                return
            }
            guard let afterInfo = after[path] else {
                failures.append("\(filename): missing after")
                return
            }
            if beforeInfo != afterInfo {
                failures.append("\(filename): changed")
            }
        }

        expectReplaced("\(baseName)-MaxHTML.html")
        expectReplaced("\(baseName)-MidHTML.html")

        expectPreserved("\(baseName)-mailHTML.html")
        expectPreserved("\(baseName).md")
        expectPreserved("\(baseName)-Sidecar.html")
        expectPreserved("\(baseName)-Sidecar/images/media_0001.jpg")

        return failures
    }

    private static func dumpManifest(label: String, root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[\(label)] (empty)")
            return
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }

        files.sort { $0.path < $1.path }
        for url in files {
            guard let info = fileInfo(at: url) else { continue }
            let mtime = manifestTimestamp(info.mtime)
            print("[\(label)] \(url.path) size=\(info.size) mtime=\(mtime)")
        }
    }
}

@MainActor
struct WETBareDomainLinkifyCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_LINKIFY_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private struct Case {
        let name: String
        let input: String
        let expected: String
        let linkifyHTTP: Bool
    }

    private static func run() {
        let cases: [Case] = [
            Case(
                name: "bare domain",
                input: "www.kama.info",
                expected: "<a href='https://www.kama.info' target='_blank' rel='noopener'>www.kama.info</a>",
                linkifyHTTP: true
            ),
            Case(
                name: "bare domain trailing punctuation",
                input: "kama.info.",
                expected: "<a href='https://kama.info' target='_blank' rel='noopener'>kama.info</a>.",
                linkifyHTTP: true
            ),
            Case(
                name: "bare domain in parentheses",
                input: "(www.kama.info)",
                expected: "(<a href='https://www.kama.info' target='_blank' rel='noopener'>www.kama.info</a>)",
                linkifyHTTP: true
            ),
            Case(
                name: "email is not a bare domain",
                input: "kontakt@kama.info",
                expected: "kontakt@kama.info",
                linkifyHTTP: true
            ),
            Case(
                name: "already schemed URL",
                input: "https://www.kama.info",
                expected: "<a href='https://www.kama.info' target='_blank' rel='noopener'>https://www.kama.info</a>",
                linkifyHTTP: true
            ),
            Case(
                name: "already anchored markdown link",
                input: "[www.kama.info](https://www.kama.info)",
                expected: "[www.kama.info](https://www.kama.info)",
                linkifyHTTP: true
            ),
            Case(
                name: "invalid dot word",
                input: "auch.nur",
                expected: "auch.nur",
                linkifyHTTP: true
            ),
            Case(
                name: "ccTLD bare domain",
                input: "example.de",
                expected: "<a href='https://example.de' target='_blank' rel='noopener'>example.de</a>",
                linkifyHTTP: true
            ),
            Case(
                name: "bare domain with previews enabled",
                input: "www.kama.info",
                expected: "<a href='https://www.kama.info' target='_blank' rel='noopener'>www.kama.info</a>",
                linkifyHTTP: false
            )
        ]

        var failures: [String] = []

        for c in cases {
            let output = WhatsAppExportService._linkifyHTMLForTesting(c.input, linkifyHTTP: c.linkifyHTTP)
            if output != c.expected {
                failures.append("[\(c.name)] expected: \(c.expected) | got: \(output)")
            }
        }

        if failures.isEmpty {
            print("WET_LINKIFY_CHECK: PASS")
        } else {
            print("WET_LINKIFY_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
    }
}

@MainActor
struct WETBareDomainPreviewCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_LINK_PREVIEW_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private struct Case {
        let name: String
        let input: String
        let expected: [String]
    }

    private static func run() {
        let cases: [Case] = [
            Case(
                name: "bare domain",
                input: "www.kama.info",
                expected: ["https://www.kama.info"]
            ),
            Case(
                name: "bare domain trailing punctuation",
                input: "www.kama.info.",
                expected: ["https://www.kama.info"]
            ),
            Case(
                name: "bare domain in parentheses",
                input: "(www.kama.info)",
                expected: ["https://www.kama.info"]
            ),
            Case(
                name: "email is not a preview",
                input: "kontakt@kama.info",
                expected: []
            ),
            Case(
                name: "invalid dot word",
                input: "auch.nur",
                expected: []
            ),
            Case(
                name: "ccTLD bare domain",
                input: "example.de",
                expected: ["https://example.de"]
            ),
            Case(
                name: "already schemed URL",
                input: "https://www.kama.info",
                expected: ["https://www.kama.info"]
            ),
            Case(
                name: "markdown link should not preview",
                input: "[www.kama.info](https://www.kama.info)",
                expected: []
            ),
            Case(
                name: "html anchor should not preview",
                input: "<a href=\"https://www.kama.info\">www.kama.info</a>",
                expected: []
            )
        ]

        var failures: [String] = []

        for c in cases {
            let output = WhatsAppExportService._previewTargetsForTesting(c.input)
            if output != c.expected {
                failures.append("[\(c.name)] expected: \(c.expected) | got: \(output)")
            }
        }

        if failures.isEmpty {
            print("WET_LINK_PREVIEW_CHECK: PASS")
        } else {
            print("WET_LINK_PREVIEW_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
    }
}

@MainActor
struct WETSystemMessageCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_SYSTEM_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private static func run() {
        let chatURL = URL(fileURLWithPath: "/Users/Marcel/Git/github.com/Marcello2020-dev/whatsapp-export-tools/_local/fixtures/private/WA_Test_Export/_chat.txt")
        let outDir = URL(fileURLWithPath: "/Users/Marcel/Git/github.com/Marcello2020-dev/whatsapp-export-tools/_local/fixtures/private/WA_Test_Export/_system_test_out", isDirectory: true)
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: outDir.path) {
                try fm.removeItem(at: outDir)
            }
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            print("WET_SYSTEM_CHECK: setup failed: \(error)")
            NSApp.terminate(nil)
            return
        }

        Task {
            do {
                let result = try await WhatsAppExportService.exportMulti(
                    chatURL: chatURL,
                    outDir: outDir,
                    meNameOverride: nil,
                    participantNameOverrides: [:],
                    variants: [.embedAll],
                    exportSortedAttachments: false,
                    allowOverwrite: true
                )

                guard let htmlURL = result.htmlByVariant[.embedAll],
                      let html = try? String(contentsOf: htmlURL, encoding: .utf8) else {
                    print("WET_SYSTEM_CHECK: export missing HTML")
                    NSApp.terminate(nil)
                    return
                }

                var failures: [String] = []
                let required = [
                    "Ende-zu-Ende-verschlüsselt",
                    "Du hast diesen Kontakt blockiert",
                    "Du hast diesen Kontakt freigegeben",
                    "Dein Sicherheitscode"
                ]

                if !html.contains("class='sys'") {
                    failures.append("system markup missing")
                }
                for phrase in required where !html.contains(phrase) {
                    failures.append("missing system phrase: \(phrase)")
                }
                if html.contains("href='https://auch.nur'") || html.contains("href=\"https://auch.nur\"") {
                    failures.append("invalid dot word linkified: auch.nur")
                }

                if failures.isEmpty {
                    print("WET_SYSTEM_CHECK: PASS")
                } else {
                    print("WET_SYSTEM_CHECK: FAIL")
                    for failure in failures {
                        print(" - \(failure)")
                    }
                }
            } catch {
                print("WET_SYSTEM_CHECK: export failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}
