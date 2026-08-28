import Foundation

struct PrintJob: Identifiable, Equatable {
    let id: UUID
    let documentID: UUID
    let createdAt: Date
    let rows: [Data]
    let feedAfterPrintSteps: UInt16

    init(
        id: UUID = UUID(),
        documentID: UUID,
        createdAt: Date = Date(),
        rows: [Data],
        feedAfterPrintSteps: UInt16 = 0
    ) {
        self.id = id
        self.documentID = documentID
        self.createdAt = createdAt
        self.rows = rows
        self.feedAfterPrintSteps = feedAfterPrintSteps
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

protocol PrintJobPrinting: AnyObject {
    func print(job: PrintJob) async throws
}
