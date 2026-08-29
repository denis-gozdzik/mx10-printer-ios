import Foundation

struct PrintQueueConfiguration: Equatable {
    var inactivityTimeout: TimeInterval
    var timeoutCheckIntervalNanoseconds: UInt64

    init(
        inactivityTimeout: TimeInterval = 30,
        timeoutCheckIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.inactivityTimeout = inactivityTimeout
        self.timeoutCheckIntervalNanoseconds = timeoutCheckIntervalNanoseconds
    }
}

enum PrintQueueError: LocalizedError, Equatable {
    case timeout(jobID: UUID, currentRow: Int, totalRows: Int, timeoutSeconds: TimeInterval)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .timeout(_, let currentRow, let totalRows, let timeoutSeconds):
            return "PRINT_TIMEOUT after \(Int(timeoutSeconds)) seconds without progress at row \(currentRow) / \(totalRows)."
        case .cancelled:
            return "Print cancelled."
        }
    }
}

@MainActor
final class PrintQueue: ObservableObject {
    @Published private(set) var pendingJobs: [PrintJob] = []
    @Published private(set) var completedJobs: [PrintJob] = []
    @Published private(set) var failedJobs: [PrintJobFailure] = []
    @Published private(set) var cancelledJobs: [PrintJob] = []
    @Published private(set) var currentJob: PrintJob?

    private let configuration: PrintQueueConfiguration
    private let logger: DiagnosticLogger
    private var workerTask: Task<Void, Never>?
    private weak var activePrinter: PrintJobPrinting?
    private var cancellationRequestedJobIDs: Set<UUID> = []
    private var timedOutJobIDs: Set<UUID> = []

    init(
        configuration: PrintQueueConfiguration = PrintQueueConfiguration(),
        logger: DiagnosticLogger = .shared
    ) {
        self.configuration = configuration
        self.logger = logger
    }

    var isPrinting: Bool {
        currentJob != nil
    }

    var hasActiveOrPendingJob: Bool {
        currentJob != nil || !pendingJobs.isEmpty
    }

