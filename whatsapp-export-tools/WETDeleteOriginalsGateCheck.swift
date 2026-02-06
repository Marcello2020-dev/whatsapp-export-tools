import Foundation
import AppKit

@MainActor
/// Gate check that asserts delete-originals only runs when the copied sources match the originals byte-for-byte.
struct WETDeleteOriginalsGateCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_DELETE_ORIGINALS_GATE_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    /// Executes the fixture-driven validation steps and exits the app after printing PASS/FAIL.
    private static func run() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let allowed = ContentView.validateDeleteOriginals(copySourcesEnabled: true, deleteOriginalsEnabled: true)
        expect(allowed == nil, "delete originals allowed when copy sources enabled")

        let rejected = ContentView.validateDeleteOriginals(copySourcesEnabled: false, deleteOriginalsEnabled: true)
        expect(rejected != nil, "delete originals rejected when copy sources disabled")

        do {
            try runRawArchiveVerificationGateTest(root: fixtureRoot(), failures: &failures)
        } catch {
            failures.append("raw-archive verification test failed: \(error)")
        }

        if failures.isEmpty {
            print("WET_DELETE_ORIGINALS_GATE_CHECK: PASS")
        } else {
            print("WET_DELETE_ORIGINALS_GATE_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
    }

    /// Locates the fixture folder, allowing overriding via env var for local debugging.
    private static func fixtureRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["WET_DELETE_ORIGINALS_GATE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("_local/fixtures/wet/delete-originals-gate/out", isDirectory: true)
    }

    /// Exercises the raw archive verification logic by staging fixture copies with drift, tamper, and missing zip cases.
    private static func runRawArchiveVerificationGateTest(root: URL, failures: inout [String]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let originalDir = sourceRoot.appendingPathComponent("WhatsApp Chat - Gate Fixture", isDirectory: true)
        try fm.createDirectory(at: originalDir, withIntermediateDirectories: true)
        let originalChat = originalDir.appendingPathComponent("_chat.txt")
        try "Gate fixture chat\n".write(to: originalChat, atomically: true, encoding: .utf8)

        let stableDate = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-11T00:00:00Z
        func setStableTimestamps(_ url: URL, to date: Date = stableDate) {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        setStableTimestamps(originalChat)
        setStableTimestamps(originalDir)

        let exportDir = root.appendingPathComponent("export", isDirectory: true)
        let rawRoot = SourceOps.rawArchiveDirectory(baseName: "GateRun", in: exportDir)
        let copiedDir = rawRoot.appendingPathComponent(originalDir.lastPathComponent, isDirectory: true)
        let copiedChat = copiedDir.appendingPathComponent("_chat.txt")

        // Helper to wipe/recreate the copied folder so each verification step starts from a clean copy.
        func stageFreshCopy() throws {
            if fm.fileExists(atPath: copiedDir.path) {
                try fm.removeItem(at: copiedDir)
            }
            try fm.createDirectory(at: rawRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: originalDir, to: copiedDir)
            setStableTimestamps(copiedChat)
            setStableTimestamps(copiedDir)
        }

        let provenance = WETSourceProvenance(
            inputKind: .folder,
            detectedFolderURL: originalDir,
            originalZipURL: nil,
            detectedPartnerRaw: "",
            overridePartnerRaw: nil
        )
        let missingZipProvenance = WETSourceProvenance(
            inputKind: .folder,
            detectedFolderURL: originalDir,
            originalZipURL: root.appendingPathComponent("missing-original.zip"),
            detectedPartnerRaw: "",
            overridePartnerRaw: nil
        )

        // Runs the raw archive verification gate and returns the collected result for the current fixture state.
        func verify(_ p: WETSourceProvenance = provenance) -> SourceOpsVerificationResult {
            SourceOps.verifyRawArchive(
                baseName: "GateRun",
                exportDir: exportDir,
                provenance: p
            )
        }

        try stageFreshCopy()
        var result = verify()
        if !result.deletableOriginals.contains(originalDir) {
            failures.append("delete gate should allow originals when bytes+timestamps match")
        }
        if !result.gateFailures.isEmpty {
            failures.append("gate failures should be empty on clean copy")
        }

        result = verify(missingZipProvenance)
        if !result.deletableOriginals.contains(originalDir) {
            failures.append("missing original zip must not block folder delete gate")
        }
        if result.gateFailures.contains("zip-byte-mismatch") {
            failures.append("missing original zip must not produce zip-byte-mismatch")
        }

        try stageFreshCopy()
        let drifted = stableDate.addingTimeInterval(3600)
        setStableTimestamps(copiedChat, to: drifted)
        result = verify()
        if !result.deletableOriginals.contains(originalDir) {
            failures.append("timestamp drift must not block delete gate")
        }
        if !result.gateFailures.isEmpty {
            failures.append("timestamp drift must not create gate failure")
        }
        if result.exportDirTimestampsMatch {
            failures.append("timestamp drift should still be detected as advisory mismatch")
        }

        try stageFreshCopy()
        try "Gate fixture chat tampered\n".write(to: copiedChat, atomically: true, encoding: .utf8)
        setStableTimestamps(copiedChat)
        setStableTimestamps(copiedDir)
        result = verify()
        if result.deletableOriginals.contains(originalDir) {
            failures.append("byte mismatch must block delete gate")
        }
        if !result.gateFailures.contains("sources-byte-mismatch") {
            failures.append("byte mismatch should report sources-byte-mismatch")
        }
    }
}
