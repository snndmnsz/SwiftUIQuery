# UIKit integration

[Documentation index](../README.md#documentation)

SwiftUIQuery supports UIKit on iOS 15+. Use `ObservableQueryResult` and `ObservableMutationResult` as ordinary stored properties, and subscribe to their `$state` publishers with Combine. No SwiftUI view, property wrapper, or hosting controller is required. The package and import name remain `SwiftUIQuery`.

## Queries and screen lifetime

The [self-contained catalog controller](../Examples/CatalogViewController.swift) shows loading, empty/error states, pull-to-refresh, and cached data. Copy that file into an iOS app target and present `UINavigationController(rootViewController: CatalogViewController())`. Its local demo operation needs no backend.

The essential binding inside a `@MainActor` view controller is:

```swift
// Stored properties; query is an ObservableQueryResult owned by this controller.
private var subscriptions = Set<AnyCancellable>()

override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard subscriptions.isEmpty else { return }
    query.$state.sink { [weak self] state in
        self?.render(state)
    }.store(in: &subscriptions)
    query.startPeriodicRefetch()
}

override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    query.stopObserving()
    subscriptions.removeAll()
}
```

Import `UIKit`, `Combine`, and `SwiftUIQuery`. Keep the result and cancellables alive for the intended screen lifetime. Use weak captures in UI subscriptions so the controller can deallocate.

`$state` immediately delivers the current snapshot and emits subsequent changes on the main actor. Render the closure's `state` argument: `@Published` emits before the stored property is updated, so reading `query.data` inside the sink can return the previous value. Errors appear in `state.error`; they do not terminate the publisher.

`startPeriodicRefetch()` starts a cache-aware fetch and adds polling only when `refetchInterval` is configured. `stopObserving()` detaches this query observer and stops its polling. On the next appearance, bind and start again to read the latest cache. Cancel any separately owned refresh tasks when leaving the screen, as the full example does.

Canceling a Combine subscription only disconnects UI delivery; it does not detach the result from the cache. Call `stopObserving()` for that. Use `cancel()` only when you intend to cancel the shared request for all consumers of the key. `dispose()` additionally releases the operation and data, so it is unsuitable for a temporary disappearance unless you configure the result again with `update(...)`.

## Mutations

Store an `ObservableMutationResult` on the controller or its view model and bind its state the same way:

```swift
save.$state.sink { [weak self] state in
    self?.saveButton.isEnabled = !state.isPending
    self?.errorLabel.text = state.error?.localizedDescription
}.store(in: &subscriptions)
```

Here `save`, `saveButton`, and `errorLabel` belong to your controller. Invoke `try await save.mutate(input)` from an owned task in the button action, and handle the thrown error. The state publisher also reports pending, success, and failure. Keep the task's capture of the controller weak; decide whether the write belongs to the screen or a longer-lived model. Canceling a task does not undo a server-side write. See the [mutation guide](Mutations.md) for cache reconciliation and optimistic rollback.

## Mixed SwiftUI and UIKit apps

Inject the same `QueryClient` and use the same key, result type, and equivalent operation in both frameworks. A UIKit `ObservableQueryResult` and a SwiftUI `QueryResult` or `ObservableQueryResult` then share cached data, in-flight work, invalidation, and mutation-driven cache updates. Each screen owns its own observation lifetime.
