import UIKit

struct StickerRenderer {
    static func image(for kind: StickerKind, pointSize: CGFloat) -> UIImage? {
        guard pointSize > 0 else {
            return nil
        }

        let configuration = UIImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .regular,
            scale: .large
        )
        return UIImage(systemName: kind.symbolName, withConfiguration: configuration)?
            .withTintColor(.black, renderingMode: .alwaysOriginal)
    }

    static func draw(kind: StickerKind, in rect: CGRect) -> CGRect? {
        guard let image = image(for: kind, pointSize: max(rect.width, rect.height)) else {
            return nil
        }

        let drawRect = aspectFitRect(for: image.size, in: rect)
        image.draw(in: drawRect)
        return drawRect
    }

    static func aspectFitRect(for imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }
}
