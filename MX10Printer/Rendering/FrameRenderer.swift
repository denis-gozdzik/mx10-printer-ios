import CoreGraphics

struct FrameRenderer {
    static func draw(element: FrameElement, in context: CGContext) {
        let rect = CGRect(
            x: element.frame.x,
            y: element.frame.y,
            width: element.frame.width,
            height: element.frame.height
        ).standardized
        let lineWidth = clampedLineWidth(element.lineWidth)
        let strokeRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        guard strokeRect.width > 0, strokeRect.height > 0 else {
            return
        }

        context.saveGState()
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setShouldAntialias(false)

        switch element.kind {
        case .rounded:
            strokeRoundedRect(strokeRect, in: context)
        case .square:
            context.stroke(strokeRect)
        case .dashed:
            context.setLineDash(phase: 0, lengths: [8, 6])
            strokeRoundedRect(strokeRect, in: context)
        case .double:
            strokeDoubleRoundedRect(strokeRect, lineWidth: lineWidth, in: context)
        case .oval:
            context.strokeEllipse(in: strokeRect)
        }

        context.restoreGState()
    }

    static func clampedLineWidth(_ lineWidth: Double) -> CGFloat {
        guard lineWidth.isFinite else {
            return 1
        }

        return CGFloat(min(max(lineWidth, 1), 8))
    }

    private static func strokeRoundedRect(_ rect: CGRect, in context: CGContext) {
        context.addPath(roundedPath(in: rect))
        context.strokePath()
    }

    private static func strokeDoubleRoundedRect(_ rect: CGRect, lineWidth: CGFloat, in context: CGContext) {
        strokeRoundedRect(rect, in: context)

        let inset = max(CGFloat(6), lineWidth * 2.5)
        let innerRect = rect.insetBy(dx: inset, dy: inset)
        guard innerRect.width > lineWidth * 2, innerRect.height > lineWidth * 2 else {
            return
        }

        strokeRoundedRect(innerRect, in: context)
    }

    private static func roundedPath(in rect: CGRect) -> CGPath {
        let cornerRadius = min(CGFloat(18), min(rect.width, rect.height) * 0.15)
        return CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }
}
