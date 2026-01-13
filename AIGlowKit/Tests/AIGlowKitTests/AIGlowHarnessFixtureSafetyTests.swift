import XCTest
import AIGlowKitDevTools

final class AIGlowHarnessFixtureSafetyTests: XCTestCase {
    func testFixturesArePIISafe() {
        let tokens = AIGlowHarnessStrings.allTextTokens
        let patterns = [
            "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
            "\\d{5,}",
            "\\b(street|st\\.|avenue|ave\\.|road|rd\\.|boulevard|blvd\\.|lane|ln\\.)\\b",
            "https?://"
        ]

        for token in tokens {
            for pattern in patterns {
                XCTAssertNil(
                    token.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                    "PII-like token found: \(token)"
                )
            }
        }
    }

    func testHarnessDisallowsExternalDataAccess() {
        XCTAssertFalse(AIGlowHarnessPolicy.allowsExternalDataAccess)
    }
}
