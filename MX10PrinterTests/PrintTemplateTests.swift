import UIKit
import XCTest
@testable import MX10Printer

@MainActor
final class PrintTemplateTests: XCTestCase {
    func testThereAreExactlyEightTemplates() {
        XCTAssertEqual(PrintTemplateKind.allCases.count, 8)
    }

    func testEveryTemplateCreatesNonEmptyDocument() {
        for kind in PrintTemplateKind.allCases {
            let document = kind.makeDocument()

            XCTAssertFalse(document.title.isEmpty, kind.rawValue)
            XCTAssertFalse(document.firstPage.elements.isEmpty, kind.rawValue)
        }
    }

    func testEveryGeneratedDocumentHasExactlyOnePage() {
        for kind in PrintTemplateKind.allCases {
            XCTAssertEqual(kind.makeDocument().pages.count, 1, kind.rawValue)
        }
    }

    func testEveryElementFrameFitsHorizontally() {
        for kind in PrintTemplateKind.allCases {
            for element in kind.makeDocument().firstPage.elements {
                XCTAssertGreaterThanOrEqual(element.frame.x, 0, kind.rawValue)
                XCTAssertGreaterThan(element.frame.width, 0, kind.rawValue)
                XCTAssertLessThanOrEqual(element.frame.x + element.frame.width, PrintDocument.pageWidth, kind.rawValue)
            }
        }
    }

    func testAllElementYPositionsAreNonNegative() {
        for kind in PrintTemplateKind.allCases {
            for element in kind.makeDocument().firstPage.elements {
                XCTAssertGreaterThanOrEqual(element.frame.y, 0, kind.rawValue)
            }
        }
    }

    func testEveryTemplateContainsAtLeastOneTextElement() {
        for kind in PrintTemplateKind.allCases {
            XCTAssertFalse(textElements(in: kind.makeDocument()).isEmpty, kind.rawValue)
        }
    }

    func testEveryTemplateContainsAtLeastOneStickerElement() {
        for kind in PrintTemplateKind.allCases {
            XCTAssertFalse(stickerElements(in: kind.makeDocument()).isEmpty, kind.rawValue)
        }
    }

    func testEveryStickerUsesExistingValidStickerKind() {
        let validKinds = Set(StickerKind.allCases)

        for kind in PrintTemplateKind.allCases {
            for sticker in stickerElements(in: kind.makeDocument()) {
                XCTAssertTrue(validKinds.contains(sticker.kind), "\(kind.rawValue) \(sticker.kind.rawValue)")
            }
        }
    }

    func testAllDefaultTemplateTextIsNonEmpty() {
        for kind in PrintTemplateKind.allCases {
            for text in textElements(in: kind.makeDocument()) {
                XCTAssertFalse(text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, kind.rawValue)
            }
        }
    }

    func testTemplatesUseBlackInkAndZeroRotation() {
        for kind in PrintTemplateKind.allCases {
            for element in kind.makeDocument().firstPage.elements {
                XCTAssertEqual(element.rotationDegrees, 0, kind.rawValue)

                if case .text(let text) = element {
                    XCTAssertEqual(text.ink, .black, kind.rawValue)
                }
            }
        }
    }

    func testTemplateFramesDoNotOverlap() {
        for kind in PrintTemplateKind.allCases {
            let frames = kind.makeDocument().firstPage.elements.map(\.frame)

            for leftIndex in frames.indices {
                for rightIndex in frames.indices where rightIndex > leftIndex {
                    XCTAssertFalse(frames[leftIndex].overlaps(frames[rightIndex]), "\(kind.rawValue) \(leftIndex) \(rightIndex)")
                }
            }
        }
    }

    func testRepeatedTemplateCreationUsesFreshDocumentPageAndElementIDs() {
        for kind in PrintTemplateKind.allCases {
            let first = kind.makeDocument()
            let second = kind.makeDocument()

            XCTAssertNotEqual(first.id, second.id, kind.rawValue)
            XCTAssertNotEqual(first.firstPage.id, second.firstPage.id, kind.rawValue)
            XCTAssertTrue(Set(first.firstPage.elements.map(\.id)).isDisjoint(with: Set(second.firstPage.elements.map(\.id))), kind.rawValue)
        }
    }

    func testDocumentsFromTemplatesSurviveCodableRoundtrip() throws {
        for kind in PrintTemplateKind.allCases {
            let document = kind.makeDocument()
            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(PrintDocument.self, from: data)

            XCTAssertEqual(decoded, document, kind.rawValue)
        }
    }

    func testCodableRoundtripPreservesTemplateElementDetails() throws {
        for kind in PrintTemplateKind.allCases {
            let document = kind.makeDocument()
            let decoded = try JSONDecoder().decode(PrintDocument.self, from: JSONEncoder().encode(document))

            XCTAssertEqual(decoded.firstPage.elements.count, document.firstPage.elements.count, kind.rawValue)
            for (decodedElement, originalElement) in zip(decoded.firstPage.elements, document.firstPage.elements) {
                XCTAssertEqual(decodedElement.frame, originalElement.frame, kind.rawValue)
                switch (decodedElement, originalElement) {
                case (.text(let decodedText), .text(let originalText)):
                    XCTAssertEqual(decodedText.text, originalText.text, kind.rawValue)
                case (.sticker(let decodedSticker), .sticker(let originalSticker)):
                    XCTAssertEqual(decodedSticker.kind, originalSticker.kind, kind.rawValue)
                default:
                    XCTFail("Element type changed during roundtrip for \(kind.rawValue)")
                }
            }
        }
    }

