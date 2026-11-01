import Foundation

/// Independent of QueryClient so an offline request cannot retain its client.
final class QueryOnlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func setOnline(_ value: Bool) {
        lock.lock()
        online = value
        let pending = value ? Array(waiters.values) : []
        if value { waiters.removeAll() }
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if online {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in self?.cancel(id) }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }
}
