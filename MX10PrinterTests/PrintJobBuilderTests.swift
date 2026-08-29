import XCTest
@testable import MX10Printer

@MainActor
final class PrintJobBuilderTests: XCTestCase {
    func testInvalidImageDecodeFailsBeforeEnqueue() {
        let invalidImage = ImageElement(
            frame: PrintElementFrame(x: 0, y: 0, width: 100, height: 100),
            imageData: Data([0x00, 0x01, 0x02])
        )
        let document = PrintDocument(
            pages: [
                PrintPage(elements: [.image(invalidImage)])
            ]
        )
        let builder = PrintJobBuilder(logger: makeLogger())

        XCTAssertThrowsError(
            try builder.makePreview(document: document, preferences: PrintingPreferences())
        ) { error in
            guard case PrintJobBuildError.imageDecodeFailed = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testBuilderProduces384PixelRasterWith48BytesPerRow() throws {
        var document = PrintDocument(title: "Raster")
        _ = document.addTextElement()
        let builder = PrintJobBuilder(logger: makeLogger())

        let preview = try builder.makePreview(
            document: document,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )

        XCTAssertEqual(preview.renderedImage.width, BitmapRasterizer.targetWidth)
        XCTAssertFalse(preview.rasterRows.isEmpty)
        XCTAssertTrue(preview.rasterRows.allSatisfy { $0.count == BitmapRasterizer.rowByteCount })
        XCTAssertEqual(preview.previewImage?.width, BitmapRasterizer.targetWidth)
    }

    func testEditedTextChangesRenderedRasterOutput() throws {
        var document = PrintDocument(title: "Text")
        let elementID = document.addTextElement()
        let builder = PrintJobBuilder(logger: makeLogger())
        let preferences = PrintingPreferences(ditheringMode: .threshold, threshold: 200)

        let before = try builder.makePreview(document: document, preferences: preferences)

        document.updateElement(id: elementID) { element in
            guard case .text(var textElement) = element else {
                return
            }

            textElement.text = "Zażółć gęślą jaźń"
            textElement.isBold = true
            element = .text(textElement)
        }

        let after = try builder.makePreview(document: document, preferences: preferences)

        XCTAssertNotEqual(before.rasterRows, after.rasterRows)
    }

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 100,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}
