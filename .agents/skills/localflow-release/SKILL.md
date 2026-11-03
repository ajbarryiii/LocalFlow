---
name: localflow-release
description: Prepare and publish a LocalFlow macOS beta release. Use when the user asks to release LocalFlow for macOS, prepare or bump a version, write a CHANGELOG.md entry, build the Developer ID-signed and notarized DMG, or publish the GitHub pre-release. Linux releases (linux-vX.Y.Z tags, linux/CHANGELOG.md) and iOS builds are separate.
---

# LocalFlow macOS release

## How releases work

Every LocalFlow release so far (2.0.0 to 2.1.8) is a macOS beta built by hand
on a Mac and published as a GitHub pre-release with an unprefixed tag. Since
2.1.1 each one has followed the same steps (2.0.0 still used FreeFlow's
bundle ID, and 2.1.0 was tagged on a merge commit):

- **Tag:** `X.Y.Z`, with no `v` prefix, on the release-prep commit, whose
  parent is the app code it ships.
- **Release:** a pre-release titled `LocalFlow X.Y.Z Beta`, with two assets:
  `LocalFlow-Dev.dmg` and `LocalFlow-Dev.dmg.sha256`.
- **App:** the Makefile's default identity, `LocalFlow Dev.app` with bundle
  ID `com.ajbarryiii.localflow.dev`, built with the model bundle,
  Developer ID-signed with the hardened runtime and secure timestamps. The
  DMG is signed, notarized and stapled.
- **Notes:** the version's `CHANGELOG.md` section, then a
  `## Download and installation` section.

The in-app updater (`Sources/UpdateManager.swift`) reads this repository's
releases, pre-releases included:

- It takes the highest semantic version among the tags. A leading `v` is
  ignored; `linux-v…` tags do not parse, so Linux releases never reach it.
- Automatic checks offer a release only once it is 3 days old; a manual
  check offers it at once.
- What's New is each newer release's body up to its first `## Download`
  heading.
- It downloads the first `.dmg` asset and installs it only if the app inside
  is signed by the same team with the same bundle ID as the running copy.

### The CI release path does not work yet

`.github/workflows/release.yml` runs for `vX.Y.Z` tags. It has never
produced a release: CI has no model bundle, so it stops at
`make release-preflight`. It would also build the production identity
(`LocalFlow.app`, `com.ajbarryiii.localflow`), which installed betas would
see as their newest version but refuse to install. Do not push `v` tags.
Making CI releases work needs a decision from the user on how CI gets the
model, a working signing secret, and a plan for moving beta users to the
production identity.

## Ground rules

- `CHANGELOG.md` is the source of the release notes. Keep it user-facing and
  limited to the macOS app; it has no hashes or PR numbers.
- Release prep goes through a branch and pull request. Never push to `main`.
- Ask before tagging, publishing a release or merging the release PR, and
  confirm the exact version and changelog first.
- The signing identity, notarization profile, model location and machine
  names stay out of the repository, the release notes and the PR. Use
  placeholders such as `DEVELOPER_ID`, `NOTARY_PROFILE` and `MODEL_BUNDLE`.
- Preserve unrelated working tree changes; never `git reset --hard`.

## Workflow

1. **Find the previous release and what changed since:**
   ```bash
   gh release list --limit 5
   git tag --list '[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -3
   git log --first-parent --reverse --oneline <previous-tag>..origin/main
   ```
   Read the merged PRs for user-visible macOS changes. Linux and iOS changes
   are not part of a macOS release.

2. **Choose the version.** Betas so far are patch releases (2.1.8 follows
   2.1.7). Confirm the version with the user unless they gave it.

3. **Prepare the release on a branch** `release/X.Y.Z` from `origin/main`:
   - `CHANGELOG.md`: a new section above the previous one:
     ```md
     ## [X.Y.Z] - YYYY-MM-DD

     Eleventh LocalFlow macOS beta. Requires an Apple Silicon Mac running macOS 26
     or later. Uses the same app identity and local data locations as <previous>.

     ### Added
     - ...
     ```
     Use only the headings that have entries (`Added`, `Changed`,
     `Improved`, `Fixed`).
   - `Info.plist`: `CFBundleShortVersionString` and `CFBundleVersion` set to
     `X.Y.Z`; `FreeFlowBuildTag` set to `beta-` plus the first 12 hex digits
     of the app code commit (`origin/main` when you branched).
   - `README.md`: the download link points at
     `releases/download/X.Y.Z/LocalFlow-Dev.dmg`.

   Commit as `Prepare LocalFlow X.Y.Z macOS beta`, push the branch, and open
   a pull request that lists the user-visible changes. The release is built
   from this commit, and the tag goes on it.

