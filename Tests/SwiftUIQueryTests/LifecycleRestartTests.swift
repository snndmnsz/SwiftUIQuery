import Foundation
import Testing
@testable import SwiftUIQuery

@MainActor
private protocol RestartResult: AnyObject {
    var data: Int? { get }
    var isFetching: Bool { get }
    func run() async
    func fetch() async
    func runPeriodicRefetch() async
    func startPeriodicRefetch()
    func cancelRefetch()
    func stopObserving()
}

@available(iOS 17, macOS 14, *)
extension QueryResult: RestartResult where Value == Int {}
extension ObservableQueryResult: RestartResult where Value == Int {}

private enum RestartAdapter: CaseIterable, Sendable {
    case observation, combine

    @available(iOS 17, macOS 14, *)
    @MainActor
    func make(client: QueryClient, interval: CacheDuration? = nil,
              operation: @escaping @Sendable () async throws -> Int) -> any RestartResult {
        let options = QueryOptions(refetchInterval: interval)
        switch self {
        case .observation:
            return QueryResult(key: "restart", client: client, options: options, operation: operation)
        case .combine:
            return ObservableQueryResult(key: "restart", client: client, options: options, operation: operation)
        }
    }
}

private enum RestartLoop: CaseIterable, Sendable {
    case lifecycle, periodic

    @MainActor
    func run(_ result: any RestartResult) async {
        switch self {
        case .lifecycle: await result.run()
        case .periodic: await result.runPeriodicRefetch()
        }
    }
}

@MainActor
@Suite("Query lifecycle replacement", .timeLimit(.minutes(1)))
struct LifecycleRestartTests {
    @available(iOS 17, *)
    @Test(arguments: RestartAdapter.allCases)
    fileprivate func manualPollingCanRestartBeforeItsTaskBegins(adapter: RestartAdapter) async {
        let counter = CallCounter()
        let query = adapter.make(client: QueryClient(), interval: .seconds(0.01)) {
            await counter.increment()
        }
        // No suspension: both tasks are enqueued before either can enter fetch().
        query.startPeriodicRefetch()
        query.cancelRefetch()
        query.startPeriodicRefetch()
        #expect(await eventually { (query.data ?? 0) >= 2 })
        query.stopObserving()
    }

    @available(iOS 17, *)
    @Test(arguments: RestartAdapter.allCases)
    fileprivate func cancelledFetchDoesNotDetachActiveLifecycle(adapter: RestartAdapter) async throws {
        let client = QueryClient()
        let query = adapter.make(client: client) { 1 }
        let active = Task { await query.run() }
        #expect(await eventually { query.data == 1 })
        let cancelled = Task { await query.fetch() }
        cancelled.cancel()
        await cancelled.value
        try await client.setQueryData(key: "restart", data: 2)
        #expect(await eventually { query.data == 2 })
        active.cancel()
        await active.value
        query.stopObserving()
    }

    @available(iOS 17, *)
    @Test(arguments: RestartAdapter.allCases, RestartLoop.allCases)
    fileprivate func immediateRestartKeepsReplacementSubscribed(
        adapter: RestartAdapter, loop: RestartLoop
    ) async throws {
        let client = QueryClient()
        let gate = TestGate()
        let query = adapter.make(client: client, interval: .hours(1)) {
            await gate.pause()
            return 1
        }
        let old = Task { await loop.run(query) }
        await gate.waitForStart()
        old.cancel()
        var replacementEnded = false
        let replacement = Task {
            await loop.run(query)
            replacementEnded = true
        }
        await gate.release()
        await old.value
        #expect(await eventually { query.data == 1 || replacementEnded })
        // A cache write after the old task finished proves the new subscription survived.
        try await client.setQueryData(key: "restart", data: 42)
        #expect(await eventually { query.data == 42 || replacementEnded })
        #expect(query.data == 42)
        #expect(!replacementEnded)
        replacement.cancel()
        await replacement.value
        #expect(!query.isFetching)
    }

    @available(iOS 17, *)
    @Test(arguments: RestartAdapter.allCases)
    fileprivate func manualPollingCanRestartDuringInitialFetch(adapter: RestartAdapter) async {
        let gate = TestGate()
        let counter = CallCounter()
        let query = adapter.make(client: QueryClient(), interval: .seconds(0.01)) {
            let value = await counter.increment()
            if value == 1 { await gate.pause() }
            return value
        }
        query.startPeriodicRefetch()
        await gate.waitForStart()
        query.cancelRefetch()
        query.startPeriodicRefetch()
        await gate.release()
        #expect(await eventually { (query.data ?? 0) >= 2 })
        query.stopObserving()
        #expect(!query.isFetching)
    }

    @available(iOS 17, *)
    @Test(arguments: RestartAdapter.allCases, RestartLoop.allCases)
    fileprivate func alreadyCancelledCallerDoesNotDetachActiveLifecycle(
        adapter: RestartAdapter, loop: RestartLoop
    ) async throws {
        let client = QueryClient()
        let query = adapter.make(client: client, interval: .hours(1)) { 1 }
        let active = Task { await query.run() }
        #expect(await eventually { query.data == 1 })
        // MainActor ordering guarantees cancellation before this task enters the API.
        let cancelled = Task { await loop.run(query) }
        cancelled.cancel()
        await cancelled.value
        try await client.setQueryData(key: "restart", data: 2)
        #expect(await eventually { query.data == 2 })
        active.cancel()
        await active.value
        query.stopObserving()
    }
}
