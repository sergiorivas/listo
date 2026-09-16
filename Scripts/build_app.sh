#!/usr/bin/env bash
# Builds Listo.app locally and leaves it in dist/ — no tests, no zip, no
# tag, no publish. Useful for quickly trying a local build (e.g. `open
# dist/Listo.app`) without running the full publish_cask.sh pipeline.
#
# Ad-hoc signed only (no Developer ID cert, no notarization) — fine to run
# directly from dist/, since there's no download involved to get
# Gatekeeper-quarantined in the first place.
#
# Usage: Scripts/build_app.sh [version]
#   Version only affects the .app's Info.plist (CFBundleVersion /
#   CFBundleShortVersionString); defaults to Scripts/version.sh's output.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$("$ROOT_DIR/Scripts/version.sh")}"

APP_NAME="Listo"
BUNDLE_ID="com.listo.app"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building ($VERSION)"
(cd "$ROOT_DIR" && swift build -c release --product ListoApp)

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/.build/release/ListoApp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
[ -f "$ROOT_DIR/Sources/ListoApp/Resources/AppIcon.icns" ] && cp "$ROOT_DIR/Sources/ListoApp/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
    cp -R "$ROOT_DIR/.build/release"/*.bundle "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
