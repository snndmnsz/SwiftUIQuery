# API reference

[Documentation index](../README.md#documentation)

API baseline: **0.1.0**. Swift 6.0+, iOS 15+, macOS 14+.

## QueryClient

An actor; calls from outside its isolation use `await`.

| Method | Purpose |
| --- | --- |
| `fetch(key:cacheTime:staleTime:gcTime:enabled:retry:retryDelay:exponentialBackoff:_:)` | Return fresh cached data, join work, or run the supplied operation. |
| `prefetch(key:cacheTime:staleTime:gcTime:retry:retryDelay:exponentialBackoff:_:)` | Cache-aware fetch that suppresses errors. |
| `refetch<Value>(key:)` | Rerun the registered operation. |
| `invalidate(_:refetchActive:)` | Mark stale and optionally await active refresh. |
| `invalidateAll(refetchActive:)` | Invalidate all records. |
| `invalidate(prefix:refetchActive:)` | Match raw-string key prefixes. |
| `cancel(_:)`, `cancelAll()` | Cancel shared work and unblock callers. |
| `remove(_:)`, `removeAll()`, `clear()` | Cancel work, clear data and registration, reset observers. |
| `getQueryData(key:as:)` | Read cached Value? without fetching. |
| `setQueryData(key:data:gcTime:)` | Set typed cache data and notify observers. gcTime is used when creating a new record. |
| `setQueryData(key:as:update:)` | Atomically transform Value? into Value. |
| `optimisticUpdate(key:as:update:)` | Write optimistically and return QueryRollback. |

`shared` is a convenience singleton. Prefer an injected client per app/session for isolation. Query operations are `@Sendable () async throws -> Value`, with `Value: Sendable`. Cache access validates the key's result type. An optional result is supported: an outer nil means absent data, while a cached optional nil remains a real result.

## QueryOptions

| Property | Default | Meaning |
| --- | --- | --- |
| `enabled` | true | Allow adapter automatic fetching/polling/invalidation refetch. |
| `staleTime` | 5 minutes | Freshness of a successful value. |
| `cacheTime` | alias for staleTime | Alternative spelling. An explicit staleTime initializer argument takes precedence. |
| `gcTime` | 5 minutes | Idle, unobserved lifetime before record/closure collection. |
| `retry` | 0 | Additional attempts; initializer clamps negative values to zero. |
| `retryDelay` | 1 second | Retry base delay. |
| `exponentialBackoff` | false | Multiply retry delay by powers of two. |
| `refetchInterval` | nil | Optional positive interval for forced periodic refetch. |
| `keepPreviousData` | true | Keep observer-local previous-key placeholder after update. |

`CacheDuration.seconds/minutes/hours/days` constructs durations. Negative and NaN values normalize to zero. Very large sleep durations saturate rather than overflowing.

## Query adapters

- `ObservableQueryResult<Value>`: Combine ObservableObject, iOS 15+, own with @StateObject in SwiftUI or a stored property and `$state` subscription in UIKit.
- `QueryResult<Value>`: Observation @Observable, iOS 17+, own with @State.

Both are @MainActor and initialize with `key`, `client`, `options`, `initialData`, and `operation`. An `owner:` convenience initializer captures an `AnyObject & Sendable` owner weakly and passes it to the operation. Main-actor view models satisfy Sendable isolation requirements.

State: `state`, `data`, `error`, `isLoading`, `isFetching`, `isSuccess`, `isError`, `isResolved`, `lastUpdated`, `isStale`, `isPreviousData`.

Methods: `fetch()`, `refetch()`, `run()`, `runPeriodicRefetch()`, `startPeriodicRefetch()`, `cancelRefetch()`, `cancel()`, `stopObserving()`, `dispose()`, `update(key:client:options:operation:)`, `update(from:)`.

`run` observes for the caller's task lifetime. `fetch`/`refetch` perform one load but keep observing. `cancel` cancels the shared request; `cancelRefetch` only cancels manually started polling. `dispose` clears the operation and data; `update` can configure the result again.

`QueryState<Value>` is a Sendable snapshot. `isSuccess` means data with no error; `isError` means error exists; `isResolved` means data or error exists. Previous data may coexist with a refresh error.

## Mutation adapters

- `ObservableMutationResult<Input, Output>`: Combine, iOS 15+, supports SwiftUI and UIKit via `$state`.
- `MutationResult<Input, Output>`: Observation, iOS 17+.

Both are @MainActor; Input and Output conform to Sendable.

Initializer: `operation`, optional `onMutate`, `onSuccess`, `onError`, `onSettled`. The `owner:` overload captures the operation owner weakly. Callback closures remain responsible for their own capture policies.

- `operation`: @Sendable (Input) async throws -> Output.
- `onMutate`: @MainActor (Input) async throws -> QueryRollback?.
- `onSuccess`: @MainActor (Output, Input) async -> Void.
- `onError`: @MainActor (any Error, Input) async -> Void.
- `onSettled`: @MainActor (Input) async -> Void.

`mutate(_:) async throws -> Output` runs a write and callbacks. `reset()` returns state to idle. `dispose()` also releases stored callbacks and operation. No implicit retry or deduplication.

State: `state`, `data`, `variables`, `error`, `isPending`, `isSuccess`, `isError`, `isIdle`. `MutationState<Input, Output>.status` is `MutationStatus.idle/pending/success/error`.

`QueryRollback.rollback() async -> Bool` restores its saved snapshot only if no newer data supersedes it. See [concurrency limitations](Mutations.md#optimistic-favorite-toggle).

## Errors and context

`QueryError`: disabled, missingOperation, typeMismatch, cancelled, underlying, disposed, ownerReleased, invalidRefetchInterval. Task cancellation uses Swift CancellationError. Service errors preserve their concrete type.

`QueryExecutionContext.currentKey` is a task-local optional QueryKey during query operation execution. QueryKey is a Hashable, Sendable raw-string identifier with string-literal support.
