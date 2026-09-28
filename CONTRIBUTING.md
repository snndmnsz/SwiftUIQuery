# Contributing

Thanks for helping improve SwiftUIQuery.

## Local setup

Use a Mac with a Swift 6-capable Xcode toolchain. Clone the repository, then run:

```sh
swift build
swift test
./Scripts/check-examples.sh
./Scripts/check-ios15.sh
```

`Sources/SwiftUIQuery` contains the library; `Tests/SwiftUIQueryTests` contains Swift Testing tests. `Examples` contains app-side usage code, not another published product.

## Changes

Keep pull requests focused. Add behavior tests for changes to caching, retries, concurrency, or state transitions. Prefer deterministic synchronization to timing assumptions. Keep tests independent so they can run in parallel.

Document observable behavior changes in `Documentation` and `CHANGELOG.md`. Do not add a dependency or raise deployment targets without discussing it in the pull request. Do not commit build output, local Xcode state, credentials, or app-specific data.

Contributions are provided under the repository's MIT license.

## Release checklist for maintainers

1. Review the diff and update the changelog.
2. Run the local commands above and require a successful CI run.
3. Update the README's version badge and installation baseline if appropriate.
4. Commit the release changes and create an annotated semantic-version tag, such as `0.1.1`.
5. Push the commit and tag, then create a GitHub release describing the changes.

Use patch versions for compatible fixes, and minor versions for API changes during the 0.x series. Existing tags must not be moved to different commits.
