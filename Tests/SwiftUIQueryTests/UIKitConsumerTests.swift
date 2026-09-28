import Combine
import Testing
import SwiftUIQuery

/// Exercises the UIKit binding pattern without requiring an iOS test host.
@MainActor
@Suite("UIKit Combine consumers", .timeLimit(.minutes(1)))
struct UIKitConsumerTests {
    @Test func disappearingAndReappearingReadsLatestSharedCache() async throws {
        let client = QueryClient()
        let counter = CallCounter()
        let query = ObservableQueryResult<Int>(key: "screen", client: client) {
            await counter.increment()
        }
        let screen = CombineScreen(query: query)
        screen.appear()
        #expect(await eventually { screen.state.data == 1 && !screen.state.isFetching })
        screen.disappear()
        try await client.setQueryData(key: "screen", data: 42)
        #expect(screen.state.data == 1)
        screen.appear()
        #expect(await eventually { screen.state.data == 42 && !screen.state.isFetching })
        #expect(await counter.value == 1)
        screen.disappear()
    }

    @Test func detachingUIKitConsumerKeepsOtherConsumersRequestAlive() async {
        let client = QueryClient()
        let gate = TestGate()
        let query = ObservableQueryResult<Int>(key: "shared-screen", client: client) {
            await gate.pause()
            return 7
        }
        let screen = CombineScreen(query: query)
        screen.appear()
        await gate.waitForStart()
        let other = QueryResult<Int>(key: "shared-screen", client: client) { 99 }
        let task = Task { await other.fetch() }
        #expect(await eventually { other.isFetching })
        screen.disappear()
        await gate.release()
        await task.value
        #expect(other.data == 7)
        #expect(screen.state.data == nil)
        other.dispose()
    }

    @Test func mutationPublishesPendingFailureAndRecoveryWithoutResubscribing() async throws {
        let mutation = ObservableMutationResult<Int, Int>(operation: { input in
            if input < 0 { throw LifecycleError.rejected }
            return input * 2
        })
        var states: [MutationState<Int, Int>] = []
        let subscription = mutation.$state.sink { states.append($0) }
        defer { subscription.cancel(); mutation.dispose() }
        #expect(states.last?.status == .idle)
        do {
            try await mutation.mutate(-1)
            Issue.record("Expected mutation failure")
        } catch {
            #expect(error as? LifecycleError == .rejected)
        }
        #expect(states.contains { $0.isPending && $0.variables == -1 })
        #expect(states.last?.error as? LifecycleError == .rejected)
        try await mutation.mutate(3)
        #expect(states.last?.data == 6)
        #expect(states.last?.status == .success)
        mutation.reset()
        #expect(states.last?.status == .idle)
    }

    @Test func cancellingCombineSubscriptionStopsUIDelivery() async {
        let query = ObservableQueryResult<Int>(key: "subscription", client: QueryClient(), initialData: 5) { 9 }
        var received: [Int?] = []
        let subscription = query.$state.sink { received.append($0.data) }
        #expect(received == [5])
        subscription.cancel()
        await query.refetch()
        #expect(query.data == 9)
        #expect(received == [5])
        query.dispose()
    }

    @Test func bindingDoesNotRetainScreenOrResult() {
        weak var releasedScreen: CombineScreen?
        weak var releasedQuery: ObservableQueryResult<Int>?
        do {
            let query = ObservableQueryResult<Int>(key: "lifetime", client: QueryClient()) { 1 }
            let screen = CombineScreen(query: query)
            releasedScreen = screen
            releasedQuery = query
            screen.appear()
        }
        #expect(releasedScreen == nil)
        #expect(releasedQuery == nil)
    }
}

@MainActor
private final class CombineScreen {
    let query: ObservableQueryResult<Int>
    private(set) var state = QueryState<Int>()
    private var subscriptions = Set<AnyCancellable>()

    init(query: ObservableQueryResult<Int>) { self.query = query }

    func appear() {
        guard subscriptions.isEmpty else { return }
        query.$state.sink { [weak self] state in
            self?.state = state
        }.store(in: &subscriptions)
        query.startPeriodicRefetch()
    }

    func disappear() {
        query.stopObserving()
        subscriptions.removeAll()
    }
}
