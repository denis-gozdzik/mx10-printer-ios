import Foundation

enum DiagnosticCategory: String, CaseIterable, Codable, Identifiable {
    case app = "APP"
    case editor = "EDITOR"
    case render = "RENDER"
    case raster = "RASTER"
    case queue = "QUEUE"
    case ble = "BLE"
    case protocolLog = "PROTOCOL"
    case printer = "PRINTER"
    case image = "IMAGE"
    case error = "ERROR"

    var id: String { rawValue }
}

struct DiagnosticLogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    var formattedLine: String {
        var line = "\(Self.timestampFormatter.string(from: timestamp)) [\(category.rawValue)] \(message)"
        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        if !metadataText.isEmpty {
            line += " \(metadataText)"
        }

        return line
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

struct DiagnosticLogExportContext: Equatable {
    var appVersion: String
    var buildNumber: String
    var iosVersion: String
    var deviceModel: String
    var printerPeripheralUUID: String
    var bluetoothState: String
    var printerConnectionState: String
    var advertisedService: String
    var protocolService: String
    var writeCharacteristic: String
    var notifyCharacteristic: String
    var ditheringMode: String
    var threshold: String
    var currentPrintJobState: String

    static let empty = DiagnosticLogExportContext(
        appVersion: "Unknown",
        buildNumber: "Unknown",
        iosVersion: "Unknown",
        deviceModel: "Unknown",
        printerPeripheralUUID: "None",
        bluetoothState: "Unknown",
        printerConnectionState: "Unknown",
        advertisedService: "AF30",
        protocolService: "AE30",
        writeCharacteristic: "AE01",
        notifyCharacteristic: "AE02",
        ditheringMode: "Unknown",
        threshold: "Unknown",
        currentPrintJobState: "idle"
    )
}

final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    @Published private(set) var entries: [DiagnosticLogEntry] = []

    private let maxEntries: Int
    private let storageURL: URL
    private let fileManager: FileManager

    init(
        maxEntries: Int = 5_000,
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.maxEntries = max(1, maxEntries)
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        loadPersistedLog()
    }

    func log(
        _ category: DiagnosticCategory,
        _ message: String,
        metadata: [String: Any] = [:]
    ) {
        let sanitizedMetadata = sanitize(metadata)
        let entry = DiagnosticLogEntry(
            category: category,
            message: sanitize(message),
            metadata: sanitizedMetadata
        )

        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.append(entry)
            }
        }
    }

    func clear() {
        entries.removeAll()
        persistLatestLog()
    }

    func exportText(context: DiagnosticLogExportContext = .empty) -> String {
        var lines: [String] = [
            "MX10Printer Diagnostic Log",
            "App version: \(context.appVersion)",
            "Build number: \(context.buildNumber)",
            "iOS version: \(context.iosVersion)",
            "Device model: \(context.deviceModel)",
            "Printer peripheral UUID: \(context.printerPeripheralUUID)",
            "Bluetooth state: \(context.bluetoothState)",
            "Printer connection state: \(context.printerConnectionState)",
            "Advertised service: \(context.advertisedService)",
            "Protocol service: \(context.protocolService)",
            "Write characteristic: \(context.writeCharacteristic)",
            "Notify characteristic: \(context.notifyCharacteristic)",
            "Current dithering mode: \(context.ditheringMode)",
            "Current threshold: \(context.threshold)",
            "Current print job state: \(context.currentPrintJobState)",
            "",
            "Log entries:"
        ]

        lines.append(contentsOf: entries.map(\.formattedLine))
        return lines.joined(separator: "\n") + "\n"
    }

    func writeExportFile(context: DiagnosticLogExportContext = .empty) throws -> URL {
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let exportURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("mx10-diagnostic-log.txt")

        try exportText(context: context).data(using: .utf8)?.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    private func append(_ entry: DiagnosticLogEntry) {
        entries.append(entry)

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        persistLatestLog()
    }

    private func persistLatestLog() {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = entries.map(\.formattedLine).joined(separator: "\n").data(using: .utf8) ?? Data()
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist diagnostic log: \(error.localizedDescription)")
        }
    }

    private func loadPersistedLog() {
        guard let data = try? Data(contentsOf: storageURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return
        }

        entries = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxEntries)
            .map { line in
                DiagnosticLogEntry(
                    category: .app,
                    message: String(line),
                    metadata: ["persisted": "true"]
                )
            }
    }

    private func sanitize(_ metadata: [String: Any]) -> [String: String] {
        metadata.reduce(into: [:]) { result, item in
            result[item.key] = shouldRedact(key: item.key) ? "[REDACTED]" : sanitize(String(describing: item.value))
        }
    }

    private func sanitize(_ value: String) -> String {
        var sanitized = value.replacingOccurrences(of: "\n", with: "\\n")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: "\\r")
        return sanitized
    }

    private func shouldRedact(key: String) -> Bool {
        let lowercased = key.lowercased()
        return [
            "api_key",
            "apikey",
            "authorization",
            "certificate",
            "cert",
            "fastlane_key",
            "github_pat",
            "match_password",
            "password",
            "private",
            "secret",
            "token"
        ].contains { lowercased.contains($0) }
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseURL
            .appendingPathComponent("MX10Printer", isDirectory: true)
            .appendingPathComponent("latest-diagnostic-log.txt")
    }
}
