import Foundation

enum MX10PrinterError: LocalizedError {
    case notReadyForPrintData
    case emptyPrintJob

    var errorDescription: String? {
        switch self {
        case .notReadyForPrintData:
            return "MX10 is not ready for print data."
        case .emptyPrintJob:
            return "The print job contains no raster rows."
        }
    }
}

final class MX10Printer: PrintJobPrinting {
    private let transport: PrintFrameTransport
    private let configuration: MX10PrintConfiguration
    private let logger: DiagnosticLogger

    init(
        bluetoothManager: MX10BluetoothManager,
        configuration: MX10PrintConfiguration = MX10PrintConfiguration(),
        logger: DiagnosticLogger = .shared
    ) {
        self.transport = bluetoothManager
        self.configuration = configuration
        self.logger = logger
    }

    init(
        transport: PrintFrameTransport,
        configuration: MX10PrintConfiguration = MX10PrintConfiguration(),
        logger: DiagnosticLogger = .shared
    ) {
        self.transport = transport
        self.configuration = configuration
        self.logger = logger
    }

    var diagnosticStateDescription: String {
        "transport=\(transport.transportState.rawValue) ready=\(transport.isReadyForWriteWithoutResponse) cachedMaxWrite=\(transport.maxWriteWithoutResponseLength ?? -1) currentMaxWrite=\(transport.currentMaximumWriteWithoutResponse ?? -1)"
    }

    func requestStatus() {
        sendControlFrame(
            MX10Protocol.requestStatus(),
            command: 0xA3,
            kind: .status,
            label: "status request"
        )
    }

    func feed(steps: UInt16) {
        sendControlFrame(
            MX10Protocol.feed(steps: steps),
            command: 0xA1,
            kind: .feed,
            label: "feed",
            metadata: ["steps": steps]
        )
    }

    func printRow(_ row: Data) async throws {
        let frame = try MX10Protocol.printRow(row)
        try await transport.sendFrame(
            frame,
            context: .control(command: 0xA2, kind: .bitmapRow)
        )
    }

