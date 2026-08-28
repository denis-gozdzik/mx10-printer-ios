import Foundation

@MainActor
final class PrintQueue: ObservableObject {
    @Published private(set) var pendingJobs: [PrintJob] = []
    @Published private(set) var completedJobs: [PrintJob] = []
    @Published private(set) var failedJobs: [PrintJobFailure] = []
    @Published private(set) var currentJob: PrintJob?

    private var workerTask: Task<Void, Never>?

    var isPrinting: Bool {
        currentJob != nil
    }

    func enqueue(_ job: PrintJob, printer: PrintJobPrinting) {
        pendingJobs.append(job)
        startIfNeeded(printer: printer)
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
        while !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            currentJob = job

            do {
                try await printer.print(job: job)
                completedJobs.append(job)
            } catch {
                failedJobs.append(PrintJobFailure(job: job, message: error.localizedDescription))
            }

            currentJob = nil
        }

        workerTask = nil
    }
}
