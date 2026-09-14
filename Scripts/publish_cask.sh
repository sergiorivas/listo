#!/usr/bin/env bash
# Builds a signed, notarized release and publishes the Homebrew Cask (spec §08).
#
# Fully hands-off on versioning: no version to pick or remember. It's
# computed from git tags (Scripts/version.sh) — the next patch after the
# latest vX.Y.Z tag — and this script tags + pushes that version itself
# once the release actually goes out, so the *next* run picks up from
# there automatically.
#
# Pipeline:
#   1. Scripts/release.sh          (build -> codesign -> notarytool -> staple -> zip)
#   2. Compute the zip's sha256 and update Casks/listo.rb (version, sha256, repo)
#   3. Create/update a GitHub release and upload the zip as its asset
#   4. Tag this commit vX.Y.Z and push the tag (only after step 3 succeeds)
#   5. If a local tap checkout is configured, copy the cask there, commit, and push
#
# Env vars (all optional):
#   LISTO_GITHUB_REPO        "owner/listo" — where releases are published (default: yourname/listo)
#   LISTO_TAP_DIR            path to a local checkout of your homebrew-tap repo;
#                            if unset, step 5 is skipped and the cask is only
#                            updated locally in this repo
#   LISTO_SIGNING_IDENTITY   passed through to release.sh
#   LISTO_NOTARY_PROFILE     passed through to release.sh
#
# Usage: Scripts/publish_cask.sh [version]
#   Just run it with no arguments in the common case. Pass one explicitly
#   only to override the computed version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$("$ROOT_DIR/Scripts/version.sh")}"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/Listo-$VERSION.zip"
CASK_PATH="$ROOT_DIR/Casks/listo.rb"
GITHUB_REPO="${LISTO_GITHUB_REPO:-yourname/listo}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1' on PATH" >&2; exit 1; }; }
require gh
require shasum

echo "==> 1/5 Build, sign, and notarize ($VERSION)"
"$ROOT_DIR/Scripts/release.sh" "$VERSION"

[ -f "$ZIP_PATH" ] || { echo "$ZIP_PATH not found after the build" >&2; exit 1; }

echo "==> 2/5 Updating Casks/listo.rb"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK_PATH"
sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA256\"/" "$CASK_PATH"
sed -i '' -E "s#github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#github.com/$GITHUB_REPO#g" "$CASK_PATH"

echo "    version = $VERSION"
echo "    sha256  = $SHA256"
echo "    repo    = $GITHUB_REPO"

echo "==> 3/5 Publishing the GitHub release"
if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP_PATH" --repo "$GITHUB_REPO" --clobber
else
    gh release create "v$VERSION" "$ZIP_PATH" \
        --repo "$GITHUB_REPO" \
        --title "Listo $VERSION" \
        --notes "See the commit history for what's in this version."
fi

echo "==> 4/5 Version tag"
if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "    v$VERSION already exists locally"
else
    git -C "$ROOT_DIR" tag -a "v$VERSION" -m "Listo $VERSION"
    echo "    Created tag v$VERSION"
fi
if git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
    if git -C "$ROOT_DIR" push origin "v$VERSION" 2>/dev/null; then
        echo "    Pushed the tag to origin"
    else
        echo "    (the tag was already on origin, or the push failed — check it by hand if needed)"
    fi
else
    echo "    No 'origin' remote configured — the tag is local only."
fi

echo "==> 5/5 Publishing the formula to the tap"
if [ -n "${LISTO_TAP_DIR:-}" ]; then
    TAP_DIR="$LISTO_TAP_DIR"
    [ -d "$TAP_DIR/.git" ] || { echo "LISTO_TAP_DIR ($TAP_DIR) is not a git checkout" >&2; exit 1; }
    mkdir -p "$TAP_DIR/Casks"
    cp "$CASK_PATH" "$TAP_DIR/Casks/listo.rb"
    (
        cd "$TAP_DIR"
        git add Casks/listo.rb
        if git diff --cached --quiet; then
            echo "    Nothing to commit in the tap"
        else
            git commit -m "listo $VERSION"
            git push
            echo "    Formula published to $TAP_DIR"
        fi
    )
else
    echo "    LISTO_TAP_DIR isn't set — Casks/listo.rb was only updated in this"
    echo "    repo. Copy it to your tap (Casks/listo.rb) and push by hand, or"
    echo "    rerun this script with LISTO_TAP_DIR=/path/to/your/tap."
fi

echo "==> Done. 'brew install --cask $GITHUB_REPO/listo' (or your tap's name) should install $VERSION."
