import Foundation

final class PrintingPreferencesStore: ObservableObject {
    @Published var preferences: PrintingPreferences {
        didSet {
            save()
        }
    }

    private let userDefaults: UserDefaults
    private let logger: DiagnosticLogger
    private let key = "printingPreferences"

    init(userDefaults: UserDefaults = .standard, logger: DiagnosticLogger = .shared) {
        self.userDefaults = userDefaults
        self.logger = logger

        if let data = userDefaults.data(forKey: key),
           let preferences = try? JSONDecoder().decode(PrintingPreferences.self, from: data) {
            self.preferences = preferences
            logLoadedPreferences(source: "persisted", preferences: preferences)
        } else {
            self.preferences = PrintingPreferences()
            logLoadedPreferences(source: "default", preferences: preferences)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }

    private func logLoadedPreferences(source: String, preferences: PrintingPreferences) {
        logger.log(
            .app,
            "printing preferences loaded",
            metadata: [
                "source": source,
                "ditheringMode": preferences.ditheringMode.rawValue,
                "threshold": preferences.threshold,
                "defaultFeedAfterPrint": preferences.defaultFeedAfterPrint,
                "showFinalRasterPreview": preferences.showFinalRasterPreview
            ]
        )
    }
}
