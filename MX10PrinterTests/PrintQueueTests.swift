import Combine
import XCTest
@testable import MX10Printer

@MainActor
final class PrintQueueTests: XCTestCase {
    func testPrintQueueProcessesJobsInEnqueueOrderAndClearsActiveState() async throws {
        let queue = makeQueue()
        let printer = RecordingPrinter()
        let jobs = [
            makeJob(byte: 0x01),
            makeJob(byte: 0x02),
            makeJob(byte: 0x03)
        ]

        for job in jobs {
            queue.enqueue(job, printer: printer)
        }

        try await waitUntil {
            queue.completedJobs.count == jobs.count
        }

        XCTAssertEqual(printer.printedJobIDs, jobs.map(\.id))
        XCTAssertEqual(printer.maxActivePrints, 1)
        XCTAssertEqual(queue.completedJobs.map(\.id), jobs.map(\.id))
        XCTAssertTrue(queue.completedJobs.allSatisfy { $0.lifecycle == .completed })
        XCTAssertTrue(queue.pendingJobs.isEmpty)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testPrintQueueClearsActiveStateAfterTransportError() async throws {
        let queue = makeQueue()
        let printer = FailingPrinter(error: TestPrintError.transport)
        let job = makeJob(byte: 0x10)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.failedJobs.count == 1
        }

        XCTAssertEqual(queue.failedJobs.first?.job.id, job.id)
        XCTAssertTrue(queue.pendingJobs.isEmpty)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testPrintQueueClearsActiveStateAfterTimeout() async throws {
        let queue = makeQueue(
            configuration: PrintQueueConfiguration(
                inactivityTimeout: 0.05,
                timeoutCheckIntervalNanoseconds: 5_000_000
            )
        )
        let printer = HangingPrinter()
        let job = makeJob(byte: 0x20)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.failedJobs.count == 1
        }

        XCTAssertTrue(printer.cancelCalled)
        XCTAssertEqual(queue.failedJobs.first?.job.id, job.id)
        XCTAssertTrue(queue.failedJobs.first?.message.contains("PRINT_TIMEOUT") == true)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testPrintQueueClearsActiveStateAfterDisconnectError() async throws {
        let queue = makeQueue()
        let printer = FailingPrinter(error: PrintTransportError.disconnected)
        let job = makeJob(byte: 0x30)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.failedJobs.count == 1
        }

        XCTAssertEqual(queue.failedJobs.first?.job.id, job.id)
        XCTAssertEqual(queue.failedJobs.first?.job.lifecycle, .failed)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testPrintQueueCancelsCurrentJobAndBecomesUsable() async throws {
        let queue = makeQueue()
        let printer = CancellablePrinter()
        let job = makeJob(byte: 0x40)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.currentJob?.id == job.id
        }

        queue.cancelCurrentJob()

        try await waitUntil {
            queue.cancelledJobs.count == 1
        }

        XCTAssertTrue(printer.cancelCalled)
        XCTAssertEqual(queue.cancelledJobs.first?.id, job.id)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testExternalDisconnectRecoveryFailsCurrentJob() async throws {
        let queue = makeQueue()
        let printer = HangingPrinter()
        let job = makeJob(byte: 0x50)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.currentJob?.id == job.id
        }

        queue.failCurrentJob(reason: "Printer disconnected")

        XCTAssertTrue(printer.cancelCalled)
        XCTAssertEqual(queue.failedJobs.first?.job.id, job.id)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.isPrinting)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testPeripheralReadyActivityDoesNotRewindPrintedRowProgress() async throws {
        let queue = makeQueue()
        let printer = StalePeripheralReadyPrinter()
        let job = PrintJob(
            documentID: UUID(),
            rows: Array(repeating: Data(repeating: 0x60, count: BitmapRasterizer.rowByteCount), count: 3)
        )

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            printer.didSendStalePeripheralReady
        }

        XCTAssertEqual(queue.currentJob?.currentRow, 2)
        XCTAssertEqual(queue.currentStatusText, "Printing 2 / 3")

