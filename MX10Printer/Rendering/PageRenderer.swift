import Foundation
import CoreImage
import UIKit

struct PageRenderer {
    func render(document: PrintDocument) -> CGImage {
        render(page: document.firstPage)
    }

    func render(page: PrintPage) -> CGImage {
        let width = Int(PrintDocument.pageWidth)
        let height = max(1, Int(ceil(page.height)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            format: format
        )
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

            for element in page.elements {
                render(element: element, in: context.cgContext)
            }
        }

        return image.cgImage!
    }

    private func render(element: PrintElement, in context: CGContext) {
        switch element {
        case .text(let textElement):
            render(textElement: textElement, in: context)
        case .image(let imageElement):
            render(imageElement: imageElement, in: context)
        }
    }

    private func render(textElement: TextElement, in context: CGContext) {
        let rect = textElement.frame.cgRect
        context.saveGState()
        applyRotation(textElement.rotationDegrees, around: rect, in: context)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textElement.alignment.nsTextAlignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        let font = textElement.isBold
            ? UIFont.boldSystemFont(ofSize: CGFloat(textElement.fontSize))
            : UIFont.systemFont(ofSize: CGFloat(textElement.fontSize))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textElement.ink.uiColor,
            .paragraphStyle: paragraphStyle
        ]

        NSString(string: textElement.text).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        context.restoreGState()
    }

    private func render(imageElement: ImageElement, in context: CGContext) {
        guard let image = preparedImage(from: imageElement) else {
            return
        }

        let rect = imageElement.frame.cgRect
        context.saveGState()
        applyRotation(imageElement.rotationDegrees, around: rect, in: context)
        context.clip(to: rect)

        let drawRect = targetRect(for: image.size, in: rect, contentMode: imageElement.contentMode)
        image.draw(in: drawRect)

        context.restoreGState()
    }

    private func preparedImage(from imageElement: ImageElement) -> UIImage? {
        guard let original = UIImage(data: imageElement.imageData),
              let cropped = crop(original, cropRect: imageElement.cropRect) else {
            return nil
        }

        return imageElement.isInverted ? inverted(cropped) : cropped
    }

    private func crop(_ image: UIImage, cropRect: NormalizedCropRect) -> UIImage? {
        guard let cgImage = image.cgImage else {
            return image
        }

        let normalized = cropRect.clamped()
        let sourceRect = CGRect(
            x: CGFloat(normalized.x) * CGFloat(cgImage.width),
            y: CGFloat(normalized.y) * CGFloat(cgImage.height),
            width: CGFloat(normalized.width) * CGFloat(cgImage.width),
            height: CGFloat(normalized.height) * CGFloat(cgImage.height)
        ).integral

        guard let croppedImage = cgImage.cropping(to: sourceRect) else {
            return image
        }

        return UIImage(cgImage: croppedImage, scale: 1, orientation: image.imageOrientation)
    }

    private func inverted(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image),
              let filter = CIFilter(name: "CIColorInvert") else {
            return image
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        let context = CIContext(options: nil)

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func targetRect(for imageSize: CGSize, in rect: CGRect, contentMode: PrintImageContentMode) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return rect
        }

        let scale: CGFloat
        switch contentMode {
        case .fit:
            scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        case .fill:
            scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        }

        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func applyRotation(_ degrees: Double, around rect: CGRect, in context: CGContext) {
        guard degrees != 0 else {
            return
        }

        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(degrees * .pi / 180))
        context.translateBy(x: -rect.midX, y: -rect.midY)
    }
}

private extension PrintElementFrame {
    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

private extension PrintTextAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:
            return .left
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }
}

private extension PrintInk {
    var uiColor: UIColor {
        switch self {
        case .black:
            return .black
        case .white:
            return .white
        }
    }
}
