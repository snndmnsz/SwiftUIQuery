# Recipes

[Documentation index](../README.md#documentation)

Fragments assume your app provides the referenced Sendable models and concurrency-safe service. See [complete examples](../Examples).

## Prefetch before navigation

```swift
await client.prefetch(key: QueryKey("product/\(productID)"), staleTime: .minutes(1)) {
    try await service.product(id: productID)
}
```

The destination can reuse the same client's fresh value. Prefetch suppresses errors; use fetch when the caller needs to handle failure.

## Refresh after a write

```swift
try await service.save(product)
await client.invalidate(prefix: "products/")
```

Enabled active queries automatically refresh and update subscribed views. Inactive queries remain stale until next fetched. Prefixes match raw strings; choose stable separators. For operation state and optimistic rollback, use a [mutation adapter](Mutations.md).

## Write a response directly

```swift
let saved = try await service.saveProfile(edit)
try await client.setQueryData(key: "profile", data: saved)
```

This cancels obsolete reads and updates subscribed UI without requiring another service call. Use invalidation when the server response does not contain enough data to update a query accurately.

## Isolate accounts

```swift
let sessionClient = QueryClient()
let key = QueryKey("account/\(accountID)/profile")
```

On sign-out, stop the old view tasks, dispose old adapters, and removeAll on the old client. Use a new client and account-scoped keys for the next session. Removal cancels request waiters and resets subscribed query state. The package cannot retract a mutation already accepted by a server; reconcile session changes in your service layer too.

## Retry transient query failures

```swift
let products: [Product] = try await client.fetch(
    key: "products", retry: 2,
    retryDelay: .seconds(1), exponentialBackoff: true
) { try await service.products() }
```

At most three attempts, with one-second and two-second waits. Built-in query retries apply to every non-cancellation error. Use retry: 0 if your service already retries or needs to distinguish status codes. Mutations never automatically retry.

## Log the query identity

```swift
if let key = QueryExecutionContext.currentKey {
    print("Loading query: \(key.rawValue)")
}
```

Use nonsensitive keys. The context is task-local inside a query operation; transport code needs no client parameter.

## Seed a preview or initial response

```swift
@MainActor
func previewQuery() -> ObservableQueryResult<[String]> {
    ObservableQueryResult(key: "preview/names", client: QueryClient(),
                          initialData: ["Avery", "Robin"]) {
        ["Avery", "Robin"]
    }
}
```

Initial data is immediately visible. On first attachment, it seeds an empty client record and uses the configured staleTime. It never overwrites an existing cached value. With staleTime zero, it stays visible while the first request refreshes it.

## Test in isolation

Create a new QueryClient for each test instead of sharing the singleton. Use continuation-controlled operations for request races and observable conditions for lifecycle transitions. [QueryLifecycleTests](../Tests/SwiftUIQueryTests/QueryLifecycleTests.swift), [MemoryLifetimeTests](../Tests/SwiftUIQueryTests/MemoryLifetimeTests.swift), and [MutationTests](../Tests/SwiftUIQueryTests/MutationTests.swift) cover shared state, ARC lifetime, cancellation, and rollback.
