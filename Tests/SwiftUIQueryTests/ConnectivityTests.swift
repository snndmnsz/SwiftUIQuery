import Foundation
import Testing
@testable import SwiftUIQuery

@MainActor
private protocol ConnectivityResult: AnyObject {
    var state: QueryState<Int> { get }
    func run() async
    func runPeriodicRefetch() async
    func startPeriodicRefetch()
    func refetch() async
    func stopObserving()
}
extension QueryResult: ConnectivityResult where Value == Int {}
extension ObservableQueryResult: ConnectivityResult where Value == Int {}

private enum ConnectivityAdapter: CaseIterable, Sendable {
    case observation, combine
    @MainActor func make(
        key: QueryKey = "network", client: QueryClient, options: QueryOptions = QueryOptions(),
        interval: (@MainActor (QueryState<Int>) -> CacheDuration?)? = nil,
        operation: @escaping @Sendable () async throws -> Int
    ) -> any ConnectivityResult {
        switch self {
        case .observation:
            QueryResult(key: key, client: client, options: options, refetchInterval: interval, operation: operation)
        case .combine:
            ObservableQueryResult(key: key, client: client, options: options, refetchInterval: interval, operation: operation)
        }
    }
}
private enum ConnectivityLoop: CaseIterable, Sendable {
    case lifecycle, periodic, manual
    @MainActor func start(_ query: any ConnectivityResult) -> Task<Void, Never>? {
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
@Suite("Network recovery", .timeLimit(.minutes(1)))
struct ConnectivityTests {
    @Test(arguments: ConnectivityAdapter.allCases, ConnectivityLoop.allCases)
    fileprivate func reconnectPreservesDataAndResumesExhaustedQueryOnce(
        adapter: ConnectivityAdapter, loop: ConnectivityLoop
    ) async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let probe = ConnectivityProbe()
        let query = adapter.make(client: client, options: QueryOptions(retry: 2, retryDelay: .seconds(0), staleTime: .seconds(0), retryOnMount: false),
                                 interval: { $0.isSuccess ? .hours(1) : nil }, operation: { try await probe.fetch() })
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.data == 1 })
        await probe.setFailing(true)
        await query.refetch()
        #expect(query.state.data == 1 && query.state.isError)
        #expect(await probe.calls == 4)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 4)
        await client.setOnline(false)
        await probe.setFailing(false)
        await client.setOnline(true)
        #expect(await eventually { query.state.data == 5 && query.state.isSuccess })
        for _ in 0..<20 { await client.setOnline(true) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 5)
        task?.cancel(); query.stopObserving(); await task?.value
    }

    @Test(arguments: ConnectivityAdapter.allCases, ConnectivityLoop.allCases)
    fileprivate func successfulReconnectRestartsStateBasedPolling(adapter: ConnectivityAdapter, loop: ConnectivityLoop) async {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let probe = ConnectivityProbe(failing: true)
        let query = adapter.make(client: client, options: QueryOptions(retry: 2, retryDelay: .seconds(0)), interval: {
            $0.isSuccess && ($0.data ?? 0) < 6 ? .seconds(0.005) : nil
        }, operation: { try await probe.fetch() })
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.isError && !query.state.isFetching })
        #expect(await probe.calls == 3)
        await client.setOnline(false)
        await probe.setFailing(false)
        await client.setOnline(true)
        #expect(await eventually { query.state.data == 6 })
        task?.cancel(); query.stopObserving(); await task?.value
    }

    @Test func offlineSharedRequestWaitsWithoutSpendingRetryBudgetAndOneCancellationIsIndependent() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        await client.setOnline(false)
        let probe = ConnectivityProbe()
        let a = QueryResult(key: "shared", client: client, options: QueryOptions(retry: 2, retryDelay: .seconds(0)), operation: { try await probe.fetch() })
        let b = ObservableQueryResult(key: "shared", client: client, operation: { try await probe.fetch() })
        let first = Task { await a.run() }
        let second = Task { await b.run() }
        #expect(await eventually { a.isPaused && b.isPaused })
        #expect(await probe.calls == 0)
        #expect(a.error == nil && b.error == nil)
        #expect(!a.isFetching && !b.isFetching)
        #expect(!a.isLoading && !b.isLoading)
        #expect(a.fetchStatus == .paused && b.fetchStatus == .paused)
        first.cancel(); await first.value
        #expect(b.isPaused)
        await client.setOnline(true)
        #expect(await eventually { b.data == 1 })
        #expect(await probe.calls == 1)
        #expect(!b.isPaused)
        second.cancel(); await second.value
    }

    @Test(arguments: ConnectivityAdapter.allCases)
    fileprivate func manualRefetchJoiningPausedRequestKeepsPausedFlags(adapter: ConnectivityAdapter) async {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        await client.setOnline(false)
        let counter = CallCounter()
        let query = adapter.make(key: "paused-refetch", client: client) { await counter.increment() }
        let lifecycle = Task { await query.run() }
        defer { lifecycle.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.isPaused })

        let refresh = Task { await query.refetch() }
        defer { refresh.cancel() }
        #expect(await eventually { await client.waiterCount(for: "paused-refetch") == 2 })
        #expect(query.state.isPaused)
        #expect(query.state.fetchStatus == .paused)
        #expect(!query.state.isFetching)
        #expect(!query.state.isLoading)
        #expect(await counter.value == 0)

        await client.setOnline(true)
        await refresh.value
        #expect(await eventually { query.state.data == 1 && query.state.fetchStatus == .idle })
        #expect(await counter.value == 1)
        lifecycle.cancel()
        await lifecycle.value
    }

    @Test func inactiveDisabledFreshAndOptedOutQueriesDoNotRefetch() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let probe = ConnectivityProbe()
        let _: Int = try await client.fetch(key: "inactive", staleTime: .seconds(0), { try await probe.fetch() })
        let fresh = QueryResult(key: "fresh", client: client, options: QueryOptions(staleTime: .hours(1)), operation: { try await probe.fetch() })
        let optedOut = QueryResult(key: "opt-out", client: client, options: QueryOptions(staleTime: .seconds(0), refetchOnReconnect: false), operation: { try await probe.fetch() })
        let disabled = QueryResult(key: "disabled", client: client, options: QueryOptions(enabled: false), operation: { try await probe.fetch() })
        let a = Task { await fresh.run() }, b = Task { await optedOut.run() }, c = Task { await disabled.run() }
        #expect(await eventually { fresh.data != nil && optedOut.data != nil })
        await client.setOnline(false)
        await client.setOnline(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 3)
        #expect(disabled.data == nil)
        a.cancel(); b.cancel(); c.cancel()
        await a.value; await b.value; await c.value
    }

    @Test func reconnectWhileInactiveDoesNotOverrideRetryOnMountFalse() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let probe = ConnectivityProbe(failing: true)
        let query = QueryResult(key: "remount", client: client, options: QueryOptions(retryOnMount: false), operation: { try await probe.fetch() })
        let first = Task { await query.run() }
        #expect(await eventually { query.isError })
        first.cancel(); await first.value
        await client.setOnline(false)
        await probe.setFailing(false)
        await client.setOnline(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 1)
        let second = Task { await query.run() }
        #expect(await eventually { query.isError })
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 1)
        await query.refetch()
        #expect(query.data == 2)
        second.cancel(); await second.value
    }

    @Test(arguments: [true, false])
    func reconnectDuringFinalAttemptDoesNotCreateAnExtraRetryBatch(fails: Bool) async {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let gate = TestGate()
        let counter = CallCounter()
        let query = QueryResult(key: "race", client: client) {
            let count = await counter.increment()
            if count == 1 {
                await gate.pause()
                if fails { throw LifecycleError.rejected }
            }
            return count
        }
        let task = Task { await query.run() }
        await gate.waitForStart()
        await client.setOnline(false)
        await client.setOnline(true)
        await gate.release()
        #expect(await eventually { fails ? query.isError : query.data == 1 })
        #expect(await counter.value == 1)
        task.cancel(); await task.value
    }

    @Test func reconnectResumesRemainingRetriesWithoutCreatingAnExtraBatch() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let counter = CallCounter()
        let query = QueryResult(key: "retry-budget", client: client,
            options: QueryOptions(retry: 2, retryDelay: .seconds(0.05))) {
            _ = await counter.increment()
            throw LifecycleError.rejected
        } as QueryResult<Int>
        let task = Task { await query.run() }
        #expect(await eventually { await counter.value == 1 })
        await client.setOnline(false)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await counter.value == 1)
        #expect(query.isPaused)
        await client.setOnline(true)
        #expect(await eventually { query.isError && !query.isFetching })
        try await Task.sleep(for: .milliseconds(120))
        #expect(await counter.value == 3)
        task.cancel(); await task.value
    }

    @Test func localOperationsCanOptOutAndFreshCacheWorksOffline() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        await client.setOnline(false)
        let value: Int = try await client.fetch(key: "local", networkMode: .always) { 42 }
        #expect(value == 42)
        let cached: Int = try await client.fetch(key: "local") { 99 }
        #expect(cached == 42)
    }

    @Test func cancellingLastOfflineConsumerReleasesClientWithoutRunningOperation() async throws {
        let probe = ConnectivityProbe()
        weak var released: QueryClient?
        do {
            let client = QueryClient(automaticallyMonitorsNetwork: false)
            released = client
            await client.setOnline(false)
            let task = Task { try await client.fetch(key: "cancelled", { try await probe.fetch() }) }
            #expect(await eventually { await client.waiterCount(for: "cancelled") == 1 })
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(await eventually { released == nil })
        #expect(await probe.calls == 0)
    }

    @Test func automaticNetworkMonitoringDoesNotRetainClient() async throws {
        weak var released: QueryClient?
        do {
            let client = QueryClient()
            released = client
            // Exercise the system subscription without depending on the host's path.
            let value: Int = try await client.fetch(key: "monitored", networkMode: .always) { 42 }
            #expect(value == 42)
        }
        #expect(await eventually { released == nil })
    }

    @Test func explicitlyCancellingSharedOfflineRequestResumesEveryWaiter() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        await client.setOnline(false)
        let counter = CallCounter()
        let first = Task { try await client.fetch(key: "cancel-shared") { await counter.increment() } }
        let second = Task { try await client.fetch(key: "cancel-shared") { await counter.increment() } }
        defer { first.cancel(); second.cancel() }
        #expect(await eventually { await client.waiterCount(for: "cancel-shared") == 2 })

        await client.cancel("cancel-shared")
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await client.waiterCount(for: "cancel-shared") == 0)
        #expect(try await client.snapshot("cancel-shared", as: Int.self)?.state.fetchStatus == .idle)
        await client.setOnline(true)
        #expect(await counter.value == 0)
    }

    @Test(arguments: ConnectivityAdapter.allCases, ConnectivityLoop.allCases)
    fileprivate func optionalFallbackRecoversWithoutPathChangeThenStopsOnSuccess(
        adapter: ConnectivityAdapter, loop: ConnectivityLoop
    ) async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let probe = ConnectivityProbe(failing: true)
        let query = adapter.make(client: client,
            options: QueryOptions(retry: 2, retryDelay: .seconds(0)),
            interval: { $0.isError ? .seconds(0.1) : nil }, operation: { try await probe.fetch() })
        let task = loop.start(query)
        defer { task?.cancel(); query.stopObserving() }
        #expect(await eventually { query.state.isError && !query.state.isFetching })
        #expect(await probe.calls == 3)
        await probe.setFailing(false)
        #expect(await eventually { query.state.data == 4 })
        try await Task.sleep(for: .milliseconds(120))
        #expect(await probe.calls == 4)
        task?.cancel(); query.stopObserving(); await task?.value
    }

    @Test func offlineFirstUsesLocalCacheButPausesRetriesAfterCacheMiss() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        await client.setOnline(false)
        let cached: Int = try await client.fetch(key: "cache-hit", networkMode: .offlineFirst) { 42 }
        #expect(cached == 42)
        let counter = CallCounter()
        let query = QueryResult<Int>(key: "cache-miss", client: client,
            options: QueryOptions(retry: 2, retryDelay: .seconds(0), networkMode: .offlineFirst)) {
            let count = await counter.increment()
            if count == 1 { throw LifecycleError.rejected }
            return count
        }
        let task = Task { await query.run() }
        #expect(await eventually { query.isPaused })
        #expect(await counter.value == 1)
        #expect(!query.isFetching && query.fetchStatus == .paused)
        await client.setOnline(true)
        #expect(await eventually { query.data == 2 && query.fetchStatus == .idle })
        task.cancel(); await task.value
    }

    @Test func pausedRequestContinuesEvenWhenAutomaticRefetchIsDisabled() async {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        await client.setOnline(false)
        let counter = CallCounter()
        let query = QueryResult(key: "resume-only", client: client,
            options: QueryOptions(refetchOnReconnect: false)) { await counter.increment() }
        let task = Task { await query.run() }
        #expect(await eventually { query.isPaused })
        await client.setOnline(true)
        #expect(await eventually { query.data == 1 })
        #expect(await counter.value == 1)
        task.cancel(); await task.value
    }

    @Test func freshCachedDataIsNotRefetchedOnReconnectEvenAfterRefreshError() async throws {
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let probe = ConnectivityProbe()
        let query = QueryResult(key: "fresh-error", client: client,
            options: QueryOptions(staleTime: .hours(1))) { try await probe.fetch() }
        let task = Task { await query.run() }
        #expect(await eventually { query.data == 1 })
        await probe.setFailing(true)
        await query.refetch()
        #expect(query.isError && query.data == 1)
        await client.setOnline(false)
        await client.setOnline(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 2)
        task.cancel(); await task.value
    }

    @Test func alwaysModeDefaultsToNoReconnectButCanExplicitlyOptIn() async {
        #expect(!QueryOptions(networkMode: .always).refetchOnReconnect)
        #expect(QueryOptions(networkMode: .offlineFirst).refetchOnReconnect)
        let client = QueryClient(automaticallyMonitorsNetwork: false)
        let counter = CallCounter()
        let query = QueryResult(key: "always-opt-in", client: client,
            options: QueryOptions(staleTime: .seconds(0), refetchOnReconnect: true, networkMode: .always)) {
            await counter.increment()
        }
        let task = Task { await query.run() }
        #expect(await eventually { query.data == 1 })
        await client.setOnline(false)
        await client.setOnline(true)
        #expect(await eventually { query.data == 2 })
        task.cancel(); await task.value
    }

}

private actor ConnectivityProbe {
    private(set) var calls = 0
    private var failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    func setFailing(_ value: Bool) { failing = value }
    func fetch() throws -> Int {
        calls += 1
        if failing { throw LifecycleError.rejected }
        return calls
    }
}
