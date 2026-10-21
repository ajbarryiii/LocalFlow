#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: PARAKEET_BUNDLE_DIR=<model bundle> $0 <version>" >&2
  echo "Example: PARAKEET_BUNDLE_DIR=MODEL_BUNDLE $0 2.1.5" >&2
  exit 2
fi

version="$1"
tag="v$version"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid semantic version: $version" >&2
  exit 1
fi

for path in CHANGELOG.md Info.plist Makefile .github/workflows/release.yml .github/scripts/changelog-section.sh; do
  if [[ ! -f "$path" ]]; then
    echo "Missing required release file: $path" >&2
    exit 1
  fi
done

# release.yml runs for vX.Y.Z tags; releases are tagged on a commit on main.
if ! git rev-parse --verify --quiet origin/main >/dev/null; then
  echo "origin/main is not available; run git fetch origin first." >&2
  exit 1
fi

if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "HEAD is not on origin/main; tag releases on a commit on main." >&2
  exit 1
fi

# A release build must include the model bundle.
if ! make --no-print-directory release-preflight; then
  echo "Set PARAKEET_BUNDLE_DIR to the prepared model bundle before releasing." >&2
  exit 1
fi

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag already exists locally: $tag" >&2
  exit 1
fi

set +e
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1
ls_remote_status=$?
set -e

if [[ $ls_remote_status -eq 0 ]]; then
  echo "Tag already exists on origin: $tag" >&2
  exit 1
elif [[ $ls_remote_status -eq 2 ]]; then
  :
else
  echo "git ls-remote failed while checking origin tag $tag" >&2
  exit "$ls_remote_status"
fi

if ! grep -q 'tags:' .github/workflows/release.yml || ! grep -q 'v\*\.\*\.\*' .github/workflows/release.yml; then
  echo "Release workflow does not appear to be semver tag-triggered." >&2
  exit 1
fi

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT

if ! .github/scripts/changelog-section.sh "$version" >"$notes"; then
  echo "Could not extract CHANGELOG.md section for $version" >&2
  exit 1
fi

if [[ ! -s "$notes" ]]; then
  echo "Extracted changelog section is empty for $version" >&2
  exit 1
fi

if ! grep -q "^## \\[$version\\]" "$notes"; then
  echo "Extracted changelog section has an unexpected heading." >&2
  exit 1
fi

echo "Release checks passed for $tag"
echo
cat "$notes"
