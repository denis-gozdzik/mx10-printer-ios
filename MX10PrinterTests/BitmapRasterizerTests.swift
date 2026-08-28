import UIKit
import XCTest
@testable import MX10Printer

final class BitmapRasterizerTests: XCTestCase {
    func testRasterRowsAre384PixelsWideAnd48BytesPerRow() {
        let image = solidImage(width: 192, height: 2, gray: 255)
        let rasterizer = BitmapRasterizer(mode: .threshold, threshold: 128)

        let rows = rasterizer.rasterRows(from: image)
        let previewImage = BitmapRasterizer.previewImage(from: rows)

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.count == BitmapRasterizer.rowByteCount })
        XCTAssertEqual(previewImage?.width ?? 0, BitmapRasterizer.targetWidth)
    }

    func testAllWhiteImageProducesEmptyRows() {
        let image = solidImage(height: 3, gray: 255)
        let rows = BitmapRasterizer(mode: .threshold, threshold: 128).rasterRows(from: image)

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0 == Data(repeating: 0x00, count: BitmapRasterizer.rowByteCount) })
    }

    func testAllBlackImageProducesFilledRows() {
        let image = solidImage(height: 3, gray: 0)
        let rows = BitmapRasterizer(mode: .threshold, threshold: 128).rasterRows(from: image)

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0 == Data(repeating: 0xFF, count: BitmapRasterizer.rowByteCount) })
    }

    func testThresholdPacksLeftToRightBits() {
        let image = splitBlackWhiteImage()
        let row = BitmapRasterizer(mode: .threshold, threshold: 128).rasterRows(from: image)[0]

        XCTAssertEqual(Data(row.prefix(24)), Data(repeating: 0xFF, count: 24))
        XCTAssertEqual(Data(row.suffix(24)), Data(repeating: 0x00, count: 24))
    }

    func testFloydSteinbergDitherProducesMixedPixelsForMidGray() {
        let image = solidImage(height: 8, gray: 127)
        let rows = BitmapRasterizer(mode: .floydSteinberg, threshold: 128).rasterRows(from: image)
        let blackPixelCount = countBlackPixels(in: rows)

        XCTAssertGreaterThan(blackPixelCount, 0)
        XCTAssertLessThan(blackPixelCount, BitmapRasterizer.targetWidth * rows.count)
    }

    func testAtkinsonDitherProducesMixedPixelsForMidGray() {
        let image = solidImage(height: 8, gray: 127)
        let rows = BitmapRasterizer(mode: .atkinson, threshold: 128).rasterRows(from: image)
        let blackPixelCount = countBlackPixels(in: rows)

        XCTAssertGreaterThan(blackPixelCount, 0)
        XCTAssertLessThan(blackPixelCount, BitmapRasterizer.targetWidth * rows.count)
    }

    private func solidImage(
        width: Int = BitmapRasterizer.targetWidth,
        height: Int = 1,
        gray: UInt8
    ) -> CGImage {
        let renderer = imageRenderer(width: width, height: height)
        let uiImage = renderer.image { context in
            UIColor(
                red: CGFloat(gray) / 255,
                green: CGFloat(gray) / 255,
                blue: CGFloat(gray) / 255,
                alpha: 1
            ).setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        return uiImage.cgImage!
    }

    private func splitBlackWhiteImage() -> CGImage {
        let renderer = imageRenderer(width: BitmapRasterizer.targetWidth, height: 1)
        let uiImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(192), height: CGFloat(1)))
            UIColor.white.setFill()
            context.fill(CGRect(x: CGFloat(192), y: 0, width: CGFloat(192), height: CGFloat(1)))
        }
        return uiImage.cgImage!
    }

    private func imageRenderer(width: Int, height: Int) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format)
    }

    private func countBlackPixels(in rows: [Data]) -> Int {
        rows.reduce(0) { total, row in
            total + row.reduce(0) { byteTotal, byte in
                byteTotal + byte.nonzeroBitCount
            }
        }
    }
}
