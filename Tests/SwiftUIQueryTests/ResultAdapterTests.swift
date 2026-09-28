import Combine
import Observation
import Testing
@testable import SwiftUIQuery

@MainActor
private protocol IntegerResult: AnyObject {
    var data: Int? { get }
    var error: (any Error)? { get }
    var isLoading: Bool { get }
    var isFetching: Bool { get }
    func fetch() async
    func refetch() async
    func update(
        key: QueryKey,
        client: QueryClient?,
        options: QueryOptions?,
        operation: @escaping @Sendable () async throws -> Int
    )
    func runPeriodicRefetch() async
}

@available(iOS 17, macOS 14, *)
extension QueryResult: IntegerResult where Value == Int {}
extension ObservableQueryResult: IntegerResult where Value == Int {}

private enum Adapter: CaseIterable, Sendable {
    case observation, combine

    @available(iOS 17, macOS 14, *)
    @MainActor
    func make(
        options: QueryOptions = QueryOptions(),
        initialData: Int? = nil,
        operation: @escaping @Sendable () async throws -> Int
    ) -> any IntegerResult {
        switch self {
        case .observation:
            QueryResult(key: "result", client: QueryClient(), options: options,
                        initialData: initialData, operation: operation)
        case .combine:
            ObservableQueryResult(key: "result", client: QueryClient(), options: options,
                                  initialData: initialData, operation: operation)
        }
    }
}

@MainActor
@Suite("Result adapter parity")
struct ResultAdapterTests {
    @available(iOS 17, *)
    @Test(arguments: Adapter.allCases)
    fileprivate func exposesLoadingAndCompletion(_ adapter: Adapter) async {
        let gate = OperationGate()
        let result = adapter.make {
            await gate.suspend()
            return 42
        }
        let task = Task { await result.fetch() }
        await gate.waitUntilStarted()
        #expect(result.isLoading)
        #expect(result.isFetching)
        #expect(result.data == nil)
        await gate.release()
        await task.value
        #expect(result.data == 42)
        #expect(!result.isLoading)
        #expect(!result.isFetching)
        #expect(result.error == nil)
    }

    @available(iOS 17, *)
    @Test(arguments: Adapter.allCases)
    fileprivate func ignoresCompletionFromPreviousKey(_ adapter: Adapter) async {
        let gate = OperationGate()
        let result = adapter.make {
            await gate.suspend()
            return 1
        }
        let first = Task { await result.fetch() }
        await gate.waitUntilStarted()
        result.update(key: "new-key", client: nil, options: nil) { 2 }
        await result.fetch()
        await gate.release()
        await first.value
        #expect(result.data == 2)
        #expect(!result.isFetching)
    }

    @available(iOS 17, *)
    @Test(arguments: Adapter.allCases)
    fileprivate func refetchFailureKeepsData(_ adapter: Adapter) async {
        let scenario = FailingAfterFirstSuccess()
        let result = adapter.make { try await scenario.next() }
        await result.fetch()
        await result.refetch()
        #expect(result.data == 10)
        #expect(result.error != nil)
        #expect(!result.isFetching)
    }

    @available(iOS 17, *)
    @Test(arguments: Adapter.allCases)
    fileprivate func disablingDoesNotRunOperation(_ adapter: Adapter) async {
        let counter = CallCounter()
        let result = adapter.make(options: QueryOptions(enabled: false), initialData: 9) {
            await counter.increment()
        }
        await result.fetch()
        #expect(await counter.value == 0)
        #expect(result.data == 9)
        #expect(result.error == nil)
        #expect(!result.isLoading && !result.isFetching)
    }

    @available(iOS 17, *)
    @Test(arguments: Adapter.allCases)
    fileprivate func updateCanKeepOrClearData(_ adapter: Adapter) async {
        let result = adapter.make { 1 }
        await result.fetch()
        result.update(key: "second", client: nil, options: nil) { 2 }
        #expect(result.data == 1)
        await result.fetch()
        #expect(result.data == 2)
        result.update(key: "third", client: nil,
                      options: QueryOptions(keepPreviousData: false)) { 3 }
        #expect(result.data == nil)
        await result.fetch()
        #expect(result.data == 3)
    }

    @available(iOS 17, *)
    @Test(arguments: Adapter.allCases)
    fileprivate func periodicLoopHonorsCancellation(_ adapter: Adapter) async {
        let gate = OperationGate()
        let result = adapter.make(options: QueryOptions(refetchInterval: .hours(1))) {
            await gate.suspend()
            return 4
        }
        let loop = Task { await result.runPeriodicRefetch() }
        await gate.waitUntilStarted()
        loop.cancel()
        await gate.release()
        await loop.value
        #expect(result.error == nil)
        #expect(!result.isFetching)
    }

    @available(iOS 17, *)
    @Test func observationStillNotifiesReaders() async {
        let result = QueryResult<Int>(key: "observation", client: QueryClient()) { 1 }
        await confirmation("Observation notifies the view") { changed in
            withObservationTracking {
                _ = result.isFetching
            } onChange: {
                changed()
            }
            await result.fetch()
        }
        #expect(result.data == 1)
    }
}

@MainActor
@Suite("iOS 15 observable result")
struct ObservableQueryResultTests {
    @Test func publishesStateChanges() async {
        let result = ObservableQueryResult<Int>(key: "combine", client: QueryClient()) { 42 }
        var states: [QueryState<Int>] = []
        let subscription = result.$state.sink { states.append($0) }
        await result.fetch()
        #expect(states.contains { $0.isLoading && $0.isFetching })
        #expect(states.last?.data == 42)
        #expect(states.last?.isFetching == false)
        withExtendedLifetime(subscription) {}
    }

    @Test func releasesResultAndPeriodicTask() {
        weak var released: ObservableQueryResult<Int>?
        do {
            let result = ObservableQueryResult<Int>(
                key: "lifetime", client: QueryClient(),
                options: QueryOptions(refetchInterval: .hours(1))
            ) { 1 }
            released = result
            result.startPeriodicRefetch()
        }
        #expect(released == nil)
    }

    @Test func copiesConfigurationWithoutCopyingState() async {
        let client = QueryClient()
        let source = ObservableQueryResult<Int>(key: "source", client: client,
                                                initialData: 7) { 8 }
        let target = ObservableQueryResult<Int>(key: "target", client: client,
                                                initialData: 3) { 4 }
        target.update(from: source)
        #expect(target.data == 3)
        await target.fetch()
        #expect(target.data == 8)
        #expect(source.data == 7)
    }
}

private actor OperationGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
