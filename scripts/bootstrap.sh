#!/usr/bin/env bash
# Bootstrap a fresh checkout: build SDK, lint, run tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ Swift version"
swift --version

echo "▶ Building SimulatorCameraClient"
swift build -c debug

echo "▶ Running tests"
swift test --parallel

if command -v swiftlint >/dev/null 2>&1; then
  echo "▶ SwiftLint"
  swiftlint --strict || true
fi

echo "✅ Bootstrap complete."
echo "   Next: open apps/MacServer/SimCameraServer.xcodeproj to run the Mac server."
