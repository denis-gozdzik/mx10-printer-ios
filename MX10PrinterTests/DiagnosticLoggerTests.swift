import XCTest
@testable import MX10Printer

@MainActor
final class DiagnosticLoggerTests: XCTestCase {
    func testLoggerKeepsBoundedRingBuffer() {
        let logger = makeLogger(maxEntries: 3)

        logger.log(.app, "one")
        logger.log(.ble, "two")
        logger.log(.queue, "three")
        logger.log(.printer, "four")

        XCTAssertEqual(logger.entries.count, 3)
        XCTAssertEqual(logger.entries.map(\.message), ["two", "three", "four"])
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

    private func makeLogger(maxEntries: Int) -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: maxEntries,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}