    func testEachTemplateCanBeRendered() {
        for kind in PrintTemplateKind.allCases {
            let image = PageRenderer(logger: makeLogger()).render(document: kind.makeDocument())

            XCTAssertEqual(image.width, Int(PrintDocument.pageWidth), kind.rawValue)
            XCTAssertEqual(image.height, Int(PrintDocument.defaultPageHeight), kind.rawValue)
        }
    }

    func testEachTemplateCreatesVisibleRasterContent() throws {
        for kind in PrintTemplateKind.allCases {
            let preview = try makePreview(for: kind)

            XCTAssertTrue(preview.rasterRows.contains { row in
                row.contains { $0 != 0 }
            }, kind.rawValue)
        }
    }

    func testEachTemplateCanBuildPrintJob() throws {
        for kind in PrintTemplateKind.allCases {
            let document = kind.makeDocument()
            let builder = PrintJobBuilder(logger: makeLogger())

            let job = try builder.makeJob(document: document, preferences: preferences)

            XCTAssertEqual(job.documentID, document.id, kind.rawValue)
            XCTAssertFalse(job.rows.isEmpty, kind.rawValue)
        }
    }

    func testSmartTrimmingOccursNaturallyForEveryTemplate() throws {
        for kind in PrintTemplateKind.allCases {
            let document = kind.makeDocument()
            let builder = PrintJobBuilder(logger: makeLogger())
            let preview = try builder.makePreview(document: document, preferences: preferences)
            let job = builder.makeJob(document: document, preview: preview, preferences: preferences)

            print("TEMPLATE_ROWS \(kind.rawValue) preview=\(preview.rasterRows.count) print=\(job.rows.count)")
            XCTAssertLessThan(job.rows.count, preview.rasterRows.count, kind.rawValue)
        }
    }

    func testPreviewRemainsFullPageWhilePrintJobIsTrimmed() throws {
        for kind in PrintTemplateKind.allCases {
            let document = kind.makeDocument()
            let builder = PrintJobBuilder(logger: makeLogger())
            let preview = try builder.makePreview(document: document, preferences: preferences)
            let job = builder.makeJob(document: document, preview: preview, preferences: preferences)

            XCTAssertEqual(preview.rasterRows.count, Int(PrintDocument.defaultPageHeight), kind.rawValue)
            XCTAssertLessThan(job.rows.count, preview.rasterRows.count, kind.rawValue)
        }
    }

    func testSameTemplateSelectionCreatesIndependentRecentCandidates() {
        let first = PrintTemplateKind.cat.makeDocument()
        let second = PrintTemplateKind.cat.makeDocument()

        XCTAssertEqual(first.title, second.title)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.firstPage.id, second.firstPage.id)
        XCTAssertTrue(Set(first.firstPage.elements.map(\.id)).isDisjoint(with: Set(second.firstPage.elements.map(\.id))))
    }

    func testTemplateSymbolsAreAvailable() {
        for kind in PrintTemplateKind.allCases {
            XCTAssertNotNil(UIImage(systemName: kind.systemImageName), "\(kind.rawValue) -> \(kind.systemImageName)")
        }
    }

    func testTemplateElementCountsMatchDefinitions() {
        let expectedCounts: [PrintTemplateKind: Int] = [
            .myName: 2,
            .school: 3,
            .forYou: 2,
            .gift: 3,
            .superStar: 3,
            .thankYou: 2,
            .cat: 2,
            .smile: 2
        ]

        for kind in PrintTemplateKind.allCases {
            XCTAssertEqual(kind.makeDocument().firstPage.elements.count, expectedCounts[kind], kind.rawValue)
        }
    }

    private var preferences: PrintingPreferences {
        PrintingPreferences(ditheringMode: .threshold, threshold: 128)
    }

    private func makePreview(for kind: PrintTemplateKind) throws -> PrintPreview {
        try PrintJobBuilder(logger: makeLogger()).makePreview(
            document: kind.makeDocument(),
            preferences: preferences
        )
    }

    private func textElements(in document: PrintDocument) -> [TextElement] {
        document.firstPage.elements.compactMap { element in
            guard case .text(let text) = element else {
                return nil
            }

            return text
        }
    }

    private func stickerElements(in document: PrintDocument) -> [StickerElement] {
        document.firstPage.elements.compactMap { element in
            guard case .sticker(let sticker) = element else {
                return nil
            }

            return sticker
        }
    }

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 200,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}

private extension PrintElementFrame {
    func overlaps(_ other: PrintElementFrame) -> Bool {
        max(x, other.x) < min(x + width, other.x + other.width)
            && max(y, other.y) < min(y + height, other.y + other.height)
    }
}
