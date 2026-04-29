#!/usr/bin/env bash
set -x
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
#   APPLE_TEAM_ID           10-char team ID (used in exportOptions.plist)
#
# Notarization — choose one:
#   KEYCHAIN_PROFILE        name of a stored notarytool keychain profile
#                           (preferred; avoids passing credentials inline)
#   APPLE_ID + APPLE_APP_PASSWORD + APPLE_TEAM_ID
#                           inline credentials used when KEYCHAIN_PROFILE
#                           is not set
#
# Optional env vars:
#   SKIP_NOTARIZE=1         skip notarization entirely (local/dev builds)
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
APP_BUNDLE="$EXPORT_PATH/$APP_NAME.app"
ENTITLEMENTS_PATH="apps/MacServer/SimulatorCameraServer/SimulatorCameraServer.entitlements"

sign() {
    local path="$1"
    echo "▶︎ Signing: $path"

    codesign --force --options runtime \
        --sign "$DEVELOPER_ID_APP_CERT" \
        --timestamp \
        "$path"
}
verify() {
    codesign --verify --deep --strict --verbose=2 "$1"
}

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "✗ xcodegen is required to generate $PROJECT from $PROJECT_SPEC"
    exit 1
fi

xcodegen generate --spec "$PROJECT_SPEC" >/dev/null

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

ARCH="${ARCH:-arm64}"

if [[ "$ARCH" == "x86_64" ]]; then
    ARCH_FLAGS="ARCHS=x86_64"
else
    ARCH_FLAGS="ARCHS=arm64"
fi

echo "▶︎ Building for architecture: $ARCH"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    $ARCH_FLAGS \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP_CERT" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    archive | xcpretty || true

echo "▶︎ Exporting .app with Developer ID signing"

cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>signingCertificate</key>      <string>Developer ID Application</string>
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
    -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" | xcpretty

echo "▶︎ Re-signing app bundle WITHOUT --deep (deterministic)"
APP_PATH="$APP_BUNDLE"
# 1. Sign embedded frameworks (if any)
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    find "$APP_PATH/Contents/Frameworks" -type f -name "*" | while read -r f; do
        file "$f" | grep -q "Mach-O" && sign "$f" || true
    done

    find "$APP_PATH/Contents/Frameworks" -type d -name "*.framework" | while read -r fw; do
        sign "$fw"
    done
fi

# 2. Sign helper tools / XPC services (if any)
if [ -d "$APP_PATH/Contents/XPCServices" ]; then
    find "$APP_PATH/Contents/XPCServices" -type d -name "*.xpc" | while read -r xpc; do
        sign "$xpc"
    done
fi

# 3. Sign main executable
sign "$APP_PATH/Contents/MacOS/$APP_NAME"

# 4. Finally sign the .app bundle WITH entitlements
echo "▶︎ Signing app bundle (final step)"
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$DEVELOPER_ID_APP_CERT" \
    --timestamp \
    "$APP_PATH"

verify "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    echo "▶︎ Notarizing (this can take several minutes)"
    ZIP_FOR_NOTARY="$BUILD_DIR/$APP_NAME-notary.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_FOR_NOTARY"

    if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    else
        SUBMISSION_OUTPUT=$(xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait --output-format json)
        echo "$SUBMISSION_OUTPUT"
        SUBMISSION_ID=$(echo "$SUBMISSION_OUTPUT" | jq -r '.id')

        xcrun notarytool log --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" "$SUBMISSION_ID"
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
