import UIKit
import XCTest
@testable import MX10Printer

@MainActor
final class DrawingTests: XCTestCase {
    func testDrawingElementCodableRoundtrip() throws {
        let element = makeDrawingElement(rotationDegrees: 90)

        let decoded = try JSONDecoder().decode(DrawingElement.self, from: JSONEncoder().encode(element))

        XCTAssertEqual(decoded, element)
    }

    func testDrawingStrokePointDataSurvivesRoundtrip() throws {
        let stroke = makeStroke(points: [DrawingPoint(x: 1, y: 2), DrawingPoint(x: 3, y: 4)])

        let decoded = try JSONDecoder().decode(DrawingStroke.self, from: JSONEncoder().encode(stroke))

        XCTAssertEqual(decoded.points, stroke.points)
    }

    func testDrawingStrokeLineWidthSurvivesRoundtrip() throws {
        let stroke = makeStroke(lineWidth: 9)

        let decoded = try JSONDecoder().decode(DrawingStroke.self, from: JSONEncoder().encode(stroke))

        XCTAssertEqual(decoded.lineWidth, 9)
    }

    func testDrawingSourceSizeSurvivesRoundtrip() throws {
        let element = makeDrawingElement(sourceSize: DrawingSize(width: 123, height: 45))

        let decoded = try JSONDecoder().decode(DrawingElement.self, from: JSONEncoder().encode(element))

        XCTAssertEqual(decoded.sourceSize, DrawingSize(width: 123, height: 45))
    }

    func testDrawingRotationDegreesSurvivesRoundtrip() throws {
        let element = makeDrawingElement(rotationDegrees: 180)

        let decoded = try JSONDecoder().decode(DrawingElement.self, from: JSONEncoder().encode(element))

        XCTAssertEqual(decoded.rotationDegrees, 180)
    }

