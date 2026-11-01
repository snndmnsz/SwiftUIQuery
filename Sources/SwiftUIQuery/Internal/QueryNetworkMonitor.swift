import Foundation
#if canImport(Network)
import Network
#endif

/// One system path monitor shared by all clients, with weakly owned subscribers.
final class QueryNetworkMonitor: @unchecked Sendable {
    static let shared = QueryNetworkMonitor()
    private let lock = NSLock()
    private var latest: Bool?
    private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]
#if canImport(Network)
    private let monitor = NWPathMonitor()
#endif

    private init() {
#if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            // A connection attempt can activate an on-demand path.
            self?.publish(path.status != .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "SwiftUIQuery.connectivity"))
#endif
    }

    func updates() -> AsyncStream<Bool> {
        let id = UUID()
        // Keep the latest transition pair without accumulating events while busy.
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            lock.lock()
            subscribers[id] = continuation
            if let latest { continuation.yield(latest) }
            lock.unlock()
        }
    }

    private func publish(_ online: Bool) {
        lock.lock()
        guard latest != online else { lock.unlock(); return }
        latest = online
        for subscriber in subscribers.values { subscriber.yield(online) }
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}
