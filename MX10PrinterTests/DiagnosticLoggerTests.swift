import XCTest
@testable import MX10Printer

@MainActor
final class DiagnosticLoggerTests: XCTestCase {
    func testBackgroundLogDoesNotSynchronouslyWaitForMainThread() async throws {
        let logger = makeLogger(maxEntries: 10)
        let didReturn = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            logger.log(.app, "background nonblocking")
            didReturn.signal()
        }

        let result = didReturn.wait(timeout: .now() + 0.2)
        guard case .success = result else {
            XCTFail("Background log call waited for the main thread")
            return
        }

        try await waitUntil {
            logger.entries.contains { $0.message == "background nonblocking" }
        }
    }

    func testThousandLogCallsDoNotCauseThousandFileWrites() async throws {
        let writer = RecordingPersistenceWriter()
        let logger = makeLogger(
            maxEntries: 2_000,
            persistenceDebounceInterval: 0.01,
            persistenceWriter: writer.write(data:to:)
        )

        for index in 0..<1_000 {
            logger.log(.app, "entry \(index)")
        }

        try await waitUntil {
            writer.writeCount > 0
        }

        XCTAssertLessThan(writer.writeCount, 1_000)
    }

    func testLoggerKeepsBoundedRingBuffer() {
        let logger = makeLogger(maxEntries: 5_000)

        for index in 0..<6_000 {
            logger.log(.app, "entry \(index)")
        }

        XCTAssertEqual(logger.entries.count, 5_000)
        XCTAssertEqual(logger.entries.first?.message, "entry 1000")
        XCTAssertEqual(logger.entries.last?.message, "entry 5999")
    }

    func testFinalPersistContainsLatestEntries() async throws {
        let writer = RecordingPersistenceWriter()
        let logger = makeLogger(
            maxEntries: 5,
            persistenceDebounceInterval: 0.01,
            persistenceWriter: writer.write(data:to:)
        )

        for index in 0..<7 {
            logger.log(.queue, "entry \(index)")
        }

        try await waitUntil {
            writer.latestText.contains("entry 6")
        }

        XCTAssertFalse(writer.latestText.contains("entry 0"))
        XCTAssertFalse(writer.latestText.contains("entry 1"))
        XCTAssertTrue(writer.latestText.contains("entry 2"))
        XCTAssertTrue(writer.latestText.contains("entry 6"))
    }

    func testLogExportIncludesHeaderAndEntries() {
        let logger = makeLogger(maxEntries: 10)
        logger.log(.app, "Print button tapped", metadata: ["document": "ABC"])
        logger.log(.ble, "write attempt", metadata: ["packetBytes": 56])

        let export = logger.exportText(
            context: DiagnosticLogExportContext(
                appVersion: "1.0.0",
                buildNumber: "7",
                iosVersion: "18.0",
                deviceModel: "iPhone",
                printerPeripheralUUID: "PRINTER-UUID",
                bluetoothState: "On",
                printerConnectionState: "Connected",
                advertisedService: "AF30",
                protocolService: "AE30",
                writeCharacteristic: "AE01",
                notifyCharacteristic: "AE02",
                ditheringMode: "threshold",
                threshold: "128",
                currentPrintJobState: "sending"
            )
        )

        XCTAssertTrue(export.contains("App version: 1.0.0"))
        XCTAssertTrue(export.contains("Build number: 7"))
        XCTAssertTrue(export.contains("Printer peripheral UUID: PRINTER-UUID"))
        XCTAssertTrue(export.contains("Advertised service: AF30"))
        XCTAssertTrue(export.contains("[APP] Print button tapped document=ABC"))
        XCTAssertTrue(export.contains("[BLE] write attempt packetBytes=56"))
    }

    func testLoggerRedactsSensitiveMetadataByKey() {
        let logger = makeLogger(maxEntries: 10)

        logger.log(.app, "secret test", metadata: ["github_pat": "plain-token", "safe": "value"])

        XCTAssertEqual(logger.entries.first?.metadata["github_pat"], "[REDACTED]")
        XCTAssertEqual(logger.entries.first?.metadata["safe"], "value")
    }

    private func makeLogger(
        maxEntries: Int,
        persistenceDebounceInterval: TimeInterval = 1,
        persistenceWriter: @escaping DiagnosticLogger.PersistenceWriter = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: maxEntries,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt"),
            persistenceDebounceInterval: persistenceDebounceInterval,
            persistenceWriter: persistenceWriter
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for diagnostic logger")
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class RecordingPersistenceWriter {
    private let lock = NSLock()
    private var storedWriteCount = 0
    private var storedLatestText = ""

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }

        return storedWriteCount
    }

    var latestText: String {
        lock.lock()
        defer { lock.unlock() }

        return storedLatestText
    }

    func write(data: Data, to url: URL) throws {
        let text = String(data: data, encoding: .utf8) ?? ""

        lock.lock()
        storedWriteCount += 1
        storedLatestText = text
        lock.unlock()

        try data.write(to: url, options: [.atomic])
    }
}
