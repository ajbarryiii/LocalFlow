# LocalFlow for iPhone (prototype)

A custom keyboard with a dictation button, backed by the bundled Parakeet model
running in the containing app. [ARCHITECTURE.md](ARCHITECTURE.md) is the
contract between the components, stated as the code is now;
[ARCHITECTURE-HISTORY.md](ARCHITECTURE-HISTORY.md) keeps the decision log it
replaced. Like the macOS app, it builds with `swiftc` and `make` only, with no
Xcode project and no Swift Package Manager.

## Requirements

- A Mac with Xcode 26 or newer (iOS 26 SDK) and an iOS 26 simulator runtime.
- `python3` (Xcode provides `/usr/bin/python3`), used to relabel the model.
- A Parakeet model bundle (`PARAKEET_BUNDLE_DIR`) to transcribe. Weights stay
  outside Git and are copied only into the local build.
- Optionally, a swipe typing bundle (`SWIPE_BUNDLE_DIR`). Without it the
  keyboard has no swipe typing and long drags across the letters are taps.

## Build and check

Run from the repository root (or `make <target>` inside `iOS/`):

```bash
make -C iOS                      # build/simulator/LocalFlow.app, no model
make -C iOS PARAKEET_BUNDLE_DIR=/path/to/bundle   # with the model in LocalFlow.app/Parakeet/
make -C iOS SWIPE_BUNDLE_DIR=/path/to/swipe-bundle  # with swipe typing in LocalFlowKeyboard.appex/Swipe/
make -C iOS check                # simulator type-check, host tests, plutil -lint
```

