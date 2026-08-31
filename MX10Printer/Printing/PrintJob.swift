import Foundation

enum PrintJobLifecycle: String, Codable, CaseIterable, Identifiable {
    case queued
    case rendering
    case ready
    case sending
    case completed
    case failed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queued:
            return "Queued"
        case .rendering:
            return "Rendering"
        case .ready:
            return "Ready"
        case .sending:
            return "Sending"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

enum PrintJobProgressActivity: String, Codable, Equatable {
    case started
    case rowSent
    case peripheralReady
    case notificationReceived
    case controlSent
    case completed
}

struct PrintJobProgress: Equatable {
    var jobID: UUID
    var currentRow: Int
    var totalRows: Int
    var bytesSent: Int
    var timestamp: Date
    var activity: PrintJobProgressActivity
}

struct PrintJob: Identifiable, Equatable {
    let id: UUID
    let documentID: UUID
    let createdAt: Date
    let rows: [Data]
    let feedAfterPrintSteps: UInt16
    var lifecycle: PrintJobLifecycle
    var currentRow: Int
    var bytesSent: Int
    var lastProgressAt: Date
    var completedAt: Date?
    var failureReason: String?

    init(
        id: UUID = UUID(),
        documentID: UUID,
        createdAt: Date = Date(),
        rows: [Data],
        feedAfterPrintSteps: UInt16 = 0,
        lifecycle: PrintJobLifecycle = .ready,
        currentRow: Int = 0,
        bytesSent: Int = 0,
        lastProgressAt: Date? = nil,
        completedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.createdAt = createdAt
        self.rows = rows
        self.feedAfterPrintSteps = feedAfterPrintSteps
        self.lifecycle = lifecycle
        self.currentRow = currentRow
        self.bytesSent = bytesSent
        self.lastProgressAt = lastProgressAt ?? createdAt
        self.completedAt = completedAt
        self.failureReason = failureReason
    }

    var rowCount: Int {
        rows.count
    }

    var duration: TimeInterval? {
        guard let completedAt else {
            return nil
        }

        return completedAt.timeIntervalSince(createdAt)
    }

    mutating func markQueued(at date: Date = Date()) {
        lifecycle = .queued
        lastProgressAt = date
    }

    mutating func markRendering(at date: Date = Date()) {
        lifecycle = .rendering
        lastProgressAt = date
    }

    mutating func markReady(at date: Date = Date()) {
        lifecycle = .ready
        lastProgressAt = date
    }

    mutating func markSending(at date: Date = Date()) {
        lifecycle = .sending
        lastProgressAt = date
    }

    mutating func apply(progress: PrintJobProgress) {
        switch progress.activity {
        case .started, .rowSent, .controlSent, .completed:
            currentRow = max(currentRow, progress.currentRow)
            bytesSent = max(bytesSent, progress.bytesSent)
        case .peripheralReady, .notificationReceived:
            break
        }

        lastProgressAt = progress.timestamp
    }

    mutating func markCompleted(at date: Date = Date()) {
        lifecycle = .completed
        completedAt = date
        lastProgressAt = date
    }

    mutating func markFailed(reason: String, at date: Date = Date()) {
        lifecycle = .failed
        failureReason = reason
        completedAt = date
        lastProgressAt = date
    }

    mutating func markCancelled(at date: Date = Date()) {
        lifecycle = .cancelled
        completedAt = date
        lastProgressAt = date
    }
}

struct PrintJobFailure: Identifiable, Equatable {
    let id: UUID
    let job: PrintJob
    let message: String

    init(job: PrintJob, message: String) {
        self.id = UUID()
        self.job = job
        self.message = message
    }
}

@MainActor
protocol PrintJobPrinting: AnyObject {
    var diagnosticStateDescription: String { get }

    func print(
        job: PrintJob,
        progress: @escaping (PrintJobProgress) -> Void
    ) async throws
    func cancelCurrentPrint()
}

extension PrintJobPrinting {
    var diagnosticStateDescription: String {
        "unknown"
    }

    func cancelCurrentPrint() {}
}
