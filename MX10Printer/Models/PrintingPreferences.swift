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

    init(
        ditheringMode: DitheringMode = .floydSteinberg,
        threshold: UInt8 = 128,
        defaultFeedAfterPrint: UInt16 = 16
    ) {
        self.ditheringMode = ditheringMode
        self.threshold = threshold
        self.defaultFeedAfterPrint = defaultFeedAfterPrint
    }
}
