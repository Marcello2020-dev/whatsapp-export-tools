import Foundation
import AppKit
import CryptoKit

@MainActor
struct WETDeterminismCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_DETERMINISM_CHECK"] == "1"
    private static var didRun = false

    static func runIfNeeded() {
        guard isEnabled, !didRun else { return }
        didRun = true
        run()
    }

    private struct FileInfo: Equatable {
        let size: UInt64
        let sha256: String
        let mtime: Date
    }

    private struct PayloadManifestSummary {
        let fileCount: Int
        let sha256: String
    }

    private static func run() {
        let folderRoot = rootURL(
            envKey: "WET_DETERMINISM_FOLDER_ROOT",
            fallback: "_local/fixtures/wet/determinism/folder"
        )
        let zipRoot = rootURL(
            envKey: "WET_DETERMINISM_ZIP_ROOT",
            fallback: "_local/fixtures/wet/determinism/zip"
        )
        let zipMtimeInput = rootURL(
            envKey: "WET_ZIP_MTIME_INPUT",
            fallback: "_local/fixtures/wet/zip-mtime/whatsapp.zip"
        )

        do {
            var zipMtimeDriftDetected = false
            let fm = FileManager.default
            if zipMtimeInput.pathExtension.lowercased() == "zip",
               fm.fileExists(atPath: zipMtimeInput.path),
               fm.fileExists(atPath: folderRoot.path) {
                do {
                    let zipSnapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: zipMtimeInput)
                    let extractedSnapshot = try snapshot(root: zipSnapshot.exportDir)
                    let folderSnapshot = try snapshot(root: folderRoot)
                    let shared = Set(folderSnapshot.keys).intersection(extractedSnapshot.keys)
                    let mtimeHistogram = mtimeHistogramFor(shared: shared, folderSnapshot: folderSnapshot, zipSnapshot: extractedSnapshot)
                    let driftDetected = detectSystematicMtimeDrift(sharedCount: shared.count, mtimeHistogram: mtimeHistogram)
                    zipMtimeDriftDetected = driftDetected
                    print("WET_DETERMINISM_CHECK: zip-mtime-drift shared=\(shared.count) drift=\(driftDetected)")
                    if let temp = zipSnapshot.tempWorkspaceURL {
                        try? fm.removeItem(at: temp)
                    }
                } catch {
                    zipMtimeDriftDetected = true
                    print("WET_DETERMINISM_CHECK: zip-mtime-drift FAIL: \(error)")
                }
            } else {
                print("WET_DETERMINISM_CHECK: zip-mtime-drift SKIP (missing fixture)")
            }

            let folderSnapshot = try snapshot(root: folderRoot)
            let zipSnapshot = try snapshot(root: zipRoot)

            let onlyFolder = Set(folderSnapshot.keys).subtracting(zipSnapshot.keys)
            let onlyZip = Set(zipSnapshot.keys).subtracting(folderSnapshot.keys)
            let shared = Set(folderSnapshot.keys).intersection(zipSnapshot.keys)
            let shaDiff = shared.filter { folderSnapshot[$0]?.sha256 != zipSnapshot[$0]?.sha256 }
            let shaDiffSorted = shaDiff.sorted()

            let folderPayload = payloadManifestSummary(from: folderSnapshot)
            let zipPayload = payloadManifestSummary(from: zipSnapshot)
            let payloadMatch = folderPayload.sha256 == zipPayload.sha256
            print("PAYLOAD-MANIFEST: files=\(folderPayload.fileCount) sha256=\(folderPayload.sha256)")
            print("PAYLOAD-MANIFEST: files=\(zipPayload.fileCount) sha256=\(zipPayload.sha256)")
            print("WET_DETERMINISM_CHECK: payload-match=\(payloadMatch)")

            let mdRel = mainMarkdownPath(in: folderSnapshot) ?? mainMarkdownPath(in: zipSnapshot)
            let mdDiff: Bool = {
                guard let mdRel,
                      let a = folderSnapshot[mdRel],
                      let b = zipSnapshot[mdRel] else {
                    return true
                }
                return a.sha256 != b.sha256
            }()

            print("WET_DETERMINISM_CHECK: fileCount folder=\(folderSnapshot.count) zip=\(zipSnapshot.count)")
            print("WET_DETERMINISM_CHECK: onlyFolder=\(onlyFolder.count) onlyZip=\(onlyZip.count) shaDiff=\(shaDiff.count)")
            if !shaDiffSorted.isEmpty {
                let maxList = 20
                for rel in shaDiffSorted.prefix(maxList) {
                    if let a = folderSnapshot[rel], let b = zipSnapshot[rel] {
                        print("WET_DETERMINISM_CHECK: shaDiff \(rel) \(a.sha256) \(b.sha256)")
                    } else {
                        print("WET_DETERMINISM_CHECK: shaDiff \(rel)")
                    }
                }
            }
            if let mdRel {
                print("WET_DETERMINISM_CHECK: markdown relpath=\(mdRel) match=\(!mdDiff)")
            } else {
                print("WET_DETERMINISM_CHECK: markdown relpath not found")
            }

            let mtimeHistogram = mtimeHistogramFor(shared: shared, folderSnapshot: folderSnapshot, zipSnapshot: zipSnapshot)
            let topDeltas = mtimeHistogram.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            print("WET_DETERMINISM_CHECK: mtime-delta unique=\(mtimeHistogram.count)")
            for (delta, count) in topDeltas.prefix(12) {
                print("WET_DETERMINISM_CHECK: mtime-delta \(delta)s count=\(count)")
            }
            let plus3600 = mtimeHistogram[3600] ?? 0
            let minus3600 = mtimeHistogram[-3600] ?? 0
            print("WET_DETERMINISM_CHECK: mtime-delta +3600s count=\(plus3600)")
            print("WET_DETERMINISM_CHECK: mtime-delta -3600s count=\(minus3600)")
            let driftDetected = detectSystematicMtimeDrift(sharedCount: shared.count, mtimeHistogram: mtimeHistogram)
            if driftDetected {
                let driftCount = mtimeHistogram.filter { abs(abs($0.key) - 3600) <= 2 }.values.reduce(0, +)
                let sharedCount = max(shared.count, 1)
                let driftRatio = Double(driftCount) / Double(sharedCount)
                print("WET_DETERMINISM_CHECK: mtime-drift ±3600s detected count=\(driftCount) ratio=\(String(format: "%.2f", driftRatio))")
            }

            let hasDiffs = !onlyFolder.isEmpty || !onlyZip.isEmpty || !shaDiff.isEmpty || mdDiff || !payloadMatch || driftDetected || zipMtimeDriftDetected
            if hasDiffs {
                print("WET_DETERMINISM_CHECK: FAIL")
            } else {
                print("WET_DETERMINISM_CHECK: PASS")
            }
        } catch {
            print("WET_DETERMINISM_CHECK: FAIL: \(error)")
        }

        if NSApp != nil {
            NSApp.terminate(nil)
        } else {
            exit(0)
        }
    }

    private static func rootURL(envKey: String, fallback: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[envKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(fallback, isDirectory: true)
    }

    private static func mainMarkdownPath(in map: [String: FileInfo]) -> String? {
        let mdFiles = map.keys.filter { $0.lowercased().hasSuffix(".md") }
        if mdFiles.count == 1 { return mdFiles[0] }
        return mdFiles.sorted().first
    }

    private static func snapshot(root: URL) throws -> [String: FileInfo] {
        let fm = FileManager.default
        var out: [String: FileInfo] = [:]

        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else {
            return out
        }

        for case let url as URL in e {
            guard let rel = normalizedRelPath(root: root, url: url) else { continue }
            if isMacOSNoisePath(rel) { continue }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if values.isDirectory == true { continue }

            let data = try Data(contentsOf: url)
            let size = UInt64(values.fileSize ?? data.count)
            let sha = sha256Hex(data)
            let mtime = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            out[rel] = FileInfo(size: size, sha256: sha, mtime: mtime)
        }

        return out
    }

    private static func mtimeHistogramFor(
        shared: Set<String>,
        folderSnapshot: [String: FileInfo],
        zipSnapshot: [String: FileInfo]
    ) -> [Int: Int] {
        var histogram: [Int: Int] = [:]
        for rel in shared {
            guard let a = folderSnapshot[rel], let b = zipSnapshot[rel] else { continue }
            let delta = Int((b.mtime.timeIntervalSince1970 - a.mtime.timeIntervalSince1970).rounded())
            histogram[delta, default: 0] += 1
        }
        return histogram
    }

    private static func detectSystematicMtimeDrift(sharedCount: Int, mtimeHistogram: [Int: Int]) -> Bool {
        let total = max(sharedCount, 1)
        let driftCandidates = mtimeHistogram.filter { abs(abs($0.key) - 3600) <= 2 }
        let driftCount = driftCandidates.values.reduce(0, +)
        let driftRatio = Double(driftCount) / Double(total)
        return driftCount >= 3 && driftRatio >= 0.8
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedRelPath(root: URL, url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return nil }
        var rel = String(fullPath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        guard !rel.isEmpty else { return nil }
        return rel.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\\", with: "/")
    }

    private static func isMacOSNoisePath(_ rel: String) -> Bool {
        for comp in rel.split(separator: "/") {
            let c = String(comp)
            let lower = c.lowercased()
            if lower == ".ds_store" { return true }
            if lower == "__macosx" { return true }
            if lower == ".spotlight-v100" { return true }
            if lower == ".fseventsd" { return true }
            if c.hasPrefix("._") { return true }
        }
        return false
    }

    private static func payloadManifestSummary(from snapshot: [String: FileInfo]) -> PayloadManifestSummary {
        let lines = snapshot
            .map { key, info in (key, info) }
            .sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
            .map { rel, info in "\(rel)\t\(info.size)\t\(info.sha256)" }
        let body = lines.joined(separator: "\n") + "\n"
        let hash = sha256Hex(Data(body.utf8))
        return PayloadManifestSummary(fileCount: lines.count, sha256: hash)
    }
}
