import XCTest
@testable import MX10Printer

final class PrintingPreferencesTests: XCTestCase {
    func testDefaultThresholdIsOneTwentyEight() {
        XCTAssertEqual(PrintingPreferences().threshold, 128)
    }

    func testDecodingLegacyPreferencesWithoutThresholdKeepsDefault() throws {
        let data = """
        {
            "ditheringMode": "floydSteinberg",
            "defaultFeedAfterPrint": 16
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(PrintingPreferences.self, from: data)

        XCTAssertEqual(preferences.threshold, 128)
        XCTAssertEqual(preferences.ditheringMode, .floydSteinberg)
    }
}
