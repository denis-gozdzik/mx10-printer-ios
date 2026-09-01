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

    func testPrintJobTrimsTrailingWhiteRowsWithBottomMargin() throws {
        let rows = makeRows(rowCount: 640, blackRows: [58])
        let preview = try makePreview(rows: rows)
        let builder = PrintJobBuilder(logger: makeLogger())

        let job = builder.makeJob(
            document: PrintDocument(title: "Short"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(preview.rasterRows.count, 640)
        XCTAssertEqual(job.rows.count, 83)
    }

    func testPrintJobKeepsFullRasterWhenBottomMarginWouldExceedPage() throws {
        let rows = makeRows(rowCount: 640, blackRows: [630])
        let preview = try makePreview(rows: rows)
        let builder = PrintJobBuilder(logger: makeLogger())

        let job = builder.makeJob(
            document: PrintDocument(title: "Bottom"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(preview.rasterRows.count, 640)
        XCTAssertEqual(job.rows.count, 640)
    }

    func testPrintJobKeepsBlankRasterUnchanged() throws {
        let rows = makeRows(rowCount: 640, blackRows: [])
        let preview = try makePreview(rows: rows)
        let builder = PrintJobBuilder(logger: makeLogger())

        let job = builder.makeJob(
            document: PrintDocument(title: "Blank"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(preview.rasterRows.count, 640)
        XCTAssertEqual(job.rows.count, 640)
        XCTAssertEqual(job.rows, rows)
    }

    func testPrintJobDoesNotRemoveLeadingWhiteRows() throws {
        let rows = makeRows(rowCount: 640, blackRows: [20])
        let preview = try makePreview(rows: rows)
        let builder = PrintJobBuilder(logger: makeLogger())

        let job = builder.makeJob(
            document: PrintDocument(title: "Leading"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(job.rows.count, 45)
        XCTAssertEqual(job.rows.prefix(20), rows.prefix(20))
        XCTAssertTrue(job.rows.prefix(20).allSatisfy { $0 == whiteRow() })
    }

    func testPrintJobTrimmingOnlyRemovesTrailingRows() throws {
        let rows = makeRows(rowCount: 640, blackRows: [2, 58])
        let preview = try makePreview(rows: rows)
        let builder = PrintJobBuilder(logger: makeLogger())

        let job = builder.makeJob(
            document: PrintDocument(title: "Contents"),
            preview: preview,
            preferences: PrintingPreferences()
        )

        XCTAssertEqual(job.rows.count, 83)
        XCTAssertEqual(job.rows, Array(rows.prefix(83)))
    }

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 100,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }

    private func makePreview(rows: [Data]) throws -> PrintPreview {
        let image = try XCTUnwrap(BitmapRasterizer.previewImage(from: rows))
        return PrintPreview(
            renderedImage: image,
            rasterRows: rows,
            previewImage: image
        )
    }

    private func makeRows(rowCount: Int, blackRows: Set<Int>) -> [Data] {
        (0..<rowCount).map { rowIndex in
            blackRows.contains(rowIndex) ? blackRow(rowIndex) : whiteRow()
        }
    }

    private func whiteRow() -> Data {
        Data(repeating: 0x00, count: BitmapRasterizer.rowByteCount)
    }

    private func blackRow(_ seed: Int) -> Data {
        var row = Data(repeating: 0x00, count: BitmapRasterizer.rowByteCount)
        row[0] = 0x80
        row[1] = UInt8(seed & 0xFF)
        return row
    }
}
