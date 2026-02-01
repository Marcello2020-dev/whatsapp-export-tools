import Foundation
import AppKit

@MainActor
struct WETDeleteOriginalsGateCheck {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["WET_DELETE_ORIGINALS_GATE_CHECK"] == "1"
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

        let allowed = ContentView.validateDeleteOriginals(copySourcesEnabled: true, deleteOriginalsEnabled: true)
        expect(allowed == nil, "delete originals allowed when copy sources enabled")

        let rejected = ContentView.validateDeleteOriginals(copySourcesEnabled: false, deleteOriginalsEnabled: true)
        expect(rejected != nil, "delete originals rejected when copy sources disabled")

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
}