The app contains `PlugIns/LocalFlowKeyboard.appex` and
`PlugIns/LocalFlowActivity.appex` (the session's Live Activity). Repeat builds
keep an unchanged copy of the 330 MB model instead of copying it again.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CHANNEL` | `dev` | `appstore` presets the production identifiers, icon and a device build (see [App Store build](#app-store-build)) |
| `PLATFORM` | `simulator` | `simulator` or `device` (arm64 only) |
| `BUNDLE_ID` | `com.ajbarryiii.localflow.ios.dev` | app ID; the keyboard is `$(BUNDLE_ID).keyboard`, the Live Activity `$(BUNDLE_ID).activity` |
| `APP_GROUP` | `group.$(BUNDLE_ID)` | shared container for app and keyboard |
| `URL_SCHEME` | `localflow-dev` | `<scheme>://dictate` |
| `UNIVERSAL_LINK` | empty | https URL the keyboard opens instead of the scheme (see [Universal link](#universal-link)) |
| `DISPLAY_NAME` | `LocalFlow Dev` | home screen and keyboard list name |
| `DEPLOYMENT_TARGET` | `26.0` | the encoder uses the `ios19` Core ML opset |
| `PARAKEET_BUNDLE_DIR` | empty | model bundle to embed |
| `SWIPE_BUNDLE_DIR` | empty | swipe typing bundle to embed in the keyboard (see [Swipe typing bundle](#swipe-typing-bundle)) |
| `BUILD_DIR` | `build/$(PLATFORM)` | output directory |
| `SWIFT_FLAGS` | empty | extra compiler flags, e.g. `-D LOCALFLOW_SELFTEST` |
| `SWIFT_JOBS` | the Mac's active cores | parallel compiler jobs for every build, type-check and test compile |
| `BUILD_NUMBER` | empty | `CFBundleVersion` for all three bundles; empty keeps the template's `1` |
| `CODESIGN_IDENTITY`, `TEAM_ID`, `APP_PROFILE`, `KEYBOARD_PROFILE`, `ACTIVITY_PROFILE` | `-` on the simulator | device signing |

Source lists (`APP_SWIFT_SOURCES`, `KEYBOARD_SWIFT_SOURCES`, `SHARED_SOURCES`, `KEYBOARDCORE_SOURCES`,
`HOSTCORE_SOURCES`, `TEST_SOURCES`, `KEYBOARD_TEST_SOURCES`, `PARAKEET_SOURCES`, `DICTIONARY_SOURCES`) can be
overridden, for example `make -C iOS check SHARED_SOURCES= HOSTCORE_SOURCES=`.

## Swipe typing bundle

`SWIPE_BUNDLE_DIR` holds the keyboard's swipe model, built outside this
repository: `SwipeEncoder.mlmodelc/` (the compiled Core ML encoder),
`lexicon.bin` (the word list) and `bundle.json`, which has `"format": 1`, the
decoder settings under `"decode"` (`beam`, `top_k`, `length_power`,
`freq_weight`, `length_bonus`) and a SHA-256 for every other file under
`"files"` (relative paths, the model directory's files listed one by one). The
build copies exactly the listed files into `LocalFlowKeyboard.appex/Swipe/`,
checks each copy against its hash and stops on any mismatch, missing file or
invalid path, then adds `bundle.json` and the licenses in
`../Resources/Swipe/`. A changed `bundle.json` or `SWIPE_BUNDLE_DIR` rebuilds
the app. The keyboard loads the bundle off the main thread when it starts (the
encoder on the CPU only); a missing or invalid bundle leaves swipe typing off.
Swipes, candidates and decoder state stay in memory and are never logged,
stored or sent.

The same bundle may carry the typing models, listed in `"files"` like the
rest: an optional `"tap"` section (soft key edges) and an optional
`"autocorrect"` section (the word lexicon, word models and their tuned
presets; see ARCHITECTURE.md, "Soft key edges" and "Word autocorrect"). The
keyboard uses each section's default model and settings. An invalid section
turns off only its own feature.

## Simulator

```bash
make -C iOS install-sim          # builds, creates/boots LocalFlow-Smoke, installs
make -C iOS run-sim              # also opens Simulator and launches the app
```

`SIM_DEVICE` (default `LocalFlow-Smoke`) is created on first use with
`SIM_DEVICE_TYPE` (default `iPhone 17 Pro`) and `SIM_RUNTIME` (default: the
newest installed iOS runtime). To enable the keyboard in the simulator, open
Settings → General → Keyboard → Keyboards → Add New Keyboard → LocalFlow Dev,
then turn on Allow Full Access.

Simulator builds are ad-hoc signed. As in Xcode simulator builds, the App
Group entitlement is embedded in each executable's `__TEXT,__entitlements` and
`__TEXT,__ents_der` sections.

### Smoke test

```bash
make -C iOS smoke-sim PARAKEET_BUNDLE_DIR=/path/to/bundle
```

This builds the self-test variant (`-D LOCALFLOW_SELFTEST`) into
`build/smoke-simulator`, installs it on `SIM_DEVICE`, and synthesizes an
invented phrase with `say`. It copies the WAV into the app's data container and
launches the app. The app checks that the App Group container is writable,
prepares the model, transcribes the samples, and prints one line:

```
LocalFlow self-test: result=pass stage=done transcript_match=true app_group=usable compute=cpuAndNeuralEngine preparation_s=… transcription_s=… audio_s=… peak_footprint_mb=… available_devices=… error=none
```

The transcript is never printed. The audio file is deleted afterwards. The log
is kept in `build/smoke-simulator/obj/selftest.log` only on failure. If
`smoke-sim` booted the simulator, it shuts it down again. Options:
`SMOKE_COMPUTE=cpuOnly`, `SMOKE_PHRASE`, `SMOKE_TIMEOUT` (seconds, default
900). Remove the device with `xcrun simctl delete LocalFlow-Smoke`.

The simulator has no Neural Engine. Core ML runs a `.cpuAndNeuralEngine` model
on the CPU there, so simulator timings say nothing about device performance.

### Enabling the keyboard without taps

The simulator reads the keyboard list from preferences, so the keyboard can be
made current without touching Settings. Run these while the simulator is
booted, then relaunch the app:

```bash
dev=LocalFlow-Keyboard; kb=com.ajbarryiii.localflow.ios.dev.keyboard
xcrun simctl spawn $dev defaults write -g AppleKeyboards -array $kb "en_US@sw=QWERTY;hw=Automatic" "emoji@sw=Emoji"
xcrun simctl spawn $dev defaults write com.apple.keyboard.preferences KeyboardsCurrentAndNext -array $kb "en_US@sw=QWERTY;hw=Automatic"
```

Full Access is a `kTCCServiceKeyboardNetwork` row, with `auth_value` 2 for the
keyboard's bundle ID, in the simulator's `data/Library/TCC/TCC.db`. Insert it
while the simulator is shut down. Reinstalling the app can reset the current
keyboard and the Full Access row.

### End-to-end without a microphone

```bash
make -C iOS e2e-sim PARAKEET_BUNDLE_DIR=/path/to/bundle [E2E_SKIP_ONBOARDING=1] [E2E_SCREEN=home] [E2E_START_SESSION=1] [E2E_HEADPHONES=bluetooth|none]
make -C iOS e2e-sim-probe [E2E_BACKGROUND=1 | E2E_FROM_BACKGROUND=1]
make -C iOS e2e-sim-scenarios
```

`e2e-sim` builds the self-test variant into `build/e2e-simulator` and installs
it on `LocalFlow-E2E` (`E2E_SIM_DEVICE`). It generates the invented
`E2E_PHRASE` with `say` and launches with `LOCALFLOW_SYNTHETIC_MIC`, a
real-time-paced synthetic source. The Mac microphone is never used, and a
requested but unusable synthetic source fails closed rather than falling back
to the real microphone. `E2E_SCREEN` accepts `onboarding`,
`onboarding-microphone|keyboard|model`, `home`, `tryit`, `keyboard-setup` and
`diagnostics`. `E2E_HEADPHONES` sets the route the synthetic microphone
reports: `bluetooth` stands in for AirPods, with the input following "Use
iPhone microphone" as iOS routes them, and `none` for the iPhone microphone
alone. The app's content-free `LocalFlow self-test:` lines go to
`build/e2e-simulator/obj/e2e-app.log`.

`e2e-sim-probe` plays the keyboard's side through the App Group files:

1. record intent
2. synthetic speech
3. finish intent
4. result

It prints only phases and pass/fail, then deletes the result file.

`e2e-sim-scenarios` runs four cases with one pass/fail line each:
- `cancel`
- `kill-relaunch`: the request is reported interrupted and never restarts
- `url-hint-fresh`
- `url-hint-stale`

On the 26.4 simulator, `simctl openurl` with a custom scheme leaves an
"Open in LocalFlow Dev?" alert that cannot be tapped headlessly, so the probes
bring the app forward with `simctl launch`. The next simulator reboot clears
the alert.

Simulator timings: the encoder runs on the CPU and prepares on every cold
launch, taking about 72 s and 840 MB.

## Device

Device builds need the App Group capability, so they need explicit App IDs
and development provisioning profiles on a paid team: one for the app, one for
the keyboard and one for the Live Activity extension (`$(BUNDLE_ID).activity`,
which needs no capability).

### Getting profiles

Make a throwaway Xcode project outside the repository; it must never be
committed. Give it automatic signing on the team: an app target, a
`com.apple.keyboard-service` extension target, each with the App Group in its
entitlements, and a Widget Extension target with the Live Activity bundle ID
and no capabilities. Build it once:

```bash
xcodebuild -project SigningHelper.xcodeproj -scheme SigningHelper -allowProvisioningUpdates \
  -destination 'generic/platform=iOS' build   # or -destination id=<UDID> -allowProvisioningDeviceRegistration for a new phone
```

This registers the App IDs and the group, then downloads team profiles to
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`.
The profiles expire after a year; rerun the helper to renew them or to add
devices. Find a profile's App ID with
`security cms -D -i <file> | plutil -extract Entitlements.application-identifier raw -o - -`.

### Building, signing and installing

`codesign` fails over SSH (`errSecInternalComponent`) because the login
keychain is locked in SSH sessions. Run signing builds in Terminal.app on the
Mac. Later `make` calls over SSH find the signed build up to date. Keep the
signing variables in a shell array, because the profile directory contains a
space.

```bash
P="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
SIGN=(PLATFORM=device CODESIGN_IDENTITY="Apple Development: Name (XXXXXXXXXX)" TEAM_ID=XXXXXXXXXX
      APP_PROFILE="$P/<app-uuid>.mobileprovision" KEYBOARD_PROFILE="$P/<keyboard-uuid>.mobileprovision"
      ACTIVITY_PROFILE="$P/<activity-uuid>.mobileprovision" PARAKEET_BUNDLE_DIR=/path/to/bundle)
make -C iOS all "${SIGN[@]}"                              # Terminal.app: builds and signs
make -C iOS install-device "${SIGN[@]}" DEVICE=<name or id> # installs, does not launch
make -C iOS smoke-device "${SIGN[@]}" DEVICE=<name or id> [SMOKE_DEVICE_INSTALL=0] [SMOKE_COMPUTE=cpuOnly]
```

- The build checks that each profile matches its App ID, and that the app's
  and the keyboard's grant the App Group. It embeds the profiles, adds
  `application-identifier`, the team identifier and `get-task-allow`, and
  signs the extensions before the app.
- The phone needs Developer Mode, a pairing with the Mac, and to stay
  unlocked during `smoke-device`. `install-device` and `smoke-device` stop with
  a clear message when the phone is locked.
- `smoke-device` installs the self-test variant, which shares the bundle ID,
  so reinstall the normal build afterwards. `SMOKE_DEVICE_INSTALL=0` reruns
  the installed build, which gives a true warm run.
- The synthetic recording is overwritten with an empty file when the run ends.
- `make -C iOS PLATFORM=device binaries` compiles and links without signing.

Measured on an iPhone 15 Pro running iOS 26.6.2, with 2.4 s of synthetic speech:

| Compute | Preparation | Transcription | Peak |
| --- | --- | --- | --- |
| Neural Engine, first launch after install | 67 s | 0.049 s | 165 MB |
| Neural Engine, later launches | 0.69 s | 0.040 s | 166 MB |
| CPU only (self-test only) | 61 s | 0.52 s | 3.2 GB |

## App Store build

`CHANNEL=appstore` builds the production app: `com.ajbarryiii.localflow.ios`
(keyboard `.keyboard`, Live Activity `.activity`), App Group `group.com.ajbarryiii.localflow.ios`, URL
scheme `localflow`, universal link
`https://wildernesslabs.ai/localflow/dictate`, display name "LocalFlow" and
the production icon, into `build/appstore/`. It always builds for the device,
refuses the self-test variant, an empty or non-https `UNIVERSAL_LINK`, needs
the model, and accepts only App Store distribution profiles.

One-time setup in the Apple Developer account, on the Mac:

1. Register the production App IDs (app, keyboard and
   `com.ajbarryiii.localflow.ios.activity`) and App Group, for example with the
   signing helper above set to the production identifiers, and enable the
   **Associated Domains** capability on the app's App ID
   `com.ajbarryiii.localflow.ios` (not the keyboard's).
2. Create an **Apple Distribution** certificate (Xcode → Settings → Accounts →
   Manage Certificates) and an **App Store** provisioning profile for the app
   and for the keyboard, each with the App Group, and one for the Live
   Activity, with no capability. The app's profile must
   include Associated Domains (`applinks:wildernesslabs.ai`); regenerate it
   after enabling the capability, or the build stops naming it.
3. Create the app record in App Store Connect, and an App Store Connect API key
   (Users and Access → Integrations) saved as
   `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8`. The key is a secret:
   never copy it into the repository.

Then, in Terminal.app (signing needs the unlocked keychain):

```bash
P="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
STORE=(CHANNEL=appstore CODESIGN_IDENTITY="Apple Distribution: Name (XXXXXXXXXX)" TEAM_ID=XXXXXXXXXX
       APP_PROFILE="$P/<app-store-app-uuid>.mobileprovision" KEYBOARD_PROFILE="$P/<app-store-keyboard-uuid>.mobileprovision"
       ACTIVITY_PROFILE="$P/<app-store-activity-uuid>.mobileprovision" PARAKEET_BUNDLE_DIR=/path/to/bundle BUILD_NUMBER=<n>)
make -C iOS ipa appstore-check "${STORE[@]}"          # build/appstore/LocalFlow.ipa, checked locally
make -C iOS appstore-validate "${STORE[@]}" ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id>   # Apple's checks
make -C iOS appstore-upload "${STORE[@]}" ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id>     # to App Store Connect
```

- `BUILD_NUMBER` must grow with every upload of the same version
  (`CFBundleShortVersionString`, in `Config/*-Info.plist`).
- `appstore-check` (`scripts/check-appstore-bundle.sh`) reads only the build,
  and checks the app inside the `.ipa`. It checks:
  - the identifiers and matching versions of all three bundles, a universal
    keyboard and Live Activity, exactly those two extensions, the
    WidgetKit extension point and `NSSupportsLiveActivities`
  - the compiled, opaque 1024-pixel icon
  - the three privacy manifests, with only reasons Apple defines
  - the Xcode build metadata and export compliance
  - the model, and that no self-test code is present
  - the distribution signature, and unexpired App Store profiles that
    authorize the signing certificate
  - the entitlements: no `get-task-allow`, `beta-reports-active` for
    TestFlight, the App Group (none on the Live Activity), and Associated
    Domains `applinks:wildernesslabs.ai` on the app only, granted by its
    profile
  - `LocalFlowUniversalLink` in the app's and the keyboard's Info.plists
  - the `.ipa` layout
- `appstore-validate` and `appstore-upload` send the `.ipa` to Apple. They run
  `appstore-check` first, and nothing else ever runs them.

### Universal link

Any app can register the `localflow` scheme, and iOS does not define which app
opens it, so another app could receive the keyboard's bounce and show a fake
LocalFlow screen. With `UNIVERSAL_LINK` set, the keyboard opens that https URL
instead, universal-links-only: iOS opens it only in the app verified for the
domain, never in Safari or another app, and if it cannot, the keyboard shows
"Open LocalFlow". The app is signed with
`com.apple.developer.associated-domains` = `["applinks:<host>"]`, and device
builds check that its profile grants Associated Domains. The keyboard gets no
new entitlement, and the scheme stays registered for the simulator, e2e and
dev builds.

- App Store builds always use `https://wildernesslabs.ai/localflow/dictate`.
- Dev builds leave it empty and bounce with the scheme. To try the universal
  link on a device, enable Associated Domains on
  `com.ajbarryiii.localflow.ios.dev`, regenerate its development profile, and
  build with `UNIVERSAL_LINK=https://wildernesslabs.ai/localflow-dev/dictate`.
- The association file is
  `https://wildernesslabs.ai/.well-known/apple-app-site-association`, deployed
  from the separate `wilderness-labs-site` repository. It maps
  `/localflow/dictate` to `5X346GR227.com.ajbarryiii.localflow.ios` and
  `/localflow-dev/dictate` to `5X346GR227.com.ajbarryiii.localflow.ios.dev`.
  iOS fetches it (through Apple's CDN) when the app is installed; the app has
  no network code for it. Without it the bounce never opens LocalFlow.

## Using the keyboard

- **Dictation:** the top bar has the mic and stop button, a level meter,
  cancel, "Insert last dictation", and **Undo** for the last insertion.
  - Undo is offered only until you type, move the cursor, change fields or
    hide the keyboard, or 30 s pass.
  - It removes text only as far as the visible context proves it was the
    dictation.
  - Start's dot shows the session: green while one is on, amber while none
    is (Start then opens LocalFlow).
  - **Left-handed** (Home → Keyboard, off by default; applies the next time
    the keyboard appears) puts Start, the recording and Cancel at the bar's
    left and the menu at its right.
- **Typing:** a basic QWERTY layer with `123` and `#+=`. It has Apple-style
  shift (double-tap for caps lock), auto-capitalization and the double-space
  period. Keys play a light haptic (Typing haptics, on by default; needs Full
  Access).
- **Autocorrect and soft key edges** (Home → Keyboard, on by default, need
  Full Access; each switch applies the next time the keyboard appears):
  - Soft key edges: a tap near a key's edge may type the likelier neighbour.
  - Autocorrect: at space, Return or `. , ! ? ; :` the word before it may be
    replaced, and the bar shows the typed word, the correction and
    suggestions to choose from. Delete right after a correction puts your
    word back, and that word is left alone until the keyboard restarts; the
    bar then offers "Never correct" to keep it uncorrected for good.
    Diagnostics → "Forget never-correct words" clears those. Only words the
    keyboard typed whole, after a space or punctuation it typed, are
    corrected; swiped words, text already in the field, words edited after
    moving the cursor, and secure fields are left alone.
- **Trackpad:** touch and hold space (about 0.5 s) and the keys blank out.
  - Drag to move the cursor horizontally, by character, or vertically, by
    line, keeping the column.
  - Faster swipes travel further.
  - Diagnostics → Cursor has sensitivity and acceleration sliders for tuning
    against Apple's keyboard.
- **Delete:** hold to repeat; after about 3.5 s it deletes whole words.
- Apple's own globe and dictation microphone below the keyboard belong to iOS
  and cannot be replaced. Turning off Settings → General → Keyboard → Enable
  Dictation hides Apple's microphone system-wide.

## The session in the Dynamic Island

While a session is on, it shows as a Live Activity in the Dynamic Island and
on the Lock Screen: ready with the time left, recording with its elapsed time,
then transcribing (or preparing the model), and gone the moment the session
ends. Tapping it opens LocalFlow. It carries only the session's phase and its
timer dates, never a transcript, audio or anything about the app you dictate
into, and the app sends it nothing over the network. iOS asks once whether to
allow Live Activities from LocalFlow; with them off (Settings → LocalFlow →
Live Activities) the session works the same and the app never asks again.
ARCHITECTURE.md, "Live Activity", has the rules.

## Reporting a bug

Open **Report a bug** on the app's home screen, then **Write email** to open a
draft addressed to `localflow@wildernesslabs.ai`. Review and edit it in your
email app before sending, or cancel without sending. The draft asks for steps
to reproduce, expected behavior, and what happened; it includes only the app
version/build, iOS version, and generic device type (iPhone or iPad). It attaches
no audio, transcripts, logs, or other user data. If no email app handles the
draft, the address and draft remain selectable for use in an email app.

## Manual tests

These need a person at a device, or Sol through computer use at the
simulator. Record results before merge. The device rows are required by
AGENTS.md.

Setup and session:
- [x] Privacy policy: the home-screen link opens the public policy in the browser only after a tap; the link sends no dictation, recordings, or app metadata. Simulator verification passed on 2026-10-14 with build 9: the link opened the published policy in Safari, and its mobile layout was readable. The user also confirmed the privacy-policy link opens correctly on the physical iPhone in TestFlight 0.1.0 (9) on 2026-10-14.
- [ ] Report a bug: the home-screen row opens the draft preview; Write email opens the configured email app with the correct recipient, subject, prompts, and version/device metadata; cancel sends nothing. With no email handler, the app shows the fallback and the address/draft remain readable and selectable. Check the layout on iPhone and iPad.
- [x] Device-signed build installs; signatures and entitlements verified (2026-10-09).
- [x] Model preparation and transcription on a device: Neural Engine cold and warm, and CPU only (self-test, 2026-10-09).
- [x] Dictation from the keyboard in another app through the bounce, on a device (the user, informally, 2026-10-09).
- [ ] Onboarding: microphone permission, keyboard + Full Access steps, first model preparation with progress.
- [ ] Wilderness Labs theme: every screen and sheet (Onboarding, Home, Try it, Keyboard setup, Dictionary and its sheets, Diagnostics, Report a bug, the bounce) is dark with readable text on aurora buttons and tiles, even with the system in light mode; the Home Screen, Settings and Spotlight icons show the ridge mark.
- [ ] Bounce on iOS 26: the keyboard opens LocalFlow, "Listening" appears only once audio flows, swipe back, dictation inserts.
- [ ] Universal-link bounce (TestFlight, or a dev build with `UNIVERSAL_LINK=https://wildernesslabs.ai/localflow-dev/dictate`): Start in another app opens LocalFlow, never Safari, from a cold launch and from the background; the menu's "Open LocalFlow" does too. With the association file unreachable or the app not associated (for example a fresh install before iOS fetches it), the keyboard shows "Open LocalFlow" and nothing else opens. Tapping the link in Notes opens LocalFlow without recording.
- [ ] Live Activity (iPhone with a Dynamic Island, and one without, for the Lock Screen and the banner): starting a session shows the mark in the island; Start on the keyboard in another app grows the coral dot and the elapsed time, Stop gives way to the transcribing glyph (preparing first after a restart) and then back to ready, each change quick and calm; long-press shows the expanded view with the timer glyph and the time left, or the recording time; with another app's Live Activity running, the minimal view; the Lock Screen view in dark and light; it goes at End session, idle expiry and a phone call; after force-quitting LocalFlow the activity reads "Session ended" once its time is past, and the next launch removes it; with Live Activities off, nothing shows and LocalFlow never asks. No sound or screen wake on any change. Simulator verification (iPhone 17 Pro, iOS 26.4, synthetic microphone, recorded with `simctl io recordVideo`, since screenshots leave out the island) passed on 2026-11-01 for the compact and expanded island, the Lock Screen in dark and light, End session, idle expiry, a killed app's "Session ended" and its removal at the next launch. Not yet checked: the minimal view (no other Live Activity source in the simulator), a phone call, Live Activities turned off, and a device.
- [ ] Session keep-alive: second dictation without an app switch; the idle countdown resets; the session ends at idle expiry, a call and End session; a lock cancels a dictation in progress but keeps the session.
- [ ] Model readiness: start a session, then Diagnostics → Release model now; the model stays "Not prepared yet" while idle, and the keyboard's Start keeps its aurora dot (VoiceOver: "Model loads when you dictate"). Swipe to another app and tap Start: the recording island records while preparation runs (VoiceOver: "Model loading"), and after Stop the wait's shimmer pill shows (also with a swipe candidate strip or the Insert last chip showing) until the transcript inserts (brief on a warm model; long after a cold preparation). While the model prepares with the keyboard idle, Start's dot breathes. Release the model again during a dictation: it is released only after the dictation ends.
- [ ] Status glyphs: with a session, Start's mark dot is aurora and the bar's middle is empty; with none it is ember, and Start stays Start while iOS asks to open LocalFlow (declining leaves it as it was, with "Open LocalFlow to start a session"); VoiceOver reads the session's time left from Start.
- [ ] Left-handed (Home → Keyboard, off by default; applies the next time the keyboard appears): Start and the recording island at the bar's left, Cancel on the island's right in reach of the left thumb, the menu at the right; Stop's reach takes q and w while recording and p still types; Cancel and Undo work; off, the bar is as before.
- [ ] Background capture survives a Bluetooth route change, or the session ends with a clear error.
- [ ] Headphones notice: with AirPods connected and Use iPhone microphone on, the bounce's Listening screen reads "Recording from your iPhone, not your headphones"; with it off, "Recording through your headphones"; with no headphones, no notice. Connecting or disconnecting them while Listening updates it. On an SE-size iPhone while the model prepares, Stop and Cancel stay on screen and the rest scrolls. Simulator verification (synthetic route, `E2E_HEADPHONES`, iPhone 17 Pro and iPhone SE) passed on 2026-10-29; device check pending.
- [ ] Field binding: dictate into Try it field A, switch to field B mid-request; no auto-insert into B, and the chip appears.
- [ ] Undo: removes exactly the dictation; disappears after typing, cursor moves, 30 s, or hiding the keyboard.
- [ ] Kill LocalFlow during recording: the request reports interrupted and never restarts; no result file remains.
- [ ] Battery: 30 min idle session vs no session (and vs Wispr Flow if installed).
- [ ] Device lock: with a session open, lock; the orange indicator stays on the lock screen. Unlock and dictate from another app without opening LocalFlow. Lock during a dictation: it is cancelled and the keyboard shows "Dictation stopped when iPhone locked". Leave it locked past the session length: the session ends and the indicator disappears. Then unlock and tap Start on the keyboard in another app: the first bounce starts a new session, with no "iPhone was locked" screen. Swipe back during a dictation, let it finish, then open LocalFlow from the Home Screen: it shows Home, not the old bounce screen.
- [ ] Peak memory during a 5-minute dictation; no jetsam in the background.

Keyboard (compare side by side with Apple's keyboard in Try it → Cursor practice):
- [ ] Hold-to-trackpad delay feels the same as Apple's.
- [ ] Slow drags land between each pair of letters; fast swipes travel similar distances.
- [ ] Vertical moves across soft-wrapped lines, short lines and blank lines keep the column.
- [ ] Held delete switches to words at a similar time and pace.
- [ ] Shift, caps lock, auto-capitalization, double-space period, `123`/`#+=`, emoji and accent deletion.
- [ ] Two-thumb rollover, including space, keeps typing order.
- [ ] Autocorrect (Home → Keyboard, on by default, with a bundle that has the `autocorrect` section): with it off, typing is unchanged, and without Full Access it is off. On, a mistyped word ("teh") is corrected at space, Return and `. , ! ? ; :`, in its case ("Teh" → "The", "TEH" → "THE"). Delete right after puts the typed word back without the space, and it is not corrected again until the keyboard restarts. After space or punctuation the bar shows the typed word, the correction and suggestions, and a choice replaces the word. Swiped words, password fields and words typed with accents are left alone. Check Notes, Messages, Safari and a WebKit field for a lagging proxy.
- [ ] Soft key edges (Home → Keyboard, on by default, with a bundle that has the `tap` section): a tap near a key's edge may type the likelier neighbour, and its callout shows the key that types; a tap at a key's centre always types that key. Off, or without Full Access or in a password field, every tap types its nearest key.
- [ ] Touch regions: fast taps on the top and bottom rows, and taps in the bar outside its controls, type without dropped letters; the Start capsule and chips still take their taps, Start also from the bar above it, and while dictating Stop also from the top-row keys under it (other keys still type); a quick skid types its key; a low tap above the space bar types the bottom row; delete takes taps just right of M.
- [ ] Never correct (autocorrect on, Full Access): after a revert (Delete right after a correction, or the typed word chosen on the strip) the top row shows "Never correct “word”" in the Undo chip's slot, not over a dictation in progress or its Undo chip. Typing on, switching fields or hiding the keyboard dismisses it and nothing is stored: after switching keyboards away and back, the word is corrected again. Tapping it keeps the word uncorrected after the keyboard restarts, in any case. Diagnostics shows "Forget never-correct words (N)"; forgetting them makes the word corrected again from the keyboard's next appearance. Check it in a password field (no correction, no offer).
- [ ] Notes, Messages, Mail and Safari fields: trackpad units, context windows, undo.
- [ ] Haptics only with Full Access; Typing haptics on key-down, off when the setting is off; VoiceOver labels; dark mode; landscape; SE-size layout.
- [ ] iPad (the keyboard is universal; the app runs in iPhone compatibility mode): the keyboard lays out and types in portrait and landscape, and dictation works through the bounce.
- [ ] Same height everywhere: the keyboard's top edge sits at the same height in Try it (fresh, and after visiting other apps), Messages, Safari (address bar and a page field), Notes and Contacts, in portrait and landscape, with no band above the top row.
- [ ] Field keys: "@" and "." beside a narrower space bar in an email field (Contacts → new contact → email); ".", "/" and ".com" in a URL field (Contacts → URL), holding ".com" offers .org/.net/.edu/.us; "." beside space in Safari's address bar. No emoji key in email and URL fields.
- [ ] Press-and-hold: holding e, a, o, n, s, c, - . ' " $ ? ! shows the choices; sliding picks, lifting types; lifting without moving types the key itself. Fast typing, swipes, the callout, held delete and the space-bar trackpad are unchanged.
- [ ] Emoji: the face key opens the panel at the same height; recents first after use, the jump bar scrolls to a category, a tap inserts, delete and ABC work, recents survive a keyboard restart without Full Access.
- [ ] Return key: in a field with `enablesReturnKeyAutomatically` (Messages, Safari's address bar) Return looks disabled and does nothing while empty, and enables with the first character, typed or dictated.
- [ ] Menu: the keys dim under it, a tap outside the card closes it; it fits or scrolls in landscape and at the largest accessibility text sizes; "Full width" / "Chat bubble" switches the cursor's text width for this kind of field.
- [ ] Appearance and accessibility: a field asking for a dark keyboard gets one, others follow the system (Safari's address bar stays dark in dark mode); Bold Text, Increase Contrast and Reduce Motion as in ARCHITECTURE.md ("Top row").
