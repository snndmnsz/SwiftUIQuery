import Foundation
import Testing
import SwiftUIQuery

@Suite("Mutations and optimistic cache", .timeLimit(.minutes(1)))
@MainActor struct MutationTests {
    @Test func mutateExecutesEveryCallAndResetsState() async throws {
        let calls = CallCounter()
        let mutation = ObservableMutationResult<Int, Int>(operation: { input in
            await calls.increment(); return input * 2
        })
        #expect(mutation.isIdle)
        #expect(try await mutation.mutate(2) == 4)
        #expect(try await mutation.mutate(2) == 4)
        #expect(await calls.value == 2)
        #expect(mutation.isSuccess && mutation.data == 4 && mutation.variables == 2)
        mutation.reset()
        #expect(mutation.isIdle && mutation.data == nil && mutation.error == nil)
    }

    @Test func pendingLastsThroughCallbacksAndInvalidation() async throws {
        let client = QueryClient()
        let calls = CallCounter()
        let query = ObservableQueryResult<Int>(key: "count", client: client) { await calls.increment() }
        await query.fetch()
        let gate = TestGate()
        var events: [String] = []
        let mutation = MutationResult<Int, Int>(operation: { $0 }, onSuccess: { _, _ in
            events.append("success")
            await client.invalidate("count")
            await gate.pause()
        }, onSettled: { _ in events.append("settled") })
        let task = Task { try await mutation.mutate(2) }
        await gate.waitForStart()
        #expect(mutation.isPending)
        #expect(await eventually { query.data == 2 })
        await gate.release()
        #expect(try await task.value == 2)
        #expect(mutation.isSuccess && events == ["success", "settled"])
        query.dispose()
    }

    @Test func failureAutomaticallyRollsBackBeforeErrorCallbacks() async throws {
        let client = QueryClient()
        try await client.setQueryData(key: "favorite", data: false)
        var errorSawRollback = false
        let mutation = ObservableMutationResult<Bool, Bool>(operation: { _ in throw LifecycleError.rejected },
            onMutate: { value in try await client.optimisticUpdate(key: "favorite", as: Bool.self) { _ in value } },
            onError: { error, _ in
                errorSawRollback = (try? await client.getQueryData(key: "favorite", as: Bool.self)) == false
                #expect(error as? LifecycleError == .rejected)
            })
        do { _ = try await mutation.mutate(true); Issue.record("Expected failure") }
        catch { #expect(error as? LifecycleError == .rejected) }
        #expect(errorSawRollback && mutation.isError)
        #expect(try await client.getQueryData(key: "favorite", as: Bool.self) == false)
    }

    @Test func rollbackCannotOverwriteNewerServerDataOrRemovedKey() async throws {
        let client = QueryClient()
        try await client.setQueryData(key: "item", data: 1)
        let rollback = try await client.optimisticUpdate(key: "item", as: Int.self) { _ in 2 }
        try await client.setQueryData(key: "item", data: 3)
        #expect(await rollback.rollback() == false)
        #expect(try await client.getQueryData(key: "item", as: Int.self) == 3)
        let removed = try await client.optimisticUpdate(key: "item", as: Int.self) { _ in 4 }
        await client.remove("item")
        try await client.setQueryData(key: "item", data: 5)
        #expect(await removed.rollback() == false)
        #expect(try await client.getQueryData(key: "item", as: Int.self) == 5)
    }

    @Test func rollbackRestoresAbsenceAndCanOnlyRunOnce() async throws {
        let client = QueryClient()
        let rollback = try await client.optimisticUpdate(key: "new", as: Int.self) { _ in 2 }
        #expect(await rollback.rollback())
        #expect(try await client.getQueryData(key: "new", as: Int.self) == nil)
        #expect(await rollback.rollback() == false)
    }

    @Test func optionalNilIsRealCachedData() async throws {
        let client = QueryClient()
        try await client.setQueryData(key: "optional", data: nil as Int?)
        let rollback = try await client.optimisticUpdate(key: "optional", as: Int?.self) { _ in 2 }
        #expect(await rollback.rollback())
        let cached: Int?? = try await client.getQueryData(key: "optional")
        #expect(cached != nil)
        #expect(cached! == nil)
    }

    @Test func updaterIsAtomicAcrossConcurrentCalls() async throws {
        let client = QueryClient()
        try await client.setQueryData(key: "counter", data: 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { try await client.setQueryData(key: "counter", as: Int.self) { ($0 ?? 0) + 1 } }
            }
            try await group.waitForAll()
        }
        #expect(try await client.getQueryData(key: "counter", as: Int.self) == 100)
    }

    @Test func rejectedCacheWriteDoesNotCancelValidWork() async throws {
        let client = QueryClient()
        let gate = TestGate()
        let pending = Task { try await client.fetch(key: "typed-write") { await gate.pause(); return 42 } }
        await gate.waitForStart()
        do { try await client.setQueryData(key: "typed-write", data: "wrong"); Issue.record("Expected mismatch") }
        catch QueryError.typeMismatch { }
        await gate.release()
        #expect(try await pending.value == 42)
    }

    @Test func olderMutationCannotOverwriteLatestInvocationState() async throws {
        let gate = TestGate()
        let mutation = MutationResult<Int, Int>(operation: { input in
            if input == 1 { await gate.pause() }
            return input
        })
        let old = Task { try await mutation.mutate(1) }
        await gate.waitForStart()
        #expect(try await mutation.mutate(2) == 2)
        await gate.release()
        #expect(try await old.value == 1)
        #expect(mutation.data == 2 && mutation.variables == 2)
    }

    @Test func resetPreventsLateCompletionFromRestoringState() async throws {
        let gate = TestGate()
        let mutation = ObservableMutationResult<Int, Int>(operation: { input in await gate.pause(); return input })
        let task = Task { try await mutation.mutate(1) }
        await gate.waitForStart()
        mutation.reset()
        await gate.release()
        _ = try await task.value
        #expect(mutation.isIdle && mutation.data == nil)
    }

    @Test func mutationFailureIsNotRetried() async {
        let calls = CallCounter()
        let mutation = MutationResult<Int, Int>(operation: { _ in
            await calls.increment(); throw LifecycleError.rejected
        })
        _ = try? await mutation.mutate(1)
        #expect(await calls.value == 1)
    }

    @Test func cancellationRollsBackAnUnfinishedMutation() async throws {
        let client = QueryClient()
        let started = TestGate()
        try await client.setQueryData(key: "cancel-mutation", data: 1)
        let mutation = MutationResult<Int, Int>(operation: { _ in
            await started.release()
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return 2
        }, onMutate: { _ in
            try await client.optimisticUpdate(key: "cancel-mutation", as: Int.self) { _ in 2 }
        })
        let task = Task { try await mutation.mutate(2) }
        await started.pause()
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(try await client.getQueryData(key: "cancel-mutation", as: Int.self) == 1)
    }
}
