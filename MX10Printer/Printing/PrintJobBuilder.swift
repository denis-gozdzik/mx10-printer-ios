import Foundation
import CoreGraphics

struct PrintPreview {
    let renderedImage: CGImage
    let rasterRows: [Data]
    let previewImage: CGImage?
}

struct PrintJobBuilder {
    var pageRenderer: PageRenderer

    init(pageRenderer: PageRenderer = PageRenderer()) {
        self.pageRenderer = pageRenderer
    }

    func makePreview(document: PrintDocument, preferences: PrintingPreferences) -> PrintPreview {
        let renderedImage = pageRenderer.render(document: document)
        let rasterizer = BitmapRasterizer(
            mode: preferences.ditheringMode,
            threshold: preferences.threshold
        )
        let rows = rasterizer.rasterRows(from: renderedImage)
        return PrintPreview(
            renderedImage: renderedImage,
            rasterRows: rows,
            previewImage: BitmapRasterizer.previewImage(from: rows)
        )
    }

    func makeJob(document: PrintDocument, preferences: PrintingPreferences) -> PrintJob {
        let preview = makePreview(document: document, preferences: preferences)
        return PrintJob(
            documentID: document.id,
            rows: preview.rasterRows,
            feedAfterPrintSteps: preferences.defaultFeedAfterPrint
        )
    }
}
