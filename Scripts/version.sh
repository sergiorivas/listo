#!/usr/bin/env bash
# Prints the version to use for a release, derived from git tags.
#
#   - If HEAD is already tagged (vX.Y.Z), prints that version as-is —
#     re-running release.sh/publish_cask.sh on a tagged commit reproduces
#     the same version.
#   - Otherwise prints the next patch version after the latest reachable
#     vX.Y.Z tag (0.1.0 if the repo has no version tags yet).
#
# Does NOT create or move any tag itself — it only computes what the next
# one should be; publish_cask.sh tags the release once it's actually
# published. Safe to run standalone: Scripts/version.sh

set -euo pipefail

if tag="$(git describe --tags --exact-match --match 'v*' 2>/dev/null)"; then
    echo "${tag#v}"
    exit 0
fi

latest="$(git tag --list 'v*' --sort=-v:refname | head -n1)"
if [ -z "$latest" ]; then
    echo "0.1.0"
    exit 0
fi

version="${latest#v}"
IFS='.' read -r major minor patch <<< "$version"
patch="${patch:-0}"
echo "${major:-0}.${minor:-0}.$((patch + 1))"
