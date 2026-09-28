import Foundation

/// Actor-isolated shared query state, request coordination, and cache lifetime.
public actor QueryClient {
    public static let shared = QueryClient()
    private var records: [QueryKey: QueryRecord] = [:]
    private var revision: UInt64 = 0

    public init() {}

    deinit {
        for record in records.values {
            record.task?.cancel()
            record.gcTask?.cancel()
            record.staleTask?.cancel()
        }
    }

    public func fetch<Value: Sendable>(
        key: QueryKey,
        cacheTime: CacheDuration = .default,
        staleTime: CacheDuration? = nil,
        gcTime: CacheDuration = .default,
        enabled: Bool = true,
        retry: Int = 0,
        retryDelay: CacheDuration = .seconds(1),
        exponentialBackoff: Bool = false,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        // The throwing imperative API cannot represent an idle result without data.
        // Disabled observable queries instead expose an ordinary idle snapshot.
        guard enabled else { throw QueryError.disabled(key) }
        return try await execute(key: key, options: QueryOptions(
            cacheTime: cacheTime, retry: retry, retryDelay: retryDelay,
            exponentialBackoff: exponentialBackoff, staleTime: staleTime, gcTime: gcTime
        ), force: false, operation: operation)
    }

    func execute<Value: Sendable>(
        key: QueryKey, options: QueryOptions, force: Bool,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try configure(key, type: Value.self, options: options, operation: operation)
        if !force, let record = records[key], record.hasValue, !record.isStale,
           let value = record.value as? Value {
            scheduleGC(key)
            return value
        }
        start(key)
        let value = try await wait(key)
        guard let typed = value as? Value else { throw mismatch(key, Value.self) }
        return typed
    }

    private func validate<Value>(_ key: QueryKey, _ type: Value.Type) throws {
        if let record = records[key], record.type != type { throw mismatch(key, type) }
    }

    private func mismatch<Value>(_ key: QueryKey, _ type: Value.Type) -> QueryError {
        .typeMismatch(key: key, expected: String(describing: type))
    }

    private func configure<Value: Sendable>(
        _ key: QueryKey, type: Value.Type, options: QueryOptions,
        operation: @escaping @Sendable () async throws -> Value
    ) throws {
        try validate(key, type)
        var record = records[key] ?? QueryRecord(type: type)
        record.options = options
        record.wasRemoved = false
        record.operation = { try await operation() }
        records[key] = record
    }

    private func start(_ key: QueryKey) {
        guard var record = records[key], record.requestID == nil,
              let operation = record.operation else { return }
        record.gcTask?.cancel()
        record.gcTask = nil
        record.gcID = nil
        let id = UUID()
        let options = record.options
        record.requestID = id
        record.requestStaleTime = options.staleTime
        record.task = Task { [weak self] in
            let result: Result<any Sendable, any Error>
            do {
                let value = try await QueryExecutionContext.$currentKey.withValue(key) {
                    try await Self.runWithRetry(options: options, operation: operation)
                }
                try Task.checkCancellation()
                result = .success(value)
            } catch { result = .failure(error) }
            await self?.complete(key, id: id, result: result)
        }
        records[key] = record
        publish(key)
    }

    private func wait(_ key: QueryKey) async throws -> any Sendable {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if records[key]?.requestID != nil {
                    records[key]?.waiters[waiterID] = continuation
                } else if let record = records[key], record.hasValue, let value = record.value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: records[key]?.error ?? QueryError.missingOperation(key))
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelWaiter(key, id: waiterID) }
        }
    }

    private func cancelWaiter(_ key: QueryKey, id: UUID) {
        guard let waiter = records[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if let record = records[key], record.waiters.isEmpty, !record.isActive {
            cancelRequest(key)
        }
    }

    private func complete(_ key: QueryKey, id: UUID, result: Result<any Sendable, any Error>) {
        guard var record = records[key], record.requestID == id else { return }
        let waiters = record.waiters.values
        record.waiters.removeAll()
        record.task = nil
        record.requestID = nil
        switch result {
        case .success(let value):
            record.value = value
            record.hasValue = true
            record.updatedAt = .now
            record.freshUntil = record.requestStaleTime.adding(to: record.updatedAt!)
            record.invalidated = false
            record.error = nil
            record.dataID = UUID()
        case .failure(let error):
            if !(error is CancellationError) { record.error = error }
        }
        records[key] = record
        publish(key)
        scheduleGC(key)
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func cancelRequest(_ key: QueryKey) {
        guard var record = records[key], record.requestID != nil else { return }
        record.task?.cancel()
        record.task = nil
        record.requestID = nil
        let waiters = record.waiters.values
        record.waiters.removeAll()
        records[key] = record
        publish(key)
        scheduleGC(key)
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    /// Explicitly cancels shared work and resumes all waiters immediately.
    public func cancel(_ key: QueryKey) { cancelRequest(key) }
    public func cancelAll() { for key in Array(records.keys) { cancelRequest(key) } }

    public func prefetch<Value: Sendable>(
        key: QueryKey, cacheTime: CacheDuration = .default,
        staleTime: CacheDuration? = nil, gcTime: CacheDuration = .default,
        retry: Int = 0, retryDelay: CacheDuration = .seconds(1),
        exponentialBackoff: Bool = false,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async {
        _ = try? await fetch(key: key, cacheTime: cacheTime, staleTime: staleTime,
                            gcTime: gcTime, retry: retry, retryDelay: retryDelay,
                            exponentialBackoff: exponentialBackoff, operation)
    }

    public func refetch<Value: Sendable>(key: QueryKey) async throws -> Value {
        try Task.checkCancellation()
        try validate(key, Value.self)
        guard records[key]?.operation != nil else { throw QueryError.missingOperation(key) }
        start(key)
        let value = try await wait(key)
        guard let typed = value as? Value else { throw mismatch(key, Value.self) }
        return typed
    }

    /// Marks data stale, cancels superseded work, and awaits enabled observers' refresh.
    public func invalidate(_ key: QueryKey, refetchActive: Bool = true) async {
        await invalidateKeys([key], refetchActive: refetchActive)
    }
    public func invalidateAll(refetchActive: Bool = true) async {
        await invalidateKeys(Array(records.keys), refetchActive: refetchActive)
    }
    /// Prefix matching uses the raw key string. Include a separator, e.g. "todos/".
    public func invalidate(prefix: String, refetchActive: Bool = true) async {
        await invalidateKeys(records.keys.filter { $0.rawValue.hasPrefix(prefix) }, refetchActive: refetchActive)
    }

    private func invalidateKeys(_ keys: [QueryKey], refetchActive: Bool) async {
        var refreshing: [QueryKey] = []
        for key in keys {
            guard records[key] != nil else { continue }
            cancelRequest(key)
            records[key]?.invalidated = true
            publish(key)
            if refetchActive, records[key]?.isActive == true, records[key]?.operation != nil {
                start(key)
                refreshing.append(key)
            } else { scheduleGC(key) }
        }
        // Every request was started before awaiting, so different keys run concurrently.
        for key in refreshing { _ = try? await wait(key) }
    }

    /// Clears data and operation; active subscriptions remain attached to the empty key.
    public func remove(_ key: QueryKey) {
        cancelRequest(key)
        guard let record = records[key] else { return }
        record.gcTask?.cancel()
        record.staleTask?.cancel()
        if record.observers.isEmpty {
            records[key] = nil
        } else {
            var empty = QueryRecord(type: record.type)
            empty.wasRemoved = true
            empty.options = record.options
            empty.observers = record.observers
            records[key] = empty
            publish(key)
        }
    }
    public func removeAll() { for key in Array(records.keys) { remove(key) } }
    public func clear() { removeAll() }

    public func getQueryData<Value: Sendable>(key: QueryKey, as type: Value.Type = Value.self) throws -> Value? {
        try validate(key, type)
        guard let record = records[key], record.hasValue else { return nil }
        return record.value as? Value
    }

    public func setQueryData<Value: Sendable>(key: QueryKey, data: Value, gcTime: CacheDuration = .default) throws {
        try validate(key, Value.self)
        cancelRequest(key)
        var record = records[key] ?? QueryRecord(type: Value.self)
        if records[key] == nil { record.options.gcTime = gcTime }
        record.wasRemoved = false
        record.value = data
        record.hasValue = true
        record.updatedAt = .now
        record.freshUntil = record.options.staleTime.adding(to: record.updatedAt!)
        record.invalidated = false
        record.error = nil
        record.dataID = UUID()
        records[key] = record
        publish(key)
        scheduleGC(key)
    }

    /// Atomic read/modify/write; the updater executes on the client actor without suspension.
    public func setQueryData<Value: Sendable>(
        key: QueryKey, as type: Value.Type = Value.self,
        update: @Sendable (Value?) throws -> Value
    ) throws {
        let previous = try getQueryData(key: key, as: type)
        try setQueryData(key: key, data: update(previous))
    }

    /// Saves only prior data state, never observer or operation closures.
    public func optimisticUpdate<Value: Sendable>(
        key: QueryKey, as type: Value.Type = Value.self,
        update: @Sendable (Value?) throws -> Value
    ) throws -> QueryRollback {
        let previous = try getQueryData(key: key, as: type)
        let old = records[key]
        let snapshot = RollbackSnapshot(value: old?.value, hasValue: old?.hasValue ?? false,
                                        error: old?.error, updatedAt: old?.updatedAt, freshUntil: old?.freshUntil,
                                        invalidated: old?.invalidated ?? false)
        try setQueryData(key: key, data: update(previous))
        let dataID = records[key]!.dataID
        return QueryRollback { [weak self] in
            await self?.restore(key, dataID: dataID, snapshot: snapshot) ?? false
        }
    }

    private func restore(_ key: QueryKey, dataID: UUID, snapshot: RollbackSnapshot) -> Bool {
        guard var record = records[key], record.dataID == dataID else { return false }
        cancelRequest(key)
        // cancelRequest changes task state, so load it again before restoring data.
        record = records[key]!
        record.value = snapshot.value
        record.hasValue = snapshot.hasValue
        record.error = snapshot.error
        record.updatedAt = snapshot.updatedAt
        record.freshUntil = snapshot.freshUntil
        record.invalidated = snapshot.invalidated
        record.dataID = UUID()
        records[key] = record
        publish(key)
        scheduleGC(key)
        return true
    }

    func subscribe<Value: Sendable>(
        key: QueryKey, options: QueryOptions, initialData: Value?,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> QuerySubscription<Value> {
        try validate(key, Value.self)
        if options.enabled {
            try configure(key, type: Value.self, options: options, operation: operation)
        } else if records[key] == nil {
            var record = QueryRecord(type: Value.self)
            record.options = options
            records[key] = record
        }
        if let initialData, records[key]?.hasValue == false, records[key]?.requestID == nil {
            try setQueryData(key: key, data: initialData, gcTime: options.gcTime)
        }
        let id = UUID()
        var continuation: AsyncStream<QuerySnapshot<Value>>.Continuation!
        let stream = AsyncStream<QuerySnapshot<Value>>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        let sink = continuation!
        sink.onTermination = { [weak self] _ in Task { await self?.unsubscribe(key, id: id) } }
        records[key]?.gcTask?.cancel()
        records[key]?.gcTask = nil
        records[key]?.gcID = nil
        records[key]?.observers[id] = QueryObserver(enabled: options.enabled) { record in
            sink.yield(QuerySnapshot<Value>(record))
        }
        publish(key)
        let lease = QueryLease { [weak self] in
            sink.finish()
            Task { await self?.unsubscribe(key, id: id) }
        }
        return QuerySubscription(snapshots: stream, lease: lease)
    }

    private func unsubscribe(_ key: QueryKey, id: UUID) {
        guard records[key]?.observers.removeValue(forKey: id) != nil else { return }
        if let record = records[key], record.observers.isEmpty, record.waiters.isEmpty {
            cancelRequest(key)
        }
        scheduleStaleness(key)
        scheduleGC(key)
    }

    func snapshot<Value: Sendable>(_ key: QueryKey, as type: Value.Type) throws -> QuerySnapshot<Value>? {
        try validate(key, type)
        return records[key].map(QuerySnapshot<Value>.init)
    }

    func waiterCount(for key: QueryKey) -> Int { records[key]?.waiters.count ?? 0 }

    private func publish(_ key: QueryKey) {
        guard records[key] != nil else { return }
        revision &+= 1
        records[key]?.revision = revision
        guard let record = records[key] else { return }
        for observer in record.observers.values { observer.receive(record) }
        scheduleStaleness(key)
    }

    private func scheduleStaleness(_ key: QueryKey) {
        guard var record = records[key] else { return }
        record.staleTask?.cancel()
        record.staleTask = nil
        if !record.observers.isEmpty, !record.isStale, let deadline = record.freshUntil {
            let dataID = record.dataID
            let delay = CacheDuration.seconds(deadline.timeIntervalSinceNow)
            record.staleTask = Task { [weak self] in
                do { try await QuerySleep.sleep(for: delay) } catch { return }
                await self?.becameStale(key, dataID: dataID)
            }
        }
        records[key] = record
    }

    private func becameStale(_ key: QueryKey, dataID: UUID) {
        guard records[key]?.dataID == dataID else { return }
        publish(key)
    }

    private func scheduleGC(_ key: QueryKey) {
        guard var record = records[key], record.observers.isEmpty, record.requestID == nil else { return }
        record.gcTask?.cancel()
        let id = UUID()
        let duration = record.options.gcTime
        record.gcID = id
        record.gcTask = Task { [weak self] in
            do { try await QuerySleep.sleep(for: duration) } catch { return }
            await self?.collect(key, id: id)
        }
        records[key] = record
    }

    private func collect(_ key: QueryKey, id: UUID) {
        guard let record = records[key], record.gcID == id,
              record.observers.isEmpty, record.requestID == nil else { return }
        record.staleTask?.cancel()
        records[key] = nil
    }

    private static func runWithRetry(
        options: QueryOptions,
        operation: @escaping @Sendable () async throws -> any Sendable
    ) async throws -> any Sendable {
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                return try await operation()
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard attempt < options.retry else { throw error }
                attempt += 1
                let multiplier = options.exponentialBackoff ? pow(2, Double(attempt - 1)) : 1
                try await QuerySleep.sleep(for: .seconds(options.retryDelay.seconds * multiplier))
            }
        }
    }
}

private struct RollbackSnapshot: Sendable {
    let value: (any Sendable)?
    let hasValue: Bool
    let error: (any Error)?
    let updatedAt: Date?
    let freshUntil: Date?
    let invalidated: Bool
}
