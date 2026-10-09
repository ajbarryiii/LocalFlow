# LocalFlow for iPhone — prototype architecture

Status: prototype. This document is the contract between the iOS components.
Change it first when the contract changes.

## Goal

A Wispr Flow–style iPhone experience that is fully local: a custom keyboard
with a dictation button that works in any app, backed by the same bundled
Parakeet model the macOS app uses. Audio, transcripts, and model inference never
leave the device. No network code, telemetry, analytics, or persistent logs of
user content.

## Platform constraints that shape the design

1. **Keyboard extensions cannot use the microphone** and have a small memory
   limit (tens of MB). The model (~330 MB compiled encoder) and audio capture
   must live in the containing app.
2. **An app cannot start recording from the background.** It can keep
   recording in the background if the audio session was activated in the
   foreground and the `audio` background mode is declared.
3. **iOS gives apps no API to switch back to the previous app.** When the
   keyboard has to launch the containing app, the user returns using the
   system "◀ App" back control or the home-indicator swipe.
4. **The GPU is unavailable in the background.** The encoder uses
   `cpuAndNeuralEngine`, as on macOS.
5. The encoder targets the `ios19` Core ML opset, so the deployment target
   is **iOS 26.0**.

These constraints lead to the same "Flow session" design Wispr Flow uses:

- The first dictation from the keyboard **bounces** to the app. The app
  activates the audio session in the foreground, starts the session, and
  begins recording immediately. The user then swipes back.
- While the session is active (default 5 minutes after the last dictation),
  the app keeps an `AVAudioEngine` input running in the background, so later
  dictations start instantly with no app switch. **Between dictations,
  captured buffers are dropped immediately and never retained.** iOS shows
  its microphone indicator for the whole session. The app explains this to
  the user.
- When the session expires or is interrupted, the engine stops and the
  audio session is deactivated. The next dictation bounces again.

## Components

```
iOS/
  ARCHITECTURE.md   this contract
  README.md         build, run, simulator, device and manual-test instructions
  Makefile          swiftc + make build (no Xcode project, no SwiftPM)
  Shared/           Foundation-only code compiled into app, keyboard and tests
  HostCore/         Foundation-only host logic compiled into app and tests
  App/              containing app (SwiftUI, audio, model, session controller)
  Keyboard/         keyboard extension (UIInputViewController + SwiftUI UI)
  Tests/            dependency-free executable tests run on the macOS host
  Config/           Info.plist and entitlements templates
```

Code reused from the macOS app (compiled into the iOS app only, not the
keyboard):

- `Sources/Parakeet/*.swift`: model runtime, unchanged except for an additive
  in-memory `transcribe(samples:)` API.
- `Sources/LocalDictationCore.swift`: deterministic "press enter" and spoken
  delimiter formatting.

`Shared/` and `HostCore/` must import only Foundation, plus CoreFoundation for
Darwin notifications, so they compile for the macOS test runner. UIKit,
AVFoundation and SwiftUI belong in `App/` and `Keyboard/`.

## Identifiers (Makefile variables, injected into Info.plist)

| Variable | Default (dev) |
| --- | --- |
| `BUNDLE_ID` | `com.ajbarryiii.localflow.ios.dev` |
| keyboard bundle ID | `$(BUNDLE_ID).keyboard` |
| `APP_GROUP` | `group.$(BUNDLE_ID)` |
| `URL_SCHEME` | `localflow-dev` |
| `DISPLAY_NAME` | `LocalFlow Dev` |

Both Info.plists carry `LocalFlowAppGroupIdentifier` and `LocalFlowURLScheme`.
`LocalFlowConfiguration.main` (Shared) reads them, so no Swift file hardcodes
an identifier.

## Inter-process protocol (Shared/)

Communication uses the App Group container plus Darwin notifications.
**Notifications and URLs are wake-up signals only and carry no data or
authority.** Any process on the device can post a Darwin notification or open
a URL, so all authority comes from files that only the app and keyboard can
write (the App Group container).

The design is level-triggered: the keyboard writes the state it wants; the host
reconciles toward it and publishes the actual state. Each file has exactly one
writer, and every write is atomic (`Data.write(options: .atomic)`, which
writes a temporary file and renames it), so a reader never sees a partial file.
This makes the protocol robust to coalesced notifications, process death and
jetsam.

