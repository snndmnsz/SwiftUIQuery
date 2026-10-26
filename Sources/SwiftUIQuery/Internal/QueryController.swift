import Foundation

/// UI state is a projection of the client's shared, revisioned query record.
@MainActor
final class QueryController<Value: Sendable> {
    private(set) var state = QueryState<Value>() {
        didSet {
            onStateChange?(state)
            // Re-evaluate a state-based interval, including a currently paused loop.
            if refetchInterval != nil { sleepTask?.cancel() }
        }
    }
    var onStateChange: (@MainActor (QueryState<Value>) -> Void)?
    private var key: QueryKey
    private var client: QueryClient
    private var options: QueryOptions
    private var refetchInterval: (@MainActor (QueryState<Value>) -> CacheDuration?)?
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
         initialData: Value? = nil,
         refetchInterval: (@MainActor (QueryState<Value>) -> CacheDuration?)? = nil,
         operation: @escaping @Sendable () async throws -> Value) {
        self.key = key
        self.client = client
        self.options = options
        self.refetchInterval = refetchInterval
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
        update(key: key, client: client, options: options,
               refetchInterval: refetchInterval, operation: operation)
    }

    func update(key: QueryKey, client: QueryClient? = nil, options: QueryOptions? = nil,
                refetchInterval: (@MainActor (QueryState<Value>) -> CacheDuration?)?,
                operation: @escaping @Sendable () async throws -> Value) {
        stopObserving()
        cancelRefetch()
        let previous = state
        self.key = key
        self.client = client ?? self.client
        self.options = options ?? self.options
        self.refetchInterval = refetchInterval
        self.operation = operation
        initialData = nil
        state = self.options.keepPreviousData
            ? QueryState(data: previous.data, lastUpdated: previous.lastUpdated,
                         isPreviousData: previous.data != nil)
            : QueryState()
    }

    func update(from result: QueryController<Value>) {
        guard let operation = result.operation else { return }
        update(key: result.key, client: result.client, options: result.options,
               refetchInterval: result.refetchInterval, operation: operation)
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

    private func execute(force: Bool, onMount: Bool = false) async {
        // A task canceled before entry has no observation ownership to release.
        guard !Task.isCancelled else { return }
        let currentGeneration = generation
        let client = client, key = key, options = options
        guard let operation else { return }
        do {
            try Task.checkCancellation()
            try await connect()
            try Task.checkCancellation()
            guard currentGeneration == generation else { return }
            if onMount, let snapshot = try await client.snapshot(key, as: Value.self) {
                guard currentGeneration == generation else { return }
                receive(snapshot, generation: currentGeneration)
                if snapshot.state.isError, !options.retryOnMount { return }
                if snapshot.state.data != nil, !options.refetchOnMount { return }
            }
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
        refetchInterval = nil
        initialData = nil
        state = QueryState()
    }

    func cancel() async { await client.cancel(key) }

    /// Keeps the subscription alive for a SwiftUI .task, even without polling.
    func run() async {
        guard !Task.isCancelled else { return }
        // SwiftUI may start a replacement before the canceled task finishes cleanup.
        // Claim a new generation before suspending so old cleanup cannot detach it.
        stopObserving()
        let currentGeneration = generation
        await poll(generation: currentGeneration)
        guard currentGeneration == generation else { return }
        if options.refetchInterval == nil, refetchInterval == nil, !Task.isCancelled {
            do { try await lifecycleSleep(for: .days(365 * 100)) } catch { }
        }
        if currentGeneration == generation { stopObserving() }
    }

    func runPeriodicRefetch() async {
        guard !Task.isCancelled else { return }
        stopObserving()
        await poll(generation: generation)
    }

    private func poll(generation currentGeneration: Int) async {
        guard !Task.isCancelled, currentGeneration == generation else { return }
        await execute(force: false, onMount: true)
        guard currentGeneration == generation else { return }
        guard options.refetchInterval != nil || refetchInterval != nil else { return }
        defer { if Task.isCancelled, currentGeneration == generation { stopObserving() } }
        while !Task.isCancelled, currentGeneration == generation {
            let interval: CacheDuration?
            do { interval = try pollingInterval() }
            catch { state.error = error; return }
            // nil disables the timer, while observation remains available to resume it.
            do { try await lifecycleSleep(for: interval) }
            catch { continue }
            guard interval != nil, options.enabled, currentGeneration == generation else { continue }
            await refetch()
        }
    }

    private func pollingInterval() throws -> CacheDuration? {
        let interval: CacheDuration?
        if let refetchInterval { interval = refetchInterval(state) }
        else { interval = options.refetchInterval }
        if let interval, interval.seconds <= 0 { throw QueryError.invalidRefetchInterval }
        return options.enabled && (refetchInterval == nil || !state.isFetching) ? interval : nil
    }

    private func beginSleep(for duration: CacheDuration?) -> (UUID, Task<Void, any Error>) {
        let id = UUID()
        let task = Task<Void, any Error> {
            if let duration { try await QuerySleep.sleep(for: duration) }
            else {
                // No timer while paused. AsyncStream cancellation wakes this wait.
                let stream = AsyncStream<Void> { _ in }
                for await _ in stream { }
                try Task.checkCancellation()
            }
        }
        sleepID = id
        sleepTask = task
        return (id, task)
    }

    private func endSleep(_ id: UUID) {
        if sleepID == id { sleepTask = nil; sleepID = nil }
    }

    private func lifecycleSleep(for duration: CacheDuration?) async throws {
        let (id, task) = beginSleep(for: duration)
        defer { endSleep(id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func startPeriodicRefetch() {
        guard pollingTask == nil else { return }
        if refetchInterval == nil, let interval = options.refetchInterval, interval.seconds <= 0 {
            state.error = QueryError.invalidRefetchInterval
            return
        }
        // cancelRefetch() cancels asynchronously; its previous fetch may still unwind.
        stopObserving()
        let currentGeneration = generation
        let id = UUID()
        pollingID = id
        pollingTask = Task { [weak self] in
            guard !Task.isCancelled, self?.pollingID == id else { return }
            await self?.execute(force: false, onMount: true)
            guard self?.pollingID == id else { return }
            defer {
                if self?.pollingID == id {
                    self?.pollingID = nil
                    self?.pollingTask = nil
                }
            }
            guard self?.options.refetchInterval != nil || self?.refetchInterval != nil else { return }
            while !Task.isCancelled, self?.generation == currentGeneration {
                let interval: CacheDuration?
                do { interval = try self?.pollingInterval() }
                catch { self?.state.error = error; return }
                // Keep only the sleep task alive across suspension, not the controller.
                guard let (sleepID, task) = self?.beginSleep(for: interval) else { return }
                do {
                    try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: { task.cancel() }
                } catch {
                    self?.endSleep(sleepID)
                    continue
                }
                self?.endSleep(sleepID)
                guard !Task.isCancelled, self?.generation == currentGeneration else { return }
                if interval != nil, self?.options.enabled == true { await self?.refetch() }
            }
        }
    }

    func cancelRefetch() {
        pollingID = nil
        pollingTask?.cancel()
        pollingTask = nil
    }
}
