#!/usr/bin/env bash
# Listo release script (spec §08): build → codesign → notarize → staple.
# Run by hand for each release; no CI pipeline yet.
#
# Requires:
#   - An Apple Developer ID Application certificate in the login keychain.
#   - `xcrun notarytool` credentials stored under the profile name below
#     (set up once via: xcrun notarytool store-credentials listo-notary
#      --apple-id you@example.com --team-id TEAMID --password app-specific-pw)
#
# Usage: Scripts/release.sh [version]
#   No version needed — it's computed from git tags (Scripts/version.sh):
#   the next patch after the latest vX.Y.Z tag, or that tag's own version
#   if HEAD is already tagged. Pass one explicitly only to override that.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$("$ROOT_DIR/Scripts/version.sh")}"
APP_NAME="Listo"
BUNDLE_ID="com.listo.app"
SIGNING_IDENTITY="${LISTO_SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${LISTO_NOTARY_PROFILE:-listo-notary}"

BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

echo "==> Building ($VERSION)"
cd "$ROOT_DIR"
swift build -c release --product ListoApp

echo "==> Assembling .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/ListoApp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Sources/ListoApp/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Listo Markdown List</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSItemContentTypes</key>
            <array><string>net.daringfireball.markdown</string></array>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -d "$ROOT_DIR/Sources/ListoApp/Resources" ]; then
    cp -R "$BUILD_DIR"/*.bundle "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

echo "==> Codesigning"
codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Zipping for notarization"
mkdir -p "$DIST_DIR"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Submitting to notarytool"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP_BUNDLE"

echo "==> Re-zipping stapled app"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Done: $ZIP_PATH"
echo "    Update Casks/listo.rb with this version's URL and 'shasum -a 256 $ZIP_PATH'."
