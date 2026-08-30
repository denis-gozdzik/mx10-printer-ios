import Foundation

struct PrintDocument: Identifiable, Codable, Equatable {
    static let pageWidth: Double = 384
    static let defaultPageHeight: Double = 640

    var id: UUID
    var title: String
    var pages: [PrintPage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Untitled Print",
        pages: [PrintPage] = [PrintPage()],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.pages = pages.isEmpty ? [PrintPage()] : pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        normalizePageHeight()
    }

    var firstPage: PrintPage {
        get {
            pages.first ?? PrintPage()
        }
        set {
            if pages.isEmpty {
                pages = [newValue]
            } else {
                pages[0] = newValue
            }
            normalizePageHeight()
        }
    }

    mutating func addTextElement() -> UUID {
        let element = TextElement(
            frame: PrintElementFrame(x: 24, y: 32, width: 336, height: 96),
            text: "MX10 Printer"
        )
        var page = firstPage
        page.elements.append(.text(element))
        firstPage = page
        touch()
        return element.id
    }

    mutating func addImageElement(imageData: Data) -> UUID {
        let element = ImageElement(
            frame: PrintElementFrame(x: 24, y: 152, width: 336, height: 220),
            imageData: imageData
        )
        var page = firstPage
        page.elements.append(.image(element))
        firstPage = page
        touch()
        return element.id
    }

    mutating func addQRCodeElement() -> UUID {
        let element = QRCodeElement(
            frame: PrintElementFrame(x: 92, y: 48, width: 200, height: 200),
            text: "https://example.com"
        )
        var page = firstPage
        page.elements.append(.qr(element))
        firstPage = page
        touch()
        return element.id
    }

    mutating func updateElement(id: UUID, update: (inout PrintElement) -> Void) {
        guard let index = firstPage.elements.firstIndex(where: { $0.id == id }) else {
            return
        }

        var page = firstPage
        update(&page.elements[index])
        page.elements[index].frame = page.elements[index].frame.clamped(pageWidth: page.width, pageHeight: page.height)
        firstPage = page
        touch()
    }

    mutating func deleteElement(id: UUID) {
        var page = firstPage
        page.elements.removeAll { $0.id == id }
        firstPage = page
        touch()
    }

    mutating func duplicateElement(id: UUID) -> UUID? {
        guard let element = firstPage.elements.first(where: { $0.id == id }) else {
            return nil
        }

        let duplicate = element.duplicated()
        var page = firstPage
        page.elements.append(duplicate)
        firstPage = page
        touch()
        return duplicate.id
    }

    mutating func touch() {
        updatedAt = Date()
        normalizePageHeight()
    }

    private mutating func normalizePageHeight() {
        guard !pages.isEmpty else {
            pages = [PrintPage()]
            return
        }

        for index in pages.indices {
            let contentBottom = pages[index].elements
                .map { $0.frame.y + $0.frame.height }
                .max() ?? 0
            pages[index].height = max(PrintDocument.defaultPageHeight, ceil(contentBottom + 48))
        }
    }
}

struct PrintPage: Identifiable, Codable, Equatable {
    var id: UUID
    var width: Double
    var height: Double
    var elements: [PrintElement]

    init(
        id: UUID = UUID(),
        width: Double = PrintDocument.pageWidth,
        height: Double = PrintDocument.defaultPageHeight,
        elements: [PrintElement] = []
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.elements = elements
    }
}

struct PrintElementFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func offsetBy(dx: Double, dy: Double) -> PrintElementFrame {
        PrintElementFrame(x: x + dx, y: y + dy, width: width, height: height)
    }

    func resizedBy(dw: Double, dh: Double) -> PrintElementFrame {
        PrintElementFrame(x: x, y: y, width: width + dw, height: height + dh)
    }

    func clamped(pageWidth: Double, pageHeight: Double) -> PrintElementFrame {
        let minimumSize = 24.0
        let clampedWidth = min(max(width, minimumSize), pageWidth)
        let clampedHeight = max(height, minimumSize)
        let clampedX = min(max(x, 0), max(0, pageWidth - clampedWidth))
        let clampedY = max(y, 0)

        return PrintElementFrame(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }
}

struct NormalizedCropRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

    func clamped() -> NormalizedCropRect {
        let clampedWidth = min(max(width, 0.05), 1)
        let clampedHeight = min(max(height, 0.05), 1)
        let clampedX = min(max(x, 0), 1 - clampedWidth)
        let clampedY = min(max(y, 0), 1 - clampedHeight)
        return NormalizedCropRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }
}

enum PrintElement: Identifiable, Codable, Equatable {
    case text(TextElement)
    case image(ImageElement)
    case qr(QRCodeElement)

    private enum CodingKeys: CodingKey {
        case type
        case text
        case image
        case qr
    }

    private enum ElementType: String, Codable {
        case text
        case image
        case qr
    }

