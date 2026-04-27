#!/usr/bin/env bash
#
# build-release.sh — archive, codesign, notarize, staple, and package
#                    the Mac companion app for a GitHub Release.
#
# Produces:
#   dist/SimulatorCamera-<VERSION>.dmg
#   dist/SimulatorCamera-<VERSION>.zip
#   dist/SimulatorCamera-<VERSION>.sha256
#
# Required env vars:
#   VERSION                 e.g. 0.2.0  (else read from git tag)
#   APPLE_DEVELOPER_ID      "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID                Apple ID used for notarization
#   APPLE_APP_PASSWORD      app-specific password for notarytool
#   APPLE_TEAM_ID           10-char team ID
#
# Optional env vars:
#   KEYCHAIN_PROFILE        reuse a stored notarytool profile instead of
#                           ID+password (takes precedence if set)
#   SKIP_NOTARIZE=1         for local/dev builds
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0-dev)}"
APP_NAME="SimulatorCameraServer"
SCHEME="SimulatorCameraServer"
PROJECT="apps/MacServer/SimulatorCameraServer.xcodeproj"
PROJECT_SPEC="apps/MacServer/project.yml"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "✗ xcodegen is required to generate $PROJECT from $PROJECT_SPEC"
    exit 1
fi

xcodegen generate --spec "$PROJECT_SPEC" >/dev/null

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "▶︎ Archiving $APP_NAME $VERSION"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    archive | xcpretty || true

echo "▶︎ Exporting .app with Developer ID signing"
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>                  <string>developer-id</string>
    <key>teamID</key>                  <string>${APPLE_TEAM_ID:-}</string>
    <key>signingStyle</key>            <string>manual</string>
    <key>stripSwiftSymbols</key>       <true/>
</dict>
</plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" | xcpretty || true

APP_BUNDLE="$EXPORT_PATH/$APP_NAME.app"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    echo "▶︎ Notarizing (this can take several minutes)"
    ZIP_FOR_NOTARY="$BUILD_DIR/$APP_NAME-notary.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_FOR_NOTARY"

    if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    else
        xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait
    fi

    echo "▶︎ Stapling"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
else
    echo "▶︎ SKIP_NOTARIZE set — skipping notarization"
fi

echo "▶︎ Packaging .zip"
ZIP_OUT="$DIST_DIR/SimulatorCamera-$VERSION.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_OUT"

echo "▶︎ Packaging .dmg"
DMG_OUT="$DIST_DIR/SimulatorCamera-$VERSION.dmg"
hdiutil create \
    -volname "SimulatorCamera $VERSION" \
    -srcfolder "$APP_BUNDLE" \
    -ov -format UDZO \
    "$DMG_OUT"

echo "▶︎ Computing checksums"
(
    cd "$DIST_DIR"
    shasum -a 256 \
        "SimulatorCamera-$VERSION.zip" \
        "SimulatorCamera-$VERSION.dmg" \
        > "SimulatorCamera-$VERSION.sha256"
)

echo
echo "✅ Done."
ls -lh "$DIST_DIR"
