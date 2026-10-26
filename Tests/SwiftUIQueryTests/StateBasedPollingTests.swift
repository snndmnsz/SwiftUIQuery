import Foundation
import Testing
@testable import SwiftUIQuery

@MainActor
private protocol PollingResult: AnyObject {
    var state: QueryState<Int> { get }
    func run() async
    func runPeriodicRefetch() async
    func startPeriodicRefetch()
    func refetch() async
    func fetch() async
    func stopObserving()
    func update(key: QueryKey, client: QueryClient?, options: QueryOptions?,
                refetchInterval: (@MainActor (QueryState<Int>) -> CacheDuration?)?,
                operation: @escaping @Sendable () async throws -> Int)
}

extension QueryResult: PollingResult where Value == Int {}
extension ObservableQueryResult: PollingResult where Value == Int {}

private enum PollingAdapter: CaseIterable, Sendable {
    case observation, combine

    @MainActor
    func make(
        client: QueryClient = QueryClient(), options: QueryOptions = QueryOptions(),
        initialData: Int? = nil,
        interval: (@MainActor (QueryState<Int>) -> CacheDuration?)? = nil,
        operation: @escaping @Sendable () async throws -> Int
    ) -> any PollingResult {
        switch self {
        case .observation:
            QueryResult(key: "polling", client: client, options: options, initialData: initialData,
                        refetchInterval: interval, operation: operation)
        case .combine:
            ObservableQueryResult(key: "polling", client: client, options: options, initialData: initialData,
                                  refetchInterval: interval, operation: operation)
        }
    }
}

private enum PollingLoop: CaseIterable, Sendable {
    case lifecycle, periodic, manual

    @MainActor
    func start(_ query: any PollingResult) -> Task<Void, Never>? {
        switch self {
        case .lifecycle: return Task { await query.run() }
        case .periodic: return Task { await query.runPeriodicRefetch() }
        case .manual:
            query.startPeriodicRefetch()
            return nil
        }
    }
}