    func printTestPattern() {
        Task { [transport, configuration, logger] in
            let rows = BitmapEncoder.testRows()
            let jobID = UUID()
            transport.beginPrintTransport(
                jobID: jobID,
                totalRows: rows.count,
                configuration: configuration.transport
            )
            logger.log(
                .printer,
                "test pattern start",
                metadata: ["job": jobID.uuidString, "rows": rows.count]
            )

            do {
                for (index, row) in rows.enumerated() {
                    let frame = try MX10Protocol.printRow(row)
                    try await transport.sendFrame(
                        frame,
                        context: .bitmapRow(jobID: jobID, rowIndex: index, totalRows: rows.count)
                    )
                    try await sleepIfNeeded(configuration.transport.interPacketDelayNanoseconds)
                }

                transport.completePrintTransport(jobID: jobID)
                logger.log(.printer, "test pattern completed", metadata: ["job": jobID.uuidString])
            } catch {
                transport.failPrintTransport(jobID: jobID, reason: error.localizedDescription)
                logger.log(
                    .error,
                    "test pattern failed",
                    metadata: ["job": jobID.uuidString, "error": error.localizedDescription]
                )
            }
        }
    }

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws {
        guard transport.canSendPrintData else {
            logger.log(.error, "print rejected", metadata: ["reason": "transport not ready"])
            throw MX10PrinterError.notReadyForPrintData
        }

        guard !job.rows.isEmpty else {
            logger.log(.error, "print rejected", metadata: ["reason": "empty job"])
            throw MX10PrinterError.emptyPrintJob
        }

        logger.log(
            .printer,
            "JOB START",
            metadata: [
                "job": job.id.uuidString,
                "rows": job.rows.count,
                "feedAfterPrintSteps": job.feedAfterPrintSteps,
                "sequence": printSequenceDescription
            ]
        )
        logger.log(
            .printer,
            "unverified init commands disabled",
            metadata: [
                "job": job.id.uuidString,
                "allowUnverifiedInitializationCommands": configuration.allowUnverifiedInitializationCommands
            ]
        )

        var currentRow = 0
        var bytesSent = 0
        let previousActivityHandler = transport.onTransportActivity
        transport.onTransportActivity = { activity in
            progress(
                PrintJobProgress(
                    jobID: job.id,
                    currentRow: currentRow,
                    totalRows: job.rows.count,
                    bytesSent: bytesSent,
                    timestamp: Date(),
                    activity: activity
                )
            )
        }

        transport.beginPrintTransport(
            jobID: job.id,
            totalRows: job.rows.count,
            configuration: configuration.transport
        )
        progress(
            PrintJobProgress(
                jobID: job.id,
                currentRow: 0,
                totalRows: job.rows.count,
                bytesSent: 0,
                timestamp: Date(),
                activity: .started
            )
        )

        do {
            for (index, row) in job.rows.enumerated() {
                try Task.checkCancellation()

                let frame = try MX10Protocol.printRow(row)

                try await transport.sendFrame(
                    frame,
                    context: .bitmapRow(
                        jobID: job.id,
                        rowIndex: index,
                        totalRows: job.rows.count
                    )
                )

                currentRow = index + 1
                bytesSent += frame.count
                progress(
                    PrintJobProgress(
                        jobID: job.id,
                        currentRow: currentRow,
                        totalRows: job.rows.count,
                        bytesSent: bytesSent,
                        timestamp: Date(),
                        activity: .rowSent
                    )
                )

                try await sleepIfNeeded(configuration.transport.interPacketDelayNanoseconds)
            }

            if job.feedAfterPrintSteps > 0 {
                let feedFrame = MX10Protocol.feed(steps: job.feedAfterPrintSteps)
                try await transport.sendFrame(
                    feedFrame,
                    context: .control(
                        command: 0xA1,
                        kind: .feed,
                        jobID: job.id,
                        shouldLogFullHex: true
                    )
                )
                bytesSent += feedFrame.count
                progress(
                    PrintJobProgress(
                        jobID: job.id,
                        currentRow: currentRow,
                        totalRows: job.rows.count,
                        bytesSent: bytesSent,
                        timestamp: Date(),
                        activity: .controlSent
                    )
                )
            }

            transport.completePrintTransport(jobID: job.id)
            progress(
                PrintJobProgress(
                    jobID: job.id,
                    currentRow: currentRow,
                    totalRows: job.rows.count,
                    bytesSent: bytesSent,
                    timestamp: Date(),
                    activity: .completed
                )
            )
            logger.log(
                .printer,
                "JOB END",
                metadata: [
                    "job": job.id.uuidString,
                    "rows": currentRow,
                    "bytesSent": bytesSent
                ]
            )
            transport.onTransportActivity = previousActivityHandler
        } catch is CancellationError {
            transport.onTransportActivity = previousActivityHandler
            transport.cancelActiveTransport()
            logger.log(
                .queue,
                "print cancelled",
                metadata: ["job": job.id.uuidString, "row": "\(currentRow)/\(job.rows.count)"]
            )
            throw PrintTransportError.cancelled
        } catch PrintTransportError.cancelled {
            transport.onTransportActivity = previousActivityHandler
            transport.cancelActiveTransport()
            logger.log(
                .queue,
                "print cancelled",
                metadata: ["job": job.id.uuidString, "row": "\(currentRow)/\(job.rows.count)"]
            )
            throw PrintTransportError.cancelled
        } catch {
            transport.onTransportActivity = previousActivityHandler
            transport.failPrintTransport(jobID: job.id, reason: error.localizedDescription)
            logger.log(
                .error,
                "print failed",
                metadata: [
                    "job": job.id.uuidString,
                    "row": "\(currentRow)/\(job.rows.count)",
                    "error": error.localizedDescription
                ]
            )
            throw error
        }
    }

    func cancelCurrentPrint() {
        transport.cancelActiveTransport()
    }

    private var printSequenceDescription: String {
        "bitmap rows; optional feed; no unverified A8/BB/A4/A6/AF/BE/BD/BF init sequence"
    }

    private func sendControlFrame(
        _ frame: Data,
        command: UInt8,
        kind: PrintPacketKind,
        label: String,
        metadata: [String: Any] = [:]
    ) {
        Task { [transport, logger] in
            do {
                var logMetadata = metadata
                logMetadata["command"] = String(format: "0x%02X", command)
                logMetadata["hex"] = frame.diagnosticHexString
                logger.log(
                    .protocolLog,
                    label,
                    metadata: logMetadata
                )
                try await transport.sendFrame(
                    frame,
                    context: .control(command: command, kind: kind)
                )
            } catch {
                logger.log(
                    .error,
                    "\(label) failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }
}

private func sleepIfNeeded(_ nanoseconds: UInt64) async throws {
    guard nanoseconds > 0 else {
        await Task.yield()
        return
    }

    try await Task.sleep(nanoseconds: nanoseconds)
}
