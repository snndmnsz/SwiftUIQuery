import Foundation

/// Accessed only inside QueryClient. Callbacks only yield Sendable snapshots.
struct QueryRecord: Sendable {
    let type: Any.Type
    var value: (any Sendable)?
    var hasValue = false
    var error: (any Error)?
    var updatedAt: Date?
    var freshUntil: Date?
    var requestStaleTime: CacheDuration = .default
    var invalidated = false
    var wasRemoved = false
    var options = QueryOptions()
    var operation: (@Sendable () async throws -> any Sendable)?
    var requestID: UUID?
    var task: Task<Void, Never>?
    var waiters: [UUID: CheckedContinuation<any Sendable, any Error>] = [:]
    var observers: [UUID: QueryObserver] = [:]
    var gcID: UUID?
    var gcTask: Task<Void, Never>?
    var staleTask: Task<Void, Never>?
    var revision: UInt64 = 0
    var dataID = UUID()

    var isStale: Bool {
        invalidated || freshUntil.map { Date.now >= $0 } ?? true
    }
    var isActive: Bool { observers.values.contains { $0.enabled } }
}

struct QueryObserver: Sendable {
    let enabled: Bool
    let receive: @Sendable (QueryRecord) -> Void
}

struct QuerySnapshot<Value: Sendable>: Sendable {
    let revision: UInt64
    let state: QueryState<Value>
    let wasRemoved: Bool

    init(_ record: QueryRecord) {
        revision = record.revision
        wasRemoved = record.wasRemoved
        state = QueryState(
            data: record.hasValue ? record.value as? Value : nil,
            error: record.error,
            isLoading: !record.hasValue && record.requestID != nil,
            isFetching: record.requestID != nil,
            lastUpdated: record.updatedAt,
            isStale: record.isStale
        )
    }
}

struct QuerySubscription<Value: Sendable>: Sendable {
    let snapshots: AsyncStream<QuerySnapshot<Value>>
    let lease: QueryLease
}

/// No strong reference back to the client. Removal is idempotent on the actor.
final class QueryLease: Sendable {
    let release: @Sendable () -> Void
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    func cancel() { release() }
    deinit { release() }
}
