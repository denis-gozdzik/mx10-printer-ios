import Foundation

enum DitheringMode: String, CaseIterable, Codable, Identifiable {
    case threshold
    case floydSteinberg
    case atkinson

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threshold:
            return "Threshold"
        case .floydSteinberg:
            return "Floyd-Steinberg"
        case .atkinson:
            return "Atkinson"
        }
    }
}

struct PrintingPreferences: Codable, Equatable {
    var ditheringMode: DitheringMode
    var threshold: UInt8
    var defaultFeedAfterPrint: UInt16
    var showFinalRasterPreview: Bool

    init(
        ditheringMode: DitheringMode = .floydSteinberg,
        threshold: UInt8 = 128,
        defaultFeedAfterPrint: UInt16 = 16,
        showFinalRasterPreview: Bool = false
    ) {
        self.ditheringMode = ditheringMode
        self.threshold = threshold
        self.defaultFeedAfterPrint = defaultFeedAfterPrint
        self.showFinalRasterPreview = showFinalRasterPreview
    }

    private enum CodingKeys: String, CodingKey {
        case ditheringMode
        case threshold
        case defaultFeedAfterPrint
        case showFinalRasterPreview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ditheringMode = try container.decodeIfPresent(DitheringMode.self, forKey: .ditheringMode) ?? .floydSteinberg
        threshold = try container.decodeIfPresent(UInt8.self, forKey: .threshold) ?? 128
        defaultFeedAfterPrint = try container.decodeIfPresent(UInt16.self, forKey: .defaultFeedAfterPrint) ?? 16
        showFinalRasterPreview = try container.decodeIfPresent(Bool.self, forKey: .showFinalRasterPreview) ?? false
    }
}
