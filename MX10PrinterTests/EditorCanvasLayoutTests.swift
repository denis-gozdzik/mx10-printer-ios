import CoreGraphics
import XCTest
@testable import MX10Printer

final class EditorCanvasLayoutTests: XCTestCase {
    func testCanvasFitsTypicalIPhoneViewportWithoutOverflow() {
        let layout = EditorCanvasLayout(
            pageSize: CGSize(width: 384, height: 640),
            availableSize: CGSize(width: 369, height: 552)
        )

        print("EDITOR_CANVAS_SCALE viewport=369x552 scale=\(layout.scale)")
        XCTAssertLessThanOrEqual(layout.displaySize.width, 369)
        XCTAssertLessThanOrEqual(layout.displaySize.height, 552)
        XCTAssertGreaterThan(layout.scale, 0)
    }

    func testScaleNeverExceedsOne() {
        let scale = EditorCanvasLayout.scale(
            pageSize: CGSize(width: 384, height: 640),
            availableSize: CGSize(width: 800, height: 1_200)
        )

        XCTAssertEqual(scale, 1)
    }

    func testWidthConstrainedViewportProducesExpectedScale() {
        let scale = EditorCanvasLayout.scale(
            pageSize: CGSize(width: 384, height: 640),
            availableSize: CGSize(width: 192, height: 1_000)
        )

        XCTAssertEqual(scale, 0.5)
    }

    func testHeightConstrainedViewportProducesExpectedScale() {
        let scale = EditorCanvasLayout.scale(
            pageSize: CGSize(width: 384, height: 640),
            availableSize: CGSize(width: 1_000, height: 320)
        )

        XCTAssertEqual(scale, 0.5)
    }

    func testDisplayTranslationConversionDividesByScale() {
        let translation = EditorCanvasLayout.documentTranslation(
            displayTranslation: CGSize(width: 75, height: -30),
            scale: 0.75
        )

        XCTAssertEqual(translation.width, 100)
        XCTAssertEqual(translation.height, -40)
    }

    func testScaleOneKeepsTranslationUnchanged() {
        let translation = EditorCanvasLayout.documentTranslation(
            displayTranslation: CGSize(width: 42, height: 18),
            scale: 1
        )

        XCTAssertEqual(translation.width, 42)
        XCTAssertEqual(translation.height, 18)
    }

    func testInvalidAvailableDimensionsFailSafely() {
        let layout = EditorCanvasLayout(
            pageSize: CGSize(width: 384, height: 640),
            availableSize: CGSize(width: 0, height: CGFloat.infinity)
        )
        let translation = EditorCanvasLayout.documentTranslation(
            displayTranslation: CGSize(width: 20, height: 20),
            scale: layout.scale
        )

        XCTAssertEqual(layout.scale, 0)
        XCTAssertEqual(layout.displaySize, CGSize.zero)
        XCTAssertEqual(translation, CGSize.zero)
    }
}
