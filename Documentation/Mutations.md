# Mutations and optimistic updates

[Documentation index](../README.md#documentation) · [Runnable iOS 15 example](../Examples/FavoriteView15.swift)

Use `ObservableMutationResult<Input, Output>` with `@StateObject` on iOS 15+, or `MutationResult<Input, Output>` with `@State` on iOS 17+. Both are main-actor state adapters with identical behavior.

Unlike a query, every `mutate(input)` call executes its operation independently. There is no cache reuse, request deduplication, or automatic retry. This avoids accidentally skipping a write or repeating a non-idempotent server action.

## Save and refresh

The following fragments assume your app provides a Sendable input/output model and a concurrency-safe service.

```swift
let save = ObservableMutationResult<EditProfile, Profile>(
    operation: { try await service.saveProfile($0) },
    onSuccess: { profile, _ in
        try? await client.setQueryData(key: "profile", data: profile)
    },
    onSettled: { _ in
        await client.invalidate(prefix: "profile/")
    }
)

// From a button's Task:
do {
    let profile = try await save.mutate(edit)
    // The callbacks have finished by this point.
} catch {
    // The same typed error is also available as save.error.
}
```

Use `isPending` to disable duplicate submissions, `data` for the server response, and `error` for failure UI. `variables` retains the submitted input. `reset()` returns to idle; it does not cancel an already-running server write. `dispose()` also releases retained operation/callback closures. An in-flight call still owns its callbacks until it settles.

The callback order is:

1. Set pending state and run `onMutate(input)`.
2. Execute the operation.
3. On success, await `onSuccess(output, input)`.
4. On failure, await the optional rollback, then `onError(error, input)`.
5. Await `onSettled(input)`, then finish success/error state.

Pending state includes reconciliation callbacks. There is no separate fire-and-forget `mutate`: Swift's async throwing method naturally serves the role of `mutateAsync`. Use `Task { try await mutation.mutate(input) }` at a synchronous event boundary and handle the error.

## Optimistic favorite toggle

```swift
let favorite = ObservableMutationResult<Bool, Bool>(
    operation: { try await service.setFavorite($0) },
    onMutate: { desired in
        try await client.optimisticUpdate(key: "favorite", as: Bool.self) { _ in desired }
    },
    onSuccess: { saved, _ in
        try? await client.setQueryData(key: "favorite", data: saved)
    },
    onSettled: { _ in
        await client.invalidate("favorite")
    }
)
```

Every subscribed view immediately receives the optimistic cache value. If the operation throws, the mutation automatically invokes the token returned by `onMutate`. Rollback happens before error callbacks. `onSettled` reconciles with the server after success or failure.

A token's `rollback()` returns false if a newer data write, removal, or an earlier rollback has superseded it. Retain the token only as long as needed: it owns the previous data snapshot. Outside a mutation adapter, call `rollback()` yourself on failure and release the token on success.

**Concurrent edits to the same resource:** the token intentionally refuses to overwrite newer data; it does not rebase or merge optimistic edits. Disable/serialize overlapping writes for that resource, or reconcile once all concurrent writes have settled. A simple snapshot rollback is insufficient to recover every ordering of multiple failed optimistic mutations. Independent resources may mutate concurrently.

## Cache updates

```swift
let previous: [Post]? = try await client.getQueryData(key: "posts")
try await client.setQueryData(key: "posts", data: updatedPosts)
try await client.setQueryData(key: "count", as: Int.self) { ($0 ?? 0) + 1 }
```

The updater is synchronous and actor-isolated: it reads and writes atomically. Keep it quick and side-effect free. A rejected type mismatch does not modify the valid record or cancel its request. Writes cancel superseded requests and notify observers.

## Lifetime and cancellation

Use the `owner:` initializer if the service/view model owns the mutation itself. It captures the operation owner weakly. Callback closures still follow normal Swift ownership rules; use weak captures when callbacks reference their owner.

The caller owns the mutation task. Cancellation reaches a cooperating operation, and a thrown error triggers rollback. Cancellation cannot undo a server write; if the operation returns success despite cancellation, success reconciliation still runs. `reset()` only prevents older calls from restoring displayed state. With concurrent invocations, every call gets its own callbacks/return value, while displayed mutation state belongs to the latest invocation.
