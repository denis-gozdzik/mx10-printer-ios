import CoreGraphics
import CoreImage
import Foundation

struct QRCodeRenderer {
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

        let outputImage = falseColorFilter.outputImage ?? qrImage
        let context = CIContext(options: nil)
        return context.createCGImage(outputImage, from: outputImage.extent.integral)
    }

    static func makeImage(from element: QRCodeElement) -> CGImage? {
        makeImage(text: element.text, errorCorrection: element.errorCorrection)
    }
}
