import UIKit
import XCTest
@testable import MX10Printer

final class QRCodeTests: XCTestCase {
    func testQRCodeElementCodableRoundTrip() throws {
        let element = QRCodeElement(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            frame: PrintElementFrame(x: 92, y: 48, width: 200, height: 200),
            text: "https://example.com/order/123",
            errorCorrection: .h,
            rotationDegrees: 90
        )
        let encoded = try JSONEncoder().encode(PrintElement.qr(element))
        let decoded = try JSONDecoder().decode(PrintElement.self, from: encoded)

        XCTAssertEqual(decoded, .qr(element))
    }

    func testLegacyTextAndImageDocumentDecodingStillWorks() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Legacy",
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
                    "text": "Legacy text",
                    "fontSize": 28,
                    "isBold": false,
                    "alignment": "leading",
                    "ink": "black",
                    "rotationDegrees": 0
                  }
                },
                {
                  "type": "image",
                  "image": {
                    "id": "00000000-0000-0000-0000-000000000004",
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
        """

        let document = try JSONDecoder().decode(PrintDocument.self, from: Data(json.utf8))

        XCTAssertEqual(document.firstPage.elements.count, 2)
        guard case .text = document.firstPage.elements[0],
              case .image = document.firstPage.elements[1] else {
            XCTFail("Expected legacy text and image elements")
            return
        }
    }

    func testDuplicateQRCodeGetsNewUUID() throws {
        let original = QRCodeElement(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            frame: PrintElementFrame(x: 92, y: 48, width: 200, height: 200),
            text: "https://example.com",
            errorCorrection: .q
        )

        guard case .qr(let duplicate) = PrintElement.qr(original).duplicated() else {
            XCTFail("Expected duplicated QR element")
            return
        }

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.text, original.text)
        XCTAssertEqual(duplicate.errorCorrection, original.errorCorrection)
        XCTAssertEqual(duplicate.frame.x, original.frame.x + 16)
        XCTAssertEqual(duplicate.frame.y, original.frame.y + 16)
    }

    func testQRCodeRendererProducesBlackAndWhitePixels() throws {
        let image = try XCTUnwrap(QRCodeRenderer.makeImage(text: "https://example.com", errorCorrection: .m))
        let pixels = rgbaPixels(from: image)
        let pixelValues = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }

        XCTAssertTrue(pixelValues.contains(0))
        XCTAssertTrue(pixelValues.contains(255))
    }

    func testQRCodeRenderingIsDeterministicForSameContent() throws {
        let first = try XCTUnwrap(QRCodeRenderer.makeImage(text: "same content", errorCorrection: .m))
        let second = try XCTUnwrap(QRCodeRenderer.makeImage(text: "same content", errorCorrection: .m))

        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        XCTAssertEqual(rgbaPixels(from: first), rgbaPixels(from: second))
    }

    func testEachQRCodeErrorCorrectionOptionRendersSuccessfully() throws {
        for correction in QRCodeErrorCorrection.allCases {
            let image = QRCodeRenderer.makeImage(text: "correction \(correction.rawValue)", errorCorrection: correction)

            XCTAssertNotNil(image)
        }
    }

    func testQRCodeQuietZoneIsWhite() throws {
        let image = try XCTUnwrap(QRCodeRenderer.makeImage(text: "https://example.com"))
        let pixels = rgbaPixels(from: image)

        for index in 0..<QRCodeRenderer.quietZoneModules {
            assertHorizontalLineIsWhite(y: index, image: image, pixels: pixels)
            assertHorizontalLineIsWhite(y: image.height - 1 - index, image: image, pixels: pixels)
            assertVerticalLineIsWhite(x: index, image: image, pixels: pixels)
            assertVerticalLineIsWhite(x: image.width - 1 - index, image: image, pixels: pixels)
        }
    }

    func testPixelPerfectDrawRectReturnsIntegerModuleScaleAndPixelAlignedOrigin() throws {
        let image = try XCTUnwrap(QRCodeRenderer.makeImage(text: "https://example.com"))
        let drawRect = try XCTUnwrap(
            QRCodeRenderer.pixelPerfectDrawRect(
                for: image,
                in: CGRect(x: 0, y: 0, width: 200, height: 200)
            )
        )

        let scale = drawRect.width / CGFloat(image.width)

        XCTAssertEqual(scale, floor(scale))
        XCTAssertEqual(drawRect.origin.x, floor(drawRect.origin.x))
        XCTAssertEqual(drawRect.origin.y, floor(drawRect.origin.y))
    }

    func testPixelPerfectDrawRectReturnsNilWhenFrameIsSmallerThanQRSourceImage() throws {
        let image = try XCTUnwrap(QRCodeRenderer.makeImage(text: "https://example.com"))
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width - 1),
            height: CGFloat(image.height - 1)
        )

        XCTAssertNil(QRCodeRenderer.pixelPerfectDrawRect(for: image, in: rect))
    }

    private func rgbaPixels(from image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }

        return pixels
    }

    private func assertHorizontalLineIsWhite(
        y: Int,
        image: CGImage,
        pixels: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for x in 0..<image.width {
            assertPixelIsWhite(x: x, y: y, image: image, pixels: pixels, file: file, line: line)
        }
    }

    private func assertVerticalLineIsWhite(
        x: Int,
        image: CGImage,
        pixels: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for y in 0..<image.height {
            assertPixelIsWhite(x: x, y: y, image: image, pixels: pixels, file: file, line: line)
        }
    }

    private func assertPixelIsWhite(
        x: Int,
        y: Int,
        image: CGImage,
        pixels: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offset = (y * image.width + x) * 4

        XCTAssertEqual(pixels[offset], 255, file: file, line: line)
        XCTAssertEqual(pixels[offset + 1], 255, file: file, line: line)
        XCTAssertEqual(pixels[offset + 2], 255, file: file, line: line)
        XCTAssertEqual(pixels[offset + 3], 255, file: file, line: line)
    }
}
