import Foundation

final class PrintDocumentStore: ObservableObject {
    @Published private(set) var recentDocuments: [PrintDocument] = []

    private let fileManager: FileManager
    private let maxRecentDocuments = 12

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        load()
    }

    func makeBlankDocument() -> PrintDocument {
        PrintDocument(title: "New Print")
    }

    func save(_ document: PrintDocument) {
        var updatedDocument = document
        updatedDocument.touch()
        recentDocuments.removeAll { $0.id == updatedDocument.id }
        recentDocuments.insert(updatedDocument, at: 0)
        recentDocuments = Array(recentDocuments.prefix(maxRecentDocuments))
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: documentsURL) else {
            recentDocuments = []
            return
        }

        recentDocuments = (try? JSONDecoder().decode([PrintDocument].self, from: data)) ?? []
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recentDocuments)
            try data.write(to: documentsURL, options: [.atomic])
        } catch {
            print("Failed to persist recent print documents: \(error.localizedDescription)")
        }
    }

    private var storageDirectory: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL.appendingPathComponent("MX10Printer", isDirectory: true)
    }

    private var documentsURL: URL {
        storageDirectory.appendingPathComponent("recent-documents.json")
    }
}