4. **Check the release-prep commit:**
   ```bash
   .github/scripts/changelog-section.sh X.Y.Z
   PARAKEET_BUNDLE_DIR="MODEL_BUNDLE" .agents/skills/localflow-release/scripts/localflow-release-check.sh X.Y.Z
   ```
   The helper checks the version fields, the README link, the changelog
   section, a clean worktree, that the commit is pushed and the tag is free,
   and (with `PARAKEET_BUNDLE_DIR`) the model bundle. It also checks that the
   build tag names a commit that differs from this one only in
   `CHANGELOG.md`, `Info.plist` and `README.md`.

5. **Build, sign and notarize on the Mac.** Signing needs the login
   keychain, so the user runs this in Terminal on the Mac, not over SSH.
   Write it as a script outside the repository, fill in the three values
   there (never in the repository), and run it from a clean worktree at the
   release-prep commit. It needs Xcode with the macOS 26 SDK, and
   `create-dmg` and `fileicon` from Homebrew. `set -eu` stops it at the
   first failed step, so a checksum file exists only after every check
   passed.
   ```sh
   #!/bin/sh
   set -eu
   DEVELOPER_ID="Developer ID Application: …"   # the signing identity
   NOTARY_PROFILE="…"                           # notarytool keychain profile
   MODEL_BUNDLE="…"                             # prepared model bundle
   # Only if make says the SDK is not supported by the compiler:
   # export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
   APP="build/LocalFlow Dev.app"
   DMG="build/LocalFlow Dev.dmg"
   PARAKEET="$APP/Contents/Resources/Parakeet"

   test -z "$(git status --porcelain)" || { echo "The worktree is not clean"; exit 1; }
   rm -rf build        # a fresh build; no earlier model files are reused
   make check
   make ARCH=arm64 CODESIGN_IDENTITY="$DEVELOPER_ID" PARAKEET_BUNDLE_DIR="$MODEL_BUNDLE"
   # make's signature has no secure timestamp, which notarization needs.
   codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
     --entitlements FreeFlow.entitlements "$APP"
   codesign --verify --deep --strict "$APP"

   # The bundled model must be the intended conversion, byte for byte. The
   # shipped one lists 4/8/15/30-second functions; the app runs only b15.
   tr -d ' \n' < "$PARAKEET/bundle.json" | grep -qF '"buckets_seconds":[4,8,15,30]' ||
     { echo "Unexpected model bundle"; exit 1; }
   for f in $(cd "$MODEL_BUNDLE" && find Encoder.mlmodelc decoder_joint.f32bin frontend.f32bin vocabulary.json -type f); do
     cmp -s "$MODEL_BUNDLE/$f" "$PARAKEET/$f" || { echo "Model file differs: $f"; exit 1; }
   done

   make dmg ARCH=arm64 CODESIGN_IDENTITY="$DEVELOPER_ID" PARAKEET_BUNDLE_DIR="$MODEL_BUNDLE"
   codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
   xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
   xcrun stapler staple "$DMG"
   xcrun stapler validate "$DMG"
   spctl --assess --type open --context context:primary-signature -v "$DMG"
   cp "$DMG" build/LocalFlow-Dev.dmg
   (cd build && shasum -a 256 LocalFlow-Dev.dmg > LocalFlow-Dev.dmg.sha256)
   ```
   `make dmg` asks Finder to make the Applications alias, so macOS may ask
   to let Terminal control Finder. Notarization uploads about 230 MB and
   takes a few minutes; publish only after the script has exited
   successfully.

6. **Publish, with the user's approval.** Write the notes file: the
   changelog section, then `## Download and installation` with the download
   link, the requirements and install steps, the app code and release-prep
   commits, which model bundle is included, the checks that were run, and
   the DMG's SHA-256. Then create the tag and pre-release on the
   release-prep commit:
   ```bash
   gh release create X.Y.Z --target <release-prep commit SHA> --prerelease \
     --title "LocalFlow X.Y.Z Beta" --notes-file <notes file> \
     build/LocalFlow-Dev.dmg build/LocalFlow-Dev.dmg.sha256
   ```

7. **Merge the release PR with a merge commit** (`gh pr merge <n> --merge`),
   with the user's approval, so the tagged commit stays on `main`.

8. **Verify:**
   - `gh release view X.Y.Z` shows a pre-release with both assets, and the
     downloaded DMG matches the checksum file.
   - The body starts with the changelog section.
   - In an installed earlier beta, Check for Updates offers X.Y.Z with its
     What's New.
