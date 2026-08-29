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

struct PrintFrameChunk: Equatable {
    let index: Int
    let totalCount: Int
    let offset: Int
    let data: Data

    var oneBasedIndex: Int {
        index + 1
    }

    var byteRangeDescription: String {
        "\(offset)..<\(offset + data.count)"
    }
}

enum PrintFrameFragmentationError: LocalizedError, Equatable {
    case invalidMaximumLength(Int)

    var errorDescription: String? {
        switch self {
        case .invalidMaximumLength(let maximumLength):
            return "Maximum write-without-response length must be positive, received \(maximumLength)."
        }
    }
}

enum PrintFrameFragmenter {
    static func chunks(for frame: Data, maximumLength: Int) throws -> [PrintFrameChunk] {
        guard maximumLength > 0 else {
            throw PrintFrameFragmentationError.invalidMaximumLength(maximumLength)
        }

        if frame.count <= maximumLength {
            return [
                PrintFrameChunk(
                    index: 0,
                    totalCount: 1,
                    offset: 0,
                    data: frame
                )
            ]
        }

        var chunks: [PrintFrameChunk] = []
        var offset = 0

        while offset < frame.count {
            let endOffset = min(offset + maximumLength, frame.count)
            chunks.append(
                PrintFrameChunk(
                    index: chunks.count,
                    totalCount: 0,
                    offset: offset,
                    data: Data(frame[offset..<endOffset])
                )
            )
            offset = endOffset
        }

        let totalCount = chunks.count
        return chunks.map {
            PrintFrameChunk(
                index: $0.index,
                totalCount: totalCount,
                offset: $0.offset,
                data: $0.data
            )
        }
    }
}

struct PrinterTransportConfiguration: Equatable, Codable {
    var interPacketDelayNanoseconds: UInt64

    init(interPacketDelayNanoseconds: UInt64 = 5_000_000) {
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
            shouldLogFullHex: shouldLogFullHex
        )
    }

    static func bitmapRow(jobID: UUID, rowIndex: Int, totalRows: Int) -> PrintPacketContext {
        PrintPacketContext(
            jobID: jobID,
            kind: .bitmapRow,
            command: 0xA2,
            rowIndex: rowIndex,
            totalRows: totalRows,
            shouldLogFullHex: rowIndex < 3 || rowIndex >= max(0, totalRows - 3)
        )
    }
}

enum PrintTransportError: LocalizedError, Equatable {
    case notReady
    case disconnected
    case writeCharacteristicMissing
    case peripheralUnavailable
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
