import Combine
import Foundation

final class PreviewDebouncer: ObservableObject {
    private let delayNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(delayNanoseconds: UInt64 = 150_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    deinit {
        task?.cancel()
    }

    @MainActor
    func schedule(_ action: @MainActor @escaping () -> Void) {
        task?.cancel()
        let delay = delayNanoseconds
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                action()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    @MainActor
    func performImmediately(_ action: @MainActor () -> Void) {
        task?.cancel()
        task = nil
        action()
    }

    @MainActor
    func cancel() {
        task?.cancel()
        task = nil
    }
}
