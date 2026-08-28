import Foundation

final class PrintingPreferencesStore: ObservableObject {
    @Published var preferences: PrintingPreferences {
        didSet {
            save()
        }
    }

    private let userDefaults: UserDefaults
    private let key = "printingPreferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let data = userDefaults.data(forKey: key),
           let preferences = try? JSONDecoder().decode(PrintingPreferences.self, from: data) {
            self.preferences = preferences
        } else {
            self.preferences = PrintingPreferences()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }
}
