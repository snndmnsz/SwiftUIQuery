#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
build_dir="$(swift build --show-bin-path)"
swiftc -typecheck -swift-version 6 \
  -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I "$build_dir" -I "$build_dir/Modules" \
  Examples/*.swift
