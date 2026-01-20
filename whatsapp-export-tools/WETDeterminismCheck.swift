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

    private static func run() {
        let folderRoot = rootURL(
            envKey: "WET_DETERMINISM_FOLDER_ROOT",
            fallback: "_local/fixtures/wet/determinism/folder"
        )
        let zipRoot = rootURL(
            envKey: "WET_DETERMINISM_ZIP_ROOT",
            fallback: "_local/fixtures/wet/determinism/zip"
        )

        do {
            let folderSnapshot = try snapshot(root: folderRoot)
            let zipSnapshot = try snapshot(root: zipRoot)

            let onlyFolder = Set(folderSnapshot.keys).subtracting(zipSnapshot.keys)
            let onlyZip = Set(zipSnapshot.keys).subtracting(folderSnapshot.keys)
            let shared = Set(folderSnapshot.keys).intersection(zipSnapshot.keys)
            let shaDiff = shared.filter { folderSnapshot[$0]?.sha256 != zipSnapshot[$0]?.sha256 }
            let shaDiffSorted = shaDiff.sorted()

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

            var mtimeHistogram: [Int: Int] = [:]
            for rel in shared {
                guard let a = folderSnapshot[rel], let b = zipSnapshot[rel] else { continue }
                let delta = Int((b.mtime.timeIntervalSince1970 - a.mtime.timeIntervalSince1970).rounded())
                mtimeHistogram[delta, default: 0] += 1
            }
            let topDeltas = mtimeHistogram.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            print("WET_DETERMINISM_CHECK: mtime-delta unique=\(mtimeHistogram.count)")
            for (delta, count) in topDeltas.prefix(12) {
                print("WET_DETERMINISM_CHECK: mtime-delta \(delta)s count=\(count)")
            }
            let plus3600 = mtimeHistogram[3600] ?? 0
            print("WET_DETERMINISM_CHECK: mtime-delta +3600s count=\(plus3600)")

            let hasDiffs = !onlyFolder.isEmpty || !onlyZip.isEmpty || !shaDiff.isEmpty || mdDiff
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

        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return out
        }

        for case let url as URL in e {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if rel.hasSuffix(".DS_Store") { continue }

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

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
