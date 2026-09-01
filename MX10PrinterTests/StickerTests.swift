import UIKit
import XCTest
@testable import MX10Printer

@MainActor
final class StickerTests: XCTestCase {
    func testEveryStickerKindHasAvailableSFSymbol() {
        for kind in StickerKind.allCases {
            XCTAssertNotNil(UIImage(systemName: kind.symbolName), "\(kind.rawValue) -> \(kind.symbolName)")
        }
    }

    func testStickerRendererReturnsImageForEveryStickerKind() {
        for kind in StickerKind.allCases {
            let image = StickerRenderer.image(for: kind, pointSize: 96)
            XCTAssertNotNil(image, "\(kind.rawValue) -> \(kind.symbolName)")
        }
    }

    func testRenderedStickerContainsVisibleDarkPixels() throws {
        let image = try renderSticker(.heart)
        let analysis = analyze(image)

        XCTAssertGreaterThan(analysis.darkPixelCount, 100)
    }

    func testStickerRenderingDoesNotFillEntireBoundsBlack() throws {
        let image = try renderSticker(.star)
        let analysis = analyze(image)

        XCTAssertGreaterThan(analysis.darkPixelCount, 100)
        XCTAssertLessThan(analysis.darkPixelCount, analysis.totalPixelCount / 2)
    }

    func testStickerAspectFitIsCentered() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        let drawRect = StickerRenderer.aspectFitRect(
            for: CGSize(width: 60, height: 30),
            in: rect
        )

        XCTAssertEqual(drawRect.width, 120)
        XCTAssertEqual(drawRect.height, 60)
        XCTAssertEqual(drawRect.minX, 0)
        XCTAssertEqual(drawRect.minY, 30)
    }

    func testPageRendererRendersStickerIntoDocumentBitmap() {
        var document = PrintDocument(title: "Sticker")
        _ = document.addStickerElement(kind: .heart)
        let image = PageRenderer(logger: makeLogger()).render(document: document)
        let analysis = analyze(image)

        XCTAssertGreaterThan(analysis.darkPixelCount, 100)
    }

    func testDifferentStickerKindsProduceDifferentPixels() throws {
        let heart = try renderSticker(.heart)
        let star = try renderSticker(.star)

        XCTAssertNotEqual(pixelData(from: heart), pixelData(from: star))
    }

    func testStickerElementSurvivesCodableRoundtrip() throws {
        var document = PrintDocument(title: "Sticker")
        let elementID = document.addStickerElement(kind: .crown)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: data)

        guard case .sticker(let sticker) = decoded.firstPage.elements.first else {
            XCTFail("Expected sticker element")
            return
        }

        XCTAssertEqual(sticker.id, elementID)
        XCTAssertEqual(sticker.kind, .crown)
    }

    func testLegacyTextOnlyDocumentDecodingStillWorks() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyTextDocumentJSON())

        XCTAssertEqual(decoded.title, "Legacy Text")
        XCTAssertEqual(decoded.firstPage.elements.count, 1)
        guard case .text(let text) = decoded.firstPage.elements.first else {
            XCTFail("Expected text element")
            return
        }

        XCTAssertEqual(text.text, "Hello")
    }

    func testLegacyImageDocumentDecodingStillWorks() throws {
        let decoded = try JSONDecoder().decode(PrintDocument.self, from: legacyImageDocumentJSON())

        XCTAssertEqual(decoded.title, "Legacy Image")
        XCTAssertEqual(decoded.firstPage.elements.count, 1)
        guard case .image(let image) = decoded.firstPage.elements.first else {
            XCTFail("Expected image element")
            return
        }

        XCTAssertEqual(image.imageData, Data([0x01, 0x02, 0x03]))
    }

    func testDuplicateStickerGetsNewUUIDAndKeepsKindWithOffset() {
        var document = PrintDocument(title: "Duplicate")
        let originalID = document.addStickerElement(kind: .moon)
        let duplicateID = document.duplicateElement(id: originalID)

        XCTAssertNotNil(duplicateID)
        XCTAssertNotEqual(originalID, duplicateID)
        XCTAssertEqual(document.firstPage.elements.count, 2)

        guard case .sticker(let original) = document.firstPage.elements[0],
              case .sticker(let duplicate) = document.firstPage.elements[1] else {
            XCTFail("Expected sticker elements")
            return
        }

        XCTAssertEqual(duplicate.kind, original.kind)
        XCTAssertEqual(duplicate.frame.x, original.frame.x + 16)
        XCTAssertEqual(duplicate.frame.y, original.frame.y + 16)
    }

    func testStickerFrameClampingUsesExistingElementBehavior() {
        var document = PrintDocument(title: "Clamp")
        let elementID = document.addStickerElement(kind: .sun)

        document.updateElement(id: elementID) { element in
            element.frame = PrintElementFrame(x: -20, y: -10, width: 4, height: 4)
        }

        guard case .sticker(let sticker) = document.firstPage.elements.first else {
            XCTFail("Expected sticker element")
            return
        }

        XCTAssertEqual(sticker.frame.x, 0)
        XCTAssertEqual(sticker.frame.y, 0)
        XCTAssertEqual(sticker.frame.width, 24)
        XCTAssertEqual(sticker.frame.height, 24)
    }

    func testSmartTrimNaturallyTrimsStickerNearTop() throws {
        var document = PrintDocument(title: "Trim Sticker")
        _ = document.addStickerElement(kind: .heart)
        let builder = PrintJobBuilder(logger: makeLogger())
        let preferences = PrintingPreferences(ditheringMode: .threshold, threshold: 128)

        let preview = try builder.makePreview(document: document, preferences: preferences)
        let job = builder.makeJob(document: document, preview: preview, preferences: preferences)

        print("STICKER_SMART_TRIM_ROWS=\(job.rows.count)")
        XCTAssertEqual(preview.rasterRows.count, 640)
        XCTAssertLessThan(job.rows.count, 640)
        XCTAssertGreaterThan(job.rows.count, 0)
    }

    private func renderSticker(
        _ kind: StickerKind,
        canvasSize: CGSize = CGSize(width: 120, height: 120)
    ) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()
            _ = StickerRenderer.draw(
                kind: kind,
                in: CGRect(origin: .zero, size: canvasSize)
            )
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func analyze(_ image: CGImage) -> PixelAnalysis {
        let data = pixelData(from: image)
        var darkPixelCount = 0

        for offset in stride(from: 0, to: data.count, by: 4) {
            let red = data[offset]
            let green = data[offset + 1]
            let blue = data[offset + 2]
            if red < 96, green < 96, blue < 96 {
                darkPixelCount += 1
            }
        }

        return PixelAnalysis(
            darkPixelCount: darkPixelCount,
            totalPixelCount: image.width * image.height
        )
    }

    private func pixelData(from image: CGImage) -> Data {
        let width = image.width
        let height = image.height
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
        return Data(pixels)
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

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 200,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}

private struct PixelAnalysis {
    let darkPixelCount: Int
    let totalPixelCount: Int
}