Directory: `<App Group container>/Dictation/`. JSON, `JSONEncoder` with
`.secondsSince1970` dates and sorted keys. Every record has `schema: Int`
(currently `1`). A record with an unknown schema is treated as absent.

| File | Writer | Reader | Content |
| --- | --- | --- | --- |
| `intent.json` | keyboard | host | `KeyboardIntent` — the latest dictation request |
| `status.json` | host | keyboard | `HostStatus` — session, model and dictation state, heartbeat, level |
| `result-<UUID>.json` | host | keyboard | `DictationResult` — one finished transcript; the keyboard deletes it after insertion |

Darwin notification names are `"\(appGroupID).intent"`, `".status"` and
`".result"`, posted after the corresponding write.

### Types (normative; Shared/DictationProtocol.swift)

```swift
enum DictationProtocol {
    static let schema = 1
    static let heartbeatInterval: TimeInterval = 1        // host rewrites status at least this often while a session is active
    static let livenessTimeout: TimeInterval = 3          // keyboard treats an older heartbeat as "host not running"
    static let pendingRecordTTL: TimeInterval = 20        // a record intent not yet started is stale after this (covers app launch)
    static let maxDictationDuration: TimeInterval = 300   // host finishes a recording automatically after this
    static let resultTTL: TimeInterval = 60               // results older than this are never inserted and are purged
}

struct KeyboardIntent: Codable, Equatable {
    enum Action: String, Codable { case record, finish, cancel }
    var schema: Int
    var requestID: UUID
    var action: Action
    var keyboardInstanceID: UUID   // the UIInputViewController instance that wrote this action
    var issuedAt: Date
}

struct HostStatus: Codable, Equatable {
    enum Session: String, Codable { case inactive, starting, active }
    enum Model: String, Codable { case unavailable, notPrepared, preparing, ready, failed }
    var schema: Int
    var sessionID: UUID?
    var session: Session
    var heartbeatAt: Date
    var sessionExpiresAt: Date?
    var model: Model
    var dictation: DictationStatus?
    var level: Float               // 0...1, meaningful only while recording
    var error: HostErrorCode?      // content-free
}

struct DictationStatus: Codable, Equatable {
    enum Phase: String, Codable { case recording, transcribing, completed, failed, cancelled }
    var requestID: UUID
    var phase: Phase
    var startedAt: Date
    var updatedAt: Date
}

enum HostErrorCode: String, Codable {
    case microphonePermissionDenied, audioSessionFailed, interrupted, sessionInactive,
         modelUnavailable, modelFailed, transcriptionFailed, notRecording, tooLong
}

struct DictationResult: Codable, Equatable {
    var schema: Int
    var requestID: UUID
    var text: String               // already post-processed by LocalDictationCore
    var pressEnter: Bool
    var createdAt: Date
}
```

### Host reconciliation (Shared/HostReconciler.swift; pure, tested)

`HostReconciler.action(intent:current:now:) -> HostAction` with
`HostAction = none | start(UUID) | finish(UUID) | cancel(UUID) | reject(UUID, HostErrorCode)`.
`current` is the host's `DictationStatus?`.

- No intent, or the intent schema is unknown: `none`.
- `record(R)`:
  - If `current.requestID == R`: `none`. This is idempotent; R is not
    restarted after it has completed, failed or been cancelled.
  - If `now - issuedAt > pendingRecordTTL`: `none`, because the intent is stale.
  - Otherwise: `start(R)`. If another request is recording, the controller
    cancels it first, since the newest request wins.
- `finish(R)`: if `current` is R and recording, `finish(R)`. If `current` is R
  in any other phase, `none`. Otherwise `reject(R, .notRecording)`, so the
  keyboard stops waiting.
- `cancel(R)`: if `current` is R and recording or transcribing, `cancel(R)`.
  Otherwise `none`.

The host evaluates this on every `.intent` notification, on a 0.5 s fallback
poll while a session is active, and once on launch or URL open.

### Keyboard presentation (Shared/KeyboardPresenter.swift; pure, tested)

`KeyboardPresenter.mode(hasFullAccess:status:intent:now:) -> KeyboardMode`:

- `needsFullAccess` if `!hasFullAccess`.
- The host is alive when `status.session == .active` and
  `now - heartbeatAt <= livenessTimeout`.
