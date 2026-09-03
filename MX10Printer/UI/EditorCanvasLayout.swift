import CoreGraphics

struct EditorCanvasLayout: Equatable {
    let pageSize: CGSize
    let availableSize: CGSize
    let scale: CGFloat
    let displaySize: CGSize

    init(pageSize: CGSize, availableSize: CGSize) {
        self.pageSize = pageSize
        self.availableSize = availableSize
        self.scale = Self.scale(pageSize: pageSize, availableSize: availableSize)
        self.displaySize = Self.displaySize(pageSize: pageSize, scale: scale)
    }

    static func scale(pageSize: CGSize, availableSize: CGSize) -> CGFloat {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              availableSize.width.isFinite,
              availableSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0,
              availableSize.width > 0,
              availableSize.height > 0 else {
            return 0
        }

        return min(1, availableSize.width / pageSize.width, availableSize.height / pageSize.height)
    }

    static func displaySize(pageSize: CGSize, scale: CGFloat) -> CGSize {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              scale.isFinite,
              pageSize.width > 0,
              pageSize.height > 0,
              scale > 0 else {
            return .zero
        }

        return CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }

    static func documentTranslation(displayTranslation: CGSize, scale: CGFloat) -> CGSize {
        guard displayTranslation.width.isFinite,
              displayTranslation.height.isFinite,
              scale.isFinite,
              scale > 0 else {
            return .zero
        }

        return CGSize(
            width: displayTranslation.width / scale,
            height: displayTranslation.height / scale
        )
    }

    static func documentPoint(displayPoint: CGPoint, scale: CGFloat) -> CGPoint {
        guard displayPoint.x.isFinite,
              displayPoint.y.isFinite,
              scale.isFinite,
              scale > 0 else {
            return .zero
        }

        return CGPoint(
            x: displayPoint.x / scale,
            y: displayPoint.y / scale
        )
    }

    static func documentPoint(
        displayPoint: CGPoint,
        scale: CGFloat,
        pageSize: CGSize
    ) -> CGPoint {
        let point = documentPoint(displayPoint: displayPoint, scale: scale)
        guard point.x.isFinite,
              point.y.isFinite,
              pageSize.width.isFinite,
              pageSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0 else {
            return .zero
        }

        return CGPoint(
            x: min(max(point.x, 0), pageSize.width),
            y: min(max(point.y, 0), pageSize.height)
        )
    }
}
