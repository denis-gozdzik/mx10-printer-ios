import Foundation

enum PrinterTransportState: String, Codable, CaseIterable, Identifiable {
    case idle
    case preparing
    case sending
    case waitingForPeripheralReady
    case completed
    case failed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .sending:
            return "Sending"
        case .waitingForPeripheralReady:
            return "Waiting for peripheral"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

enum PrintPacketKind: String, Codable {
    case status
    case feed
    case bitmapRow
    case testPattern
    case control
}

struct PrinterTransportConfiguration: Equatable, Codable {
    var interPacketDelayNanoseconds: UInt64

    init(interPacketDelayNanoseconds: UInt64 = 20_000_000) {
        self.interPacketDelayNanoseconds = interPacketDelayNanoseconds
    }

    static let debugDefault = PrinterTransportConfiguration()
}

struct PrintPacketContext: Equatable {
    var jobID: UUID?
    var kind: PrintPacketKind
    var command: UInt8
    var rowIndex: Int?
    var totalRows: Int?
    var shouldLogFrame: Bool
    var shouldLogFullHex: Bool

    static func control(
        command: UInt8,
        kind: PrintPacketKind,
        jobID: UUID? = nil,
        shouldLogFullHex: Bool = true
    ) -> PrintPacketContext {
        PrintPacketContext(
            jobID: jobID,
            kind: kind,
            command: command,
            rowIndex: nil,
            totalRows: nil,
            shouldLogFrame: true,
            shouldLogFullHex: shouldLogFullHex
        )
    }

    static func bitmapRow(jobID: UUID, rowIndex: Int, totalRows: Int) -> PrintPacketContext {
        let rowNumber = rowIndex + 1
        let isFirstRows = rowIndex < 3
        let isLastRows = rowIndex >= max(0, totalRows - 3)

        return PrintPacketContext(
            jobID: jobID,
            kind: .bitmapRow,
            command: 0xA2,
            rowIndex: rowIndex,
            totalRows: totalRows,
            shouldLogFrame: isFirstRows || isLastRows || rowNumber.isMultiple(of: 50),
            shouldLogFullHex: isFirstRows || isLastRows
        )
    }
}

enum PrintTransportError: LocalizedError, Equatable {
    case notReady
    case disconnected
    case writeCharacteristicMissing
    case peripheralUnavailable
    case invalidMaximumWriteLength(Int)
    case maximumWriteLengthTooSmall(frameBytes: Int, currentMaximum: Int, cachedMaximum: Int?)
    case concurrentPeripheralReadyWait
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Printer transport is not ready."
        case .disconnected:
            return "Printer disconnected."
        case .writeCharacteristicMissing:
            return "AE01 write characteristic is missing."
        case .peripheralUnavailable:
            return "Printer peripheral is unavailable."
        case .invalidMaximumWriteLength(let currentMaximum):
            return "Maximum write-without-response length must be positive, received \(currentMaximum)."
        case .maximumWriteLengthTooSmall(let frameBytes, let currentMaximum, let cachedMaximum):
            let cachedDescription = cachedMaximum.map { "\($0)" } ?? "unknown"
            return "Current write-without-response length \(currentMaximum) is too small for \(frameBytes)-byte MX10 frame; cached value was \(cachedDescription)."
        case .concurrentPeripheralReadyWait:
            return "A write-without-response readiness wait is already active."
        case .cancelled:
            return "Print transport cancelled."
        }
    }
}

protocol PrintFrameTransport: AnyObject {
    var canSendPrintData: Bool { get }
    var maxWriteWithoutResponseLength: Int? { get }
    var currentMaximumWriteWithoutResponse: Int? { get }
    var isReadyForWriteWithoutResponse: Bool { get }
    var transportState: PrinterTransportState { get }
    var onTransportActivity: ((PrintJobProgressActivity) -> Void)? { get set }

    func beginPrintTransport(
        jobID: UUID,
        totalRows: Int,
        configuration: PrinterTransportConfiguration
    )
    func sendFrame(_ frame: Data, context: PrintPacketContext) async throws
    func completePrintTransport(jobID: UUID)
    func failPrintTransport(jobID: UUID?, reason: String)
    func cancelActiveTransport()
}

extension Data {
    var diagnosticHexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