- `recording(level:startedAt:)` / `transcribing`: when the host is alive and
  `status.dictation` is recording or transcribing `intent.requestID`. A new
  keyboard instance therefore adopts a recording started by another instance,
  which happens after the bounce.
- `starting`: when the latest intent is `record`, it is younger than
  `pendingRecordTTL`, and the host has not picked it up yet. This covers the
  bounce while the app launches.
- `ready`: the host is alive and idle.
- `hostUnavailable`: otherwise. Tapping the mic bounces.
- `error(HostErrorCode)`: when the latest dictation for `intent.requestID`
  failed. Show it once, then return to `ready`.

### Result ownership and insertion (Shared/)

- A keyboard instance inserts a result only if the instance itself wrote
  `finish(R)` for that request ID, and `now - createdAt <= resultTTL`. A newly
  created keyboard in a different text field never inserts someone else's
  transcript.
- After insertion, the keyboard deletes `result-R.json`. The host purges
  results older than `resultTTL` on each heartbeat, and all results when a
  session ends or the app launches.
- `TextInsertionFormatter.text(for:contextBefore:)` is pure and tested. It
  trims the transcript. It adds one leading space when the context ends in a
  non-whitespace character that is not an opening bracket or quote, unless the
  transcript starts with closing punctuation (`.,;:!?)]}`). It returns `""` for
  an empty transcript. `pressEnter` inserts `"\n"` after the text.

### SharedDictationStore (Shared/SharedDictationStore.swift)

- `init?(configuration:)` resolves
  `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` and
  returns nil if the container is unavailable. Without Full Access, the
  keyboard reports `needsFullAccess`.
- `init(directory:)` is for tests.
- Methods: `readIntent()`, `writeIntent(_:)`, `readStatus()`,
  `writeStatus(_:)`, `writeResult(_:)`, `readResult(requestID:)`,
  `deleteResult(requestID:)`, `purgeResults(olderThan:now:)`,
  `purgeAllResults()`.
- File protection: results and the intent use `.completeFileProtection`;
  status uses `.completeFileProtectionUntilFirstUserAuthentication`.

### DarwinNotifier (Shared/DarwinNotifier.swift)

This is a thin wrapper over `CFNotificationCenterGetDarwinNotifyCenter()`:
`post(_ signal:)` and `observe(_ signal:, handler:) -> Observation`.
Removing the observation unregisters it. Handlers are delivered on the main
queue.

### Shared settings

The keyboard can read these, so they live in App Group `UserDefaults`
(`LocalFlowSettings` in Shared): `sessionMinutes` (5, 15 or 60; default 5),
`spokenDelimitersEnabled` (default true), `pressEnterEnabled` (default true)
and `hapticsEnabled` (default true). No transcript history is stored.

## Host app (App/, HostCore/)

- **`HostSessionController`** (`@MainActor`, `ObservableObject`) owns the
  session lifecycle, heartbeat timer, intent observation and polling,
  reconciliation, and status publishing. It writes status after every state
  change and at least every `heartbeatInterval` while a session is active.
- **`MicrophoneCapture`**: `AVAudioSession` `.playAndRecord` with
  `[.mixWithOthers, .allowBluetoothHFP]`, activated only in the foreground.
  It runs one `AVAudioEngine` input tap for the whole session and converts to
  16 kHz mono `Float32`. It handles interruptions (a call ends the session),
  media-services reset and engine configuration changes. If a restart is
  impossible in the background, it ends the session and reports the reason.
- **`DictationSampleBuffer`** (HostCore; pure, tested) accumulates samples
  only while a request is recording and drops them otherwise. It is capped at
  `maxDictationDuration` and computes a normalized level.
- **`HostURLRoute`** (HostCore; pure, tested) parses `<scheme>://dictate`,
  rejects everything else, and ignores query parameters. Opening the URL brings
  the app to the foreground, starts the session if needed, and runs one
  reconciliation pass. The URL itself never starts recording; only a fresh
  `record` intent does.
- **Transcription** uses its own
  `LocalParakeetService(startupStrategy: .fifteenSecondsFirst)` instance,
  which loads one encoder function to bound memory. It calls
  `transcribe(samples:)` and then `LocalDictationCore.process`, with
  `macros: []` and the settings above. The call is wrapped in a UIKit
  background task. Model preparation starts when a session starts, and during
  onboarding.
