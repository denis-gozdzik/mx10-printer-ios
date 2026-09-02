import UIKit
import XCTest
@testable import MX10Printer

@MainActor
final class FrameTests: XCTestCase {
    func testThereAreExactlyFiveFrameKinds() {
        XCTAssertEqual(FrameKind.allCases, [.rounded, .square, .dashed, .double, .oval])
    }

    func testAddFrameElementCreatesFrameElement() {
        var document = PrintDocument(title: "Frame")
        let elementID = document.addFrameElement(kind: .dashed)

        guard case .frame(let frame) = document.firstPage.elements.first else {
            XCTFail("Expected frame element")
            return
        }

        XCTAssertEqual(frame.id, elementID)
        XCTAssertEqual(frame.kind, .dashed)
        XCTAssertEqual(frame.lineWidth, 3)
        XCTAssertEqual(frame.rotationDegrees, 0)
    }

    func testAddFrameElementInsertsAtIndexZeroBehindContent() {
        var document = PrintDocument(title: "Layering")
        _ = document.addTextElement()
        _ = document.addStickerElement(kind: .heart)
        let frameID = document.addFrameElement(kind: .rounded)

        XCTAssertEqual(document.firstPage.elements.first?.id, frameID)
        guard case .frame = document.firstPage.elements[0],
              case .text = document.firstPage.elements[1],
              case .sticker = document.firstPage.elements[2] else {
            XCTFail("Expected frame inserted before existing content")
            return
        }
    }

    func testFrameElementCodableRoundtripPreservesFields() throws {
        let element = FrameElement(
            frame: PrintElementFrame(x: 12, y: 24, width: 180, height: 96),
            kind: .double,
            lineWidth: 7,
            rotationDegrees: 90
        )
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(FrameElement.self, from: data)

        XCTAssertEqual(decoded.kind, .double)
        XCTAssertEqual(decoded.frame, element.frame)
        XCTAssertEqual(decoded.lineWidth, 7)
        XCTAssertEqual(decoded.rotationDegrees, 90)
    }

    func testExistingTextOnlyDocumentStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyTextDocumentJSON())

        XCTAssertEqual(decoded.title, "Legacy Text")
        XCTAssertEqual(decoded.firstPage.elements.count, 1)
        guard case .text(let text) = decoded.firstPage.elements.first else {
            XCTFail("Expected text element")
            return
        }

        XCTAssertEqual(text.text, "Hello")
    }

    func testExistingImageDocumentStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyImageDocumentJSON())

        XCTAssertEqual(decoded.title, "Legacy Image")
        XCTAssertEqual(decoded.firstPage.elements.count, 1)
        guard case .image(let image) = decoded.firstPage.elements.first else {
            XCTFail("Expected image element")
            return
        }

        XCTAssertEqual(image.imageData, Data([0x01, 0x02, 0x03]))
    }

    func testExistingStickerDocumentStillDecodes() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyStickerDocumentJSON())

        XCTAssertEqual(decoded.title, "Legacy Sticker")
        XCTAssertEqual(decoded.firstPage.elements.count, 1)
        guard case .sticker(let sticker) = decoded.firstPage.elements.first else {
            XCTFail("Expected sticker element")
            return
        }

        XCTAssertEqual(sticker.kind, .heart)
    }

    func testDuplicateFrameGetsNewIDAndPreservesFieldsWithOffset() {
        var document = PrintDocument(title: "Duplicate")
        let originalID = document.addFrameElement(kind: .oval)

        document.updateElement(id: originalID) { element in
            guard case .frame(var frame) = element else {
                return
            }

            frame.lineWidth = 6
            frame.rotationDegrees = 180
            element = .frame(frame)
        }

        let duplicateID = document.duplicateElement(id: originalID)

        XCTAssertNotNil(duplicateID)
        XCTAssertNotEqual(originalID, duplicateID)
        guard case .frame(let original) = document.firstPage.elements[0],
              case .frame(let duplicate) = document.firstPage.elements[1] else {
            XCTFail("Expected frame elements")
            return
        }

        XCTAssertEqual(duplicate.kind, original.kind)
        XCTAssertEqual(duplicate.lineWidth, original.lineWidth)
        XCTAssertEqual(duplicate.rotationDegrees, original.rotationDegrees)
        XCTAssertEqual(duplicate.frame.x, original.frame.x + 16)
        XCTAssertEqual(duplicate.frame.y, original.frame.y + 16)
    }

    func testFrameMovementAndClampingUsesExistingModelPath() {
        var document = PrintDocument(title: "Clamp")
        let elementID = document.addFrameElement(kind: .square)

        document.updateElement(id: elementID) { element in
            element.frame = PrintElementFrame(x: -40, y: -20, width: 4, height: 4)
        }

        guard case .frame(let frame) = document.firstPage.elements.first else {
            XCTFail("Expected frame element")
            return
        }

        XCTAssertEqual(frame.frame.x, 0)
        XCTAssertEqual(frame.frame.y, 0)
        XCTAssertEqual(frame.frame.width, 24)
        XCTAssertEqual(frame.frame.height, 24)
    }

    func testEachFrameKindRendersVisibleBlackPixels() throws {
        for kind in FrameKind.allCases {
            let pixels = try renderFrame(kind: kind).pixels

            XCTAssertGreaterThan(pixels.darkPixelCount(), 500, kind.rawValue)
        }
    }

    func testEachFrameKindLeavesWhiteInterior() throws {
        let interior = CGRect(x: 70, y: 70, width: 240, height: 60)

        for kind in FrameKind.allCases {
            let pixels = try renderFrame(kind: kind).pixels

            XCTAssertGreaterThan(pixels.whitePixelCount(in: interior), 8_000, kind.rawValue)
        }
    }

    func testRoundedAndSquareFramesProduceDifferentPixels() throws {
        let rounded = try renderFrame(kind: .rounded).data
        let square = try renderFrame(kind: .square).data

        XCTAssertNotEqual(rounded, square)
    }

    func testDashedFrameContainsMeasurableGaps() throws {
        let pixels = try renderFrame(kind: .dashed, lineWidth: 4).pixels
        var darkSamples = 0
        var whiteSamples = 0

        for x in 50..<330 {
            if pixels.isDark(x: x, y: 22) {
                darkSamples += 1
            }
            if pixels.isWhite(x: x, y: 22) {
                whiteSamples += 1
            }
        }

        XCTAssertGreaterThan(darkSamples, 20)
        XCTAssertGreaterThan(whiteSamples, 20)
    }

    func testDoubleFrameProducesTwoOutlineRegions() throws {
        let pixels = try renderFrame(kind: .double, lineWidth: 4).pixels
        let darkRuns = pixels.darkRunsAlongVerticalLine(x: 192, yRange: 18..<62)

        XCTAssertGreaterThanOrEqual(darkRuns.count, 2)
    }

    func testOvalFrameRendersCorrectly() throws {
        let pixels = try renderFrame(kind: .oval).pixels

        XCTAssertGreaterThan(pixels.darkPixelCount(), 500)
        XCTAssertTrue(pixels.isWhite(x: 192, y: 95))
        XCTAssertTrue(pixels.isWhite(x: 20, y: 22))
    }

    func testVerySmallDoubleFrameDoesNotCrash() throws {
        let rendered = try renderFrame(
            kind: .double,
            frame: PrintElementFrame(x: 10, y: 10, width: 12, height: 12),
            canvasSize: CGSize(width: 48, height: 48)
        )

        XCTAssertEqual(rendered.image.width, 48)
        XCTAssertEqual(rendered.image.height, 48)
    }

    func testLineWidthBelowOneIsSafelyRendered() throws {
        XCTAssertEqual(FrameRenderer.clampedLineWidth(0), 1)

        let pixels = try renderFrame(kind: .rounded, lineWidth: 0).pixels

        XCTAssertGreaterThan(pixels.darkPixelCount(), 100)
    }

    func testLineWidthAboveEightIsSafelyRendered() throws {
        XCTAssertEqual(FrameRenderer.clampedLineWidth(20), 8)

        let pixels = try renderFrame(kind: .rounded, lineWidth: 20).pixels

        XCTAssertGreaterThan(pixels.darkPixelCount(), 500)
        XCTAssertGreaterThan(pixels.whitePixelCount(in: CGRect(x: 80, y: 80, width: 220, height: 40)), 5_000)
    }

    func testPageRendererRendersFrameWithOtherContent() {
        let image = PageRenderer(logger: makeLogger()).render(document: makeMixedFrameDocument())
        let pixels = PixelBuffer(image: image)

        XCTAssertGreaterThan(pixels.darkPixelCount(), 1_000)
        XCTAssertGreaterThan(pixels.whitePixelCount(in: CGRect(x: 260, y: 92, width: 48, height: 36)), 1_000)
    }

    func testExistingTextAndStickerRemainVisibleWhenFrameIsPresent() {
        let image = PageRenderer(logger: makeLogger()).render(document: makeMixedFrameDocument())
        let pixels = PixelBuffer(image: image)

        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 44, y: 48, width: 70, height: 70)), 100)
        XCTAssertGreaterThan(pixels.darkPixelCount(in: CGRect(x: 128, y: 54, width: 150, height: 54)), 100)
        XCTAssertGreaterThan(pixels.whitePixelCount(in: CGRect(x: 290, y: 110, width: 36, height: 24)), 500)
    }

    func testPrintJobBuilderNaturallyTrimsFrameNearTop() throws {
        let document = makeMixedFrameDocument()
        let builder = PrintJobBuilder(logger: makeLogger())
        let preferences = PrintingPreferences(ditheringMode: .threshold, threshold: 128)
        let preview = try builder.makePreview(document: document, preferences: preferences)
        let job = builder.makeJob(document: document, preview: preview, preferences: preferences)

        print("FRAME_SMART_TRIM_ROWS=\(job.rows.count)")
        XCTAssertEqual(preview.rasterRows.count, Int(PrintDocument.defaultPageHeight))
        XCTAssertLessThan(job.rows.count, preview.rasterRows.count)
    }

    func testBuild19TemplatesStillContainOnlyTextAndStickers() {
        let expectedCounts: [PrintTemplateKind: Int] = [
            .myName: 2,
            .school: 3,
            .forYou: 2,
            .gift: 3,
            .superStar: 3,
            .thankYou: 2,
            .cat: 2,
            .smile: 2
        ]

        for kind in PrintTemplateKind.allCases {
            let elements = kind.makeDocument().firstPage.elements

            XCTAssertEqual(elements.count, expectedCounts[kind], kind.rawValue)
            XCTAssertTrue(elements.allSatisfy { element in
                if case .text = element {
                    return true
                }
                if case .sticker = element {
                    return true
                }
                return false
            }, kind.rawValue)
        }
    }

    private func makeMixedFrameDocument() -> PrintDocument {
        let frame = FrameElement(
            frame: PrintElementFrame(x: 18, y: 20, width: 348, height: 150),
            kind: .rounded,
            lineWidth: 3,
            rotationDegrees: 0
        )
        let sticker = StickerElement(
            frame: PrintElementFrame(x: 44, y: 48, width: 70, height: 70),
            kind: .heart
        )
        let text = TextElement(
            frame: PrintElementFrame(x: 128, y: 54, width: 150, height: 54),
            text: "HELLO",
            fontSize: 32,
            isBold: true,
            alignment: .center
        )

        return PrintDocument(
            title: "Frame test",
            pages: [
                PrintPage(
                    height: PrintDocument.defaultPageHeight,
                    elements: [
                        .frame(frame),
                        .sticker(sticker),
                        .text(text)
                    ]
                )
            ]
        )
    }

    private func renderFrame(
        kind: FrameKind,
        lineWidth: Double = 3,
        frame: PrintElementFrame = PrintElementFrame(x: 18, y: 20, width: 348, height: 150),
        canvasSize: CGSize = CGSize(width: 384, height: 220)
    ) throws -> RenderedPixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()
            FrameRenderer.draw(
                element: FrameElement(frame: frame, kind: kind, lineWidth: lineWidth),
                in: context.cgContext
            )
        }

        return RenderedPixels(image: try XCTUnwrap(image.cgImage))
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

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 200,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}

private struct RenderedPixels {
    let image: CGImage

    var data: Data {
        pixels.data
    }

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
