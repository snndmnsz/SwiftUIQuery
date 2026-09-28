import Foundation

/// UI state is a projection of the client's shared, revisioned query record.
@MainActor
final class QueryController<Value: Sendable> {
    private(set) var state = QueryState<Value>() {
        didSet { onStateChange?(state) }
    }
    var onStateChange: (@MainActor (QueryState<Value>) -> Void)?
    private var key: QueryKey
    private var client: QueryClient
    private var options: QueryOptions
    private var operation: (@Sendable () async throws -> Value)?
    private var initialData: Value?
    private var generation = 0
    private var latestRevision: UInt64 = 0
    private var executions: [UUID: Task<Value, any Error>] = [:]
    private var connection: Task<QuerySubscription<Value>, any Error>?
    private var observationTask: Task<Void, Never>?
    private var lease: QueryLease?
    private var pollingTask: Task<Void, Never>?
    private var pollingID: UUID?
    private var sleepTask: Task<Void, any Error>?
    private var sleepID: UUID?

    init(key: QueryKey, client: QueryClient = .shared, options: QueryOptions = QueryOptions(),
         initialData: Value? = nil, operation: @escaping @Sendable () async throws -> Value) {
        self.key = key
        self.client = client
        self.options = options
        self.initialData = initialData
        self.operation = operation
        state.data = initialData
    }

    deinit {
        connection?.cancel()
        observationTask?.cancel()
        lease?.cancel()
        pollingTask?.cancel()
        sleepTask?.cancel()
        for task in executions.values { task.cancel() }
    }

    func update(key: QueryKey, client: QueryClient? = nil, options: QueryOptions? = nil,
                operation: @escaping @Sendable () async throws -> Value) {
        stopObserving()
        cancelRefetch()
        let previous = state
        self.key = key
        self.client = client ?? self.client
        self.options = options ?? self.options
        self.operation = operation
        initialData = nil
        state = self.options.keepPreviousData
            ? QueryState(data: previous.data, lastUpdated: previous.lastUpdated,
                         isPreviousData: previous.data != nil)
            : QueryState()
    }

    func update(from result: QueryController<Value>) {
        guard let operation = result.operation else { return }
        update(key: result.key, client: result.client, options: result.options, operation: operation)
    }

    private func connect() async throws {
        if lease != nil { return }
        let currentGeneration = generation
        if connection == nil {
            guard let operation else { throw QueryError.disposed }
            let client = client, key = key, options = options, initialData = initialData
            connection = Task {
                try Task.checkCancellation()
                return try await client.subscribe(key: key, options: options,
                                                   initialData: initialData, operation: operation)
            }
        }
        guard let connection else { return }
        let subscription: QuerySubscription<Value>
        do { subscription = try await connection.value }
        catch {
            if currentGeneration == generation { self.connection = nil }
            throw error
        }
        guard currentGeneration == generation else { throw CancellationError() }
        if lease == nil {
            lease = subscription.lease
            initialData = nil
            let stream = subscription.snapshots
            observationTask = Task { [weak self] in
                for await snapshot in stream {
                    guard !Task.isCancelled else { break }
                    self?.receive(snapshot, generation: currentGeneration)
                }
            }
            self.connection = nil
        }
    }

    private func receive(_ snapshot: QuerySnapshot<Value>, generation: Int) {
        guard generation == self.generation, snapshot.revision >= latestRevision else { return }
        latestRevision = snapshot.revision
        var next = snapshot.state
        // The initial idle snapshot may arrive after a local call has started.
        // Keep its loading indication until that call observes shared completion.
        if !executions.isEmpty {
            next.isFetching = true
            next.isLoading = next.data == nil
        }
        if !snapshot.wasRemoved, next.data == nil, state.isPreviousData, options.keepPreviousData {
            next.data = state.data
            next.lastUpdated = state.lastUpdated
            next.isPreviousData = true
            next.isLoading = false
        }
        state = next
    }

