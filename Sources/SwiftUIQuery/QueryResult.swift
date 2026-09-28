import Foundation
import Observation

/// Observation adapter for iOS 17+. Own it with `@State` in SwiftUI.
///
/// Both result adapters use the same query state machine and client cache.
@available(iOS 17, macOS 14, *)
@MainActor
@Observable
public final class QueryResult<Value: Sendable> {
    public private(set) var state: QueryState<Value>
    @ObservationIgnored private let controller: QueryController<Value>

    public init(
        key: QueryKey,
        client: QueryClient = .shared,
        options: QueryOptions = QueryOptions(),
        initialData: Value? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        let controller = QueryController(
            key: key,
            client: client,
            options: options,
            initialData: initialData,
            operation: operation
        )
        self.controller = controller
        state = controller.state
        controller.onStateChange = { [weak self] state in
            self?.state = state
        }
    }

    /// Weak ownership variant for services or view models that own this result/client.
    public convenience init<Owner: AnyObject & Sendable>(
        key: QueryKey, owner: Owner, client: QueryClient = .shared,
        options: QueryOptions = QueryOptions(), initialData: Value? = nil,
        operation: @escaping @Sendable (Owner) async throws -> Value
    ) {
        self.init(key: key, client: client, options: options, initialData: initialData) { [weak owner] in
            guard let owner else { throw QueryError.ownerReleased }
            return try await operation(owner)
        }
    }

    public var isStale: Bool { state.isStale }
    public var isPreviousData: Bool { state.isPreviousData }
    public func stopObserving() { controller.stopObserving() }
    public func dispose() { controller.dispose() }
    public func cancel() async { await controller.cancel() }

    public var data: Value? {
        state.data
    }

    public var error: (any Error)? {
        state.error
    }

    public var isLoading: Bool {
        state.isLoading
    }

    public var isFetching: Bool {
        state.isFetching
    }

    public var isSuccess: Bool {
        state.isSuccess
    }

    public var isError: Bool {
        state.isError
    }

    public var isResolved: Bool {
        state.isResolved
    }

    public var lastUpdated: Date? {
        state.lastUpdated
    }

    public func update(
        key: QueryKey,
        client: QueryClient? = nil,
        options: QueryOptions? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        controller.update(key: key, client: client, options: options, operation: operation)
    }

    public func update(from result: QueryResult<Value>) {
        controller.update(from: result.controller)
    }

    /// Use from SwiftUI .task to observe until that task is canceled.
    public func run() async { await controller.run() }

    public func fetch() async {
        await controller.fetch()
    }

    public func refetch() async {
        await controller.refetch()
    }

    public func runPeriodicRefetch() async {
        await controller.runPeriodicRefetch()
    }

    public func startPeriodicRefetch() {
        controller.startPeriodicRefetch()
    }

    public func cancelRefetch() {
        controller.cancelRefetch()
    }
}