- **UI (SwiftUI)**:
  - Onboarding: microphone permission, steps to enable the keyboard (Settings
    → LocalFlow → Keyboards → enable, Allow Full Access), and one-time model
    preparation with progress.
  - Home: session card (start/end, time remaining, a microphone-indicator
    explanation), model state, a "try it here" text field, and settings.
  - Bounce screen, shown when opened from the keyboard: "Listening — swipe
    back to your app".
- **Self-test build** (`-D LOCALFLOW_SELFTEST`, never in normal builds):
  - `LOCALFLOW_SELFTEST_AUDIO=<path>` transcribes a synthetic file and prints
    only a pass/fail line and timings.
  - `LOCALFLOW_SYNTHETIC_MIC=<path>` replaces `MicrophoneCapture` with a
    real-time-paced synthetic source, so the simulator end-to-end flow needs
    no Mac microphone access.

## Keyboard extension (Keyboard/)

- `KeyboardViewController: UIInputViewController` hosts the SwiftUI
  `KeyboardRootView` (about 260 pt tall).
- `KeyboardDictationClient` uses `SharedDictationStore`, `DarwinNotifier`
  and `KeyboardPresenter`. It polls status every 0.2 s only while visible,
  observes `.status` and `.result`, and keeps the owned finish set in memory
  for the instance.
- Mic tap:
  - `ready`: write a `record` intent with a new ID and post `.intent`.
  - `hostUnavailable`: write the same intent, then open
    `<scheme>://dictate` through `HostAppLauncher`.
  - `recording`: write `finish`, record ownership, and post `.intent`.
  - Cancel: write `cancel`.
- `HostAppLauncher` walks the responder chain to the application object and
  invokes `open(_:options:completionHandler:)`. Extensions cannot use
  `UIApplication.shared`, so this is a known App Review gray area; call it out.
  If it fails, show "Open LocalFlow to start a session".
- UI: a dictation pad with a globe key when `needsInputModeSwitchKey` is true
  (also `handleInputModeList`), a large mic/stop button with live level bars
  and elapsed time, cancel, space, delete with auto-repeat, and a return key
  labeled from `returnKeyType`. Add a status line and a Full Access banner.
  Support light and dark mode, and haptics only with Full Access and the
  setting enabled.
- The keyboard never links Parakeet, AVFoundation capture or LocalDictationCore.
  It has no network access and does not log content.

## Privacy and security invariants (review checklist)

1. Audio is never written to disk. Between dictations, capture buffers are
   dropped in the tap callback.
2. Transcripts exist on disk only as a single `result-R.json` in the App Group
   container for at most `resultTTL`. They are deleted on insertion, expiry or
   session end. There is no history.
3. No network APIs anywhere. No telemetry. `os.Logger` messages carry only
   content-free state, with no transcript, text context or levels.
4. URLs and Darwin notifications carry no authority (see above).
5. The keyboard reads `documentContextBeforeInput` only to choose spacing. It
   never stores or transmits it.
6. Recording requires a fresh keyboard intent, and the host enforces the
   maximum duration.

## Build and test (iOS/Makefile)

- `make -C iOS` builds `iOS/build/<platform>/LocalFlow.app`, containing
  `PlugIns/LocalFlowKeyboard.appex`. The default platform is the arm64
  simulator. `PARAKEET_BUNDLE_DIR` copies the model into `LocalFlow.app/Parakeet/`
  and relabels it with `scripts/label-localflow-model.py`, as the macOS build
  does.
- `make -C iOS check` runs three steps: a simulator type-check of the app and
  keyboard with `-warnings-as-errors`; the host tests (`Shared` + `HostCore` +
  `Tests`, compiled for macOS); and `plutil -lint`.
- `make -C iOS smoke-sim` builds the self-test variant into a separate build
  dir, installs it on a dedicated simulator, and transcribes `say`-generated
  synthetic speech.
- Device builds (`PLATFORM=device`) need `CODESIGN_IDENTITY`, `TEAM_ID` and
  two provisioning profiles with the App Group capability. See README.
- The root `make check` is unchanged in scope except for the shared Parakeet
  API. CI (`macos-15`) does not yet run iOS checks; enabling that is a
  workflow change and needs approval.
