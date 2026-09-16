#!/usr/bin/env bash
# Publishes a new Listo version via the prebuilt-binary Homebrew Formula
# path: builds an ad-hoc-signed .app locally, uploads it as a GitHub
# release asset, and regenerates Formula/listo.rb in your tap to download
# that zip and install it directly — no `swift build` on the installing
# machine.
#
# There's no Developer ID cert or notarization here — that would need a
# paid Apple Developer account. Downloaded files get Gatekeeper-quarantined
# regardless of signing, so the formula's install step strips that with
# `xattr -cr` rather than fighting notarization — good enough to open an
# ad-hoc-signed app, not a replacement for the real thing.
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
#   5. Regenerate Formula/listo.rb in LISTO_TAP_DIR with the new
#      version/url/sha256, commit, and push
#
# Env vars:
#   LISTO_GITHUB_REPO   "owner/listo" (default: sergiorivas/listo)
#   LISTO_TAP_DIR       path to a local checkout of your homebrew tap
#                       (default: ../homebrew-tap, alongside this repo)
#
# Usage: Scripts/publish_formula.sh [version]
#   Just run it with no arguments in the common case. Pass one explicitly
#   only to override the computed version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$("$ROOT_DIR/Scripts/version.sh")}"
GITHUB_REPO="${LISTO_GITHUB_REPO:-sergiorivas/listo}"
TAP_DIR="${LISTO_TAP_DIR:-$ROOT_DIR/../homebrew-tap}"
FORMULA_PATH="$TAP_DIR/Formula/listo.rb"

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

# Homebrew's stage step auto-cd's into an archive's single top-level
# directory before running `install` (a heuristic for tarballs like
# "mypkg-1.2.3/" that wrap the real payload) — since Listo.app is itself a
# directory and would be the *only* top-level entry in a zip made from it
# alone, that heuristic unwraps it and `install` ends up running from
# inside Listo.app, where `prefix.install "Listo.app"` fails with ENOENT.
# Staging a second top-level file alongside the app keeps Homebrew from
# treating Listo.app as a wrapper to strip.
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

echo "==> 5/5 Updating the tap formula"
mkdir -p "$TAP_DIR/Formula"
cat > "$FORMULA_PATH" <<RUBY
class Listo < Formula
  desc "To-do list that lives as plain Markdown on disk"
  homepage "https://github.com/$GITHUB_REPO"
  url "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ZIP_NAME"
  sha256 "$SHA256"
  version "$VERSION"

  def install
    # Homebrew already unpacked the zip into the working directory, so
    # Listo.app is right here. Strip the quarantine flag the download
    # picked up — the app is only ad-hoc signed, not notarized, so
    # Gatekeeper would otherwise refuse to open it.
    system "xattr", "-cr", "."
    prefix.install "Listo.app"
    system "ln", "-sf", prefix/"Listo.app", "/Applications/Listo.app"
  end

  def caveats
    <<~EOS
      Listo.app was symlinked into /Applications so it shows up in
      Launchpad/Finder like a normal Mac app.

      This build is ad-hoc signed, not notarized by Apple. If macOS still
      refuses to open it, run:
        xattr -cr /Applications/Listo.app

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

echo "==> Done. 'brew install sergiorivas/tap/listo' (or 'brew upgrade listo') should install $VERSION."
