---
name: freeflow-release
description: Prepare and publish LocalFlow app releases. Use when the user asks to release LocalFlow, prepare a new version, bump the LocalFlow version, write or update LocalFlow changelog entries, validate a LocalFlow semver release, create a vX.Y.Z tag, or publish a signed LocalFlow DMG through the repository GitHub Actions release workflow.
---

# LocalFlow Release

## Overview

Use this skill to prepare a LocalFlow release from the local repository. LocalFlow releases are semver-tag driven: pushing a tag like `v2.1.5` that points at a commit on `main` triggers `.github/workflows/release.yml`, which stamps the app bundle, extracts the matching `CHANGELOG.md` section, builds/signs/notarizes `LocalFlow.dmg` for Apple Silicon (`ARCH=arm64`, macOS 26 or later), and creates the GitHub Release.

The workflow only runs for tags matching `v*.*.*`. Earlier LocalFlow tags (`2.0.0` through `2.1.4`) have no `v` prefix, so they never triggered it; do not create new unprefixed tags.

A release build must include the model. The app bundle only contains the model when `PARAKEET_BUNDLE_DIR` points at a prepared model bundle (a directory with `bundle.json`); without it the app builds but cannot dictate. `make release-preflight` fails when the variable is empty or the directory has no `bundle.json`, and both release workflows run it before building. The workflows do not currently provide `PARAKEET_BUNDLE_DIR`, so a CI release stops at that step until the user decides how CI obtains the model.

Every release prep must update `CHANGELOG.md` by comparing the previous public release with the current release target. The changelog section should describe the user-visible changes that shipped since the previous release, not just summarize the final release-prep commit.

## Ground Rules

- Treat `CHANGELOG.md` as the release notes source of truth, and update it before any release commit or tag.
- Keep changelog language user-facing. Avoid implementation details unless they affect maintainers or troubleshooting.
- Do not edit `README.md` or unrelated docs unless the user explicitly asks.
- Do not push to `main`. Release-prep changes go through a branch and pull request.
- Do not merge, tag, or push tags until the user has explicitly approved the exact release version and changelog.
- Never use `git reset --hard` or destructive cleanup while preparing a release.
- Preserve unrelated working tree changes. If unrelated changes exist, report them and avoid staging them.

## Release Workflow

1. Inspect current state:
   ```bash
   git status --short --branch
   git log --oneline --decorate -n 20
   ```

2. Find the previous public release:
   ```bash
   git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname
   git tag --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname
   git log --oneline --decorate -- Info.plist CHANGELOG.md .github/workflows/release.yml
   git blame -L 11,14 Info.plist
   ```
   Use the latest public semver tag reachable from `main` as the previous-release boundary. Prefer a `vX.Y.Z` tag; until one exists, use the latest unprefixed `X.Y.Z` tag and say so. If tags are missing or inconsistent, fall back to the commit that introduced the prior `CHANGELOG.md` section or changed `CFBundleShortVersionString`/`CFBundleVersion`, and state that fallback explicitly.

3. Determine the next version:
   - `PATCH` for fixes, polish, release-system updates, and small user-visible improvements.
   - `MINOR` for notable new user-facing capabilities.
   - `MAJOR` only for breaking behavior or major compatibility changes.
   Confirm the version with the user if it was not specified.

4. Build and write the `CHANGELOG.md` entry from the previous release to the current release target:
   ```bash
   git log --first-parent --reverse --oneline <previous-release-tag>..HEAD
   git log --reverse --oneline <previous-release-tag>..HEAD
   git diff --stat <previous-release-tag>..HEAD
   git diff --name-status <previous-release-tag>..HEAD
   ```
   Prefer first-parent merge commits for feature grouping, then inspect individual commits and relevant diffs for details. Write a concise section near the top of `CHANGELOG.md`, above the previous release:
   ```md
   ## [2.1.5] - YYYY-MM-DD

   ### Added
   - User-facing new capabilities.

   ### Improved
   - User-facing improvements and reliability work.

   ### Fixed
   - User-visible bugs and update/release fixes.
   ```
   Include only categories that have entries. If the release contains mostly internal work, describe the user-facing effect, such as reliability, update behavior, packaging, or troubleshooting improvements. Do not include raw commit hashes in the changelog.

5. Validate locally before committing. `PARAKEET_BUNDLE_DIR` must point at the prepared model bundle:
   ```bash
   .github/scripts/changelog-section.sh <version>
   git diff --check
   make check
   make release-preflight PARAKEET_BUNDLE_DIR="MODEL_BUNDLE"
   make clean
   make ARCH=arm64 CODESIGN_IDENTITY=- PARAKEET_BUNDLE_DIR="MODEL_BUNDLE"
   ```

6. Commit only release-prep files on a branch and open a pull request against `main`:
   ```bash
   git switch -c release/localflow-<version>
   git add CHANGELOG.md
   git commit -m "Prepare v<version> release"
   ```
   Include other files only when they are deliberately part of the release prep.

7. After the user approves and the pull request is merged, tag the merged commit on `main` and push only the tag:
   ```bash
   git fetch origin
   git switch main
   git merge --ff-only origin/main
   PARAKEET_BUNDLE_DIR="MODEL_BUNDLE" .agents/skills/freeflow-release/scripts/freeflow-release-check.sh <version>
   git tag v<version>
   git push origin v<version>
   ```

8. After GitHub Actions finishes, verify:
   - GitHub Release `v<version>` exists and is marked latest.
   - `LocalFlow.dmg` is attached.
   - Release body starts with the matching `CHANGELOG.md` section.
   - A previous app version detects the update and shows What’s New.

## Helper Script

Run `PARAKEET_BUNDLE_DIR="MODEL_BUNDLE" .agents/skills/freeflow-release/scripts/freeflow-release-check.sh <version>` from the LocalFlow repo root to check release preconditions. It validates semver shape, required files, that `HEAD` is on `origin/main`, the model bundle (`make release-preflight`), changelog extraction, workflow trigger basics, and `v<version>` tag availability.
