import CoreGraphics
import CoreImage
import Foundation

struct QRCodeRenderer {
    static let quietZoneModules = 4

    static func makeImage(
        text: String,
        errorCorrection: QRCodeErrorCorrection = .m
    ) -> CGImage? {
        guard let message = text.data(using: .utf8),
              let qrFilter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        qrFilter.setValue(message, forKey: "inputMessage")
        qrFilter.setValue(errorCorrection.rawValue, forKey: "inputCorrectionLevel")

        guard let qrImage = qrFilter.outputImage,
              let falseColorFilter = CIFilter(name: "CIFalseColor") else {
            return nil
        }

        falseColorFilter.setValue(qrImage, forKey: kCIInputImageKey)
        falseColorFilter.setValue(CIColor.black, forKey: "inputColor0")
        falseColorFilter.setValue(CIColor.white, forKey: "inputColor1")

        let symbolImage = falseColorFilter.outputImage ?? qrImage
        let quietZone = CGFloat(quietZoneModules)
        let paddedExtent = symbolImage.extent
            .insetBy(dx: -quietZone, dy: -quietZone)
            .integral

        let whiteBackground = CIImage(color: .white)
            .cropped(to: paddedExtent)

        let paddedImage = symbolImage.composited(over: whiteBackground)

        let context = CIContext(options: nil)
        return context.createCGImage(paddedImage, from: paddedExtent)
    }

    static func makeImage(from element: QRCodeElement) -> CGImage? {
        makeImage(text: element.text, errorCorrection: element.errorCorrection)
    }

    static func pixelPerfectDrawRect(
        for image: CGImage,
        in rect: CGRect
    ) -> CGRect? {
        guard image.width > 0,
              image.height > 0,
              image.width == image.height else {
            return nil
        }

        let availableSide = floor(min(rect.width, rect.height))
        let integerScale = Int(availableSide) / image.width

        guard integerScale >= 1 else {
            return nil
        }

        let renderedSide = CGFloat(image.width * integerScale)

        return CGRect(
            x: floor(rect.midX - renderedSide / 2),
            y: floor(rect.midY - renderedSide / 2),
            width: renderedSide,
            height: renderedSide
        )
    }
}
