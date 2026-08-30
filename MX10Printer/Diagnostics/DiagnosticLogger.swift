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
    let preformattedLine: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        message: String,
        metadata: [String: String] = [:],
        preformattedLine: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.metadata = metadata
        self.preformattedLine = preformattedLine
    }

    var formattedLine: String {
        if let preformattedLine {
            return preformattedLine
        }

        var line = "\(Self.timestampString(from: timestamp)) [\(category.rawValue)] \(message)"
        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        if !metadataText.isEmpty {
            line += " \(metadataText)"
        }

        return line
    }

    private static func timestampString(from date: Date) -> String {
        timestampFormatterLock.lock()
        defer { timestampFormatterLock.unlock() }

        return timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let timestampFormatterLock = NSLock()
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

    typealias PersistenceWriter = (Data, URL) throws -> Void

    private let maxEntries: Int
    private let storageURL: URL
    private let fileManager: FileManager
    private let persistenceDebounceInterval: TimeInterval
    private let persistenceWriter: PersistenceWriter
    private let persistenceQueue = DispatchQueue(label: "pl.mx10printer.diagnostic-log.persistence", qos: .utility)

    private var pendingPersistenceWorkItem: DispatchWorkItem?
    private var hasUnpersistedEntries = false

    init(
        maxEntries: Int = 5_000,
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        persistenceDebounceInterval: TimeInterval = 1,
        persistenceWriter: @escaping PersistenceWriter = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.maxEntries = max(1, maxEntries)
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        self.persistenceDebounceInterval = max(0, persistenceDebounceInterval)
        self.persistenceWriter = persistenceWriter
        loadPersistedLog()
    }

    deinit {
        pendingPersistenceWorkItem?.cancel()
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
            appendOnMain(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendOnMain(entry)
            }
        }
    }

    func clear() {
        if Thread.isMainThread {
            clearOnMain()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.clearOnMain()
            }
        }
    }

    func exportText(context: DiagnosticLogExportContext = .empty) -> String {
        Self.exportText(context: context, entries: entriesSnapshot())
    }

    func writeExportFile(context: DiagnosticLogExportContext = .empty) throws -> URL {
        let snapshot = entriesSnapshot()
        let exportURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("mx10-diagnostic-log.txt")

        try persistenceQueue.sync {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = Self.exportText(context: context, entries: snapshot).data(using: .utf8) ?? Data()
            try persistenceWriter(data, exportURL)
        }

        return exportURL
    }

    private static func exportText(
        context: DiagnosticLogExportContext,
        entries: [DiagnosticLogEntry]
    ) -> String {
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

    private func appendOnMain(_ entry: DiagnosticLogEntry) {
        entries.append(entry)

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        schedulePersistLatestLog()
    }

    private func clearOnMain() {
        pendingPersistenceWorkItem?.cancel()
        pendingPersistenceWorkItem = nil
        hasUnpersistedEntries = false
        entries.removeAll()
        persistSnapshot([])
    }

    private func schedulePersistLatestLog() {
        hasUnpersistedEntries = true

        guard pendingPersistenceWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performScheduledPersist()
        }
        pendingPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + persistenceDebounceInterval,
            execute: workItem
        )
    }

    private func performScheduledPersist() {
        pendingPersistenceWorkItem = nil

        guard hasUnpersistedEntries else {
            return
        }

        hasUnpersistedEntries = false
        persistSnapshot(entries)
    }

    private func persistSnapshot(_ snapshot: [DiagnosticLogEntry]) {
        persistenceQueue.async { [fileManager, storageURL, persistenceWriter] in
            do {
                try fileManager.createDirectory(
                    at: storageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = snapshot.map(\.formattedLine).joined(separator: "\n").data(using: .utf8) ?? Data()
                try persistenceWriter(data, storageURL)
            } catch {
                assertionFailure("Failed to persist diagnostic log: \(error.localizedDescription)")
            }
        }
    }

    private func entriesSnapshot() -> [DiagnosticLogEntry] {
        if Thread.isMainThread {
            return entries
        }

        return DispatchQueue.main.sync {
            entries
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
                    preformattedLine: String(line)
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
