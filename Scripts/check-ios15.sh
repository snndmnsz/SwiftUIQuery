#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
validation_dir="$(mktemp -d)"
trap 'rm -rf "$validation_dir"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target="$(uname -m)-apple-ios15.0-simulator"

# Compile the entire library at the actual minimum target. This catches
# accidental unguarded iOS 16/17 API usage, even on a newer simulator SDK.
xcrun swiftc -emit-module -parse-as-library -swift-version 6 \
  -module-name SwiftUIQuery -target "$target" -sdk "$sdk" \
  Sources/SwiftUIQuery/*.swift Sources/SwiftUIQuery/Internal/*.swift \
  -emit-module-path "$validation_dir/SwiftUIQuery.swiftmodule"

# Check SwiftUI and UIKit examples from an iOS 15 consumer. The modern view is
# availability-guarded; Combine views and the UIKit controller compile unguarded.
xcrun swiftc -typecheck -swift-version 6 \
  -target "$target" -sdk "$sdk" -I "$validation_dir" \
  Examples/*.swift