    func fetch() async { await execute(force: false) }
    func refetch() async { await execute(force: true) }

    private func execute(force: Bool) async {
        let currentGeneration = generation
        let client = client, key = key, options = options
        guard let operation else { return }
        do {
            try Task.checkCancellation()
            try await connect()
            try Task.checkCancellation()
            guard currentGeneration == generation else { return }
            if force || options.enabled {
                state.isLoading = state.data == nil
                state.isFetching = true
                let id = UUID()
                let task = Task {
                    try await client.execute(key: key, options: options, force: force, operation: operation)
                }
                executions[id] = task
                defer { executions[id] = nil }
                _ = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
            }
        } catch is CancellationError {
            if Task.isCancelled, currentGeneration == generation { stopObserving() }
        } catch {
            // Setup/type failures are local; operation failures are shared in the snapshot.
            guard currentGeneration == generation else { return }
            state.error = error
        }
        guard currentGeneration == generation else { return }
        if let snapshot = try? await client.snapshot(key, as: Value.self) {
            receive(snapshot, generation: currentGeneration)
        }
    }

    /// Detaches this observer without canceling work used by other observers.
    func stopObserving() {
        cancelRefetch()
        for task in executions.values { task.cancel() }
        executions.removeAll()
        sleepTask?.cancel()
        sleepTask = nil
        sleepID = nil
        generation += 1
        latestRevision = 0
        connection?.cancel()
        connection = nil
        observationTask?.cancel()
        observationTask = nil
        lease?.cancel()
        lease = nil
        state.isLoading = false
        state.isFetching = false
    }

    /// Releases the retained operation and previous UI data. update() can configure it again.
    func dispose() {
        cancelRefetch()
        stopObserving()
        operation = nil
        initialData = nil
        state = QueryState()
    }

    func cancel() async { await client.cancel(key) }

    /// Keeps the subscription alive for a SwiftUI .task, even without polling.
    func run() async {
        let currentGeneration = generation
        await runPeriodicRefetch()
        guard currentGeneration == generation else { return }
        if options.refetchInterval == nil, !Task.isCancelled {
            do { try await lifecycleSleep(for: .days(365 * 100)) } catch { }
        }
        if currentGeneration == generation { stopObserving() }
    }

    func runPeriodicRefetch() async {
        let currentGeneration = generation
        await fetch()
        guard currentGeneration == generation else { return }
        guard let interval = options.refetchInterval else { return }
        guard interval.seconds > 0 else {
            state.error = QueryError.invalidRefetchInterval
            return
        }
        defer { if Task.isCancelled, currentGeneration == generation { stopObserving() } }
        while !Task.isCancelled, currentGeneration == generation {
            do { try await lifecycleSleep(for: interval) } catch { return }
            guard options.enabled, currentGeneration == generation else { continue }
            await refetch()
        }
    }

    private func lifecycleSleep(for duration: CacheDuration) async throws {
        let id = UUID()
        let task = Task { try await QuerySleep.sleep(for: duration) }
        sleepID = id
        sleepTask = task
        defer {
            if sleepID == id { sleepTask = nil; sleepID = nil }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func startPeriodicRefetch() {
        guard pollingTask == nil else { return }
        let interval = options.refetchInterval
        let currentGeneration = generation
        if let interval, interval.seconds <= 0 {
            state.error = QueryError.invalidRefetchInterval
            return
        }
        let id = UUID()
        pollingID = id
        pollingTask = Task { [weak self] in
            await self?.fetch()
            guard self?.pollingID == id else { return }
            guard let interval else {
                self?.pollingID = nil
                self?.pollingTask = nil
                return
            }
            while !Task.isCancelled {
                do { try await QuerySleep.sleep(for: interval) } catch { return }
                guard let self, self.generation == currentGeneration else { return }
                if self.options.enabled { await self.refetch() }
            }
        }
    }

    func cancelRefetch() {
        pollingID = nil
        pollingTask?.cancel()
        pollingTask = nil
    }
}
