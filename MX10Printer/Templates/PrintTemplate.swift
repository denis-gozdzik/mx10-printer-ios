import Foundation

enum PrintTemplateKind: String, CaseIterable, Identifiable {
    case myName
    case school
    case forYou
    case gift
    case superStar
    case thankYou
    case cat
    case smile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myName:
            return "Moje imię"
        case .school:
            return "Do szkoły"
        case .forYou:
            return "Dla Ciebie"
        case .gift:
            return "Prezent"
        case .superStar:
            return "Super!"
        case .thankYou:
            return "Dziękuję"
        case .cat:
            return "Kotek"
        case .smile:
            return "Uśmiech"
        }
    }

    var subtitle: String {
        switch self {
        case .myName:
            return "Naklejka na zeszyt lub pudełko"
        case .school:
            return "Podpisz swoje rzeczy"
        case .forYou:
            return "Mała wiadomość dla kogoś"
        case .gift:
            return "Etykieta do prezentu"
        case .superStar:
            return "Naklejka pochwała"
        case .thankYou:
            return "Małe podziękowanie"
        case .cat:
            return "Kocia naklejka"
        case .smile:
            return "Po prostu dobry humor"
        }
    }

    var systemImageName: String {
        switch self {
        case .myName:
            return StickerKind.star.symbolName
        case .school:
            return StickerKind.star.symbolName
        case .forYou:
            return StickerKind.heart.symbolName
        case .gift:
            return StickerKind.gift.symbolName
        case .superStar:
            return StickerKind.sparkles.symbolName
        case .thankYou:
            return StickerKind.heart.symbolName
        case .cat:
            return StickerKind.cat.symbolName
        case .smile:
            return StickerKind.smile.symbolName
        }
    }

    func makeDocument() -> PrintDocument {
        PrintDocument(
            title: title,
            pages: [
                PrintPage(
                    height: PrintDocument.defaultPageHeight,
                    elements: elements
                )
            ]
        )
    }

    private var elements: [PrintElement] {
        switch self {
        case .myName:
            return [
                sticker(.star, x: 24, y: 32, width: 72, height: 72),
                text("MOJE IMIĘ", x: 108, y: 28, width: 252, height: 84, fontSize: 34)
            ]
        case .school:
            return [
                sticker(.star, x: 24, y: 38, width: 64, height: 64),
                text("NALEŻY DO:", x: 104, y: 30, width: 256, height: 54, fontSize: 24),
                text("IMIĘ", x: 104, y: 86, width: 256, height: 58, fontSize: 32)
            ]
        case .forYou:
            return [
                sticker(.heart, x: 24, y: 32, width: 88, height: 88),
                text("DLA CIEBIE!", x: 124, y: 38, width: 236, height: 74, fontSize: 32)
            ]
        case .gift:
            return [
                sticker(.gift, x: 24, y: 34, width: 90, height: 90),
                text("PREZENT DLA:", x: 126, y: 30, width: 234, height: 54, fontSize: 24),
                text("IMIĘ", x: 126, y: 84, width: 234, height: 60, fontSize: 30)
            ]
        case .superStar:
            return [
                sticker(.star, x: 28, y: 30, width: 82, height: 82),
                sticker(.sparkles, x: 286, y: 34, width: 66, height: 66),
                text("SUPER!", x: 112, y: 36, width: 172, height: 74, fontSize: 36)
            ]
        case .thankYou:
            return [
                sticker(.heart, x: 24, y: 32, width: 82, height: 82),
                text("DZIĘKUJĘ!", x: 116, y: 38, width: 244, height: 72, fontSize: 30)
            ]
        case .cat:
            return [
                sticker(.cat, x: 32, y: 30, width: 110, height: 110),
                text("MIAU!", x: 158, y: 44, width: 190, height: 72, fontSize: 36)
            ]
        case .smile:
            return [
                sticker(.smile, x: 28, y: 30, width: 100, height: 100),
                text("UŚMIECH!", x: 142, y: 42, width: 214, height: 72, fontSize: 30)
            ]
        }
    }

    private func sticker(
        _ kind: StickerKind,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> PrintElement {
        .sticker(
            StickerElement(
                frame: PrintElementFrame(x: x, y: y, width: width, height: height),
                kind: kind,
                rotationDegrees: 0
            )
        )
    }

    private func text(
        _ value: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        fontSize: Double
    ) -> PrintElement {
        .text(
            TextElement(
                frame: PrintElementFrame(x: x, y: y, width: width, height: height),
                text: value,
                fontSize: fontSize,
                isBold: true,
                alignment: .center,
                ink: .black,
                rotationDegrees: 0
            )
        )
    }
}
