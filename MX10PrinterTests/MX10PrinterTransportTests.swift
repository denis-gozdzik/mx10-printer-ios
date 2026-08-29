import XCTest
@testable import MX10Printer

@MainActor
final class MX10PrinterTransportTests: XCTestCase {
    func testPrinterResumesAfterPeripheralReady() async throws {
        let transport = MockFrameTransport()
        transport.waitOnFirstSend = true
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )
        let job = makeJob(rowCount: 2)
        var progressEvents: [PrintJobProgress] = []

        let task = Task {
            try await printer.print(job: job) { progress in
                progressEvents.append(progress)
            }
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(transport.didBackpressure)
        XCTAssertTrue(transport.sentFrames.isEmpty)

        transport.markPeripheralReady()
        try await task.value

        XCTAssertEqual(transport.sentFrames.count, 2)
        XCTAssertEqual(transport.transportState, .completed)
        XCTAssertEqual(progressEvents.last?.activity, .completed)
        XCTAssertEqual(progressEvents.last?.currentRow, 2)
    }

    func testPrinterRejectsPacketLargerThanMaximumWriteLength() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )

        do {
            try await printer.print(job: makeJob(rowCount: 1)) { _ in }
            XCTFail("Expected max write length failure")
        } catch let error as MX10PrinterError {
            XCTAssertEqual(
                error.localizedDescription,
                MX10PrinterError.packetTooLarge(packetSize: 56, maximum: 20).localizedDescription
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(transport.sentFrames.isEmpty)
        XCTAssertEqual(transport.transportState, .failed)
    }

    func testPrinterSendsRowsBeforeFeedAndReportsBytes() async throws {
        let transport = MockFrameTransport()
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )
        let job = PrintJob(
            documentID: UUID(),
            rows: [
                Data(repeating: 0x00, count: BitmapRasterizer.rowByteCount),
                Data(repeating: 0xFF, count: BitmapRasterizer.rowByteCount)
            ],
            feedAfterPrintSteps: 16
        )
        var progressEvents: [PrintJobProgress] = []

        try await printer.print(job: job) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(transport.sentFrames.map { $0.context.kind }, [.bitmapRow, .bitmapRow, .feed])
        XCTAssertEqual(transport.sentFrames.map { $0.frame[2] }, [0xA2, 0xA2, 0xA1])
        XCTAssertEqual(progressEvents.last?.bytesSent, 56 + 56 + 10)
    }

    private func makeJob(rowCount: Int) -> PrintJob {
        PrintJob(
            documentID: UUID(),
            rows: (0..<rowCount).map { _ in
                Data(repeating: 0xFF, count: BitmapRasterizer.rowByteCount)
            }
        )
    }

    private func makeLogger() -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: 100,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}

private final class MockFrameTransport: PrintFrameTransport {
    var canSendPrintData = true
    var maxWriteWithoutResponseLength: Int? = 512
    var isReadyForWriteWithoutResponse = true
    var transportState: PrinterTransportState = .idle
    var onTransportActivity: ((PrintJobProgressActivity) -> Void)?
    var waitOnFirstSend = false
    private(set) var didBackpressure = false
    private(set) var sentFrames: [(frame: Data, context: PrintPacketContext)] = []

    private var readinessContinuation: CheckedContinuation<Void, Never>?

    func beginPrintTransport(
        jobID: UUID,
        totalRows: Int,
        configuration: PrinterTransportConfiguration
    ) {
        transportState = .preparing
    }

    func sendFrame(_ frame: Data, context: PrintPacketContext) async throws {
        if let maximum = maxWriteWithoutResponseLength, frame.count > maximum {
            transportState = .failed
            throw PrintTransportError.packetExceedsMaximumWriteLength(packetSize: frame.count, maximum: maximum)
        }

        if waitOnFirstSend {
            waitOnFirstSend = false
            didBackpressure = true
            isReadyForWriteWithoutResponse = false
            transportState = .waitingForPeripheralReady
            await withCheckedContinuation { continuation in
                readinessContinuation = continuation
            }
        }

        transportState = .sending
        sentFrames.append((frame, context))
    }

    func completePrintTransport(jobID: UUID) {
        transportState = .completed
    }

    func failPrintTransport(jobID: UUID?, reason: String) {
        transportState = .failed
    }

    func cancelActiveTransport() {
        transportState = .cancelled
        readinessContinuation?.resume()
        readinessContinuation = nil
    }

    func markPeripheralReady() {
        isReadyForWriteWithoutResponse = true
        onTransportActivity?(.peripheralReady)
        readinessContinuation?.resume()
        readinessContinuation = nil
    }
}
