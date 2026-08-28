import XCTest
@testable import MX10Printer

@MainActor
final class PrintQueueTests: XCTestCase {
    func testPrintQueueProcessesJobsInEnqueueOrder() async throws {
        let queue = PrintQueue()
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
            printer.printedJobIDs.count == jobs.count
        }

        XCTAssertEqual(printer.printedJobIDs, jobs.map(\.id))
        XCTAssertEqual(printer.maxActivePrints, 1)
        XCTAssertEqual(queue.completedJobs, jobs)
        XCTAssertTrue(queue.pendingJobs.isEmpty)
        XCTAssertFalse(queue.isPrinting)
    }

    private func makeJob(byte: UInt8) -> PrintJob {
        PrintJob(
            documentID: UUID(),
            rows: [Data(repeating: byte, count: BitmapRasterizer.rowByteCount)]
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

private final class RecordingPrinter: PrintJobPrinting {
    private(set) var printedJobIDs: [UUID] = []
    private(set) var maxActivePrints = 0
    private var activePrints = 0

    func print(job: PrintJob) async throws {
        activePrints += 1
        maxActivePrints = max(maxActivePrints, activePrints)
        printedJobIDs.append(job.id)

        try await Task.sleep(nanoseconds: 1_000_000)

        activePrints -= 1
    }
}
