#!/usr/bin/env bash
# Publishes a new Listo version via a prebuilt-binary Homebrew Cask: builds
# an ad-hoc-signed .app locally, uploads it as a GitHub release asset, and
# regenerates Casks/listo.rb in your tap to download that zip and install
# it directly — no `swift build` on the installing machine.
#
# This is a Cask, not a Formula, because Homebrew's Formula `install` step
# runs inside a sandbox that only permits writes under HOMEBREW_PREFIX (and
# a few other Homebrew-owned paths) — there's no way for a Formula to write
# Listo.app into /Applications itself. Casks exist precisely to place a
# macOS .app into /Applications, and aren't subject to that sandbox.
#
# There's no Developer ID cert or notarization here — that would need a
# paid Apple Developer account. Downloaded files get Gatekeeper-quarantined
# regardless of signing, so the cask's `postflight` strips that with
# `xattr -cr` on the installed app — good enough to open an ad-hoc-signed
# app, not a replacement for the real thing.
#
# Fully hands-off on versioning: computed from git tags (Scripts/version.sh)
# — the next patch after the latest vX.Y.Z tag — and this script creates +
# pushes that tag itself.
#
# Pipeline:
#   1. swift test
#   2. Build the .app bundle, ad-hoc codesign it, zip it
#   3. Tag this commit vX.Y.Z, push the branch and the tag
#   4. Create/update the vX.Y.Z GitHub release and upload the zip asset
#   5. Regenerate Casks/listo.rb in LISTO_TAP_DIR with the new
#      version/url/sha256, commit, and push
#
# Env vars:
#   LISTO_GITHUB_REPO   "owner/listo" (default: sergiorivas/listo)
#   LISTO_TAP_DIR       path to a local checkout of your homebrew tap
#                       (default: ../homebrew-tap, alongside this repo)
#
# Usage: Scripts/publish_cask.sh [version]
#   Just run it with no arguments in the common case. Pass one explicitly
#   only to override the computed version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$("$ROOT_DIR/Scripts/version.sh")}"
GITHUB_REPO="${LISTO_GITHUB_REPO:-sergiorivas/listo}"
TAP_DIR="${LISTO_TAP_DIR:-$ROOT_DIR/../homebrew-tap}"
CASK_PATH="$TAP_DIR/Casks/listo.rb"

APP_NAME="Listo"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_NAME="Listo-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

[ -d "$TAP_DIR/.git" ] || { echo "LISTO_TAP_DIR ($TAP_DIR) is not a git checkout" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "Missing 'shasum' on PATH" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "Missing 'gh' on PATH" >&2; exit 1; }

echo "==> 1/5 Running tests"
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

echo "==> 2/5 Building and packaging ($VERSION)"
"$ROOT_DIR/Scripts/build_app.sh" "$VERSION"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

# Homebrew's Formula stage step auto-cd's into an archive's single
# top-level directory before running `install` (a heuristic for tarballs
# like "mypkg-1.2.3/" that wrap the real payload) — a zip made from
# Listo.app alone would have exactly one top-level entry and trip that
# heuristic. Casks don't do this auto-cd, but staging a second top-level
# file alongside the app costs nothing and keeps the zip's layout
# unambiguous either way.
STAGE_DIR="$DIST_DIR/stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
cat > "$STAGE_DIR/PACKAGE_INFO.txt" <<EOF
Listo $VERSION
https://github.com/$GITHUB_REPO
EOF
ditto -c -k "$STAGE_DIR" "$ZIP_PATH"
rm -rf "$STAGE_DIR"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "    sha256 = $SHA256"

echo "==> 3/5 Tagging v$VERSION"
if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "    v$VERSION already exists locally"
else
    git -C "$ROOT_DIR" tag -a "v$VERSION" -m "Listo $VERSION"
    echo "    Created tag v$VERSION"
fi
git -C "$ROOT_DIR" push origin HEAD
git -C "$ROOT_DIR" push origin "v$VERSION"

echo "==> 4/5 Publishing the GitHub release"
if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP_PATH" --repo "$GITHUB_REPO" --clobber
else
    gh release create "v$VERSION" "$ZIP_PATH" \
        --repo "$GITHUB_REPO" \
        --title "Listo $VERSION" \
        --notes "See the commit history for what's in this version."
fi

echo "==> 5/5 Updating the tap cask"
mkdir -p "$TAP_DIR/Casks"
cat > "$CASK_PATH" <<RUBY
cask "listo" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/Listo-#{version}.zip"
  name "Listo"
  desc "To-do list that lives as plain Markdown on disk"
  homepage "https://github.com/$GITHUB_REPO"

  app "Listo.app"

  postflight do
    # This build is ad-hoc signed, not notarized by Apple (that needs a
    # paid Developer ID account) — macOS would otherwise refuse to open
    # it because of the Gatekeeper quarantine flag the download picked
    # up.
    system_command "/usr/bin/xattr", args: ["-cr", "#{appdir}/Listo.app"]
  end

  caveats do
    <<~EOS
      This build is ad-hoc signed, not notarized by Apple. If macOS still
      refuses to open it, run:
        xattr -cr #{appdir}/Listo.app
    EOS
  end
end
RUBY
if [ -f "$TAP_DIR/Formula/listo.rb" ]; then
    git -C "$TAP_DIR" rm -q "Formula/listo.rb"
fi

(
    cd "$TAP_DIR"
    git add Casks/listo.rb
    if git diff --cached --quiet; then
        echo "    No changes to commit in the tap"
    else
        git commit -m "listo $VERSION"
        git push
        echo "    Cask published to $TAP_DIR"
    fi
)

echo "==> Done. 'brew install --cask sergiorivas/tap/listo' (or 'brew upgrade --cask listo') should install $VERSION."
