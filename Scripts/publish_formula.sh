#!/usr/bin/env bash
# Publishes a new Listo version via the build-from-source Homebrew Formula
# path: tags this commit, pushes it, and regenerates Formula/listo.rb in
# your tap so `brew install`/`brew upgrade` build the app locally on the
# installing machine. Since nothing pre-built is downloaded, there's no
# Gatekeeper quarantine to fight and no Developer ID/notarization needed —
# unlike Scripts/publish_cask.sh (a separate, currently-unused path for
# once there's a paid Apple Developer account to sign/notarize a
# pre-built .app instead).
#
# Fully hands-off on versioning, same as publish_cask.sh: computed from git
# tags (Scripts/version.sh) — the next patch after the latest vX.Y.Z tag —
# and this script creates + pushes that tag itself.
#
# Pipeline:
#   1. swift test
#   2. Tag this commit vX.Y.Z, push the branch and the tag
#   3. Download the tag's GitHub-generated source tarball and hash it
#      (can't be computed locally — must match exactly what `brew install`
#      itself will download)
#   4. Regenerate Formula/listo.rb in LISTO_TAP_DIR with the new
#      version/sha256, commit, and push
#
# Env vars:
#   LISTO_GITHUB_REPO   "owner/listo" (default: sergiorivas/listo)
#   LISTO_TAP_DIR       path to a local checkout of your homebrew tap
#                       (required)
#
# Usage: Scripts/publish_formula.sh [version]
#   Just run it with no arguments in the common case. Pass one explicitly
#   only to override the computed version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$("$ROOT_DIR/Scripts/version.sh")}"
GITHUB_REPO="${LISTO_GITHUB_REPO:-sergiorivas/listo}"
TAP_DIR="${LISTO_TAP_DIR:?Set LISTO_TAP_DIR to a local checkout of your homebrew tap (e.g. git@github.com:sergiorivas/homebrew-tap.git)}"
FORMULA_PATH="$TAP_DIR/Formula/listo.rb"

[ -d "$TAP_DIR/.git" ] || { echo "LISTO_TAP_DIR ($TAP_DIR) is not a git checkout" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "Missing 'shasum' on PATH" >&2; exit 1; }

echo "==> 1/4 Running tests"
# On Apple Silicon, a Rosetta-translated shell (e.g. Terminal/iTerm set to
# "Open using Rosetta") makes the xctest bundle built for arm64 fail to
# load with an architecture-mismatch error — `swift test` still exits 0
# for the (separately reported, unrelated, genuinely empty) Swift Testing
# suite, so this would otherwise silently "pass" zero tests instead of
# actually running the 43 in Tests/. Forcing an arm64 process sidesteps it.
if [[ "$(sysctl -in hw.optional.arm64 2>/dev/null)" == "1" ]] && [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null)" == "1" ]]; then
    (cd "$ROOT_DIR" && arch -arm64 swift test)
else
    (cd "$ROOT_DIR" && swift test)
fi

echo "==> 2/4 Tagging v$VERSION"
if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "    v$VERSION already exists locally"
else
    git -C "$ROOT_DIR" tag -a "v$VERSION" -m "Listo $VERSION"
    echo "    Created tag v$VERSION"
fi
git -C "$ROOT_DIR" push origin HEAD
git -C "$ROOT_DIR" push origin "v$VERSION"

echo "==> 3/4 Hashing the release tarball"
TARBALL_URL="https://github.com/$GITHUB_REPO/archive/refs/tags/v$VERSION.tar.gz"
TMP_TARBALL="$(mktemp -t listo-release-XXXXXX).tar.gz"
trap 'rm -f "$TMP_TARBALL"' EXIT
# GitHub needs a moment after the tag push before the archive endpoint
# reflects it; a couple of quick retries avoids a spurious 404.
for attempt in 1 2 3; do
    if curl -fsSL "$TARBALL_URL" -o "$TMP_TARBALL"; then
        break
    fi
    [ "$attempt" -eq 3 ] && { echo "Couldn't download $TARBALL_URL" >&2; exit 1; }
    sleep 3
done
SHA256="$(shasum -a 256 "$TMP_TARBALL" | awk '{print $1}')"

echo "    version = $VERSION"
echo "    sha256  = $SHA256"

echo "==> 4/4 Updating the tap formula"
mkdir -p "$TAP_DIR/Formula"
cat > "$FORMULA_PATH" <<RUBY
class Listo < Formula
  desc "To-do list that lives as plain Markdown on disk"
  homepage "https://github.com/$GITHUB_REPO"
  url "https://github.com/$GITHUB_REPO/archive/refs/tags/v$VERSION.tar.gz"
  sha256 "$SHA256"

  def install
    system "swift", "build", "-c", "release", "--product", "ListoApp"

    app = prefix/"Listo.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath
    cp ".build/release/ListoApp", app/"Contents/MacOS/Listo"

    (app/"Contents/Info.plist").write <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>CFBundleExecutable</key><string>Listo</string>
          <key>CFBundleIdentifier</key><string>com.listo.app</string>
          <key>CFBundleName</key><string>Listo</string>
          <key>CFBundleDisplayName</key><string>Listo</string>
          <key>CFBundleVersion</key><string>#{version}</string>
          <key>CFBundleShortVersionString</key><string>#{version}</string>
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

    # Ad-hoc sign, same as a local \`swift build\`/Xcode run already does —
    # keeps AMFI/Gatekeeper happy about an unsigned binary. Since the app
    # is built locally rather than downloaded, macOS never quarantines it
    # in the first place, so this is belt-and-suspenders, not a
    # replacement for real notarization.
    system "codesign", "--force", "--deep", "--sign", "-", app

    prefix.install app
    system "ln", "-sf", app, "/Applications/Listo.app"
  end

  def caveats
    <<~EOS
      Listo.app was symlinked into /Applications so it shows up in
      Launchpad/Finder like a normal Mac app.

      Note for \`brew uninstall\`: it only removes files inside the
      Homebrew prefix, so the /Applications symlink is left behind
      (pointing at a now-missing app) — remove it yourself if needed:
        rm /Applications/Listo.app
    EOS
  end
end
RUBY

(
    cd "$TAP_DIR"
    git add Formula/listo.rb
    if git diff --cached --quiet; then
        echo "    No changes to commit in the tap"
    else
        git commit -m "listo $VERSION"
        git push
        echo "    Formula published to $TAP_DIR"
    fi
)

echo "==> Done. 'brew install sergiorivas/tap/listo' (or 'brew upgrade listo') should build $VERSION."