    var id: UUID {
        switch self {
        case .text(let element):
            return element.id
        case .image(let element):
            return element.id
        case .qr(let element):
            return element.id
        }
    }

    var frame: PrintElementFrame {
        get {
            switch self {
            case .text(let element):
                return element.frame
            case .image(let element):
                return element.frame
            case .qr(let element):
                return element.frame
            }
        }
        set {
            switch self {
            case .text(var element):
                element.frame = newValue
                self = .text(element)
            case .image(var element):
                element.frame = newValue
                self = .image(element)
            case .qr(var element):
                element.frame = newValue
                self = .qr(element)
            }
        }
    }

    var rotationDegrees: Double {
        switch self {
        case .text(let element):
            return element.rotationDegrees
        case .image(let element):
            return element.rotationDegrees
        case .qr(let element):
            return element.rotationDegrees
        }
    }

    func duplicated() -> PrintElement {
        switch self {
        case .text(var element):
            element.id = UUID()
            element.frame = element.frame.offsetBy(dx: 16, dy: 16)
            return .text(element)
        case .image(var element):
            element.id = UUID()
            element.frame = element.frame.offsetBy(dx: 16, dy: 16)
            return .image(element)
        case .qr(var element):
            element.id = UUID()
            element.frame = element.frame.offsetBy(dx: 16, dy: 16)
            return .qr(element)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ElementType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(TextElement.self, forKey: .text))
        case .image:
            self = .image(try container.decode(ImageElement.self, forKey: .image))
        case .qr:
            self = .qr(try container.decode(QRCodeElement.self, forKey: .qr))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let element):
            try container.encode(ElementType.text, forKey: .type)
            try container.encode(element, forKey: .text)
        case .image(let element):
            try container.encode(ElementType.image, forKey: .type)
            try container.encode(element, forKey: .image)
        case .qr(let element):
            try container.encode(ElementType.qr, forKey: .type)
            try container.encode(element, forKey: .qr)
        }
    }
}

struct TextElement: Identifiable, Codable, Equatable {
    var id: UUID
    var frame: PrintElementFrame
    var text: String
    var fontSize: Double
    var isBold: Bool
    var alignment: PrintTextAlignment
    var ink: PrintInk
    var rotationDegrees: Double

    init(
        id: UUID = UUID(),
        frame: PrintElementFrame,
        text: String = "",
        fontSize: Double = 28,
        isBold: Bool = false,
        alignment: PrintTextAlignment = .leading,
        ink: PrintInk = .black,
        rotationDegrees: Double = 0
    ) {
        self.id = id
        self.frame = frame
        self.text = text
        self.fontSize = fontSize
        self.isBold = isBold
        self.alignment = alignment
        self.ink = ink
        self.rotationDegrees = rotationDegrees
    }
}

struct ImageElement: Identifiable, Codable, Equatable {
    var id: UUID
    var frame: PrintElementFrame
    var imageData: Data
    var contentMode: PrintImageContentMode
    var cropRect: NormalizedCropRect
    var rotationDegrees: Double
    var isInverted: Bool

    init(
        id: UUID = UUID(),
        frame: PrintElementFrame,
        imageData: Data,
        contentMode: PrintImageContentMode = .fit,
        cropRect: NormalizedCropRect = .full,
        rotationDegrees: Double = 0,
        isInverted: Bool = false
    ) {
        self.id = id
        self.frame = frame
        self.imageData = imageData
        self.contentMode = contentMode
        self.cropRect = cropRect
        self.rotationDegrees = rotationDegrees
        self.isInverted = isInverted
    }
}

struct QRCodeElement: Identifiable, Codable, Equatable {
    var id: UUID
    var frame: PrintElementFrame
    var text: String
    var errorCorrection: QRCodeErrorCorrection
    var rotationDegrees: Double

    init(
        id: UUID = UUID(),
        frame: PrintElementFrame,
        text: String = "https://example.com",
        errorCorrection: QRCodeErrorCorrection = .m,
        rotationDegrees: Double = 0
    ) {
        self.id = id
        self.frame = frame
        self.text = text
        self.errorCorrection = errorCorrection
        self.rotationDegrees = rotationDegrees
    }
}

enum QRCodeErrorCorrection: String, CaseIterable, Codable, Identifiable {
    case l = "L"
    case m = "M"
    case q = "Q"
    case h = "H"

    var id: String { rawValue }
    var title: String { rawValue }
}

enum PrintTextAlignment: String, CaseIterable, Codable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading:
            return "Left"
        case .center:
            return "Center"
        case .trailing:
            return "Right"
        }
    }
}

enum PrintInk: String, CaseIterable, Codable, Identifiable {
    case black
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black:
            return "Black"
        case .white:
            return "White"
        }
    }
}

enum PrintImageContentMode: String, CaseIterable, Codable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit:
            return "Fit"
        case .fill:
            return "Fill"
        }
    }
}
