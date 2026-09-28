# Examples

| Example | Minimum OS | Observation style |
| --- | --- | --- |
| [CatalogView15](CatalogView15.swift) | iOS 15 / macOS 14 | `ObservableQueryResult` + `@StateObject` |
| [FavoriteView15](FavoriteView15.swift) | iOS 15 / macOS 14 | Query + mutation, optimistic update and rollback |
| [CatalogView](CatalogView.swift) | iOS 17 / macOS 14 | `QueryResult` + `@State` |
| [CatalogViewController](CatalogViewController.swift) | iOS 15 | UIKit + `ObservableQueryResult.$state` + Combine |

The two SwiftUI catalog examples use the local `DemoCatalog` actor and `CatalogProduct` model declared in `CatalogView.swift`. No server or credentials are needed.

1. Add SwiftUIQuery to your app with Swift Package Manager.
2. Copy both Swift files into the app target.
3. Show `CatalogView15()` for an iOS 15 app, or `CatalogView()` for an iOS 17+ app.
4. Replace `DemoCatalog` with your own concurrency-safe service when ready.

The examples show initial loading, explicit refresh, empty/error states, and preservation of existing data during a failed refresh. The iOS 15 example can be embedded in your app's existing navigation container.

For UIKit, copy only `CatalogViewController.swift` and present `UINavigationController(rootViewController: CatalogViewController())`. It is self-contained and uses no SwiftUI imports. Its Combine subscription renders snapshots, starts the query on appearance, and detaches on disappearance. See the [UIKit guide](../Documentation/UIKit.md).

Run `./Scripts/check-examples.sh` to type-check SwiftUI examples on macOS, and `./Scripts/check-ios15.sh` to compile the library and all SwiftUI/UIKit consumer examples at an iOS 15 deployment target. UIKit code is conditionally excluded on macOS. These are compile checks, not an iOS 15 device execution test.

If your app enables default Main Actor isolation, keep transport models and service code nonisolated using annotations available in your Swift toolchain, or place them in a module with nonisolated defaults.

FavoriteView15.swift is self-contained and uses its own local actor. Copy it into an app target and show FavoriteView15() to try optimistic mutation behavior without a backend. All SwiftUI views use query.run() so their subscriptions follow SwiftUI task cancellation.
