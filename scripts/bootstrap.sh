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
if command -v xcodegen >/dev/null 2>&1; then
  echo "▶ Generating Xcode projects"
  xcodegen generate --spec apps/MacServer/project.yml >/dev/null
  xcodegen generate --spec apps/iOSDemo/project.yml >/dev/null
  echo "   Next: open apps/MacServer/SimulatorCameraServer.xcodeproj to run the Mac server."
  echo "         open apps/iOSDemo/SimCameraDemo.xcodeproj to run the sample app."
else
  echo "   Install xcodegen to generate the Mac and iOS app projects."
fi
