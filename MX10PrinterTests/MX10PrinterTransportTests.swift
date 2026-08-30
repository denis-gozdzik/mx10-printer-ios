import XCTest
@testable import MX10Printer

@MainActor
final class MX10PrinterTransportTests: XCTestCase {
    func testPrinterUsesFreshMaximumWriteLengthAfterInitialTwenty() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        transport.maximumWriteReadings = [245, 245]
        let printer = makePrinter(transport: transport)

        try await printer.print(job: makeJob(rowCount: 1)) { _ in }

        XCTAssertEqual(transport.beginMaximumObservations.first?.cached, 20)
        XCTAssertEqual(transport.beginMaximumObservations.first?.current, 245)
        XCTAssertEqual(transport.writeMaximumObservations.first?.current, 245)
        XCTAssertEqual(transport.sentFrames.filter { $0.frame[2] == 0xA2 }.count, 1)
        XCTAssertEqual(transport.sentFrames.first { $0.frame[2] == 0xA2 }?.frame.count, 56)
    }

    func testFiftySixByteA2FrameIsAcceptedWhenFreshMaximumIsTwoFortyFive() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        transport.maximumWriteReadings = [245, 245]
        let printer = makePrinter(transport: transport)

        try await printer.print(job: makeJob(rowCount: 1)) { _ in }

        let rowFrames = transport.sentFrames.filter { $0.frame[2] == 0xA2 }

        XCTAssertEqual(rowFrames.map { $0.frame.count }, [56])
        XCTAssertEqual(rowFrames.map { $0.frame[2] }, [0xA2])
        XCTAssertEqual(transport.transportState, .completed)
    }

    func testFiftySixByteA2FrameIsNotBlindlyFragmentedWhenFreshMaximumIsTooSmall() async throws {
        let transport = MockFrameTransport()
        transport.maxWriteWithoutResponseLength = 20
        transport.maximumWriteReadings = [20, 20]
        let printer = makePrinter(transport: transport)

        do {
            try await printer.print(job: makeJob(rowCount: 1)) { _ in }
            XCTFail("Expected max write length failure")
        } catch let error as PrintTransportError {
            XCTAssertEqual(
                error,
                .maximumWriteLengthTooSmall(frameBytes: 56, currentMaximum: 20, cachedMaximum: 20)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(transport.sentFrames.allSatisfy { $0.frame[2] != 0xA2 })
        XCTAssertEqual(transport.transportState, .failed)
    }

    func testPrinterProgressMovesFromRowOneThroughRowN() async throws {
        let transport = MockFrameTransport()
        transport.maximumWriteReadings = Array(repeating: 245, count: 5)
        let printer = makePrinter(transport: transport)
        var rowProgress: [Int] = []

        try await printer.print(job: makeJob(rowCount: 4)) { progress in
            if progress.activity == .rowSent {
                rowProgress.append(progress.currentRow)
            }
        }

        XCTAssertEqual(rowProgress, [1, 2, 3, 4])
        XCTAssertEqual(transport.sentFrames.filter { $0.frame[2] == 0xA2 }.count, 4)
    }

    func testBackpressureResumesSameRowWithoutDuplication() async throws {
        let transport = MockFrameTransport()
        transport.maximumWriteReadings = [245, 245, 245]
        transport.waitBeforeFrameIndexes = [6]
        let printer = makePrinter(transport: transport)
        let job = makeJob(rowCount: 2)

        let task = Task {
            try await printer.print(job: job) { _ in }
        }

        try await waitUntil {
            transport.didBackpressure
        }
        XCTAssertEqual(transport.sentFrames.compactMap { $0.context.rowIndex }, [0])

        transport.markPeripheralReady()
        try await task.value

        XCTAssertEqual(transport.sentFrames.compactMap { $0.context.rowIndex }, [0, 1])
        XCTAssertEqual(transport.transportState, .completed)
    }

    func testManualFeedUsesVerifiedA1Frame() async throws {
        let transport = MockFrameTransport()
        let printer = makePrinter(transport: transport)

        printer.feed(steps: 16)

        try await waitUntil {
            transport.sentFrames.count == 1
        }

        XCTAssertEqual(
            transport.sentFrames.first?.frame,
            Data([0x51, 0x78, 0xA1, 0x00, 0x02, 0x00, 0x10, 0x00, 0x57, 0xFF])
        )
        XCTAssertEqual(transport.sentFrames.first?.context.command, 0xA1)
        XCTAssertEqual(transport.sentFrames.first?.context.kind, .feed)
    }

    func testPrinterSendsSessionCommandSequenceAndReportsBytes() async throws {
        let transport = MockFrameTransport()
        let printer = makePrinter(transport: transport)
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

        XCTAssertEqual(transport.sentFrames.map { $0.frame[2] }, [
            0xA3, 0xA4, 0xAF, 0xBE, 0xA6,
            0xA2, 0xA2,
            0xBD, 0xA1, 0xA6, 0xA3
        ])
        XCTAssertEqual(transport.sentFrames.filter { $0.frame[2] == 0xA2 }.count, 2)
        XCTAssertEqual(progressEvents.last?.bytesSent, 215)
    }

    func testPrintCompletionOccursOnlyAfterCompleteSessionSequence() async throws {
        let transport = MockFrameTransport()
        let printer = makePrinter(transport: transport)

        try await printer.print(job: makeJob(rowCount: 3)) { _ in }

        XCTAssertEqual(transport.sentFrames.map { $0.frame[2] }, [
            0xA3, 0xA4, 0xAF, 0xBE, 0xA6,
            0xA2, 0xA2, 0xA2,
            0xBD, 0xA1, 0xA6, 0xA3
        ])
        XCTAssertEqual(transport.sentFrames.filter { $0.frame[2] == 0xA2 }.count, 3)
        XCTAssertEqual(transport.completedAfterFrameCount, transport.sentFrames.count)
        XCTAssertEqual(transport.completedAfterFrameCount, 12)
    }

    func testPrintTestPatternUsesCompleteSessionSequence() async throws {
        let transport = MockFrameTransport()
        let printer = makePrinter(transport: transport)
        let rowCount = BitmapEncoder.testRows().count

        printer.printTestPattern()

        try await waitUntil {
            transport.completedAfterFrameCount != nil
        }

        XCTAssertEqual(transport.sentFrames.map { $0.frame[2] }, expectedSessionCommands(rowCount: rowCount))
        XCTAssertEqual(transport.sentFrames.filter { $0.frame[2] == 0xA2 }.count, rowCount)
        XCTAssertEqual(transport.completedAfterFrameCount, transport.sentFrames.count)
    }

    func testBitmapRowDiagnosticsAreMarkedForFirstLastAndEveryFiftiethRow() {
        let totalRows = 640

        let loggedRows = (0..<totalRows)
            .map { PrintPacketContext.bitmapRow(jobID: UUID(), rowIndex: $0, totalRows: totalRows) }
            .enumerated()
            .filter { $0.element.shouldLogFrame }
            .map { $0.offset + 1 }

        XCTAssertTrue([1, 2, 3].allSatisfy(loggedRows.contains))
        XCTAssertTrue([638, 639, 640].allSatisfy(loggedRows.contains))
        XCTAssertTrue([50, 100, 150, 600].allSatisfy(loggedRows.contains))
        XCTAssertFalse(loggedRows.contains(4))
        XCTAssertFalse(loggedRows.contains(49))
        XCTAssertFalse(loggedRows.contains(51))
        XCTAssertFalse(
            PrintPacketContext.bitmapRow(jobID: UUID(), rowIndex: 49, totalRows: totalRows).shouldLogFullHex
        )
        XCTAssertTrue(
            PrintPacketContext.bitmapRow(jobID: UUID(), rowIndex: 639, totalRows: totalRows).shouldLogFullHex
        )
    }

    private func makePrinter(transport: MockFrameTransport) -> MX10Printer {
        MX10Printer(
            transport: transport,
            configuration: MX10PrintConfiguration(
                transport: PrinterTransportConfiguration(interPacketDelayNanoseconds: 0)
            ),
            logger: makeLogger()
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

    private func expectedSessionCommands(rowCount: Int) -> [UInt8] {
        [0xA3, 0xA4, 0xAF, 0xBE, 0xA6]
            + Array(repeating: 0xA2, count: rowCount)
            + [0xBD, 0xA1, 0xA6, 0xA3]
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
    var currentMaximumWriteWithoutResponse: Int?
    var isReadyForWriteWithoutResponse = true
    var transportState: PrinterTransportState = .idle
    var onTransportActivity: ((PrintJobProgressActivity) -> Void)?
    var maximumWriteReadings: [Int] = []
    var waitBeforeFrameIndexes: Set<Int> = []
    private(set) var didBackpressure = false
    private(set) var sentFrames: [(frame: Data, context: PrintPacketContext)] = []
    private(set) var beginMaximumObservations: [(cached: Int?, current: Int)] = []
    private(set) var writeMaximumObservations: [(cached: Int?, current: Int, frameBytes: Int)] = []
    private(set) var completedAfterFrameCount: Int?

    private var readinessContinuation: CheckedContinuation<Void, Never>?
    private var frameIndex = 0
    private var cancelled = false

    func beginPrintTransport(
        jobID: UUID,
        totalRows: Int,
        configuration: PrinterTransportConfiguration
    ) {
        cancelled = false
        transportState = .preparing
        let cached = maxWriteWithoutResponseLength
        let current = readFreshMaximum(defaultValue: cached ?? 512)
        beginMaximumObservations.append((cached: cached, current: current))
    }

    func sendFrame(_ frame: Data, context: PrintPacketContext) async throws {
        if cancelled {
            throw PrintTransportError.cancelled
        }

        let cached = maxWriteWithoutResponseLength
        let current = readFreshMaximum(defaultValue: frame.count)
        writeMaximumObservations.append((cached: cached, current: current, frameBytes: frame.count))

        guard current > 0 else {
            transportState = .failed
            throw PrintTransportError.invalidMaximumWriteLength(current)
        }

        guard frame.count <= current else {
            transportState = .failed
            throw PrintTransportError.maximumWriteLengthTooSmall(
                frameBytes: frame.count,
                currentMaximum: current,
                cachedMaximum: cached
            )
        }

        let currentFrameIndex = frameIndex
        frameIndex += 1

        if waitBeforeFrameIndexes.remove(currentFrameIndex) != nil {
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

        transportState = .sending
        sentFrames.append((frame, context))
    }

    func completePrintTransport(jobID: UUID) {
        completedAfterFrameCount = sentFrames.count
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
        readinessContinuation?.resume()
        readinessContinuation = nil
    }

    private func readFreshMaximum(defaultValue: Int) -> Int {
        let current: Int
        if maximumWriteReadings.isEmpty {
            current = currentMaximumWriteWithoutResponse ?? maxWriteWithoutResponseLength ?? defaultValue
        } else {
            current = maximumWriteReadings.removeFirst()
        }

        currentMaximumWriteWithoutResponse = current
        maxWriteWithoutResponseLength = current
        return current
    }
}