@MainActor
@Suite("State-based polling", .timeLimit(.minutes(1)))
struct StateBasedPollingTests {
    @Test(arguments: PollingAdapter.allCases, PollingLoop.allCases)
    fileprivate func exhaustedRetriesPauseAndManualSuccessResumes(
        adapter: PollingAdapter, loop: PollingLoop
    ) async throws {
        let counter = CallCounter()
        let query = adapter.make(options: QueryOptions(retry: 2, retryDelay: .seconds(0)), interval: {
            $0.isSuccess && ($0.data ?? 0) < 6 ? .seconds(0.005) : nil
        }) {
            let call = await counter.increment()
            if call <= 3 { throw LifecycleError.rejected }
            return call
        }
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.isError && !query.state.isFetching })
        // Wait across multiple would-be ticks to prove the exhausted request stays stopped.
        try await QuerySleep.sleep(for: .seconds(0.05))
        #expect(await counter.value == 3)
        #expect(query.state.error as? LifecycleError == .rejected)
        await query.refetch()
        #expect(await eventually { query.state.data == 6 })
        try await QuerySleep.sleep(for: .seconds(0.05))
        #expect(await counter.value == 6)
        task?.cancel(); query.stopObserving()
        await task?.value
    }

    @Test(arguments: PollingAdapter.allCases, PollingLoop.allCases)
    fileprivate func refreshErrorPreservesDataAndStopsAfterItsOwnRetries(
        adapter: PollingAdapter, loop: PollingLoop
    ) async throws {
        let counter = CallCounter()
        let query = adapter.make(options: QueryOptions(retry: 2, retryDelay: .seconds(0)), interval: {
            $0.isSuccess ? .seconds(0.005) : nil
        }) {
            let call = await counter.increment()
            if call > 1 { throw LifecycleError.rejected }
            return call
        }
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.isError && !query.state.isFetching })
        try await QuerySleep.sleep(for: .seconds(0.05))
        #expect(await counter.value == 4)
        #expect(query.state.data == 1)
        task?.cancel(); query.stopObserving()
        await task?.value
    }

    @Test(arguments: PollingAdapter.allCases, PollingLoop.allCases)
    fileprivate func sharedStateChangesRescheduleAndResumePolling(
        adapter: PollingAdapter, loop: PollingLoop
    ) async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let query = adapter.make(client: client, initialData: 10, interval: {
            guard let data = $0.data, data < 10 else { return nil }
            return data == 1 ? .hours(1) : .seconds(0.005)
        }) { await counter.increment() + 9 }
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.lastUpdated != nil })
        // Resume a nil policy into a long wait, then replace that pending timer.
        try await client.setQueryData(key: "polling", data: 1)
        #expect(await eventually { query.state.data == 1 })
        try await client.setQueryData(key: "polling", data: 2)
        #expect(await eventually { query.state.data == 10 })
        #expect(await counter.value == 1)
        task?.cancel(); query.stopObserving()
        await task?.value
    }

    @Test(arguments: PollingAdapter.allCases)
    fileprivate func fixedIntervalsContinueAfterFailures(adapter: PollingAdapter) async {
        let counter = CallCounter()
        let query = adapter.make(options: QueryOptions(refetchInterval: .seconds(0.005))) {
            let call = await counter.increment()
            if call <= 2 { throw LifecycleError.rejected }
            return call
        }
        let task = Task { await query.runPeriodicRefetch() }
        #expect(await eventually { (query.state.data ?? 0) >= 3 })
        task.cancel(); await task.value
        query.stopObserving()
    }

    @Test(arguments: PollingAdapter.allCases)
    fileprivate func dynamicIntervalOverridesFixedIntervalAndRejectsZero(adapter: PollingAdapter) async {
        let query = adapter.make(options: QueryOptions(refetchInterval: .seconds(0)), interval: { _ in nil }) { 1 }
        let task = Task { await query.run() }
        #expect(await eventually { query.state.data == 1 })
        #expect(query.state.error == nil)
        task.cancel(); await task.value
        let invalid = adapter.make(interval: { _ in .seconds(0) }) { 1 }
        await invalid.runPeriodicRefetch()
        guard case .invalidRefetchInterval = invalid.state.error as? QueryError else {
            Issue.record("Expected invalid interval")
            invalid.stopObserving()
            return
        }
        invalid.stopObserving()
    }

    @Test(arguments: PollingAdapter.allCases, PollingLoop.allCases)
    fileprivate func retryOnMountControlsFailedLifecycleRestart(
        adapter: PollingAdapter, loop: PollingLoop
    ) async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let query = adapter.make(client: client, options: QueryOptions(retryOnMount: false)) {
            await counter.increment()
            throw LifecycleError.rejected
        }
        // An explicit fetch always runs, independently of the mount policy.
        await query.fetch()
        query.stopObserving()
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.isError && !query.state.isFetching })
        try await QuerySleep.sleep(for: .seconds(0.05))
        #expect(await counter.value == 1)
        await query.refetch()
        #expect(await counter.value == 2)
        task?.cancel(); query.stopObserving()
        await task?.value
    }

    @Test(arguments: PollingAdapter.allCases)
    fileprivate func refetchOnMountSkipsStaleDataButStillLoadsEmptyQueries(adapter: PollingAdapter) async {
        let counter = CallCounter()
        let options = QueryOptions(staleTime: .seconds(0), refetchOnMount: false)
        let query = adapter.make(options: options, initialData: 9) { await counter.increment() }
        await query.runPeriodicRefetch()
        #expect(query.state.data == 9)
        #expect(await counter.value == 0)
        await query.fetch()
        #expect(query.state.data == 1)
        query.stopObserving()
        let empty = adapter.make(options: options) { await counter.increment() }
        await empty.runPeriodicRefetch()
        #expect(empty.state.data == 2)
        empty.stopObserving()
    }

    @Test(arguments: PollingAdapter.allCases)
    fileprivate func defaultMountPolicyRetriesPreviousFailure(adapter: PollingAdapter) async {
        let counter = CallCounter()
        let query = adapter.make {
            let call = await counter.increment()
            if call == 1 { throw LifecycleError.rejected }
            return call
        }
        await query.fetch()
        #expect(query.state.isError)
        query.stopObserving()
        await query.runPeriodicRefetch()
        #expect(query.state.data == 2 && query.state.error == nil)
        query.stopObserving()
    }

    @Test(arguments: PollingAdapter.allCases, PollingLoop.allCases)
    fileprivate func cancelledPausedLoopCannotDetachItsReplacement(
        adapter: PollingAdapter, loop: PollingLoop
    ) async throws {
        let client = QueryClient()
        let query = adapter.make(client: client, interval: { _ in nil }) { 1 }
        let old = loop.start(query)
        #expect(await eventually { query.state.data == 1 })
        old?.cancel()
        query.stopObserving()
        let replacement = loop.start(query)
        defer { replacement?.cancel(); query.stopObserving() }
        await old?.value
        try await client.setQueryData(key: "polling", data: 42)
        #expect(await eventually { query.state.data == 42 })
        replacement?.cancel(); query.stopObserving()
        await replacement?.value
        try await client.setQueryData(key: "polling", data: 99)
        // Ensure released subscriptions cannot publish newer cache data.
        await Task.yield()
        #expect(query.state.data == 42)
    }

    @Test(arguments: PollingAdapter.allCases)
    fileprivate func updateReplacesPolicyAndDisabledQueriesStayIdle(adapter: PollingAdapter) async throws {
        let counter = CallCounter()
        let query = adapter.make(options: QueryOptions(enabled: false), initialData: 9, interval: { _ in .seconds(0.005) }) {
            await counter.increment()
        }
        let idle = Task { await query.run() }
        #expect(await eventually { query.state.lastUpdated != nil })
        await query.refetch()
        try await QuerySleep.sleep(for: .seconds(0.05))
        #expect(await counter.value == 1)
        idle.cancel(); await idle.value
        query.update(key: "updated", client: nil, options: QueryOptions(), refetchInterval: {
            ($0.data ?? 0) < 3 ? .seconds(0.005) : nil
        }) { await counter.increment() }
        let active = Task { await query.run() }
        #expect(await eventually { query.state.data == 3 })
        active.cancel(); await active.value
        query.stopObserving()
    }

    @Test func pausedManualPollingDoesNotRetainControllerAndDisposeReleasesPolicy() async {
        final class Token {}
        weak var released: Token?
        weak var controller: QueryController<Int>?
        do {
            let token = Token()
            released = token
            let query = QueryController<Int>(key: "release-policy", client: QueryClient(),
                                            refetchInterval: { [token] _ in _ = token; return nil }) { 1 }
            controller = query
            query.startPeriodicRefetch()
            #expect(await eventually { query.state.data == 1 })
        }
        #expect(await eventually { controller == nil && released == nil })
        let query = QueryController<Int>(key: "dispose-policy", client: QueryClient()) { 1 }
        do {
            let token = Token()
            released = token
            query.update(key: "dispose-policy", refetchInterval: { [token] _ in _ = token; return nil }) { 1 }
        }
        #expect(released != nil)
        query.dispose()
        #expect(released == nil)
    }


    @Test func updateRetainsCopiesAndExplicitlyClearsPolicy() async {
        let counter = CallCounter()
        let client = QueryClient()
        let query = QueryController<Int>(key: "policy", client: client, refetchInterval: {
            $0.isSuccess && ($0.data ?? 0) < 2 ? .seconds(0.005) : nil
        }) { 0 }
        query.update(key: "retained") { await counter.increment() }
        let retained = Task { await query.run() }
        #expect(await eventually { query.state.data == 2 })
        retained.cancel(); await retained.value
        let source = QueryController<Int>(key: "copied", client: client,
            refetchInterval: { $0.isSuccess && ($0.data ?? 0) < 4 ? .seconds(0.005) : nil }) {
                await counter.increment()
            }
        query.update(from: source)
        let copied = Task { await query.run() }
        #expect(await eventually { query.state.data == 4 })
        copied.cancel(); await copied.value
        query.update(key: "cleared", refetchInterval: nil) { 8 }
        // Without a policy or fixed interval this method completes after its fetch.
        await query.runPeriodicRefetch()
        #expect(query.state.data == 8)
        query.dispose(); source.dispose()
    }

}