        printer.finish()

        try await waitUntil {
            queue.completedJobs.count == 1
        }

        XCTAssertEqual(queue.completedJobs.first?.currentRow, 3)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testDuplicatePrintTapCannotEnqueueSecondActiveJob() async throws {
        let queue = makeQueue()
        let printer = CancellablePrinter()
        let firstJob = makeJob(byte: 0x70)
        let duplicateJob = makeJob(byte: 0x71)

        XCTAssertTrue(queue.enqueueIfIdle(firstJob, printer: printer))
        XCTAssertFalse(queue.enqueueIfIdle(duplicateJob, printer: printer))

        try await waitUntil {
            queue.currentJob?.id == firstJob.id
        }

        XCTAssertTrue(queue.pendingJobs.isEmpty)
        XCTAssertEqual(queue.currentJob?.id, firstJob.id)

        queue.cancelCurrentJob()

        try await waitUntil {
            queue.cancelledJobs.count == 1
        }

        XCTAssertEqual(queue.cancelledJobs.first?.id, firstJob.id)
        XCTAssertTrue(queue.completedJobs.isEmpty)
        XCTAssertTrue(queue.failedJobs.isEmpty)
        XCTAssertNil(queue.currentJob)
        XCTAssertFalse(queue.hasActiveOrPendingJob)
    }

    func testSixHundredFortyRowJobReportsFinalProgress() async throws {
        let queue = makeQueue(
            configuration: PrintQueueConfiguration(progressPublishInterval: 60)
        )
        let printer = BurstProgressPrinter()
        let job = makeJob(byte: 0x80, rowCount: 640)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.completedJobs.count == 1
        }

        XCTAssertEqual(queue.completedJobs.first?.currentRow, 640)
        XCTAssertEqual(queue.completedJobs.first?.rowCount, 640)
        XCTAssertEqual(queue.currentStatusText, "Completed")
    }

    func testProgressThrottlingLimitsSwiftUIPublicationAndProgressLogs() async throws {
        let logger = makeLogger(maxEntries: 2_000)
        let queue = PrintQueue(
            configuration: PrintQueueConfiguration(progressPublishInterval: 60),
            logger: logger
        )
        let printer = BurstProgressPrinter()
        let job = makeJob(byte: 0x81, rowCount: 640)
        let publicationCounter = PublicationCounter()
        let cancellable = queue.objectWillChange.sink {
            publicationCounter.increment()
        }

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.completedJobs.count == 1
        }

        let progressLogs = logger.entries.filter { $0.category == .queue && $0.message == "progress" }
        XCTAssertEqual(printer.sentRows, 640)
        XCTAssertLessThan(publicationCounter.count, 80)
        XCTAssertLessThan(progressLogs.count, 80)
        XCTAssertEqual(progressLogs.last?.metadata["row"], "640/640")
        withExtendedLifetime(cancellable) {}
    }

    func testTransportActivityStillPreventsTimeoutWhenProgressPublishingIsThrottled() async throws {
        let queue = makeQueue(
            configuration: PrintQueueConfiguration(
                inactivityTimeout: 0.05,
                timeoutCheckIntervalNanoseconds: 5_000_000,
                progressPublishInterval: 60
            )
        )
        let printer = ActivityKeepsAlivePrinter()
        let job = makeJob(byte: 0x82)

        queue.enqueue(job, printer: printer)

        try await waitUntil {
            queue.completedJobs.count == 1
        }

        XCTAssertTrue(queue.failedJobs.isEmpty)
        XCTAssertEqual(queue.completedJobs.first?.id, job.id)
        XCTAssertGreaterThanOrEqual(printer.transportActivityEvents, 3)
    }

    private func makeQueue(
        configuration: PrintQueueConfiguration = PrintQueueConfiguration()
    ) -> PrintQueue {
        PrintQueue(configuration: configuration, logger: makeLogger())
    }

    private func makeLogger(maxEntries: Int = 100) -> DiagnosticLogger {
        DiagnosticLogger(
            maxEntries: maxEntries,
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }

    private func makeJob(byte: UInt8, rowCount: Int = 1) -> PrintJob {
        PrintJob(
            documentID: UUID(),
            rows: Array(
                repeating: Data(repeating: byte, count: BitmapRasterizer.rowByteCount),
                count: rowCount
            )
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for print queue")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum TestPrintError: LocalizedError {
    case transport

    var errorDescription: String? {
        "Transport failed"
    }
}

private final class RecordingPrinter: PrintJobPrinting {
    private(set) var printedJobIDs: [UUID] = []
    private(set) var maxActivePrints = 0
    private var activePrints = 0

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        activePrints += 1
        maxActivePrints = max(maxActivePrints, activePrints)
        printedJobIDs.append(job.id)
        defer { activePrints -= 1 }

        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: job.rowCount,
                totalRows: job.rowCount,
                bytesSent: job.rows.reduce(0) { $0 + $1.count },
                timestamp: Date(),
                activity: .rowSent
            )
        )

        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private final class FailingPrinter: PrintJobPrinting {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        throw error
    }
}