    var currentStatusText: String {
        guard let currentJob else {
            if !pendingJobs.isEmpty {
                return "Queued"
            }

            if let cancelled = cancelledJobs.last,
               (completedJobs.last?.completedAt ?? .distantPast) < (cancelled.completedAt ?? .distantPast),
               (failedJobs.last?.job.completedAt ?? .distantPast) < (cancelled.completedAt ?? .distantPast) {
                return "Cancelled"
            }

            if let failed = failedJobs.last,
               (completedJobs.last?.completedAt ?? .distantPast) < (failed.job.completedAt ?? .distantPast) {
                return "Failed"
            }

            if !completedJobs.isEmpty {
                return "Completed"
            }

            return "Ready"
        }

        switch currentJob.lifecycle {
        case .queued:
            return "Queued"
        case .rendering:
            return "Rendering..."
        case .ready:
            return "Preparing..."
        case .sending:
            return "Printing \(currentJob.currentRow) / \(currentJob.rowCount)"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var progressFraction: Double {
        guard let currentJob, currentJob.rowCount > 0 else {
            return 0
        }

        return min(1, max(0, Double(currentJob.currentRow) / Double(currentJob.rowCount)))
    }

    var diagnosticStateText: String {
        if let currentJob {
            return "\(currentJob.lifecycle.rawValue) job=\(currentJob.id.uuidString) row=\(currentJob.currentRow)/\(currentJob.rowCount) bytes=\(currentJob.bytesSent)"
        }

        return "idle pending=\(pendingJobs.count) completed=\(completedJobs.count) failed=\(failedJobs.count) cancelled=\(cancelledJobs.count)"
    }

    @discardableResult
    func enqueueIfIdle(_ job: PrintJob, printer: PrintJobPrinting) -> Bool {
        guard !hasActiveOrPendingJob else {
            logger.log(
                .queue,
                "enqueue rejected",
                metadata: [
                    "job": job.id.uuidString,
                    "reason": "active or pending job exists",
                    "currentJob": currentJob?.id.uuidString ?? "none",
                    "pending": pendingJobs.count,
                    "workerActive": "\(workerTask != nil)"
                ]
            )
            return false
        }

        enqueue(job, printer: printer)
        return true
    }

    func enqueue(_ job: PrintJob, printer: PrintJobPrinting) {
        var queuedJob = job
        queuedJob.markQueued()
        pendingJobs.append(queuedJob)
        logger.log(
            .queue,
            "enqueue",
            metadata: [
                "job": queuedJob.id.uuidString,
                "rows": queuedJob.rowCount,
                "pending": pendingJobs.count
            ]
        )
        startIfNeeded(printer: printer)
    }

    func cancelCurrentJob() {
        guard let job = currentJob else {
            logger.log(.queue, "cancel requested without active job")
            return
        }

        cancellationRequestedJobIDs.insert(job.id)
        logger.log(
            .queue,
            "cancel requested",
            metadata: [
                "job": job.id.uuidString,
                "row": "\(job.currentRow)/\(job.rowCount)"
            ]
        )
        activePrinter?.cancelCurrentPrint()
    }

    func failCurrentJob(reason: String) {
        guard var job = currentJob else {
            return
        }

        logger.log(
            .error,
            "active job failed externally",
            metadata: [
                "job": job.id.uuidString,
                "reason": reason,
                "row": "\(job.currentRow)/\(job.rowCount)"
            ]
        )
        activePrinter?.cancelCurrentPrint()
        workerTask?.cancel()
        job.markFailed(reason: reason)
        failedJobs.append(PrintJobFailure(job: job, message: reason))
        currentJob = nil
        activePrinter = nil
        workerTask = nil
    }

    private func startIfNeeded(printer: PrintJobPrinting) {
        guard workerTask == nil else {
            return
        }

        workerTask = Task {
            await process(printer: printer)
        }
    }

    private func process(printer: PrintJobPrinting) async {
        activePrinter = printer

        while !pendingJobs.isEmpty, !Task.isCancelled {
            var job = pendingJobs.removeFirst()
            job.markSending()
            currentJob = job
            logger.log(
                .queue,
                "start",
                metadata: [
                    "job": job.id.uuidString,
                    "rows": job.rowCount,
                    "inactivityTimeoutSeconds": configuration.inactivityTimeout
                ]
            )

            do {
                try await run(job: job, printer: printer)

                guard var completedJob = currentJob, completedJob.id == job.id else {
                    continue
                }

                completedJob.markCompleted()
                completedJobs.append(completedJob)
                currentJob = nil
                logger.log(
                    .queue,
                    "complete",
                    metadata: [
                        "job": completedJob.id.uuidString,
                        "rows": completedJob.currentRow,
                        "bytesSent": completedJob.bytesSent,
                        "durationSeconds": completedJob.duration ?? 0
                    ]
                )
            } catch {
                guard var failedJob = currentJob, failedJob.id == job.id else {
                    continue
                }

                if cancellationRequestedJobIDs.remove(failedJob.id) != nil ||
                    (error as? PrintTransportError) == .cancelled ||
                    error is CancellationError {
                    failedJob.markCancelled()
                    cancelledJobs.append(failedJob)
                    logger.log(
                        .queue,
                        "cancelled",
                        metadata: [
                            "job": failedJob.id.uuidString,
                            "row": "\(failedJob.currentRow)/\(failedJob.rowCount)"
                        ]
                    )
                } else {
                    failedJob.markFailed(reason: error.localizedDescription)
                    failedJobs.append(PrintJobFailure(job: failedJob, message: error.localizedDescription))
                    logger.log(
                        .error,
                        "failed",
                        metadata: [
                            "job": failedJob.id.uuidString,
                            "row": "\(failedJob.currentRow)/\(failedJob.rowCount)",
                            "error": error.localizedDescription
                        ]
                    )
                }

                currentJob = nil
            }
        }

        activePrinter = nil
        workerTask = nil
    }

    private enum WorkerEvent {
        case completed
        case timedOut
        case failed(Error)
    }

    private func run(job: PrintJob, printer: PrintJobPrinting) async throws {
        let printTask = Task { @MainActor in
            try await printer.print(job: job) { [weak self] progress in
                self?.apply(progress: progress)
            }
        }

        do {
            let event = await withTaskGroup(of: WorkerEvent.self) { group in
                group.addTask {
                    do {
                        try await printTask.value
                        return .completed
                    } catch {
                        return .failed(error)
                    }
                }

                group.addTask { [configuration] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: configuration.timeoutCheckIntervalNanoseconds)
                        } catch {
                            return .failed(error)
                        }

                        let timedOut = await MainActor.run {
                            self.currentJobTimedOut(now: Date())
                        }

                        if timedOut {
                            await MainActor.run {
                                self.timedOutJobIDs.insert(job.id)
                                self.activePrinter?.cancelCurrentPrint()
                            }
                            printTask.cancel()
                            return .timedOut
                        }
                    }

                    return .failed(CancellationError())
                }

                let event = await group.next() ?? .completed
                group.cancelAll()
                return event
            }

            switch event {
            case .completed:
                break
            case .timedOut:
                timedOutJobIDs.remove(job.id)
                let row = currentJob?.currentRow ?? 0
                let totalRows = currentJob?.rowCount ?? job.rowCount
                logger.log(
                    .error,
                    "PRINT_TIMEOUT",
                    metadata: [
                        "job": job.id.uuidString,
                        "row": "\(row)/\(totalRows)",
                        "bleState": printer.diagnosticStateDescription
                    ]
                )
                throw PrintQueueError.timeout(
                    jobID: job.id,
                    currentRow: row,
                    totalRows: totalRows,
                    timeoutSeconds: configuration.inactivityTimeout
                )
            case .failed(let error):
                if timedOutJobIDs.remove(job.id) != nil {
                    let row = currentJob?.currentRow ?? 0
                    let totalRows = currentJob?.rowCount ?? job.rowCount
                    logger.log(
                        .error,
                        "PRINT_TIMEOUT",
                        metadata: [
                            "job": job.id.uuidString,
                            "row": "\(row)/\(totalRows)",
                            "bleState": printer.diagnosticStateDescription
                        ]
                    )
                    throw PrintQueueError.timeout(
                        jobID: job.id,
                        currentRow: row,
                        totalRows: totalRows,
                        timeoutSeconds: configuration.inactivityTimeout
                    )
                }

                throw error
            }
        } catch {
            printTask.cancel()
            throw error
        }
    }

    private func apply(progress: PrintJobProgress) {
        guard var job = currentJob, job.id == progress.jobID else {
            return
        }

        job.apply(progress: progress)
        currentJob = job
        let uiStatus = currentStatusText
        let uiProgressValue = progressFraction
        logger.log(
            .queue,
            "progress",
            metadata: [
                "job": job.id.uuidString,
                "activity": progress.activity.rawValue,
                "row": "\(job.currentRow)/\(job.rowCount)",
                "bytesSent": job.bytesSent,
                "uiStatus": uiStatus,
                "uiProgressFraction": String(format: "%.4f", uiProgressValue)
            ]
        )
    }

    private func currentJobTimedOut(now: Date) -> Bool {
        guard let currentJob else {
            return false
        }

        return now.timeIntervalSince(currentJob.lastProgressAt) >= configuration.inactivityTimeout
    }
}
