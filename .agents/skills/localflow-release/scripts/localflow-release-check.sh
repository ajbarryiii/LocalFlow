#!/usr/bin/env bash
# Checks a LocalFlow macOS beta's release-prep commit before it is built and
# published (see ../SKILL.md). Run from the repository root at that commit.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: [PARAKEET_BUNDLE_DIR=<model bundle>] $0 <version>" >&2
  echo "Example: PARAKEET_BUNDLE_DIR=MODEL_BUNDLE $0 2.1.9" >&2
  exit 2
fi

version="$1"
# Betas are tagged without a "v": a v-prefixed tag runs release.yml.
tag="$version"

fail() {
  echo "$*" >&2
  exit 1
}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid semantic version: $version"

for path in CHANGELOG.md Info.plist README.md Makefile .github/scripts/changelog-section.sh; do
  [[ -f "$path" ]] || fail "Missing required release file: $path"
done

[[ -z "$(git status --porcelain)" ]] || fail "The worktree is not clean; build releases from a clean checkout."

# The string value after <key>$1</key> in Info.plist.
plist_value() {
  awk -v key="<key>$1</key>" '
    index($0, key) { getline; sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>[[:space:]]*$/, ""); print; exit }
  ' Info.plist
}

for key in CFBundleShortVersionString CFBundleVersion; do
  value="$(plist_value "$key")"
  [[ "$value" == "$version" ]] || fail "Info.plist $key is \"$value\", expected \"$version\"."
done

build_tag="$(plist_value FreeFlowBuildTag)"
[[ "$build_tag" =~ ^beta-[0-9a-f]{12}$ ]] ||
  fail "Info.plist FreeFlowBuildTag is \"$build_tag\", expected beta- and 12 hex digits of the app code commit."
app_commit="${build_tag#beta-}"
git rev-parse --verify --quiet "$app_commit^{commit}" >/dev/null ||
  fail "FreeFlowBuildTag names $app_commit, which is not a commit here (git fetch origin first)."
git merge-base --is-ancestor "$app_commit" HEAD ||
  fail "FreeFlowBuildTag names $app_commit, which is not part of HEAD."
# The release-prep commit changes only release metadata, so the app built
# from it is the app code commit the build tag names (as in 2.1.1 to 2.1.8).
unexpected="$(git diff --name-only "$app_commit" HEAD | grep -vxE 'CHANGELOG\.md|Info\.plist|README\.md' || true)"
[[ -z "$unexpected" ]] ||
  fail "FreeFlowBuildTag names $app_commit, but HEAD also changes more than release metadata:
$unexpected
Set it to beta- and the first 12 hex digits of the commit the release-prep branch started from."

grep -qF "releases/download/$version/LocalFlow-Dev.dmg" README.md ||
  fail "README.md does not link to releases/download/$version/LocalFlow-Dev.dmg."

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
.github/scripts/changelog-section.sh "$version" >"$notes" ||
  fail "Could not extract the CHANGELOG.md section for $version."
grep -q "^## \\[$version\\] - [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}" "$notes" ||
  fail "The CHANGELOG.md section must start with \"## [$version] - YYYY-MM-DD\"."
[[ "$(grep -c . "$notes")" -gt 1 ]] || fail "The CHANGELOG.md section for $version is empty."

# gh creates the tag on this commit, so GitHub must already have it.
[[ -n "$(git branch -r --contains HEAD)" ]] ||
  fail "HEAD is not on any remote branch; push the release-prep branch first."

for candidate in "$tag" "v$version"; do
  if git rev-parse --verify --quiet "refs/tags/$candidate" >/dev/null; then
    fail "Tag already exists locally: $candidate"
  fi
  set +e
  git ls-remote --exit-code --tags origin "refs/tags/$candidate" >/dev/null 2>&1
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    fail "Tag already exists on origin: $candidate"
  elif [[ $status -ne 2 ]]; then
    fail "git ls-remote failed while checking origin for tag $candidate."
  fi
done

if [[ -n "${PARAKEET_BUNDLE_DIR:-}" ]]; then
  make --no-print-directory release-preflight PARAKEET_BUNDLE_DIR="$PARAKEET_BUNDLE_DIR" ||
    fail "The model bundle check failed."
else
  echo "PARAKEET_BUNDLE_DIR is not set: the model bundle was not checked (the build needs it)."
fi

echo "Release checks passed for $tag (app code $app_commit, release prep $(git rev-parse --short=12 HEAD))."
echo
cat "$notes"
