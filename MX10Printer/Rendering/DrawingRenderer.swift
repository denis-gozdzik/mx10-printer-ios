import CoreGraphics
import Foundation

struct DrawingRenderer {
    static let minimumLineWidth: CGFloat = 1
    static let maximumLineWidth: CGFloat = 32

    static func draw(element: DrawingElement, in context: CGContext) {
        let rect = element.frame.cgRect
        guard rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0,
              element.sourceSize.width.isFinite,
              element.sourceSize.height.isFinite,
              element.sourceSize.width > 0,
              element.sourceSize.height > 0,
              !element.strokes.isEmpty else {
            return
        }

        let scaleX = rect.width / CGFloat(element.sourceSize.width)
        let scaleY = rect.height / CGFloat(element.sourceSize.height)
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX > 0,
              scaleY > 0 else {
            return
        }

        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in element.strokes {
            draw(stroke: stroke, in: context, rect: rect, scaleX: scaleX, scaleY: scaleY)
        }

        context.restoreGState()
    }

    static func clampedLineWidth(_ lineWidth: Double) -> CGFloat {
        guard lineWidth.isFinite, lineWidth > 0 else {
            return minimumLineWidth
        }

        return min(max(CGFloat(lineWidth), minimumLineWidth), maximumLineWidth)
    }

    private static func draw(
        stroke: DrawingStroke,
        in context: CGContext,
        rect: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        let points = stroke.points.compactMap { point -> CGPoint? in
            guard point.isFinite else {
                return nil
            }

            return CGPoint(
                x: rect.minX + CGFloat(point.x) * scaleX,
                y: rect.minY + CGFloat(point.y) * scaleY
            )
        }
        guard let firstPoint = points.first else {
            return
        }

        let strokeScale = min(scaleX, scaleY)
        let lineWidth = clampedLineWidth(stroke.lineWidth * Double(strokeScale))
        context.setLineWidth(lineWidth)

        guard points.count > 1 else {
            let dotRect = CGRect(
                x: firstPoint.x - lineWidth / 2,
                y: firstPoint.y - lineWidth / 2,
                width: lineWidth,
                height: lineWidth
            )
            context.fillEllipse(in: dotRect)
            return
        }

        context.beginPath()
        context.move(to: firstPoint)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }
}

private extension PrintElementFrame {
    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}
