import Foundation
import AppKit

@MainActor
struct WETOutputStructureDedupCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_OUTPUT_STRUCTURE_DEDUP_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private static func run() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        expect(
            WETPartnerNaming.normalizedPartnerFolderName("Carolin Lehmann Lehmann") == "Carolin Lehmann",
            "dedup trailing token"
        )
        expect(
            WETPartnerNaming.normalizedPartnerFolderName("Name Name") == "Name",
            "dedup double name"
        )
        expect(
            WETPartnerNaming.normalizedPartnerFolderName("A B C") == "A B C",
            "no change for distinct tokens"
        )
        expect(
            WETPartnerNaming.normalizedPartnerFolderName("A  B   B") == "A B",
            "collapse whitespace + dedup"
        )

        do {
            try runStructureTest(root: fixtureRoot(), failures: &failures)
        } catch {
            failures.append("structure test failed: \(error)")
        }

        if failures.isEmpty {
            print("WET_OUTPUT_STRUCTURE_DEDUP_CHECK: PASS")
        } else {
            print("WET_OUTPUT_STRUCTURE_DEDUP_CHECK: FAIL")
            for failure in failures {
                print(" - \(failure)")
            }
        }

        NSApp.terminate(nil)
    }

    private static func fixtureRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["WET_OUTPUT_STRUCTURE_DEDUP_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("_local/fixtures/wet/output-structure-dedup/out", isDirectory: true)
    }

    private static func runStructureTest(root: URL, failures: inout [String]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let partner = WETPartnerNaming.normalizedPartnerFolderName("X Y")
        let run1 = ContentView.runRootDirectory(outDir: root, partnerFolderName: partner, baseName: "Run1")
        let run2 = ContentView.runRootDirectory(outDir: root, partnerFolderName: partner, baseName: "Run2")

        try fm.createDirectory(at: run1, withIntermediateDirectories: true)
        try fm.createDirectory(at: run2, withIntermediateDirectories: true)

        let run1File = run1.appendingPathComponent("Run1-MaxHTML.html")
        let run2File = run2.appendingPathComponent("Run2-MaxHTML.html")
        try "dummy run1".write(to: run1File, atomically: true, encoding: .utf8)
        try "dummy run2".write(to: run2File, atomically: true, encoding: .utf8)

        if run1.deletingLastPathComponent().lastPathComponent != partner {
            failures.append("run1 not under partner folder")
        }
        if run2.deletingLastPathComponent().lastPathComponent != partner {
            failures.append("run2 not under partner folder")
        }
        if run1 == run2 {
            failures.append("run directories should differ")
        }
        if fm.fileExists(atPath: run1.appendingPathComponent(run2File.lastPathComponent).path) {
            failures.append("run2 artifacts appear in run1")
        }
        if fm.fileExists(atPath: run2.appendingPathComponent(run1File.lastPathComponent).path) {
            failures.append("run1 artifacts appear in run2")
        }
    }
}