private final class HangingPrinter: PrintJobPrinting {
    private(set) var cancelCalled = false

    var diagnosticStateDescription: String {
        "mock hanging"
    }

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }

    func cancelCurrentPrint() {
        cancelCalled = true
    }
}

private final class CancellablePrinter: PrintJobPrinting {
    private(set) var cancelCalled = false

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        while !cancelCalled {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        throw PrintTransportError.cancelled
    }

    func cancelCurrentPrint() {
        cancelCalled = true
    }
}

private final class StalePeripheralReadyPrinter: PrintJobPrinting {
    private(set) var didSendStalePeripheralReady = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 1,
                totalRows: job.rowCount,
                bytesSent: 56,
                timestamp: Date(),
                activity: .rowSent
            )
        )
        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 2,
                totalRows: job.rowCount,
                bytesSent: 112,
                timestamp: Date(),
                activity: .rowSent
            )
        )
        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 1,
                totalRows: job.rowCount,
                bytesSent: 56,
                timestamp: Date(),
                activity: .peripheralReady
            )
        )
        didSendStalePeripheralReady = true

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }

        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 3,
                totalRows: job.rowCount,
                bytesSent: 168,
                timestamp: Date(),
                activity: .rowSent
            )
        )
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private final class BurstProgressPrinter: PrintJobPrinting {
    private(set) var sentRows = 0

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 0,
                totalRows: job.rowCount,
                bytesSent: 0,
                timestamp: Date(),
                activity: .started
            )
        )

        for row in 1...job.rowCount {
            sentRows += 1
            progress(
                PrintJobProgress(
                    jobID: job.id,
                    currentRow: row,
                    totalRows: job.rowCount,
                    bytesSent: row * 56,
                    timestamp: Date(),
                    activity: .rowSent
                )
            )
        }

        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: job.rowCount,
                totalRows: job.rowCount,
                bytesSent: job.rowCount * 56,
                timestamp: Date(),
                activity: .completed
            )
        )
    }
}

private final class ActivityKeepsAlivePrinter: PrintJobPrinting {
    private(set) var transportActivityEvents = 0

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 0,
                totalRows: job.rowCount,
                bytesSent: 0,
                timestamp: Date(),
                activity: .started
            )
        )

        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 30_000_000)
            transportActivityEvents += 1
            progress(
                PrintJobProgress(
                    jobID: job.id,
                    currentRow: 0,
                    totalRows: job.rowCount,
                    bytesSent: 0,
                    timestamp: Date(),
                    activity: .peripheralReady
                )
            )
        }

        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: job.rowCount,
                totalRows: job.rowCount,
                bytesSent: 56,
                timestamp: Date(),
                activity: .rowSent
            )
        )
    }
}

private final class PublicationCounter {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return storedCount
    }

    func increment() {
        lock.lock()
        storedCount += 1
        lock.unlock()
    }
}
