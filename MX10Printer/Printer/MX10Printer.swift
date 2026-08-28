import Foundation

enum MX10PrinterError: LocalizedError {
    case notReadyForPrintData

    var errorDescription: String? {
        switch self {
        case .notReadyForPrintData:
            return "MX10 is not ready for print data."
        }
    }
}

final class MX10Printer: PrintJobPrinting {
    private let bluetoothManager: MX10BluetoothManager
    private let rowDelayNanoseconds: UInt64

    init(
        bluetoothManager: MX10BluetoothManager,
        rowDelayNanoseconds: UInt64 = 20_000_000
    ) {
        self.bluetoothManager = bluetoothManager
        self.rowDelayNanoseconds = rowDelayNanoseconds
    }

    func requestStatus() {
        bluetoothManager.send(data: MX10Protocol.requestStatus())
    }

    func feed(steps: UInt16) {
        bluetoothManager.send(data: MX10Protocol.feed(steps: steps))
    }

    func printRow(_ row: Data) throws {
        let frame = try MX10Protocol.printRow(row)
        bluetoothManager.send(data: frame)
    }

    func printTestPattern() {
        let rows = BitmapEncoder.testRows()

        for row in rows {
            do {
                let frame = try MX10Protocol.printRow(row)
                bluetoothManager.send(data: frame)
            } catch {
                Swift.print("Failed to print test row: \(error.localizedDescription)")
            }
        }
    }

    func print(job: PrintJob) async throws {
        guard bluetoothManager.canSendPrintData else {
            throw MX10PrinterError.notReadyForPrintData
        }

        for row in job.rows {
            try printRow(row)
            try await Task.sleep(nanoseconds: rowDelayNanoseconds)
        }

        if job.feedAfterPrintSteps > 0 {
            feed(steps: job.feedAfterPrintSteps)
        }
    }
}
