import Foundation
import CoreGraphics

struct BitmapRasterizer {
    static let targetWidth = 384
    static let rowByteCount = 48

    var mode: DitheringMode
    var threshold: UInt8
    var logger: DiagnosticLogger

    init(
        mode: DitheringMode = .floydSteinberg,
        threshold: UInt8 = 128,
        logger: DiagnosticLogger = .shared
    ) {
        self.mode = mode
        self.threshold = threshold
        self.logger = logger
    }

    func rasterRows(from image: CGImage) -> [Data] {
        let preparedImage = image.width == Self.targetWidth ? image : scaledToTargetWidth(image)
        let width = preparedImage.width
        let height = preparedImage.height
        logger.log(
            .raster,
            "raster start",
            metadata: [
                "sourceDimensions": "\(image.width)x\(image.height)",
                "renderedDimensions": "\(width)x\(height)",
                "targetWidth": Self.targetWidth,
                "mode": mode.rawValue,
                "threshold": threshold
            ]
        )
        let grayscale = grayscalePixels(from: preparedImage)
        logger.log(
            .raster,
            "grayscale",
            metadata: [
                "dimensions": "\(width)x\(height)",
                "pixels": grayscale.count
            ]
        )

        let blackPixels: [Bool]
        switch mode {
        case .threshold:
            blackPixels = thresholdPixels(grayscale, threshold: threshold)
        case .floydSteinberg:
            blackPixels = ditherFloydSteinberg(grayscale, width: width, height: height, threshold: threshold)
        case .atkinson:
            blackPixels = ditherAtkinson(grayscale, width: width, height: height, threshold: threshold)
        }

        let rows = packRows(blackPixels, width: width, height: height)
        logger.log(
            .raster,
            "raster complete",
            metadata: [
                "width": width,
                "rows": rows.count,
                "bytesPerRow": Self.rowByteCount,
                "mode": mode.rawValue
            ]
        )
        return rows
    }

