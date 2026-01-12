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

    private static let manifestFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

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

        let sidecarDir = root.appendingPathComponent(baseName, isDirectory: true)
        try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)

        let seedFiles: [(String, String)] = [
            ("\(baseName)-max.html", "dummy max"),
            ("\(baseName)-mid.html", "dummy mid"),
            ("\(baseName)-min.html", "dummy email"),
            ("\(baseName).md", "dummy md"),
            ("\(baseName)-sdc.html", "dummy sidecar html")
        ]
        for (name, content) in seedFiles {
            let url = root.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        let sidecarFiles: [(String, String)] = [
            ("media-index.json", "dummy sidecar index"),
            ("media_0001.jpg", "dummy asset")
        ]
        for (name, content) in sidecarFiles {
            let url = sidecarDir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func runReplace(root: URL, baseName: String) throws {
        let fm = FileManager.default
        let variantSuffixes = ["-max", "-mid"]
        let deleteTargets = ContentView.replaceDeleteTargets(
            baseName: baseName,
            variantSuffixes: variantSuffixes,
            wantsMarkdown: false,
            wantsSidecar: false,
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
            to: root.appendingPathComponent("\(baseName)-max.html"),
            atomically: true,
            encoding: .utf8
        )
        try "replaced mid".write(
            to: root.appendingPathComponent("\(baseName)-mid.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func snapshot(root: URL, baseName: String) -> [String: FileInfo] {
        let files: [URL] = [
            root.appendingPathComponent("\(baseName)-max.html"),
            root.appendingPathComponent("\(baseName)-mid.html"),
            root.appendingPathComponent("\(baseName)-min.html"),
            root.appendingPathComponent("\(baseName).md"),
            root.appendingPathComponent("\(baseName)-sdc.html"),
            root.appendingPathComponent("\(baseName)/media-index.json"),
            root.appendingPathComponent("\(baseName)/media_0001.jpg")
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

        expectReplaced("\(baseName)-max.html")
        expectReplaced("\(baseName)-mid.html")

        expectPreserved("\(baseName)-min.html")
        expectPreserved("\(baseName).md")
        expectPreserved("\(baseName)-sdc.html")
        expectPreserved("\(baseName)/media-index.json")
        expectPreserved("\(baseName)/media_0001.jpg")

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
            let mtime = manifestFormatter.string(from: info.mtime)
            print("[\(label)] \(url.path) size=\(info.size) mtime=\(mtime)Z")
        }
    }
}
