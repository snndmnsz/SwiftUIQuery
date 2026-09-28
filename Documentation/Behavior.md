# Query behavior

[Documentation index](../README.md#documentation)

## Shared query records

One `QueryClient` actor owns each key's data, error, request, observers, and lifetime. Both result adapters project that same record onto the main actor. A refetch, cache write, cancellation, or removal reaches every subscribed result for the key. Notifications are asynchronous and coalesced to the latest snapshot; observers must not depend on seeing every intermediate transition.

`fetch`, `refetch`, and `run` attach an adapter to the client. Merely constructing an adapter does not start requests or attach an observer. `run()` keeps that subscription alive until the calling task is canceled, so use `.task { await query.run() }` in SwiftUI. Manual `fetch()` leaves the subscription attached until `stopObserving()`, `dispose()`, or deallocation. Active means at least one **enabled** observer; disabled observers still pin the record in memory and receive shared data.

Every result-changing parameter belongs in the key. Same-key operations must represent the same result type and logical resource. Registration validates the result type before changing anything. The last valid registered operation is used by client-level refetch/invalidation. Type identity lasts until garbage collection or removal; removal with existing observers keeps their type until they detach.

## Freshness and garbage collection

- `staleTime`: how long a successful value is fresh. Stale data remains available while it refreshes.
- `gcTime`: how long an **unobserved, idle** record remains before its data and registered closure are removed automatically.
- Both default to five minutes. `cacheTime` is an alias for `staleTime`; it is not a GC setting.
- A supplied `staleTime` overrides `cacheTime`. Request starters determine the completed value's freshness deadline; joiners do not extend it. Later calls can replace the registration and the next request's policy.
- `staleTime: .seconds(0)` always considers completed data stale, but still deduplicates tracked requests. `gcTime: .seconds(0)` schedules cleanup as soon as the record becomes unobserved and idle.
- Active observers prevent GC. Direct cache writes and cached fetches restart an inactive record's GC deadline. The latest registered `gcTime` is used. There is no size limit or disk persistence.

Expiration marks observed state as stale; it does not itself start a request. An adapter's `run`/`fetch`, explicit refetch, polling, or active invalidation initiates work. `getQueryData` can read stale data without fetching and does not extend its GC deadline. `lastUpdated` is the actual cached data timestamp, including when a new observer reads it.

GC timers do not retain the client. They free both values and operation captures. Capture an independent service rather than an entire owner, or use the adapters' `owner:` initializer, which captures the owner weakly. An owner that is already executing an async method can still live until that method returns. Arbitrary caller-created strong cycles cannot be automatically repaired; see [memory ownership](SwiftUI.md#memory-ownership).

## Query operations

| Operation | Behavior |
| --- | --- |
| `fetch` | Fresh cached value, otherwise join/start work. |
| `prefetch` | Same cache behavior, suppresses errors. |
| `refetch` | Bypass fresh data, join existing tracked work if present. |
| `invalidate` | Preserve data, mark stale, cancel superseded work, refetch enabled active queries. |
| `invalidate(prefix:)` | Same policy for raw-string prefix matches. |
| `cancel` / `cancelAll` | Revoke request identity, signal task cancellation, resume waiters with CancellationError. |
| `remove` / `removeAll` / `clear` | Cancel work and delete data/operation. Attached observers receive an empty snapshot. |
| `getQueryData` | Read current data, including stale data, without executing an operation. |
| `setQueryData` | Validate type, cancel superseded work, write data, and notify observers. |

Invalidation awaits its active refreshes; refresh failures are available in shared error state. Pass `refetchActive: false` to only mark stale. An inactive query waits for a later fetch. Prefix matching is a raw string match, not a structured key hierarchy: use delimiters such as `"products/"`.

Client `refetch(key:)` requires a registered operation. An adapter's `refetch()` has its own operation and works even before the first fetch or after removal. Adapter `enabled: false` means idle, not error; it reads cached/initial data and allows explicit manual refetch. The low-level throwing `client.fetch(enabled: false)` still throws `QueryError.disabled`, because its `Value` return type cannot represent an empty idle result.

## Cancellation and stale completions

Every completion is checked against the current request ID before changing shared state. Old completions cannot restore removed data, clear newer work, or overwrite newer UI data. Snapshots have monotonic revisions so asynchronously delivered old snapshots cannot regress a result.

Canceling one imperative caller releases that waiter promptly. Shared work continues for other waiters or enabled observers. When the last consumer leaves, the operation task is canceled. Explicit `client.cancel(key)` cancels the shared request for everyone; `query.cancel()` exposes the same behavior. Removing or invalidating work now cancels its waiters too.

Swift task cancellation is cooperative: an operation that ignores cancellation may continue executing, but cannot write back. The package cannot undo server side effects. Use a cancellation-aware transport and suitable service timeouts. `cancelRefetch()` only stops the adapter's manually started polling loop; use `cancel()` for the shared request.

## Observable state and initial values

`isLoading` means fetching without data; `isFetching` also includes refresh with existing data. Errors retain previous data and preserve their concrete error type. `isStale` follows the cache deadline/invalidation. `initialData` is visible immediately and seeds an empty, idle client record when the adapter first attaches. It does not replace a request already in flight. It does not overwrite existing cached data.

`update()` detaches the previous key, stops manual polling, replaces configuration, and optionally retains the previous data as an observer-local placeholder. `isPreviousData` identifies that placeholder; it never seeds the new key's cache. Call `run` or `fetch` after update. For account changes, use a new session client and account-scoped keys, disable previous-data retention, and dispose old adapters.

## Retries and polling

Query `retry` counts extra attempts and defaults to zero. Exponential delays are `retryDelay × 2^(attempt − 1)`. All non-cancellation errors are eligible; there is no error predicate, jitter, or configured backoff cap. The sleep conversion saturates safely for large durations.

Polling performs a cache-aware initial fetch and then **forced refetches** on each tick, regardless of freshness. Intervals must be positive. Disabled queries do not poll. Work is sequential within one loop; ticks do not overlap that loop's request. `run()` supports both polling and non-polling views. `runPeriodicRefetch()` returns after the initial fetch if no interval is configured. Use only one lifecycle loop per adapter. Restart after changing options.

## Mutation and optimistic updates

See [Mutations](Mutations.md). Mutations are independent writes: never query-cached, deduplicated, or automatically retried. Query cache optimistic writes return a conditional rollback token, preventing rollback from overwriting a newer server/cache write. This is a snapshot rollback primitive, not a transaction engine that merges concurrent optimistic edits.

Out of scope: persistence, foreground/reconnect refresh, infinite-query orchestration, and automatic background execution.
