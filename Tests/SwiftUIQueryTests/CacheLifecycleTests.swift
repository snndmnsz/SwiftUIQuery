import Testing
import SwiftUIQuery

@Suite("Cache lifecycle regressions")
struct CacheLifecycleTests {
    @Test(arguments: [false, true])
    func staleCompletionMustNotOverwriteNewValue(invalidateAll: Bool) async throws {
        let client = QueryClient()
        let gate = Gate()
        let old = Task {
            try await client.fetch(key: "item") {
                await gate.pause()
                return 1
            }
        }
        await gate.waitUntilStarted()
        if invalidateAll {
            await client.invalidateAll()
        } else {
            await client.invalidate("item")
        }
        let new: Int = try await client.fetch(key: "item") { 2 }
        #expect(new == 2)
        await gate.release()
        _ = try? await old.value
        let cached: Int = try await client.fetch(key: "item") { 99 }
        #expect(cached == 2)
    }

    @Test func rejectedTypeMustNotReplaceRegisteredOperation() async throws {
        let client = QueryClient()
        let _: Int = try await client.fetch(key: "typed") { 42 }
        do {
            let _: String = try await client.fetch(key: "typed") { "wrong type" }
            Issue.record("Expected type mismatch")
        } catch QueryError.typeMismatch { }
        let value: Int = try await client.refetch(key: "typed")
        #expect(value == 42)
    }

    @Test(arguments: Removal.allCases)
    func removingEntryMustNotRestoreItOnOldCompletion(removal: Removal) async throws {
        let client = QueryClient()
        let gate = Gate()
        let old = Task {
            try await client.fetch(key: "account") {
                await gate.pause()
                return "old account data"
            }
        }
        await gate.waitUntilStarted()
        switch removal {
        case .one: await client.remove("account")
        case .all: await client.removeAll()
        case .clear: await client.clear()
        }
        await gate.release()
        _ = try? await old.value
        do {
            let _: String = try await client.refetch(key: "account")
            Issue.record("Removal must forget the registered operation")
        } catch QueryError.missingOperation { }
        let current: String = try await client.fetch(key: "account") { "new account data" }
        #expect(current == "new account data")
    }

    @Test func rejectedInFlightTypePreservesOriginalOperation() async throws {
        let client = QueryClient()
        let gate = Gate()
        let pending = Task {
            try await client.fetch(key: "typed-active") {
                await gate.pause()
                return 42
            }
        }
        await gate.waitUntilStarted()
        do {
            let _: String = try await client.fetch(key: "typed-active") { "invalid" }
            Issue.record("Expected type mismatch")
        } catch QueryError.typeMismatch { }
        await gate.release()
        #expect(try await pending.value == 42)
        let refreshed: Int = try await client.refetch(key: "typed-active")
        #expect(refreshed == 42)
    }

    @Test func expiredValueDoesNotAllowTypeReplacement() async throws {
        let client = QueryClient()
        let _: Int = try await client.fetch(key: "expired", cacheTime: .seconds(0)) { 42 }
        do {
            let _: String = try await client.fetch(key: "expired") { "invalid" }
            Issue.record("A key's registered result type lasts until removal")
        } catch QueryError.typeMismatch { }
        let refreshed: Int = try await client.refetch(key: "expired")
        #expect(refreshed == 42)
    }

    @Test func removalAllowsNewTypeWithoutOldWriteContamination() async throws {
        let client = QueryClient()
        let gate = Gate()
        let pending = Task {
            try await client.fetch(key: "reused") {
                await gate.pause()
                return 1
            }
        }
        await gate.waitUntilStarted()
        await client.remove("reused")
        let _: String = try await client.fetch(key: "reused") { "new type" }
        await gate.release()
        _ = try? await pending.value
        let cached: String = try await client.fetch(key: "reused") { "unexpected" }
        #expect(cached == "new type")
    }

    @Test func cachesOptionalNilWithoutExecutingAgain() async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let first: Int? = try await client.fetch(key: "nil") {
            await counter.increment()
            return nil as Int?
        }
        let second: Int? = try await client.fetch(key: "nil") {
            await counter.increment()
            return 99 as Int?
        }
        #expect(first == nil)
        #expect(second == nil)
        #expect(await counter.value == 1)
    }

    @Test func cacheHitRegistersLatestValidOperation() async throws {
        let client = QueryClient()
        let first: Int = try await client.fetch(key: "latest") { 1 }
        let cached: Int = try await client.fetch(key: "latest") { 2 }
        let refreshed: Int = try await client.refetch(key: "latest")
        #expect(first == 1)
        #expect(cached == 1)
        #expect(refreshed == 2)
    }

    enum Removal: CaseIterable, Sendable { case one, all, clear }

}

private actor Gate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
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
