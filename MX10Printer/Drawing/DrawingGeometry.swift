import CoreGraphics
import Foundation

enum DrawingPenWidth: String, CaseIterable, Identifiable {
    case thin
    case medium
    case thick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thin:
            return "Thin"
        case .medium:
            return "Medium"
        case .thick:
            return "Thick"
        }
    }

    var lineWidth: Double {
        switch self {
        case .thin:
            return 2
        case .medium:
            return 5
        case .thick:
            return 9
        }
    }
}

struct DrawingGeometry {
    static let pointSamplingDistance: Double = 1.5

    static func sampledStroke(from stroke: DrawingStroke, adding point: DrawingPoint) -> DrawingStroke {
        var sampled = stroke
        guard shouldAppendPoint(to: sampled, point: point) else {
            return sampled
        }

        sampled.points.append(point)
        return sampled
    }

    static func shouldAppendPoint(
        to stroke: DrawingStroke,
        point: DrawingPoint,
        minimumDistance: Double = pointSamplingDistance
    ) -> Bool {
        guard point.isFinite else {
            return false
        }

        guard let lastPoint = stroke.points.last else {
            return true
        }

        return distance(from: lastPoint, to: point) >= minimumDistance
    }

    static func boundingFrame(
        for strokes: [DrawingStroke],
        pageWidth: Double,
        pageHeight: Double
    ) -> PrintElementFrame? {
        let validStrokes = strokes.filter { $0.lineWidth.isFinite && $0.lineWidth > 0 }
        let points = validStrokes.flatMap { $0.points }.filter(\.isFinite)
        guard !points.isEmpty,
              pageWidth.isFinite,
              pageHeight.isFinite,
              pageWidth > 0,
              pageHeight > 0 else {
            return nil
        }

        let maxLineWidth = validStrokes.map(\.lineWidth).max() ?? DrawingPenWidth.medium.lineWidth
        let padding = maxLineWidth / 2 + 2
        let minX = max(0, (points.map(\.x).min() ?? 0) - padding)
        let minY = max(0, (points.map(\.y).min() ?? 0) - padding)
        let maxX = min(pageWidth, (points.map(\.x).max() ?? 0) + padding)
        let maxY = min(pageHeight, (points.map(\.y).max() ?? 0) + padding)
        let width = max(1, maxX - minX)
        let height = max(1, maxY - minY)

        return PrintElementFrame(x: minX, y: minY, width: width, height: height)
    }

    static func drawingElement(
        from pageStrokes: [DrawingStroke],
        pageWidth: Double,
        pageHeight: Double
    ) -> DrawingElement? {
        guard let frame = boundingFrame(for: pageStrokes, pageWidth: pageWidth, pageHeight: pageHeight) else {
            return nil
        }

        let localStrokes = pageStrokes.compactMap { stroke -> DrawingStroke? in
            guard stroke.lineWidth.isFinite, stroke.lineWidth > 0 else {
                return nil
            }

            let localPoints = stroke.points.compactMap { point -> DrawingPoint? in
                guard point.isFinite else {
                    return nil
                }

                return DrawingPoint(x: point.x - frame.x, y: point.y - frame.y)
            }
            guard !localPoints.isEmpty else {
                return nil
            }

            return DrawingStroke(id: stroke.id, points: localPoints, lineWidth: stroke.lineWidth)
        }
        guard !localStrokes.isEmpty else {
            return nil
        }

        return DrawingElement(
            frame: frame,
            sourceSize: DrawingSize(width: frame.width, height: frame.height),
            strokes: localStrokes
        )
    }

    static func eraserTolerance(for stroke: DrawingStroke) -> Double {
        guard stroke.lineWidth.isFinite, stroke.lineWidth > 0 else {
            return 8
        }

        return max(8, stroke.lineWidth / 2 + 6)
    }

    static func stroke(_ stroke: DrawingStroke, contains point: DrawingPoint) -> Bool {
        guard point.isFinite else {
            return false
        }

        return Self.stroke(stroke, contains: point, tolerance: eraserTolerance(for: stroke))
    }

    static func stroke(
        _ stroke: DrawingStroke,
        contains point: DrawingPoint,
        tolerance: Double
    ) -> Bool {
        guard point.isFinite,
              tolerance.isFinite,
              tolerance >= 0 else {
            return false
        }

        let points = stroke.points.filter(\.isFinite)
        guard let first = points.first else {
            return false
        }

        guard points.count > 1 else {
            return distance(from: first, to: point) <= tolerance
        }

        for index in points.indices.dropLast() {
            if pointSegmentDistance(point: point, start: points[index], end: points[index + 1]) <= tolerance {
                return true
            }
        }

        return false
    }

    static func totalPointCount(in strokes: [DrawingStroke]) -> Int {
        strokes.reduce(0) { $0 + $1.points.count }
    }

    static func distance(from first: DrawingPoint, to second: DrawingPoint) -> Double {
        hypot(second.x - first.x, second.y - first.y)
    }

    private static func pointSegmentDistance(
        point: DrawingPoint,
        start: DrawingPoint,
        end: DrawingPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return distance(from: point, to: start)
        }

        let rawT = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(1, max(0, rawT))
        let projected = DrawingPoint(
            x: start.x + t * dx,
            y: start.y + t * dy
        )

        return distance(from: point, to: projected)
    }
}

extension DrawingPoint {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}
