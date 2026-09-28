# Getting started

[Documentation index](../README.md#documentation)

## Requirements

| Requirement | Minimum |
| --- | --- |
| Swift toolchain | 6.0 |
| iOS deployment target | 15.0 |
| macOS deployment target | 14.0 |
| Package manager | Swift Package Manager |

The manifest uses Swift 6 language mode. Result values must conform to `Sendable`, and query operations are `@Sendable` closures. The package has no third-party dependencies.

## Add the package

In Xcode, open **File → Add Package Dependencies**, paste `https://github.com/snndmnsz/SwiftUIQuery.git`, select a version, and add the library product to your target. For the 0.1 series, prefer **Up to Next Minor Version** starting at `0.1.0`.

Do not embed credentials in the package URL or commit access tokens.

To work on a local checkout, add its folder as a local package in Xcode. A Swift package can also depend on `.package(path: "../SwiftUIQuery")` during development.

## Fetch a value

This example needs no network service:

```swift
import SwiftUIQuery

func loadGreeting() async throws -> String {
    let client = QueryClient.shared
    return try await client.fetch(key: "greeting", cacheTime: .minutes(1)) {
        "Hello, SwiftUIQuery!"
    }
}
```

Replace the closure with your existing async service call. Your service owns requests, authentication, status-code validation, and decoding. SwiftUIQuery owns query coordination.

## Choose a client lifetime

`QueryClient.shared` is convenient for a single shared cache. Create `QueryClient()` when a feature, test, or account session needs an independent cache. Keep the client alive for as long as you want to reuse its results; creating a new client for every request defeats caching.

## Choose a key

```swift
let key = QueryKey("account:\(accountID):posts:page:\(page)")
```

Include every input that changes the result. Use the same result type and equivalent operation for every use of a key. Keep keys stable and avoid access tokens or other secrets: keys may appear in errors or logs.

## Show results in SwiftUI

For iOS 15+, use [CatalogView15](../Examples/CatalogView15.swift) and copy the shared demo model/service from [CatalogView.swift](../Examples/CatalogView.swift). The iOS 17+ `CatalogView` uses Observation. Both examples use a local actor as a simulated service, so no credentials are needed. Replace `DemoCatalog.loadProducts()` with your own service when ready. See the [compatibility guide](iOS15.md) for adapter selection.

Then follow the [SwiftUI guide](SwiftUI.md) for refresh and parameter changes.

## Show results in UIKit

Copy the self-contained [CatalogViewController](../Examples/CatalogViewController.swift) into an iOS 15+ app target. Store the Combine adapters as ordinary properties and bind their `$state` publishers. Follow the [UIKit guide](UIKit.md) for screen lifecycle, refresh, and mutations.

## Verify a checkout

Run from the repository root on a Mac with an active Xcode toolchain:

```sh
swift build
swift test
./Scripts/check-examples.sh
./Scripts/check-ios15.sh
```

The tests use Swift Testing and do not require an iOS Simulator or a live backend. The example scripts check SwiftUI code on macOS and all SwiftUI/UIKit examples at an explicit iOS 15 target. CI also builds for iOS Simulator. Compiling with an iOS 15 deployment target checks API availability; it is not an execution test on an iOS 15 runtime.
