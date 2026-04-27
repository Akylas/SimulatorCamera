#!/usr/bin/env bash
#
# smoke-test.sh — local end-to-end sanity check.
#
# 1. `swift build`s the iOS SDK (SimulatorCameraClient) for macOS to make
#    sure the whole Swift package still compiles after the v0.2.0 shim.
# 2. `swift test` runs the SCMF codec unit tests.
# 3. Boots the Mac companion app if an .xcodeproj exists (otherwise reports
#    what's missing and stops).
# 4. Opens the iOS Simulator with a recent iPhone runtime.
#
# Run from the repo root:
#   ./scripts/smoke-test.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

say() { printf "\n\033[1;34m▶︎\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$*"; exit 1; }

say "swift --version"
swift --version || die "Swift toolchain not found — install Xcode command line tools."

say "swift build"
swift build
ok "SwiftPM package compiles."

say "swift test"
swift test
ok "Unit tests pass."

MAC_PROJ="apps/MacServer/SimulatorCameraServer.xcodeproj"
MAC_SPEC="apps/MacServer/project.yml"
if command -v xcodegen >/dev/null 2>&1 && [[ -f "$MAC_SPEC" ]]; then
    say "Generating Mac project"
    xcodegen generate --spec "$MAC_SPEC" >/dev/null
fi

if [[ -d "$MAC_PROJ" ]]; then
    say "xcodebuild -list ($MAC_PROJ)"
    xcodebuild -list -project "$MAC_PROJ" | head -40
    ok "Mac companion project loads."

    say "Launching SimulatorCameraServer.app (debug build)"
    xcodebuild -project "$MAC_PROJ" \
        -scheme SimulatorCameraServer \
        -configuration Debug \
        -derivedDataPath .build/mac \
        build | tail -5
    open ".build/mac/Build/Products/Debug/SimulatorCameraServer.app"
    ok "Mac server launched — pick 'Mac Camera' and click Start."
else
    warn "No .xcodeproj at $MAC_PROJ yet."
    warn "Generate it with XcodeGen: brew install xcodegen && xcodegen generate --spec \"$MAC_SPEC\""
fi

say "Booting iOS Simulator"
SIM_NAME="iPhone 15"
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
open -a Simulator
ok "Simulator up. Run the iOS demo app against it and watch for frames."

cat <<'EOF'

---------------------------------------------------------------
Next manual steps:
  1. In the Mac server window: choose 'Mac Camera', click Start.
     You should see 'Streaming from Mac camera' and a frame counter.
  2. In Xcode, open apps/iOSDemo/ and Run to the iPhone 15 Simulator.
  3. The demo view should show your webcam feed at ~25–30 FPS with
     a green "Streaming" badge.

If the Simulator stays black with 'Waiting for SimulatorCamera...',
check the Mac app says 'Client connected' and that port 9876 isn't
blocked by a local firewall.
---------------------------------------------------------------
EOF
