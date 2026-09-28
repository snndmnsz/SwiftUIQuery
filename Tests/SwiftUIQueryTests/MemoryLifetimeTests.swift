import Foundation
import Testing
@testable import SwiftUIQuery

private final class MemoryPayload: Sendable { let bytes = [UInt8](repeating: 1, count: 1024) }
@MainActor private final class WeakReference<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
private final class QueryOwner: Sendable {
    let client: QueryClient
    init(_ client: QueryClient) { self.client = client }
    func load() -> Int { 42 }
}
@MainActor private final class ScreenOwner {
    var query: ObservableQueryResult<Int>?
    init() {
        query = ObservableQueryResult(key: "weak-owner", owner: self, client: QueryClient()) { owner in
            await owner.load()
        }
    }
    func load() -> Int { 42 }
}

@Suite("Memory lifetime", .timeLimit(.minutes(1)))
@MainActor struct MemoryLifetimeTests {
    private func cachePayload(_ client: QueryClient, key: QueryKey) async throws -> WeakReference<MemoryPayload> {
        let value = try await client.fetch(key: key, staleTime: .seconds(0), gcTime: .seconds(0)) { MemoryPayload() }
        return WeakReference(value)
    }
    private func capturePayload(_ client: QueryClient, key: QueryKey) async throws -> WeakReference<MemoryPayload> {
        let value = MemoryPayload()
        let _: Int = try await client.fetch(key: key, gcTime: .seconds(0)) { value.bytes.count }
        return WeakReference(value)
    }
    @Test func inactiveDataAndClosuresAreAutomaticallyCollected() async throws {
        let client = QueryClient()
        var references: [WeakReference<MemoryPayload>] = []
        for n in 0..<100 {
            references.append(try await cachePayload(client, key: QueryKey("data/\(n)")))
            references.append(try await capturePayload(client, key: QueryKey("operation/\(n)")))
        }
        #expect(await eventually { references.allSatisfy { $0.value == nil } })
    }

    private func createCycle() async throws -> (WeakReference<QueryOwner>, WeakReference<QueryClient>) {
        let client = QueryClient()
        let owner = QueryOwner(client)
        let _: Int = try await client.fetch(key: "cycle", gcTime: .seconds(0)) { owner.load() }
        return (WeakReference(owner), WeakReference(client))
    }
    @Test func inactiveOperationCycleIsBrokenByGC() async throws {
        let (owner, client) = try await createCycle()
        #expect(await eventually { owner.value == nil && client.value == nil })
    }

    @Test func garbageCollectionTimerDoesNotRetainOtherwiseUnusedClient() async throws {
        weak var released: QueryClient?
        do {
            let client = QueryClient()
            released = client
            let _: Int = try await client.fetch(key: "long-gc", gcTime: .days(1)) { 1 }
        }
        #expect(await eventually { released == nil })
    }

    @Test func weakOwnerInitializerAvoidsViewModelResultCycle() async {
        weak var owner: ScreenOwner?
        weak var query: ObservableQueryResult<Int>?
        do {
            let screen = ScreenOwner()
            owner = screen
            query = screen.query
            await screen.query?.fetch()
        }
        #expect(await eventually { owner == nil && query == nil })
    }

    @Test func activeObserverPinsDataUntilDetached() async throws {
        let client = QueryClient()
        let query = ObservableQueryResult<MemoryPayload>(key: "pinned", client: client,
            options: QueryOptions(staleTime: .seconds(0), gcTime: .seconds(0))) { MemoryPayload() }
        await query.fetch()
        weak var payload = query.data
        #expect(payload != nil)
        #expect(try await client.getQueryData(key: "pinned", as: MemoryPayload.self) != nil)
        query.dispose()
        #expect(await eventually { payload == nil })
    }

    @Test func deinitializingActiveAdaptersReleasesSubscriptionsAndData() async throws {
        let client = QueryClient()
        weak var query: QueryResult<MemoryPayload>?
        weak var payload: MemoryPayload?
        do {
            let result = QueryResult<MemoryPayload>(key: "released", client: client,
                options: QueryOptions(gcTime: .seconds(0))) { MemoryPayload() }
            query = result
            await result.fetch()
            payload = result.data
        }
        #expect(await eventually { query == nil && payload == nil })
    }
}
