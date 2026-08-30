import UIKit
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
        XCTAssertGreaterThan(preview.printRowCount, 0)
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

    func testTrailingBlankRowsAreRemovedWithBottomMargin() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [112])

        let result = try builder.trimRasterRowsForPrinting(rows)

        XCTAssertEqual(result.originalRows, 640)
        XCTAssertEqual(result.printRows, 136)
        XCTAssertEqual(result.removedRows, 504)
        XCTAssertEqual(result.bottomMargin, 24)
    }

    func testTwentyFourRowBottomMarginIsRetained() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [112])

        let result = try builder.trimRasterRowsForPrinting(rows)

        XCTAssertEqual(result.rows[111], blackRow())
        XCTAssertEqual(Array(result.rows[112...135]), Array(repeating: whiteRow(), count: 24))
    }

    func testContentReachingBottomIsNotTrimmed() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [640])

        let result = try builder.trimRasterRowsForPrinting(rows)

        XCTAssertEqual(result.printRows, 640)
        XCTAssertEqual(result.removedRows, 0)
    }

    func testLeadingWhitespaceRemainsUnchanged() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [120])

        let result = try builder.trimRasterRowsForPrinting(rows)

        XCTAssertEqual(Array(result.rows.prefix(119)), Array(rows.prefix(119)))
    }

    func testCompletelyBlankRasterReturnsEmptyContent() {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = Array(repeating: whiteRow(), count: 640)

        XCTAssertThrowsError(try builder.trimRasterRowsForPrinting(rows)) { error in
            XCTAssertEqual(error as? PrintJobBuildError, .emptyContent)
        }
    }

    func testCompletelyBlankDocumentReturnsEmptyContent() {
        let builder = PrintJobBuilder(logger: makeLogger())
        let document = PrintDocument(title: "Blank")

        XCTAssertThrowsError(
            try builder.makeJob(
                document: document,
                preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
            )
        ) { error in
            XCTAssertEqual(error as? PrintJobBuildError, .emptyContent)
        }
    }

    func testTrimmedRowsRemainExactlyFortyEightBytes() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [112])

        let result = try builder.trimRasterRowsForPrinting(rows)

        XCTAssertTrue(result.rows.allSatisfy { $0.count == BitmapRasterizer.rowByteCount })
    }

    func testOriginalPreviewRasterRemainsUnchangedWhenMakingJob() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [112])
        let preview = PrintPreview(
            renderedImage: solidImage(height: 640, gray: 255),
            rasterRows: rows,
            printRowCount: builder.printableRowCount(for: rows),
            previewImage: nil
        )
        let originalRows = preview.rasterRows

        _ = try builder.makeJob(
            document: PrintDocument(title: "Trim"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(preview.rasterRows, originalRows)
    }

    func testPrintJobReceivesTrimmedRows() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let rows = rasterRows(count: 640, blackRowNumbers: [112])
        let preview = PrintPreview(
            renderedImage: solidImage(height: 640, gray: 255),
            rasterRows: rows,
            printRowCount: builder.printableRowCount(for: rows),
            previewImage: nil
        )

        let job = try builder.makeJob(
            document: PrintDocument(title: "Trim"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(job.rows.count, 136)
        XCTAssertEqual(job.rows.last, whiteRow())
    }

    func testPrintJobCreationUsesLatestDocumentState() throws {
        var document = PrintDocument(title: "Latest")
        let elementID = document.addTextElement()
        let builder = PrintJobBuilder(logger: makeLogger())

        document.updateElement(id: elementID) { element in
            guard case .text(var textElement) = element else {
                return
            }

            textElement.text = "Latest state"
            textElement.fontSize = 42
            element = .text(textElement)
        }

        let job = try builder.makeJob(
            document: document,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 200)
        )

        XCTAssertFalse(job.rows.isEmpty)
        XCTAssertLessThanOrEqual(job.rows.count, 640)
    }

    func testBuilderAcceptsDocumentContainingQR() throws {
        var document = PrintDocument(title: "QR")
        _ = document.addQRCodeElement()
        let builder = PrintJobBuilder(logger: makeLogger())

        let job = try builder.makeJob(
            document: document,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )

        XCTAssertFalse(job.rows.isEmpty)
        XCTAssertTrue(job.rows.allSatisfy { $0.count == BitmapRasterizer.rowByteCount })
    }

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 100,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }

    private func rasterRows(count: Int, blackRowNumbers: Set<Int>) -> [Data] {
        (1...count).map { rowNumber in
            blackRowNumbers.contains(rowNumber) ? blackRow() : whiteRow()
        }
    }

    private func whiteRow() -> Data {
        Data(repeating: 0x00, count: BitmapRasterizer.rowByteCount)
    }

    private func blackRow() -> Data {
        Data(repeating: 0xFF, count: BitmapRasterizer.rowByteCount)
    }

    private func solidImage(
        width: Int = BitmapRasterizer.targetWidth,
        height: Int,
        gray: UInt8
    ) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            format: format
        )
        return renderer.image { context in
            UIColor(
                red: CGFloat(gray) / 255,
                green: CGFloat(gray) / 255,
                blue: CGFloat(gray) / 255,
                alpha: 1
            ).setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }.cgImage!
    }
}