    func testExistingTextJSONStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyTextDocumentJSON())

        guard case .text(let text) = decoded.firstPage.elements.first else {
            XCTFail("Expected text element")
            return
        }

        XCTAssertEqual(text.text, "Hello")
    }

    func testExistingImageJSONStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyImageDocumentJSON())

        guard case .image(let image) = decoded.firstPage.elements.first else {
            XCTFail("Expected image element")
            return
        }

        XCTAssertEqual(image.imageData, Data([0x01, 0x02, 0x03]))
    }

    func testExistingStickerJSONStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyStickerDocumentJSON())

        guard case .sticker(let sticker) = decoded.firstPage.elements.first else {
            XCTFail("Expected sticker element")
            return
        }

        XCTAssertEqual(sticker.kind, .heart)
    }

    func testExistingFrameJSONStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyFrameDocumentJSON())

        guard case .frame(let frame) = decoded.firstPage.elements.first else {
            XCTFail("Expected frame element")
            return
        }

        XCTAssertEqual(frame.kind, .rounded)
    }

    func testPrintDocumentWithDrawingRoundtrips() throws {
        let document = PrintDocument(
            title: "Drawing",
            pages: [PrintPage(elements: [.drawing(makeDrawingElement())])]
        )

        let decoded = try JSONDecoder().decode(PrintDocument.self, from: JSONEncoder().encode(document))

        XCTAssertEqual(decoded, document)
    }

    func testPenWidthsAreExactlyThinMediumThick() {
        XCTAssertEqual(DrawingPenWidth.allCases.map(\.title), ["Thin", "Medium", "Thick"])
        XCTAssertEqual(DrawingPenWidth.allCases.map(\.lineWidth), [2.0, 5.0, 9.0])
    }

    func testAddDrawingElementAppendsAboveExistingContent() {
        var document = PrintDocument(title: "Layering")
        _ = document.addFrameElement(kind: .rounded)
        _ = document.addTextElement()
        let drawing = makeDrawingElement()
        let elementID = document.addDrawingElement(drawing)

        XCTAssertEqual(document.firstPage.elements.last?.id, elementID)
        guard case .drawing = document.firstPage.elements.last else {
            XCTFail("Expected drawing appended after existing content")
            return
        }
    }

    func testDuplicateDrawingGetsNewDrawingElementUUID() {
        let (original, duplicate) = duplicatedDrawingElements()

        XCTAssertNotEqual(duplicate.id, original.id)
    }

    func testDuplicatedDrawingStrokesGetFreshUUIDs() {
        let (original, duplicate) = duplicatedDrawingElements()

        XCTAssertEqual(duplicate.strokes.count, original.strokes.count)
        XCTAssertFalse(zip(original.strokes, duplicate.strokes).contains { pair in
            pair.0.id == pair.1.id
        })
    }

    func testDuplicateDrawingPreservesPoints() {
        let (original, duplicate) = duplicatedDrawingElements()

        XCTAssertEqual(duplicate.strokes.map(\.points), original.strokes.map(\.points))
    }

    func testDuplicateDrawingPreservesLineWidths() {
        let (original, duplicate) = duplicatedDrawingElements()

        XCTAssertEqual(duplicate.strokes.map(\.lineWidth), original.strokes.map(\.lineWidth))
    }

    func testDuplicateDrawingPreservesSourceSize() {
        let (original, duplicate) = duplicatedDrawingElements()

        XCTAssertEqual(duplicate.sourceSize, original.sourceSize)
    }

    func testDuplicateDrawingUsesExistingFrameOffset() {
        let (original, duplicate) = duplicatedDrawingElements()

        XCTAssertEqual(duplicate.frame.x, original.frame.x + 16)
        XCTAssertEqual(duplicate.frame.y, original.frame.y + 16)
    }

    func testSavedDrawingCanMoveResizeRotateDuplicateAndDelete() {
        var document = PrintDocument(title: "Edit drawing")
        let drawingID = document.addDrawingElement(makeDrawingElement())

        document.updateElement(id: drawingID) { element in
            element.frame = element.frame.offsetBy(dx: 12, dy: 14).resizedBy(dw: 20, dh: 10)
            guard case .drawing(var drawing) = element else {
                return
            }

            drawing.rotationDegrees = 90
            element = .drawing(drawing)
        }

        let duplicateID = document.duplicateElement(id: drawingID)
        document.deleteElement(id: drawingID)

        XCTAssertNotNil(duplicateID)
        XCTAssertEqual(document.firstPage.elements.count, 1)
        XCTAssertEqual(document.firstPage.elements.first?.id, duplicateID)
        guard case .drawing(let duplicate) = document.firstPage.elements.first else {
            XCTFail("Expected duplicated drawing")
            return
        }

        XCTAssertEqual(duplicate.rotationDegrees, 90)
        XCTAssertEqual(duplicate.frame.x, 48)
        XCTAssertEqual(duplicate.frame.y, 50)
        XCTAssertEqual(duplicate.frame.width, 140)
        XCTAssertEqual(duplicate.frame.height, 90)
    }

    func testPointSamplingKeepsFirstPoint() {
        let stroke = DrawingStroke(points: [], lineWidth: 5)

        let sampled = DrawingGeometry.sampledStroke(from: stroke, adding: DrawingPoint(x: 10, y: 10))

        XCTAssertEqual(sampled.points, [DrawingPoint(x: 10, y: 10)])
    }

    func testMovementBelowSamplingThresholdDoesNotAppendPoint() {
        let stroke = DrawingStroke(points: [DrawingPoint(x: 10, y: 10)], lineWidth: 5)

        let sampled = DrawingGeometry.sampledStroke(from: stroke, adding: DrawingPoint(x: 11, y: 10))

        XCTAssertEqual(sampled.points.count, 1)
    }

    func testMovementAboveSamplingThresholdAppendsPoint() {
        let stroke = DrawingStroke(points: [DrawingPoint(x: 10, y: 10)], lineWidth: 5)

        let sampled = DrawingGeometry.sampledStroke(from: stroke, adding: DrawingPoint(x: 12, y: 10))

        XCTAssertEqual(sampled.points.count, 2)
    }

    func testBoundingBoxIncludesDrawing() throws {
        let frame = try XCTUnwrap(DrawingGeometry.boundingFrame(
            for: [makeStroke(points: [DrawingPoint(x: 40, y: 50), DrawingPoint(x: 60, y: 70)], lineWidth: 5)],
            pageWidth: 384,
            pageHeight: 640
        ))

        XCTAssertLessThanOrEqual(frame.x, 40)
        XCTAssertLessThanOrEqual(frame.y, 50)
        XCTAssertGreaterThanOrEqual(frame.x + frame.width, 60)
        XCTAssertGreaterThanOrEqual(frame.y + frame.height, 70)
    }

    func testBoundingBoxIncludesLineWidthPadding() throws {
        let frame = try XCTUnwrap(DrawingGeometry.boundingFrame(
            for: [makeStroke(points: [DrawingPoint(x: 50, y: 50)], lineWidth: 10)],
            pageWidth: 384,
            pageHeight: 640
        ))

        XCTAssertEqual(frame.x, 43)
        XCTAssertEqual(frame.y, 43)
        XCTAssertEqual(frame.width, 14)
        XCTAssertEqual(frame.height, 14)
    }

    func testPageSpaceStrokesConvertToLocalDrawingElementCoordinates() throws {
        let element = try XCTUnwrap(DrawingGeometry.drawingElement(
            from: [makeStroke(points: [DrawingPoint(x: 40, y: 50), DrawingPoint(x: 60, y: 70)], lineWidth: 5)],
            pageWidth: 384,
            pageHeight: 640
        ))

        let points = try XCTUnwrap(element.strokes.first?.points)
        XCTAssertEqual(points[0].x, 4.5)
        XCTAssertEqual(points[0].y, 4.5)
        XCTAssertEqual(points[1].x, 24.5)
        XCTAssertEqual(points[1].y, 24.5)
        XCTAssertEqual(element.sourceSize.width, element.frame.width)
        XCTAssertEqual(element.sourceSize.height, element.frame.height)
    }

    func testConvertedDrawingElementIsNotFullPageForSmallDrawing() throws {
        let element = try XCTUnwrap(DrawingGeometry.drawingElement(
            from: [makeStroke(points: [DrawingPoint(x: 40, y: 50), DrawingPoint(x: 60, y: 70)], lineWidth: 5)],
            pageWidth: 384,
            pageHeight: 640
        ))

        XCTAssertLessThan(element.frame.width, 384)
        XCTAssertLessThan(element.frame.height, 640)
    }

    func testEraserHitTestDetectsPointNearStroke() {
        let stroke = makeStroke(points: [DrawingPoint(x: 10, y: 10), DrawingPoint(x: 40, y: 10)], lineWidth: 5)

        XCTAssertTrue(DrawingGeometry.stroke(stroke, contains: DrawingPoint(x: 20, y: 14)))
    }

    func testEraserHitTestRejectsDistantPoint() {
        let stroke = makeStroke(points: [DrawingPoint(x: 10, y: 10), DrawingPoint(x: 40, y: 10)], lineWidth: 5)

        XCTAssertFalse(DrawingGeometry.stroke(stroke, contains: DrawingPoint(x: 20, y: 80)))
    }

    func testEraserDetectsSegmentBetweenTwoPoints() {
        let stroke = makeStroke(points: [DrawingPoint(x: 10, y: 10), DrawingPoint(x: 90, y: 90)], lineWidth: 2)

        XCTAssertTrue(DrawingGeometry.stroke(stroke, contains: DrawingPoint(x: 50, y: 51)))
    }

    func testOnePointStrokeHitTestWorks() {
        let stroke = makeStroke(points: [DrawingPoint(x: 20, y: 20)], lineWidth: 2)

        XCTAssertTrue(DrawingGeometry.stroke(stroke, contains: DrawingPoint(x: 23, y: 20)))
        XCTAssertFalse(DrawingGeometry.stroke(stroke, contains: DrawingPoint(x: 60, y: 20)))
    }

    func testEraserToleranceUsesStrokeWidthWithMinimum() {
        XCTAssertEqual(DrawingGeometry.eraserTolerance(for: makeStroke(lineWidth: 2)), 8)
        XCTAssertEqual(DrawingGeometry.eraserTolerance(for: makeStroke(lineWidth: 9)), 10.5)
    }

    func testOnePointDrawingProducesVisibleBlackDot() throws {
        let element = DrawingElement(
            frame: PrintElementFrame(x: 10, y: 10, width: 30, height: 30),
            sourceSize: DrawingSize(width: 30, height: 30),
            strokes: [makeStroke(points: [DrawingPoint(x: 15, y: 15)], lineWidth: 9)]
        )
        let pixels = try renderDrawing(element).pixels

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 20, y: 20, width: 12, height: 12)), 40)
    }

    func testMultiPointDrawingProducesVisibleBlackLine() throws {
        let pixels = try renderDrawing(makeDrawingElement()).pixels

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 20, y: 20, width: 100, height: 60)), 200)
    }

    func testDrawingBackgroundInteriorRemainsWhite() throws {
        let pixels = try renderDrawing(makeDrawingElement()).pixels

        XCTAssertGreaterThan(pixels.whitePixelCount(in: CGRect(x: 250, y: 250, width: 40, height: 40)), 1_000)
    }

    func testThinMediumThickProduceDifferentMeasurableStrokeThickness() throws {
        let thin = try renderHorizontalLine(width: DrawingPenWidth.thin.lineWidth).pixels
        let medium = try renderHorizontalLine(width: DrawingPenWidth.medium.lineWidth).pixels
        let thick = try renderHorizontalLine(width: DrawingPenWidth.thick.lineWidth).pixels

        let thinRun = thin.darkRunsAlongVerticalLine(x: 60, yRange: 0..<100).first?.count ?? 0
        let mediumRun = medium.darkRunsAlongVerticalLine(x: 60, yRange: 0..<100).first?.count ?? 0
        let thickRun = thick.darkRunsAlongVerticalLine(x: 60, yRange: 0..<100).first?.count ?? 0

        XCTAssertLessThan(thinRun, mediumRun)
        XCTAssertLessThan(mediumRun, thickRun)
    }

    func testResizingDrawingElementScalesGeometry() throws {
        let element = DrawingElement(
            frame: PrintElementFrame(x: 10, y: 10, width: 80, height: 80),
            sourceSize: DrawingSize(width: 40, height: 40),
            strokes: [makeStroke(points: [DrawingPoint(x: 20, y: 20)], lineWidth: 5)]
        )
        let pixels = try renderDrawing(element).pixels

        XCTAssertTrue(pixels.isDark(x: 50, y: 50))
    }

    func testRotationRendersWithoutCrash() {
        var document = PrintDocument(pages: [PrintPage(elements: [.drawing(makeDrawingElement(rotationDegrees: 90))])])
        document.touch()

        let image = PageRenderer(logger: makeLogger()).render(document: document)

        XCTAssertEqual(image.width, Int(PrintDocument.pageWidth))
    }

    func testMalformedZeroSourceSizeDoesNotCrash() throws {
        let element = DrawingElement(
            frame: PrintElementFrame(x: 10, y: 10, width: 80, height: 80),
            sourceSize: DrawingSize(width: 0, height: 0),
            strokes: [makeStroke()]
        )
        let pixels = try renderDrawing(element).pixels

        XCTAssertEqual(pixels.darkPixelCount(), 0)
    }

    func testEmptyStrokesDoNotCrash() throws {
        let element = DrawingElement(
            frame: PrintElementFrame(x: 10, y: 10, width: 80, height: 80),
            sourceSize: DrawingSize(width: 80, height: 80),
            strokes: []
        )
        let pixels = try renderDrawing(element).pixels

        XCTAssertEqual(pixels.darkPixelCount(), 0)
    }

    func testPageRendererRendersDrawingAlone() {
        let image = PageRenderer(logger: makeLogger()).render(document: PrintDocument(pages: [
            PrintPage(elements: [.drawing(makeDrawingElement())])
        ]))
        let pixels = PixelBuffer(image: image)

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 20, y: 20, width: 100, height: 60)), 200)
    }

    func testPageRendererRendersFrameStickerTextImageAndDrawingTogether() {
        let image = PageRenderer(logger: makeLogger()).render(document: makeMixedDrawingDocument(includeImage: true))
        let pixels = PixelBuffer(image: image)

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 18, y: 20, width: 348, height: 150)), 1_000)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 44, y: 48, width: 70, height: 70)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 128, y: 54, width: 150, height: 54)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 286, y: 52, width: 36, height: 36)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 80, y: 112, width: 150, height: 45)), 100)
    }

    func testExistingContentRemainsVisibleWithDrawingPresent() {
        let image = PageRenderer(logger: makeLogger()).render(document: makeMixedDrawingDocument(includeImage: true))
        let pixels = PixelBuffer(image: image)

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 44, y: 48, width: 70, height: 70)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 128, y: 54, width: 150, height: 54)), 100)
        XCTAssertGreaterThan(pixels.whitePixelCount(in: CGRect(x: 250, y: 180, width: 80, height: 60)), 4_000)
    }

    func testFullPreviewRemainsNormalPageHeightWithDrawing() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let preview = try builder.makePreview(
            document: makeMixedDrawingDocument(),
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )

        XCTAssertEqual(preview.rasterRows.count, Int(PrintDocument.defaultPageHeight))
    }

    func testSmallDrawingNearTopNaturallyGivesPrintRowsBelowFullPage() throws {
        let builder = PrintJobBuilder(logger: makeLogger())
        let document = PrintDocument(pages: [
            PrintPage(elements: [.drawing(makeDrawingElement())])
        ])
        let preview = try builder.makePreview(
            document: document,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )
        let job = builder.makeJob(
            document: document,
            preview: preview,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )

        print("DRAWING_SMART_TRIM_ROWS=\(job.rows.count)")
        XCTAssertLessThan(job.rows.count, preview.rasterRows.count)
    }

    func testPhysicalLikeDocumentRendersAndSmartTrims() throws {
        let document = makeMixedDrawingDocument(includeImage: true)
        let renderer = PageRenderer(logger: makeLogger())
        let image = renderer.render(document: document)
        let pixels = PixelBuffer(image: image)
        let builder = PrintJobBuilder(pageRenderer: renderer, logger: makeLogger())
        let preview = try builder.makePreview(
            document: document,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )
        let job = builder.makeJob(
            document: document,
            preview: preview,
            preferences: PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        )

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 18, y: 20, width: 348, height: 150)), 1_000)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 44, y: 48, width: 70, height: 70)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 128, y: 54, width: 150, height: 54)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 80, y: 112, width: 150, height: 45)), 100)
        XCTAssertGreaterThan(pixels.whitePixelCount(in: CGRect(x: 260, y: 190, width: 80, height: 60)), 4_000)
        XCTAssertLessThan(job.rows.count, 640)
    }

    private func duplicatedDrawingElements() -> (DrawingElement, DrawingElement) {
        let original = makeDrawingElement()
        var document = PrintDocument(pages: [PrintPage(elements: [.drawing(original)])])
        let duplicateID = document.duplicateElement(id: original.id)

        XCTAssertNotNil(duplicateID)
        guard case .drawing(let duplicate) = document.firstPage.elements.last else {
            XCTFail("Expected duplicated drawing")
            return (original, original)
        }

        return (original, duplicate)
    }

    private func makeDrawingElement(
        frame: PrintElementFrame = PrintElementFrame(x: 20, y: 20, width: 120, height: 80),
        sourceSize: DrawingSize = DrawingSize(width: 120, height: 80),
        rotationDegrees: Double = 0
    ) -> DrawingElement {
        DrawingElement(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            frame: frame,
            sourceSize: sourceSize,
            strokes: [
                makeStroke(
                    id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                    points: [
                        DrawingPoint(x: 10, y: 10),
                        DrawingPoint(x: 38, y: 44),
                        DrawingPoint(x: 72, y: 28),
                        DrawingPoint(x: 110, y: 60)
                    ],
                    lineWidth: 5
                ),
                makeStroke(
                    id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                    points: [DrawingPoint(x: 64, y: 14)],
                    lineWidth: 9
                )
            ],
            rotationDegrees: rotationDegrees
        )
    }

    private func makeStroke(
        id: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        points: [DrawingPoint] = [DrawingPoint(x: 10, y: 10), DrawingPoint(x: 90, y: 45)],
        lineWidth: Double = 5
    ) -> DrawingStroke {
        DrawingStroke(id: id, points: points, lineWidth: lineWidth)
    }

    private func makeMixedDrawingDocument(includeImage: Bool = false) -> PrintDocument {
        var elements: [PrintElement] = [
            .frame(FrameElement(
                frame: PrintElementFrame(x: 18, y: 20, width: 348, height: 150),
                kind: .rounded,
                lineWidth: 3
            )),
            .sticker(StickerElement(
                frame: PrintElementFrame(x: 44, y: 48, width: 70, height: 70),
                kind: .heart
            )),
            .text(TextElement(
                frame: PrintElementFrame(x: 128, y: 54, width: 150, height: 54),
                text: "HELLO",
                fontSize: 32,
                isBold: true,
                alignment: .center
            )),
            .drawing(DrawingElement(
                frame: PrintElementFrame(x: 80, y: 112, width: 160, height: 48),
                sourceSize: DrawingSize(width: 160, height: 48),
                strokes: [
                    makeStroke(points: [
                        DrawingPoint(x: 4, y: 28),
                        DrawingPoint(x: 35, y: 38),
                        DrawingPoint(x: 70, y: 18),
                        DrawingPoint(x: 105, y: 38),
                        DrawingPoint(x: 150, y: 22)
                    ], lineWidth: 5)
                ]
            ))
        ]

        if includeImage {
            elements.insert(
                .image(ImageElement(
                    frame: PrintElementFrame(x: 286, y: 52, width: 36, height: 36),
                    imageData: makeTestImageData()
                )),
                at: 3
            )
        }

        return PrintDocument(
            title: "Drawing mix",
            pages: [
                PrintPage(
                    height: PrintDocument.defaultPageHeight,
                    elements: elements
                )
            ]
        )
    }

    private func renderDrawing(
        _ element: DrawingElement,
        canvasSize: CGSize = CGSize(width: 384, height: 220)
    ) throws -> RenderedPixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()
            DrawingRenderer.draw(element: element, in: context.cgContext)
        }

        return RenderedPixels(image: try XCTUnwrap(image.cgImage))
    }

    private func renderHorizontalLine(width: Double) throws -> RenderedPixels {
        try renderDrawing(
            DrawingElement(
                frame: PrintElementFrame(x: 10, y: 10, width: 120, height: 80),
                sourceSize: DrawingSize(width: 120, height: 80),
                strokes: [
                    makeStroke(points: [DrawingPoint(x: 10, y: 40), DrawingPoint(x: 110, y: 40)], lineWidth: width)
                ]
            ),
            canvasSize: CGSize(width: 150, height: 100)
        )
    }

    private func makeTestImageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        return image.pngData() ?? Data()
    }

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 200,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }

    private func legacyTextDocumentJSON() -> Data {
        Data(
            #"""
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "title": "Legacy Text",
              "pages": [
                {
                  "id": "00000000-0000-0000-0000-000000000002",
                  "width": 384,
                  "height": 640,
                  "elements": [
                    {
                      "type": "text",
                      "text": {
                        "id": "00000000-0000-0000-0000-000000000003",
                        "frame": { "x": 24, "y": 32, "width": 336, "height": 96 },
                        "text": "Hello",
                        "fontSize": 28,
                        "isBold": false,
                        "alignment": "leading",
                        "ink": "black",
                        "rotationDegrees": 0
                      }
                    }
                  ]
                }
              ],
              "createdAt": 0,
              "updatedAt": 0
            }
            """#.utf8
        )
    }

    private func legacyImageDocumentJSON() -> Data {
        Data(
            #"""
            {
              "id": "00000000-0000-0000-0000-000000000004",
              "title": "Legacy Image",
              "pages": [
                {
                  "id": "00000000-0000-0000-0000-000000000005",
                  "width": 384,
                  "height": 640,
                  "elements": [
                    {
                      "type": "image",
                      "image": {
                        "id": "00000000-0000-0000-0000-000000000006",
                        "frame": { "x": 24, "y": 152, "width": 336, "height": 220 },
                        "imageData": "AQID",
                        "contentMode": "fit",
                        "cropRect": { "x": 0, "y": 0, "width": 1, "height": 1 },
                        "rotationDegrees": 0,
                        "isInverted": false
                      }
                    }
                  ]
                }
              ],
              "createdAt": 0,
              "updatedAt": 0
            }
            """#.utf8
        )
    }

    private func legacyStickerDocumentJSON() -> Data {
        Data(
            #"""
            {
              "id": "00000000-0000-0000-0000-000000000007",
              "title": "Legacy Sticker",
              "pages": [
                {
                  "id": "00000000-0000-0000-0000-000000000008",
                  "width": 384,
                  "height": 640,
                  "elements": [
                    {
                      "type": "sticker",
                      "sticker": {
                        "id": "00000000-0000-0000-0000-000000000009",
                        "frame": { "x": 132, "y": 48, "width": 120, "height": 120 },
                        "kind": "heart",
                        "rotationDegrees": 0
                      }
                    }
                  ]
                }
              ],
              "createdAt": 0,
              "updatedAt": 0
            }
            """#.utf8
        )
    }

    private func legacyFrameDocumentJSON() -> Data {
        Data(
            #"""
            {
              "id": "00000000-0000-0000-0000-000000000010",
              "title": "Legacy Frame",
              "pages": [
                {
                  "id": "00000000-0000-0000-0000-000000000011",
                  "width": 384,
                  "height": 640,
                  "elements": [
                    {
                      "type": "frame",
                      "frame": {
                        "id": "00000000-0000-0000-0000-000000000012",
                        "frame": { "x": 18, "y": 20, "width": 348, "height": 150 },
                        "kind": "rounded",
                        "lineWidth": 3,
                        "rotationDegrees": 0
                      }
                    }
                  ]
                }
              ],
              "createdAt": 0,
              "updatedAt": 0
            }
            """#.utf8
        )
    }
}

private struct RenderedPixels {
    let image: CGImage

    var pixels: PixelBuffer {
        PixelBuffer(image: image)
    }
}

private struct PixelBuffer {
    let width: Int
    let height: Int
    let data: Data

    init(image: CGImage) {
        width = image.width
        height = image.height

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        data = Data(pixels)
    }

    func darkPixelCount(in rect: CGRect? = nil) -> Int {
        sampleCount(in: rect) { x, y in
            isDark(x: x, y: y)
        }
    }

    func whitePixelCount(in rect: CGRect? = nil) -> Int {
        sampleCount(in: rect) { x, y in
            isWhite(x: x, y: y)
        }
    }

    func isDark(x: Int, y: Int) -> Bool {
        guard let offset = pixelOffset(x: x, y: y) else {
            return false
        }

        return data[offset] < 96 && data[offset + 1] < 96 && data[offset + 2] < 96
    }

    func isWhite(x: Int, y: Int) -> Bool {
        guard let offset = pixelOffset(x: x, y: y) else {
            return false
        }

        return data[offset] > 220 && data[offset + 1] > 220 && data[offset + 2] > 220
    }

    func darkRunsAlongVerticalLine(x: Int, yRange: Range<Int>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var runStart: Int?

        for y in yRange {
            if isDark(x: x, y: y) {
                if runStart == nil {
                    runStart = y
                }
            } else if let start = runStart {
                runs.append(start..<y)
                runStart = nil
            }
        }

        if let start = runStart {
            runs.append(start..<yRange.upperBound)
        }

        return runs
    }

    private func sampleCount(in rect: CGRect?, matching predicate: (Int, Int) -> Bool) -> Int {
        let bounds = clampedBounds(for: rect)
        var count = 0

        for y in bounds.yRange {
            for x in bounds.xRange where predicate(x, y) {
                count += 1
            }
        }

        return count
    }

    private func pixelOffset(x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height else {
            return nil
        }

        return (y * width + x) * 4
    }

    private func clampedBounds(for rect: CGRect?) -> (xRange: Range<Int>, yRange: Range<Int>) {
        guard let rect else {
            return (0..<width, 0..<height)
        }

        let minX = max(0, Int(floor(rect.minX)))
        let maxX = min(width, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY)))
        let maxY = min(height, Int(ceil(rect.maxY)))

        return (minX..<max(minX, maxX), minY..<max(minY, maxY))
    }
}
