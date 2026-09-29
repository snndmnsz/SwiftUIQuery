# Changelog

## 0.1.1 — 2026-09-29

### Fixed

- Give replacement `run()` and `runPeriodicRefetch()` lifecycles a new generation so cleanup from a canceled task cannot detach the replacement's subscription.
- Keep manual polling alive when canceled and restarted during its initial fetch or before its task begins executing.
- Ignore already-canceled lifecycle and fetch calls instead of letting them tear down another active observation.
- Add five parameterized regression tests covering fourteen scenarios across Observation and Combine adapters.

## 0.1.0 — 2026-09-28

Initial release of SwiftUIQuery for SwiftUI and UIKit.

### Features

- Actor-based query coordination with shared in-flight work and in-memory caching.
- Separate data freshness and inactive-cache lifetimes, automatic collection, and stale notifications.
- Observation adapters for iOS 17+ and Combine adapters for iOS 15+, backed by shared query state.
- Query invalidation, prefix matching, explicit cancellation, prefetching, and typed cache reads and writes.
- View-lifetime observation, periodic refresh, parameter changes, and weak-owner initializers.
- Configurable query retries, backoff, and preservation of existing data during refresh.
- Mutation state, asynchronous callbacks, and conditional optimistic rollback.
- SwiftUI and UIKit examples, API documentation, and integration guides.
- 81 tests covering cache behavior, cancellation, memory lifetime, mutations, and both observation adapters.
- GitHub Actions validation, including iOS 15 API compatibility and iOS Simulator builds.

### Requirements

Swift 6.0+, iOS 15+, or macOS 14+. No third-party dependencies. MIT license.
