# SwiftUI integration

[Documentation index](../README.md#documentation)

## Choose an adapter

| Minimum iOS | Query | Mutation | Owner |
| --- | --- | --- | --- |
| 15 | ObservableQueryResult<Value> | ObservableMutationResult<Input, Output> | @StateObject |
| 17 | QueryResult<Value> | MutationResult<Input, Output> | @State |

All adapters are @MainActor. Use @ObservedObject for a child receiving a Combine adapter. For Observation, a plain stored property can read an injected result. The two query adapters subscribe to the same client records and can be mixed in one app.

## Tie observation to a view

```swift
.task { await query.run() }
.refreshable { await query.refetch() }
```

`run()` subscribes, performs a cache-aware initial fetch, and waits for cancellation. With a refetchInterval it also polls. SwiftUI cancels the task when the view disappears; the adapter detaches, and unused idle records can begin their gcTime countdown. Reappearing attaches again and reuses fresh cached data.

Do not place code after `await query.run()` that needs to execute while the view is visible: run owns that task's lifetime. For one-shot work, use fetch/refetch. Those methods keep observing afterward; call `stopObserving()` when no longer needed. `dispose()` additionally releases the operation and UI data. One adapter should have one lifecycle loop. Starting a replacement `run()` or `runPeriodicRefetch()` supersedes the previous lifecycle; cancellation cleanup from the old task cannot detach the new subscription. A caller that is already canceled does not change an active lifecycle.

`refetch()` works even before the adapter's first fetch or after client removal. `enabled: false` keeps automatic loads idle, still exposes cached/initial data, and permits explicit manual refetch. Same-key changes from another observer remain visible.

## Parameter changes

Assume the following fragment has an existing query and concurrency-safe service:

```swift
.task(id: categoryID) {
    let selected = categoryID
    query.update(
        key: QueryKey("products/category/\(selected)"),
        options: QueryOptions(keepPreviousData: true)
    ) {
        try await service.products(categoryID: selected)
    }
    await query.run()
}
```

Previous data is an observer-local placeholder, identified by `isPreviousData`. It is never written into the new key's cache. Set keepPreviousData to false for changes such as account switches where displaying previous data would be misleading. Old-key or superseded same-key completions cannot regress the visible result.

## Loading and failures

Prefer showing existing data with a smaller refresh/error indicator. `isLoading` means there is no data yet; `isFetching` also includes refreshes. Failed refreshes preserve previous data and the original error type. `lastUpdated` belongs to the cache value, not to the time a view read it. `isStale` changes when freshness expires without discarding data.

## Polling

```swift
let options = QueryOptions(
    refetchInterval: .seconds(30),
    staleTime: .minutes(1),
    gcTime: .minutes(5)
)
```

With `.task { await query.run() }`, the initial load uses cache, then every tick forces a refetch even if data is fresh. The interval must be positive. Each loop waits for its previous request, avoiding overlap. Change options through update and restart the lifecycle task.

For manual ownership, `startPeriodicRefetch()`/`cancelRefetch()` start/stop an internal loop. Canceling polling stops future ticks; `query.cancel()` explicitly cancels shared request work for all consumers. Detaching one observer preserves requests used by other observers or waiters.

## Memory ownership

The cache retains operation closures until removal or inactive GC. The adapter also retains its configured closure. Avoid capturing an entire view model that owns the result. Capture an independent service and immutable parameters, or use the weak-owner initializer:

```swift
@MainActor
final class ProfileModel {
    var query: ObservableQueryResult<String>?

    init(client: QueryClient) {
        query = ObservableQueryResult(key: "profile", owner: self, client: client) { owner in
            await owner.loadName()
        }
    }

    func loadName() async -> String { "Avery" }
}
```

The operation receives the owner only while executing; the stored closure does not keep it alive. A missing owner throws QueryError.ownerReleased. Do not capture that owner again from outside the operation parameter. For ordinary closure initializers, use weak capture where necessary. Mutation callbacks follow the same ownership rules.

GC bounds inactive cache retention; it cannot break every arbitrary caller-created cycle, nor forcibly terminate an operation that ignores task cancellation. Use dispose for explicit teardown, cancellation-aware services, and service timeouts.

## Examples and mutation UI

[CatalogView15](../Examples/CatalogView15.swift) and [CatalogView](../Examples/CatalogView.swift) show loading and refresh. [FavoriteView15](../Examples/FavoriteView15.swift) demonstrates mutation, pending state, optimistic cache update, automatic rollback, and reconciliation without a server. See [Mutations](Mutations.md).
