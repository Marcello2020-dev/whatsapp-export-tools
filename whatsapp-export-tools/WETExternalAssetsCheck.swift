import Foundation
import AppKit

@MainActor
/// Validates that external asset publishing preserves asset folders and HTML references in the export directory.
struct WETExternalAssetsCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_EXTERNAL_ASSETS_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    /// Runs the fixture workflow: stage directories, publish assets, and assert the final export contains everything expected.
    private static func run() {
        let root = fixtureRoot()
        let staging = root.appendingPathComponent(".wa_export_tmp_test", isDirectory: true)

        do {
            try prepare(root: root, staging: staging)
            let htmlStaged = try seedExternalAssets(staging: staging)
            try publishExternalAssets(staging: staging, exportDir: root)
            try publishHTML(staged: htmlStaged, exportDir: root)
            try verify(root: root)
            print("WET_EXTERNAL_ASSETS_CHECK: PASS")
        } catch {
            print("WET_EXTERNAL_ASSETS_CHECK: FAIL: \(error)")
        }

        NSApp.terminate(nil)
    }

    /// Locates the external-assets fixture tree, with an optional environment override.
    private static func fixtureRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["WET_EXTERNAL_ASSETS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("_local/fixtures/wet/synthetic/external-assets-test/out", isDirectory: true)
    }

    /// Cleans and re-creates the fixture export + staging directories.
    private static func prepare(root: URL, staging: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    /// Places fake thumbnails/previews and a sample HTML referencing them into the staging area.
    private static func seedExternalAssets(staging: URL) throws -> URL {
        let thumbsDir = staging.appendingPathComponent("_thumbs", isDirectory: true)
        let previewsDir = staging.appendingPathComponent("_previews", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)

        let thumbFile = thumbsDir.appendingPathComponent("thumb_test.jpg")
        let previewFile = previewsDir.appendingPathComponent("preview_test.png")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: thumbFile, options: .atomic)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: previewFile, options: .atomic)

        let html = """
        <html><body>
        <img src="_thumbs/thumb_test.jpg">
        <img src="_previews/preview_test.png">
        </body></html>
        """
        let htmlStaged = staging.appendingPathComponent("external_assets_test.html")
        try html.write(to: htmlStaged, atomically: true, encoding: .utf8)
        return htmlStaged
    }

    /// Relies on `WhatsAppExportService` to publish any `_thumbs/_previews` folders from staging into the export.
    private static func publishExternalAssets(staging: URL, exportDir: URL) throws {
        _ = try WhatsAppExportService.publishExternalAssetsIfPresent(
            stagingRoot: staging,
            exportDir: exportDir,
            allowOverwrite: true,
            debugEnabled: true,
            debugLog: { msg in print("WET_EXTERNAL_ASSETS_CHECK: \(msg)") }
        )
    }

    /// Moves the generated HTML into the export directory after assets are published.
    private static func publishHTML(staged: URL, exportDir: URL) throws {
        let final = exportDir.appendingPathComponent(staged.lastPathComponent)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: staged, to: final)
    }

    /// Asserts the exported directories/HTML contain the referenced `_thumbs/_previews` data after publishing.
    private static func verify(root: URL) throws {
        let fm = FileManager.default
        let thumbsDir = root.appendingPathComponent("_thumbs", isDirectory: true)
        let previewsDir = root.appendingPathComponent("_previews", isDirectory: true)

        func assertNonEmptyDir(_ dir: URL) throws {
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                throw NSError(domain: "WETExternalAssetsCheck", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing directory: \(dir.lastPathComponent)"
                ])
            }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if files.isEmpty {
                throw NSError(domain: "WETExternalAssetsCheck", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Empty directory: \(dir.lastPathComponent)"
                ])
            }
        }

        try assertNonEmptyDir(thumbsDir)
        try assertNonEmptyDir(previewsDir)

        let htmlURL = root.appendingPathComponent("external_assets_test.html")
        let html = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
        if !html.contains("_thumbs/") || !html.contains("_previews/") {
            throw NSError(domain: "WETExternalAssetsCheck", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "HTML missing _thumbs/_previews references"
            ])
        }
    }
}
