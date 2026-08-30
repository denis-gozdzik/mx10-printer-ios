import XCTest
@testable import MX10Printer

@MainActor
final class PreviewDebouncerTests: XCTestCase {
    func testRepeatedSchedulesDoNotRunOnePreviewBuildPerEvent() async throws {
        let debouncer = PreviewDebouncer(delayNanoseconds: 20_000_000)
        var builds: [Int] = []

        debouncer.schedule {
            builds.append(1)
        }
        debouncer.schedule {
            builds.append(2)
        }
        debouncer.schedule {
            builds.append(3)
        }

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(builds, [3])
    }

    func testForcedPreviewCancelsPendingWorkAndUsesLatestState() async throws {
        let debouncer = PreviewDebouncer(delayNanoseconds: 100_000_000)
        var renderedState = "none"
        var document = PrintDocument(title: "Original")

        debouncer.schedule {
            renderedState = document.title
        }

        document.title = "Latest"
        debouncer.performImmediately {
            renderedState = document.title
        }

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(renderedState, "Latest")
    }
}
