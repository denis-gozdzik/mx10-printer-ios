import Foundation
import CoreGraphics
import UIKit

struct PrintPreview {
    let renderedImage: CGImage
    let rasterRows: [Data]
    let previewImage: CGImage?
}

enum PrintJobBuildError: LocalizedError, Equatable {
    case imageDecodeFailed(elementID: UUID)
    case invalidRaster(rowCount: Int, invalidRowCount: Int)

    var errorDescription: String? {
        switch self {
        case .imageDecodeFailed(let elementID):
            return "Image decode failed for element \(elementID.uuidString)."
        case .invalidRaster(let rowCount, let invalidRowCount):
            return "Invalid raster output: rows=\(rowCount), invalidRows=\(invalidRowCount)."
        }
    }
}

struct PrintJobBuilder {
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
        logger.log(
            .raster,
            "preview built",
            metadata: [
                "document": document.id.uuidString,
                "renderedDimensions": "\(renderedImage.width)x\(renderedImage.height)",
                "rows": rows.count,
                "bytesPerRow": BitmapRasterizer.rowByteCount,
                "mode": preferences.ditheringMode.rawValue,
                "threshold": preferences.threshold
            ]
        )
        return PrintPreview(
            renderedImage: renderedImage,
            rasterRows: rows,
            previewImage: BitmapRasterizer.previewImage(from: rows)
        )
    }

    func makeJob(document: PrintDocument, preferences: PrintingPreferences) throws -> PrintJob {
        let preview = try makePreview(document: document, preferences: preferences)
        return makeJob(
            document: document,
            preview: preview,
            preferences: preferences
        )
    }

    func makeJob(
        document: PrintDocument,
        preview: PrintPreview,
        preferences: PrintingPreferences
    ) -> PrintJob {
        logger.log(
            .queue,
            "make print job",
            metadata: [
                "document": document.id.uuidString,
                "rows": preview.rasterRows.count,
                "bytesPerRow": BitmapRasterizer.rowByteCount
            ]
        )
        return PrintJob(
            documentID: document.id,
            rows: preview.rasterRows,
            feedAfterPrintSteps: preferences.defaultFeedAfterPrint
        )
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
}