    static func previewImage(from rows: [Data]) -> CGImage? {
        guard !rows.isEmpty else {
            DiagnosticLogger.shared.log(.raster, "preview unavailable", metadata: ["reason": "empty rows"])
            return nil
        }

        let width = targetWidth
        let height = rows.count
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        for y in 0..<height {
            let row = rows[y]
            for x in 0..<width {
                let byte = row[x / 8]
                let mask = UInt8(0x80 >> (x % 8))
                let isBlack = (byte & mask) != 0
                let value: UInt8 = isBlack ? 0 : 255
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }

        let image = makeImage(width: width, height: height, pixels: &pixels)
        DiagnosticLogger.shared.log(
            .raster,
            "1-bit preview image",
            metadata: [
                "width": width,
                "height": height,
                "rows": rows.count,
                "bytesPerRow": Self.rowByteCount
            ]
        )
        return image
    }

    private func scaledToTargetWidth(_ image: CGImage) -> CGImage {
        let targetHeight = max(1, Int((Double(image.height) * Double(Self.targetWidth) / Double(image.width)).rounded()))
        let bytesPerPixel = 4
        let bytesPerRow = Self.targetWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: targetHeight * bytesPerRow)

        guard Self.withBitmapContext(width: Self.targetWidth, height: targetHeight, pixels: &pixels, render: { context in
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(Self.targetWidth),
                    height: CGFloat(targetHeight)
                )
            )
            return true
        }) == true else {
            logger.log(
                .error,
                "scale to target width failed",
                metadata: [
                    "sourceDimensions": "\(image.width)x\(image.height)",
                    "targetWidth": Self.targetWidth
                ]
            )
            return image
        }

        logger.log(
            .raster,
            "scale to target width",
            metadata: [
                "sourceDimensions": "\(image.width)x\(image.height)",
                "scaledDimensions": "\(Self.targetWidth)x\(targetHeight)"
            ]
        )
        return Self.makeImage(width: Self.targetWidth, height: targetHeight, pixels: &pixels) ?? image
    }

    private func grayscalePixels(from image: CGImage) -> [Double] {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        guard Self.withBitmapContext(width: width, height: height, pixels: &pixels, render: { context in
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
            return true
        }) == true else {
            logger.log(
                .error,
                "grayscale context failed",
                metadata: ["dimensions": "\(width)x\(height)"]
            )
            return [Double](repeating: 255, count: width * height)
        }

        return (0..<(width * height)).map { index in
            let offset = index * bytesPerPixel
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let alpha = Double(pixels[offset + 3]) / 255
            let luma = 0.299 * red + 0.587 * green + 0.114 * blue
            return luma * alpha + 255 * (1 - alpha)
        }
    }

    private func thresholdPixels(_ pixels: [Double], threshold: UInt8) -> [Bool] {
        pixels.map { $0 < Double(threshold) }
    }

    private func ditherFloydSteinberg(_ pixels: [Double], width: Int, height: Int, threshold: UInt8) -> [Bool] {
        diffuse(
            pixels,
            width: width,
            height: height,
            threshold: threshold,
            neighbors: [
                (1, 0, 7.0 / 16.0),
                (-1, 1, 3.0 / 16.0),
                (0, 1, 5.0 / 16.0),
                (1, 1, 1.0 / 16.0)
            ]
        )
    }

    private func ditherAtkinson(_ pixels: [Double], width: Int, height: Int, threshold: UInt8) -> [Bool] {
        diffuse(
            pixels,
            width: width,
            height: height,
            threshold: threshold,
            neighbors: [
                (1, 0, 1.0 / 8.0),
                (2, 0, 1.0 / 8.0),
                (-1, 1, 1.0 / 8.0),
                (0, 1, 1.0 / 8.0),
                (1, 1, 1.0 / 8.0),
                (0, 2, 1.0 / 8.0)
            ]
        )
    }

    private func diffuse(
        _ pixels: [Double],
        width: Int,
        height: Int,
        threshold: UInt8,
        neighbors: [(dx: Int, dy: Int, weight: Double)]
    ) -> [Bool] {
        var values = pixels
        var result = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let oldValue = values[index]
                let newValue: Double = oldValue < Double(threshold) ? 0 : 255
                result[index] = newValue == 0
                let error = oldValue - newValue

                for neighbor in neighbors {
                    let nx = x + neighbor.dx
                    let ny = y + neighbor.dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else {
                        continue
                    }

                    let neighborIndex = ny * width + nx
                    values[neighborIndex] = min(255, max(0, values[neighborIndex] + error * neighbor.weight))
                }
            }
        }

        return result
    }

    private func packRows(_ blackPixels: [Bool], width: Int, height: Int) -> [Data] {
        precondition(width == Self.targetWidth, "MX10 raster rows must be 384 pixels wide")

        var rows: [Data] = []
        rows.reserveCapacity(height)

        for y in 0..<height {
            var row = Data(repeating: 0, count: Self.rowByteCount)
            for x in 0..<width where blackPixels[y * width + x] {
                let byteIndex = x / 8
                let bit = UInt8(0x80 >> (x % 8))
                row[byteIndex] |= bit
            }
            rows.append(row)
        }

        return rows
    }

    private static func withBitmapContext<T>(
        width: Int,
        height: Int,
        pixels: inout [UInt8],
        render: (CGContext) -> T
    ) -> T? {
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = bitmapContext(width: width, height: height, data: baseAddress) else {
                return nil
            }

            return render(context)
        }
    }

    private static func bitmapContext(width: Int, height: Int, data: UnsafeMutableRawPointer) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    private static func makeImage(width: Int, height: Int, pixels: inout [UInt8]) -> CGImage? {
        var image: CGImage?
        _ = withBitmapContext(width: width, height: height, pixels: &pixels) { context in
            image = context.makeImage()
            return true
        }
        return image
    }
}
