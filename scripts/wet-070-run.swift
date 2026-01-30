import Foundation

@main
struct WET070Runner {
    struct RunSnapshot {
        let manifestData: Data
        let shaData: Data
        let bundleHash: String
        let listing: [String]
        let baseName: String
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            fputs("Usage: wet-070-run <input-path> <output-dir> <sidecar|nosidecar>\n", stderr)
            exit(2)
        }

        let inputURL = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
        let mode = args[3].lowercased()
        let exportSidecar: Bool
        switch mode {
        case "sidecar":
            exportSidecar = true
        case "nosidecar", "no-sidecar":
            exportSidecar = false
        default:
            fputs("Invalid mode. Use sidecar or nosidecar.\n", stderr)
            exit(2)
        }

        do {
            let fm = FileManager.default

            func ensureCleanDir(_ url: URL) throws {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }

            let snapshot = try WhatsAppExportService.resolveInputSnapshot(inputURL: inputURL)
            defer {
                if let tmp = snapshot.tempWorkspaceURL, fm.fileExists(atPath: tmp.path) {
                    try? fm.removeItem(at: tmp)
                }
            }

            func runOnce(label: String) async throws -> RunSnapshot {
                try ensureCleanDir(outDir)

                let result = try await WhatsAppExportService.exportMulti(
                    chatURL: snapshot.chatURL,
                    outDir: outDir,
                    meNameOverride: "Me",
                    participantNameOverrides: [:],
                    variants: [.embedAll, .thumbnailsOnly, .textOnly],
                    exportSortedAttachments: exportSidecar,
                    allowOverwrite: true
                )

                let primary = result.primaryHTML.lastPathComponent
                let suffixes = ["-max.html", "-mid.html", "-min.html"]
                var baseName = primary
                for suffix in suffixes where baseName.hasSuffix(suffix) {
                    baseName = String(baseName.dropLast(suffix.count))
                    break
                }

                let manifestURL = outDir.appendingPathComponent("\(baseName).manifest.json")
                let shaURL = outDir.appendingPathComponent("\(baseName).sha256")

                let manifestData = try Data(contentsOf: manifestURL)
                let shaData = try Data(contentsOf: shaURL)

                let bundleHash: String = {
                    guard let obj = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                          let hash = obj["bundleHashSha256"] as? String else {
                        return "n/a"
                    }
                    return hash
                }()

                let listing = (try? fm.contentsOfDirectory(
                    at: outDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ))?.map { $0.lastPathComponent }.sorted() ?? []

                print("RUN \(label): baseName=\(baseName) manifestBytes=\(manifestData.count) shaBytes=\(shaData.count) bundleHash=\(bundleHash)")

                return RunSnapshot(
                    manifestData: manifestData,
                    shaData: shaData,
                    bundleHash: bundleHash,
                    listing: listing,
                    baseName: baseName
                )
            }

            let first = try await runOnce(label: "1")
            let second = try await runOnce(label: "2")

            let manifestMatch = first.manifestData == second.manifestData
            let shaMatch = first.shaData == second.shaData
            let bundleMatch = first.bundleHash == second.bundleHash

            print("DETERMINISM manifest=\(manifestMatch) sha=\(shaMatch) bundleHash=\(bundleMatch)")

            if manifestMatch && shaMatch && bundleMatch {
                print("WET-070: PASS")
            } else {
                print("WET-070: FAIL")
                exit(1)
            }

            print("OUTPUT LISTING:")
            for name in second.listing {
                print("- \(name)")
            }
        } catch {
            print("WET-070: FAIL: \(error)")
            exit(1)
        }
    }
}
