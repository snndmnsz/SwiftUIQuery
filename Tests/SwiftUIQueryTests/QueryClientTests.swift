import Testing
@testable import SwiftUIQuery

@Suite("QueryClient")
struct QueryClientTests {
    @Test func returnsCachedValueWithoutExecutingAgain() async throws {
        let client = QueryClient()
        let counter = CallCounter()

        let first: Int = try await client.fetch(key: "answer") {
            await counter.increment()
            return 42
        }
        let second: Int = try await client.fetch(key: "answer") {
            await counter.increment()
            return 99
        }

        #expect(first == 42)
        #expect(second == 42)
        #expect(await counter.value == 1)
    }

    @Test func expiredValueFetchesAgain() async throws {
        let client = QueryClient()
        let counter = CallCounter()

        let first: Int = try await client.fetch(key: "short", cacheTime: .seconds(0.01)) {
            await counter.increment()
            return 1
        }

        try await Task.sleep(for: .milliseconds(20))

        let second: Int = try await client.fetch(key: "short", cacheTime: .seconds(1)) {
            await counter.increment()
            return 2
        }

        #expect(first == 1)
        #expect(second == 2)
        #expect(await counter.value == 2)
    }

    @Test func simultaneousCallersShareOneTask() async throws {
        let client = QueryClient()
        let counter = CallCounter()

        async let first: Int = client.fetch(key: "shared") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return 7
        }
        async let second: Int = client.fetch(key: "shared") {
            await counter.increment()
            return 8
        }

        let values = try await [first, second]

        // Either caller can register work first; both must receive that result.
        #expect(values[0] == values[1])
        #expect(values[0] == 7 || values[0] == 8)
        #expect(await counter.value == 1)
    }

    @Test func invalidateForcesNextFetch() async throws {
        let client = QueryClient()

        let first: Int = try await client.fetch(key: "invalidate") { 1 }
        await client.invalidate("invalidate")
        let second: Int = try await client.fetch(key: "invalidate") { 2 }

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func removeClearsOperationAndValue() async throws {
        let client = QueryClient()

        let value: Int = try await client.fetch(key: "remove") { 1 }
        await client.remove("remove")

        #expect(value == 1)

        do {
            let _: Int = try await client.refetch(key: "remove")
            Issue.record("Expected missing operation")
        } catch QueryError.missingOperation {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func disabledFetchDoesNotExecute() async throws {
        let client = QueryClient()
        let counter = CallCounter()

        do {
            let _: Int = try await client.fetch(key: "disabled", enabled: false) {
                await counter.increment()
                return 1
            }
            Issue.record("Expected disabled error")
        } catch QueryError.disabled {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await counter.value == 0)
    }

    @Test func cancellationPropagatesAsSwiftCancellationError() async throws {
        let client = QueryClient()

        do {
            let _: Int = try await client.fetch(key: "cancelled") {
                throw CancellationError()
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func retryExecutesUntilSuccess() async throws {
        let client = QueryClient()
        let counter = CallCounter()

        let value: Int = try await client.fetch(
            key: "retry",
            retry: 2,
            retryDelay: .seconds(0)
        ) {
            let count = await counter.increment()
            if count < 2 {
                throw SampleError.failed
            }
            return 5
        }

        #expect(value == 5)
        #expect(await counter.value == 2)
    }

    @Test func refetchUsesRegisteredOperation() async throws {
        let client = QueryClient()
        let counter = CallCounter()

        let first: Int = try await client.fetch(key: "refetch") {
            await counter.increment()
            return await counter.value
        }
        await client.invalidate("refetch")
        let second: Int = try await client.refetch(key: "refetch")

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func operationRunsWithCurrentQueryKey() async throws {
        let client = QueryClient()

        let key: QueryKey = "context-key"
        let observedKey: QueryKey? = try await client.fetch(key: key) {
            QueryExecutionContext.currentKey
        }

        #expect(observedKey == key)
    }

    @Test func typeMismatchThrows() async throws {
        let client = QueryClient()

        let _: Int = try await client.fetch(key: "typed") { 1 }

        do {
            let _: String = try await client.fetch(key: "typed") { "wrong" }
            Issue.record("Expected type mismatch")
        } catch QueryError.typeMismatch {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @available(iOS 17, *)
    @Test @MainActor func queryResultKeepsPreviousDataWhenRefetchFails() async throws {
        let client = QueryClient()
        let scenario = FailingAfterFirstSuccess()
        let result = QueryResult<Int>(
            key: "visible-data",
            client: client,
            options: QueryOptions(cacheTime: .seconds(0))
        ) {
            try await scenario.next()
        }

        await result.fetch()
        await result.fetch()

        #expect(result.data == 10)
        #expect(result.isError)
    }

    @available(iOS 17, *)
    @Test @MainActor func queryResultKeepsPreviousDataWhenUpdated() async throws {
        let client = QueryClient()
        let result = QueryResult<Int>(
            key: "first-key",
            client: client
        ) {
            10
        }

        await result.fetch()

        result.update(key: "second-key") {
            20
        }

        #expect(result.data == 10)
        #expect(!result.isLoading)

        await result.fetch()

        #expect(result.data == 20)
    }

    @available(iOS 17, *)
    @Test @MainActor func queryResultCanClearPreviousDataWhenUpdated() async throws {
        let client = QueryClient()
        let result = QueryResult<Int>(
            key: "clear-first",
            client: client
        ) {
            10
        }

        await result.fetch()

        result.update(
            key: "clear-second",
            options: QueryOptions(keepPreviousData: false)
        ) {
            20
        }

        #expect(result.data == nil)
    }

    @available(iOS 17, *)
    @Test @MainActor func staleUpdatedFetchDoesNotOverwriteLatestData() async throws {
        let client = QueryClient()
        let gate = FetchGate()
        let result = QueryResult<Int>(
            key: "stale-first",
            client: client
        ) {
            await gate.waitForRelease()
            return 1
        }

        let firstTask = Task {
            await result.fetch()
        }

        result.update(key: "stale-second") {
            2
        }
        await result.fetch()
        await gate.release()
        await firstTask.value

        #expect(result.data == 2)
    }

    @available(iOS 17, *)
    @Test @MainActor func queryResultCancelsPeriodicRefetchOnDeinit() async throws {
        let client = QueryClient()
        let counter = CallCounter()
        weak var weakResult: QueryResult<Int>?

        do {
            let result = QueryResult<Int>(
                key: "periodic-deinit",
                client: client,
                options: QueryOptions(cacheTime: .seconds(0), refetchInterval: .seconds(1))
            ) {
                await counter.increment()
            }
            weakResult = result
            result.startPeriodicRefetch()
        }

        #expect(weakResult == nil)

        let valueAfterDeinit = await counter.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.value == valueAfterDeinit)
    }
}

actor CallCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

enum SampleError: Error {
    case failed
}

actor FailingAfterFirstSuccess {
    private var calls = 0

    func next() throws -> Int {
        calls += 1

        if calls == 1 {
            return 10
        }

        throw SampleError.failed
    }
}

actor FetchGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        guard !isReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waitingContinuations = continuations
        continuations.removeAll()
        waitingContinuations.forEach { $0.resume() }
    }
}
