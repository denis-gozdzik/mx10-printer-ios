import Foundation
import CoreGraphics
import UIKit

struct PrintPreview {
    let renderedImage: CGImage
    let rasterRows: [Data]
    let printRowCount: Int
    let previewImage: CGImage?
}

enum PrintJobBuildError: LocalizedError, Equatable {
    case imageDecodeFailed(elementID: UUID)
    case invalidRaster(rowCount: Int, invalidRowCount: Int)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .imageDecodeFailed(let elementID):
            return "Image decode failed for element \(elementID.uuidString)."
        case .invalidRaster(let rowCount, let invalidRowCount):
            return "Invalid raster output: rows=\(rowCount), invalidRows=\(invalidRowCount)."
        case .emptyContent:
            return "The document contains no printable content."
        }
    }
}

struct PrintRasterTrimResult: Equatable {
    let rows: [Data]
    let originalRows: Int
    let printRows: Int
    let removedRows: Int
    let bottomMargin: Int
}

struct PrintJobBuilder {
    static let bottomPrintMarginRows = 24

    var pageRenderer: PageRenderer
    var logger: DiagnosticLogger

    init(
        pageRenderer: PageRenderer? = nil,
        logger: DiagnosticLogger = .shared
    ) {
        self.logger = logger
        self.pageRenderer = pageRenderer ?? PageRenderer(logger: logger)
    }

    func makePreview(document: PrintDocument, preferences: PrintingPreferences) throws -> PrintPreview {
        try validateImages(in: document)

        let renderedImage = pageRenderer.render(document: document)
        let rasterizer = BitmapRasterizer(
            mode: preferences.ditheringMode,
            threshold: preferences.threshold,
            logger: logger
        )
        let rows = rasterizer.rasterRows(from: renderedImage)
        try validateRaster(rows)
        let printRowCount = printableRowCount(for: rows)
        logger.log(
            .raster,
            "preview built",
            metadata: [
                "document": document.id.uuidString,
                "renderedDimensions": "\(renderedImage.width)x\(renderedImage.height)",
                "rows": rows.count,
                "printRows": printRowCount,
                "bytesPerRow": BitmapRasterizer.rowByteCount,
                "mode": preferences.ditheringMode.rawValue,
                "threshold": preferences.threshold
            ]
        )
        return PrintPreview(
            renderedImage: renderedImage,
            rasterRows: rows,
            printRowCount: printRowCount,
            previewImage: BitmapRasterizer.previewImage(from: rows)
        )
    }

    func makeJob(document: PrintDocument, preferences: PrintingPreferences) throws -> PrintJob {
        let preview = try makePreview(document: document, preferences: preferences)
        return try makeJob(
            document: document,
            preview: preview,
            preferences: preferences
        )
    }

    func makeJob(
        document: PrintDocument,
        preview: PrintPreview,
        preferences: PrintingPreferences
    ) throws -> PrintJob {
        let trimResult = try trimRasterRowsForPrinting(preview.rasterRows)
        logger.log(
            .raster,
            "raster trim",
            metadata: [
                "originalRows": trimResult.originalRows,
                "printRows": trimResult.printRows,
                "removedRows": trimResult.removedRows,
                "bottomMargin": trimResult.bottomMargin
            ]
        )
        logger.log(
            .queue,
            "make print job",
            metadata: [
                "document": document.id.uuidString,
                "rows": trimResult.printRows,
                "bytesPerRow": BitmapRasterizer.rowByteCount
            ]
        )
        return PrintJob(
            documentID: document.id,
            rows: trimResult.rows,
            feedAfterPrintSteps: preferences.defaultFeedAfterPrint
        )
    }

    func trimRasterRowsForPrinting(_ rows: [Data]) throws -> PrintRasterTrimResult {
        try validateRaster(rows)

        guard let lastContentIndex = rows.lastIndex(where: { !isWhiteRow($0) }) else {
            logger.log(.error, "empty printable raster", metadata: ["rows": rows.count])
            throw PrintJobBuildError.emptyContent
        }

        let printRowCount = min(
            rows.count,
            lastContentIndex + 1 + Self.bottomPrintMarginRows
        )
        let trimmedRows = Array(rows.prefix(printRowCount))

        return PrintRasterTrimResult(
            rows: trimmedRows,
            originalRows: rows.count,
            printRows: trimmedRows.count,
            removedRows: rows.count - trimmedRows.count,
            bottomMargin: Self.bottomPrintMarginRows
        )
    }

    func printableRowCount(for rows: [Data]) -> Int {
        guard let lastContentIndex = rows.lastIndex(where: { !isWhiteRow($0) }) else {
            return 0
        }

        return min(rows.count, lastContentIndex + 1 + Self.bottomPrintMarginRows)
    }

    private func validateImages(in document: PrintDocument) throws {
        for element in document.firstPage.elements {
            guard case .image(let imageElement) = element else {
                continue
            }

            logger.log(
                .image,
                "validate image element",
                metadata: [
                    "element": imageElement.id.uuidString,
                    "dataBytes": imageElement.imageData.count,
                    "contentMode": imageElement.contentMode.rawValue,
                    "rotation": imageElement.rotationDegrees,
                    "crop": "x:\(imageElement.cropRect.x),y:\(imageElement.cropRect.y),w:\(imageElement.cropRect.width),h:\(imageElement.cropRect.height)"
                ]
            )

            guard let image = UIImage(data: imageElement.imageData) else {
                logger.log(
                    .error,
                    "image decode failed",
                    metadata: ["element": imageElement.id.uuidString]
                )
                throw PrintJobBuildError.imageDecodeFailed(elementID: imageElement.id)
            }

            logger.log(
                .image,
                "image input decoded",
                metadata: [
                    "element": imageElement.id.uuidString,
                    "sourceDimensions": "\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))",
                    "orientation": "\(image.imageOrientation.rawValue)",
                    "cgImage": image.cgImage == nil ? "missing" : "available"
                ]
            )
        }
    }

    private func validateRaster(_ rows: [Data]) throws {
        let invalidRows = rows.filter { $0.count != BitmapRasterizer.rowByteCount }.count
        guard !rows.isEmpty, invalidRows == 0 else {
            logger.log(
                .error,
                "invalid raster",
                metadata: [
                    "rows": rows.count,
                    "invalidRows": invalidRows,
                    "expectedBytesPerRow": BitmapRasterizer.rowByteCount
                ]
            )
            throw PrintJobBuildError.invalidRaster(
                rowCount: rows.count,
                invalidRowCount: invalidRows
            )
        }
    }

    private func isWhiteRow(_ row: Data) -> Bool {
        row.allSatisfy { $0 == 0x00 }
    }
}
