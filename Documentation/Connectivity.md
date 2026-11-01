# Connectivity and recovery

SwiftUIQuery follows TanStack Query's network-mode model using native Apple path monitoring. It is not a complete TanStack API port. Networking policy remains separate from your transport: the package does not interpret HTTP responses, refresh credentials, decode payloads, or present UI.

## Network modes

`QueryOptions.networkMode` defaults to `.online`. Clients share a system `NWPathMonitor`; an unknown initial path and a path requiring a connection attempt are treated optimistically. Path status is a scheduling hint, not proof that a server is reachable.

- `.online`: initial attempts and retries wait when no network path is available.
- `.always`: operations run regardless of connectivity. Use this for local database/file queries or a transport managing its own connectivity. `refetchOnReconnect` defaults to false in this mode; it can be explicitly enabled.
- `.offlineFirst`: the initial attempt runs even offline, allowing a local/HTTP cache to answer. If it fails, retries wait for connectivity.

Offline waiting does not consume retry attempts. Requests already executing are not forcibly canceled. Cached data and timestamps remain available. Adapters expose `fetchStatus` (`idle`, `fetching`, `paused`) and `isPaused`; paused requests have `isFetching == false` and `isLoading == false`.

```swift
let documents = QueryResult(
    key: "documents",
    options: QueryOptions(networkMode: .always)
) {
    try await database.documents()
}
```

## Connection recovery and cancellation

Paused requests continue when connectivity returns, independently of `refetchOnReconnect`. They retain their existing retry budget; canceled requests do not resume.

Separately, `refetchOnReconnect: true` refreshes active stale queries on an offline-to-online transition. Same-key consumers share one request; repeated online events do nothing. Fresh, disabled, and inactive queries do not start requests. A reconnect does not create a second retry batch alongside an existing request. An in-flight final attempt can still fail; reconnect is not an unlimited retry policy.

A query that was inactive during reconnect follows its mount policy when subscribed again. `retryOnMount: false` is respected, and the package does not schedule a hidden pending refetch for an inactive query.

Canceling one consumer does not cancel work still used by another consumer. The last consumer can cancel an offline wait; cancellation does not need an online event to finish. Stop observing when the consumer becomes inactive.

## Server recovery without a path change

A server can recover without a network interface event. Use the existing state-based `refetchInterval` to choose the cadence after exhausted retries, just as you would use a TanStack interval function:

```swift
let query = QueryResult(
    key: "items",
    options: QueryOptions(retry: 2, retryDelay: .seconds(5), exponentialBackoff: true),
    refetchInterval: { state in
        state.isError ? .seconds(60) : .seconds(30)
    }
) {
    try await api.items()
}
// await query.run() from the visible screen's cancellable task.
```

`retry` counts additional attempts: `2` permits three attempts per batch. After exhaustion, the interval callback can schedule another batch or return nil to pause polling. Offline batches wait for connectivity rather than repeatedly calling the transport. On success the same callback chooses the normal cadence. The package prescribes no application-specific duration and has no separate error-interval option.

Both `QueryResult` and `ObservableQueryResult` use the same controller for `run()`, `runPeriodicRefetch()`, and `startPeriodicRefetch()`. Explicit `fetch()` and `refetch()` do not install polling loops by themselves.

## Explicit connectivity and tests

```swift
let client = QueryClient(automaticallyMonitorsNetwork: false)
await client.setOnline(false)
// .online attempts now wait; fresh cached reads and .always operations still work.
await client.setOnline(true)
// Paused requests continue; active stale queries can refetch.
```

Disable automatic monitoring when supplying connectivity yourself so system events cannot override your custom source or test. Clients initially assume online until receiving an offline event. Imperative `fetch` and `prefetch` accept `networkMode` too. Completed unobserved requests are not automatically reissued.

## TanStack compatibility boundary

Network modes, paused-versus-fetching state, retry continuation, and Boolean reconnect policy follow the [TanStack network-mode model](https://tanstack.com/query/latest/docs/framework/react/guides/network-mode). `NWPathMonitor` replaces the browser's network-event source.

SwiftUIQuery still exposes a smaller API: reconnect is Boolean, not TanStack's Boolean/always/function union; existing retry and stale-time defaults are unchanged. Focus management, persisted/offline mutations, and the rest of TanStack's API are not implemented by this change. Applications own error presentation; HTTP rate limits and authentication-specific cooldowns remain the transport's responsibility.
