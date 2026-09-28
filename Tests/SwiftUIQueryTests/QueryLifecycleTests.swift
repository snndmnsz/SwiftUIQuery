import Foundation
import Testing
@testable import SwiftUIQuery

actor TestGate {
    private var started = false
    private var opened = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        started = true
        starters.forEach { $0.resume() }; starters.removeAll()
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { starters.append($0) }
    }
    func release() {
        opened = true
        waiting.forEach { $0.resume() }; waiting.removeAll()
    }
}

@MainActor
func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date.now.addingTimeInterval(3)
    while Date.now < deadline {
        if await predicate() { return true }
        await Task.yield()
    }
    return await predicate()
}

@Suite("Shared query lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct QueryLifecycleTests {
    @Test func sharedResultsReceiveRefetchAndSetData() async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let a = QueryResult<Int>(key: "shared", client: client) { await counter.increment() }
        let b = ObservableQueryResult<Int>(key: "shared", client: client) { await counter.increment() }
        await a.fetch(); await b.fetch()
        #expect(a.data == 1 && b.data == 1)
        await a.refetch()
        #expect(await eventually { b.data == 2 })
        try await client.setQueryData(key: "shared", data: 3)
        #expect(await eventually { a.data == 3 && b.data == 3 })
        a.dispose(); b.dispose()
    }

    @Test func activeInvalidationRefetchesButDisabledObserverStaysIdle() async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let active = ObservableQueryResult<Int>(key: "items/1", client: client) { await counter.increment() }
        let disabled = ObservableQueryResult<Int>(key: "items/2", client: client,
                                                 options: QueryOptions(enabled: false)) { 99 }
        await active.fetch(); await disabled.fetch()
        await client.invalidate(prefix: "items/")
        #expect(await eventually { active.data == 2 })
        #expect(disabled.data == nil && disabled.error == nil)
        #expect(!disabled.isFetching)
        // Manual refetch is allowed even before the first enabled fetch.
        await disabled.refetch()
        #expect(disabled.data == 99)
        active.dispose(); disabled.dispose()
    }

    @Test func sameKeyLateResultCannotOverwriteUI() async throws {
        let client = QueryClient()
        let gate = TestGate()
        let counter = CallCounter()
        let query = ObservableQueryResult<Int>(key: "race", client: client) {
            let call = await counter.increment()
            if call == 1 { await gate.pause() }
            return call
        }
        let old = Task { await query.fetch() }
        await gate.waitForStart()
        await client.invalidate("race")
        #expect(await eventually { query.data == 2 })
        await gate.release()
        await old.value
        #expect(query.data == 2)
        #expect(try await client.getQueryData(key: "race", as: Int.self) == 2)
        query.dispose()
    }

    @Test func initialDataSeedsCacheAndCacheHitKeepsOriginalTimestamp() async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let a = ObservableQueryResult<Int>(key: "initial", client: client, initialData: 7) {
            await counter.increment()
        }
        await a.fetch()
        let timestamp = a.lastUpdated
        let b = QueryResult<Int>(key: "initial", client: client, initialData: 99) { 100 }
        await b.fetch()
        #expect(a.data == 7 && b.data == 7)
        #expect(b.lastUpdated == timestamp)
        #expect(await counter.value == 0)
        a.dispose(); b.dispose()
    }

    @Test func disabledQueryCanReadSharedDataWithoutAnError() async throws {
        let client = QueryClient()
        try await client.setQueryData(key: "disabled", data: 8)
        let query = ObservableQueryResult<Int>(key: "disabled", client: client,
                                              options: QueryOptions(enabled: false)) { 99 }
        await query.fetch()
        #expect(query.data == 8 && query.error == nil)
        #expect(!query.isLoading && !query.isFetching)
        query.dispose()
    }

    @Test func previousDataIsPlaceholderAndNeverSeedsNewKey() async throws {
        let client = QueryClient()
        let query = ObservableQueryResult<Int>(key: "page/1", client: client) { 1 }
        await query.fetch()
        query.update(key: "page/2") { 2 }
        #expect(query.data == 1 && query.isPreviousData)
        #expect(try await client.getQueryData(key: "page/2", as: Int.self) == nil)
        await query.fetch()
        #expect(query.data == 2 && !query.isPreviousData)
        query.dispose()
    }

    @Test func removeResetsAllObserversAndAllowsManualReload() async throws {
        let client = QueryClient()
        let query = ObservableQueryResult<Int>(key: "removed", client: client) { 42 }
        await query.fetch()
        await client.removeAll()
        #expect(await eventually { query.data == nil && !query.isFetching })
        await query.refetch()
        #expect(query.data == 42)
        query.dispose()
    }

    @Test func explicitCancellationResumesWaitersBeforeUncooperativeWorkFinishes() async throws {
        let client = QueryClient()
        let gate = TestGate()
        let task = Task { try await client.fetch(key: "cancel") { await gate.pause(); return 1 } }
        await gate.waitForStart()
        await client.cancel("cancel")
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        // Reaching here before opening the gate proves prompt waiter cancellation.
        try await client.setQueryData(key: "cancel", data: 2)
        await gate.release()
        #expect(try await client.getQueryData(key: "cancel", as: Int.self) == 2)
    }

    @Test func cancellingOneWaiterDoesNotCancelOtherConsumer() async throws {
        let client = QueryClient()
        let gate = TestGate()
        let first = Task { try await client.fetch(key: "joined") { await gate.pause(); return 7 } }
        await gate.waitForStart()
        // An active observer is a second legitimate consumer of shared work.
        let subscription: QuerySubscription<Int> = try await client.subscribe(
            key: "joined", options: QueryOptions(), initialData: nil, operation: { 99 })
        first.cancel()
        do { _ = try await first.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        await gate.release()
        #expect(await eventually { (try? await client.getQueryData(key: "joined", as: Int.self)) == 7 })
        subscription.lease.cancel()
    }

    @Test func cancellingLastWaiterReachesOperation() async throws {
        let client = QueryClient()
        let started = TestGate()
        let observedCancellation = TestGate()
        let task = Task {
            try await client.fetch(key: "last") {
                await started.release()
                do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                catch { await observedCancellation.release(); throw error }
                return 1
            }
        }
        await started.pause()
        task.cancel()
        _ = try? await task.value
        await observedCancellation.pause()
        #expect(try await client.getQueryData(key: "last", as: Int.self) == nil)
    }

    @Test func zeroFreshnessStillDeduplicatesAndPreservesStarterPolicy() async throws {
        let client = QueryClient()
        let gate = TestGate()
        let counter = CallCounter()
        let first = Task {
            try await client.fetch(key: "zero", staleTime: .seconds(0)) {
                await counter.increment(); await gate.pause(); return 1
            }
        }
        await gate.waitForStart()
        let second = Task {
            try await client.fetch(key: "zero", staleTime: .hours(1)) {
                await counter.increment(); return 99
            }
        }
        // Observe registration through an actor-isolated test hook, not a timed sleep.
        #expect(await eventually { await client.waiterCount(for: "zero") == 2 })
        await gate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        let next: Int = try await client.fetch(key: "zero") { await counter.increment(); return 2 }
        #expect(next == 2)
        #expect(await counter.value == 2)
    }


    @Test func pollingActuallyRefreshesDespiteFreshCache() async {
        let client = QueryClient()
        let counter = CallCounter()
        let query = ObservableQueryResult<Int>(key: "poll", client: client,
            options: QueryOptions(refetchInterval: .seconds(0.01), staleTime: .hours(1))) {
            await counter.increment()
        }
        let loop = Task { await query.runPeriodicRefetch() }
        #expect(await eventually { query.data.map { $0 >= 2 } ?? false })
        loop.cancel(); await loop.value
        #expect(!query.isFetching)
        query.dispose()
    }

    @Test func zeroPollingIntervalIsRejected() async {
        let query = ObservableQueryResult<Int>(key: "zero-poll", client: QueryClient(),
                                               options: QueryOptions(refetchInterval: .seconds(0))) { 1 }
        await query.runPeriodicRefetch()
        guard case .invalidRefetchInterval = query.error as? QueryError else {
            Issue.record("Expected invalid interval"); return
        }
        query.dispose()
    }

    @Test func runDetachesOnViewTaskCancellationWithoutPolling() async throws {
        let client = QueryClient()
        let query = ObservableQueryResult<Int>(key: "view", client: client,
                                               options: QueryOptions(gcTime: .seconds(0))) { 1 }
        let task = Task { await query.run() }
        #expect(await eventually { query.data == 1 })
        task.cancel()
        await task.value
        #expect(await eventually { (try? await client.getQueryData(key: "view", as: Int.self)) == nil })
        #expect(!query.isFetching)
    }

    @Test func staleTimeNotifiesObserversWithoutEvictingData() async throws {
        let query = ObservableQueryResult<Int>(key: "stale", client: QueryClient(),
                                               options: QueryOptions(staleTime: .seconds(0.01))) { 1 }
        await query.fetch()
        #expect(await eventually { query.isStale })
        #expect(query.data == 1)
        query.dispose()
    }

    @Test func oldFailureCannotClearNewRequest() async throws {
        let client = QueryClient()
        let oldGate = TestGate(), newGate = TestGate()
        let old = Task { try await client.fetch(key: "failure") { () async throws -> Int in
            await oldGate.pause(); throw LifecycleError.rejected
        } }
        await oldGate.waitForStart()
        await client.invalidate("failure")
        let current = Task { try await client.fetch(key: "failure") { await newGate.pause(); return 2 } }
        await newGate.waitForStart()
        await oldGate.release()
        _ = try? await old.value
        #expect(await client.waiterCount(for: "failure") == 1)
        await newGate.release()
        #expect(try await current.value == 2)
    }

    @Test func disposeEndsLifecycleWaitWithoutCancellingCaller() async {
        let query = ObservableQueryResult<Int>(key: "dispose-run", client: QueryClient()) { 1 }
        let task = Task { await query.run() }
        #expect(await eventually { query.data == 1 })
        query.dispose()
        await task.value
        #expect(query.data == nil)
    }

    @Test func failedSubscriptionCanRecoverAfterConflictingRecordIsRemoved() async throws {
        let client = QueryClient()
        try await client.setQueryData(key: "recover", data: "string")
        let query = ObservableQueryResult<Int>(key: "recover", client: client) { 42 }
        await query.fetch()
        #expect(query.error != nil)
        await client.remove("recover")
        await query.fetch()
        #expect(query.data == 42 && query.error == nil)
        query.dispose()
    }

    @Test func joiningWithInitialDataDoesNotCancelAnExistingRequest() async throws {
        let client = QueryClient()
        let gate = TestGate()
        let first = Task { try await client.fetch(key: "seed-join") { await gate.pause(); return 7 } }
        await gate.waitForStart()
        let query = ObservableQueryResult<Int>(key: "seed-join", client: client, initialData: 99) { 42 }
        let joined = Task { await query.fetch() }
        #expect(await eventually { await client.waiterCount(for: "seed-join") == 2 })
        await gate.release()
        #expect(try await first.value == 7)
        await joined.value
        #expect(query.data == 7 && query.error == nil)
        query.dispose()
    }

    @Test func disposingDuringFetchCancelsItsWaiterAndCooperativeOperation() async {
        let started = TestGate(), cancelled = TestGate()
        let query = ObservableQueryResult<Int>(key: "dispose-fetch", client: QueryClient()) {
            await started.release()
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            catch { await cancelled.release(); throw error }
            return 1
        }
        let task = Task { await query.fetch() }
        await started.pause()
        query.dispose()
        await task.value
        await cancelled.pause()
        #expect(query.data == nil && !query.isFetching)
    }

    @Test func originalErrorTypeIsPreserved() async {
        let client = QueryClient()
        do {
            let _: Int = try await client.fetch(key: "error") { throw LifecycleError.rejected }
            Issue.record("Expected failure")
        } catch { #expect(error as? LifecycleError == .rejected) }
    }
}

enum LifecycleError: Error { case rejected }
