import XCTest
@testable import MX10Printer

@MainActor
final class MX10PrinterTransportTests: XCTestCase {
    func testPrinterResumesAtSecondChunkAfterBackpressure() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        transport.waitBeforeChunkIndexes = [1]
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )
        let job = makeJob(rowCount: 1)
        var progressEvents: [PrintJobProgress] = []

        let task = Task {
            try await printer.print(job: job) { progress in
                progressEvents.append(progress)
            }
        }

        try await waitUntil {
            transport.didBackpressure
        }
        XCTAssertTrue(transport.didBackpressure)
        XCTAssertEqual(transport.sentChunks.map { $0.chunk.index }, [0])

        transport.markPeripheralReady()
        try await task.value

        XCTAssertEqual(transport.sentFrames.count, 1)
        XCTAssertEqual(transport.sentChunks.map { $0.chunk.index }, [0, 1, 2])
        XCTAssertEqual(transport.transportState, .completed)
        XCTAssertEqual(progressEvents.last?.activity, .completed)
        XCTAssertEqual(progressEvents.last?.currentRow, 1)
    }

    func testPrinterFragmentsPacketLargerThanMaximumWriteLength() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )

        try await printer.print(job: makeJob(rowCount: 1)) { _ in }

        XCTAssertEqual(transport.sentFrames.count, 1)
        XCTAssertEqual(transport.sentChunks.map { $0.chunk.data.count }, [20, 20, 16])
        XCTAssertEqual(transport.transportState, .completed)
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

    func testCancellationBetweenChunksStopsRemainingChunks() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        transport.cancelBeforeChunkIndexes = [1]
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )

        do {
            try await printer.print(job: makeJob(rowCount: 1)) { _ in }
            XCTFail("Expected cancellation")
        } catch let error as PrintTransportError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.sentChunks.map { $0.chunk.index }, [0])
        XCTAssertEqual(transport.transportState, .cancelled)
    }

    func testDisconnectBetweenChunksFailsJobCleanly() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        transport.disconnectBeforeChunkIndexes = [1]
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )

        do {
            try await printer.print(job: makeJob(rowCount: 1)) { _ in }
            XCTFail("Expected disconnect")
        } catch let error as PrintTransportError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(transport.sentChunks.map { $0.chunk.index }, [0])
        XCTAssertEqual(transport.transportState, .failed)
    }

    func testRowProgressWaitsForFinalChunkAndRowsStaySequential() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        var events: [String] = []
        transport.onChunkSent = { chunk, context in
            events.append("chunk-\(context.rowIndex ?? -1)-\(chunk.index)")
        }
        let printer = MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
        )

        try await printer.print(job: makeJob(rowCount: 2)) { progress in
            if progress.activity == .rowSent {
                events.append("rowSent-\(progress.currentRow)")
            }
        }

        XCTAssertEqual(
            events,
            [
                "chunk-0-0",
                "chunk-0-1",
                "chunk-0-2",
                "rowSent-1",
                "chunk-1-0",
                "chunk-1-1",
                "chunk-1-2",
                "rowSent-2"
            ]
        )
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

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class MockFrameTransport: PrintFrameTransport {
    var canSendPrintData = true
    var maxWriteWithoutResponseLength: Int? = 512
    var isReadyForWriteWithoutResponse = true
    var transportState: PrinterTransportState = .idle
    var onTransportActivity: ((PrintJobProgressActivity) -> Void)?
    var waitBeforeChunkIndexes: Set<Int> = []
    var cancelBeforeChunkIndexes: Set<Int> = []
    var disconnectBeforeChunkIndexes: Set<Int> = []
    var onChunkSent: ((PrintFrameChunk, PrintPacketContext) -> Void)?
    private(set) var didBackpressure = false
    private(set) var sentFrames: [(frame: Data, context: PrintPacketContext)] = []
    private(set) var sentChunks: [(chunk: PrintFrameChunk, context: PrintPacketContext)] = []

    private var readinessContinuation: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private var disconnected = false

    func beginPrintTransport(
        jobID: UUID,
        totalRows: Int,
        configuration: PrinterTransportConfiguration
    ) {
        transportState = .preparing
        cancelled = false
        disconnected = false
    }

    func sendFrame(_ frame: Data, context: PrintPacketContext) async throws {
        let maximum = maxWriteWithoutResponseLength ?? frame.count
        let chunks = try PrintFrameFragmenter.chunks(for: frame, maximumLength: maximum)

        for chunk in chunks {
            if cancelled {
                throw PrintTransportError.cancelled
            }

            if disconnected {
                transportState = .failed
                throw PrintTransportError.disconnected
            }

            if cancelBeforeChunkIndexes.contains(chunk.index) {
                cancelActiveTransport()
                throw PrintTransportError.cancelled
            }

            if disconnectBeforeChunkIndexes.contains(chunk.index) {
                disconnected = true
                transportState = .failed
                throw PrintTransportError.disconnected
            }

            if waitBeforeChunkIndexes.remove(chunk.index) != nil {
                didBackpressure = true
                isReadyForWriteWithoutResponse = false
                transportState = .waitingForPeripheralReady
                await withCheckedContinuation { continuation in
                    readinessContinuation = continuation
                }
            }

            if cancelled {
                throw PrintTransportError.cancelled
            }

            if disconnected {
                transportState = .failed
                throw PrintTransportError.disconnected
            }

            transportState = .sending
            sentChunks.append((chunk, context))
            onChunkSent?(chunk, context)
        }

        sentFrames.append((frame, context))
    }

    func completePrintTransport(jobID: UUID) {
        transportState = .completed
    }

    func failPrintTransport(jobID: UUID?, reason: String) {
        transportState = .failed
    }

    func cancelActiveTransport() {
        cancelled = true
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
