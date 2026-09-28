# Supporting iOS 15

[Documentation index](../README.md#documentation)

SwiftUIQuery supports iOS 15+ through Combine and iOS 17+ through Observation. The package requires a Swift 6.0+ toolchain and macOS 14+ for Mac apps. Toolchain version and deployment target are separate requirements.

## Which type should I use?

| Your app's minimum iOS | Result type | Owning view | Observing child view |
| --- | --- | --- | --- |
| 15 or 16 | `ObservableQueryResult<Value>` | `@StateObject` | `@ObservedObject` |
| 17 or later | `QueryResult<Value>` | `@State` | Plain stored property |

`ObservableQueryResult` works on iOS 17 and later too. An iOS 15 app can use it everywhere without `if #available` branches. It uses Apple's Combine framework; no third-party backport is required.

## Existing iOS 17 apps

Use `QueryResult` with `@State` to observe query state on iOS 17+. Its availability annotation lets the package also provide Combine adapters for older deployment targets.

## Apps lowering their minimum to iOS 15

Replace the result type and observation wrappers together:

```swift
// Before: iOS 17+
@State private var query: QueryResult<[Product]>

// After: iOS 15+
@StateObject private var query: ObservableQueryResult<[Product]>
```

In a custom initializer, construct the result through `StateObject(wrappedValue:)`, as shown in [CatalogView15](../Examples/CatalogView15.swift). Use `@ObservedObject` in children receiving that object. The fetch, refetch, update, polling, and cache APIs stay the same.

Changing the package alone does not lower your app's deployment target or backport other app APIs. Check your views for newer features such as `NavigationStack` before lowering the app's own target.

## What is shared?

Both public result types delegate to a single internal controller. Query identity, cache behavior, retries, retained previous data, generation checks, and periodic loading follow the same code path. The Observation adapter tracks reads; the Combine adapter publishes state changes through `$state` and `objectWillChange`.

Attached result objects sharing a client/key receive the same cache state updates, even when one uses Combine and the other Observation. Use run() from a view task to attach for its lifetime.

## Validation

The test suite covers both adapters, including loading transitions, stale completion protection, errors with previous data, disabled queries, and periodic cancellation. Dedicated checks verify Combine publication and Observation notifications.

`./Scripts/check-ios15.sh` compiles every library source and all consumer examples against an explicit `iOS 15.0` deployment target. CI also builds the package for iOS Simulator with that target. These checks catch unguarded newer APIs; they do not replace running your application on an iOS 15 device or simulator.

## Mutations

Use ObservableMutationResult<Input, Output> on iOS 15+, or MutationResult<Input, Output> on iOS 17+. The state, callbacks, optimistic rollback, and concurrency rules are identical. See [Mutations](Mutations.md).
