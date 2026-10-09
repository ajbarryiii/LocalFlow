# LocalFlow for iPhone — prototype architecture

Status: prototype, contract revision 2 (it incorporates the first design
review). This document is the contract between the iOS components. Change it
first when the contract changes.

## Goal

A Wispr Flow–style iPhone experience that is fully local: a custom keyboard
with a dictation button, backed by the same bundled Parakeet model the macOS
app uses. Audio, transcripts, and model inference stay on the device. There is
no network code, telemetry, analytics, or persistent logging of user content.

Custom keyboards do not appear everywhere. iOS substitutes the system keyboard
in secure text fields and phone-pad fields, and apps can reject custom
keyboards entirely. Those fields are out of scope.

## Platform constraints that shape the design

1. **Keyboard extensions cannot use the microphone** and have a small memory
   limit (tens of MB). The model (~330 MB compiled encoder) and audio capture
   must live in the containing app.
2. **An app cannot start recording from the background.** It can keep
   recording in the background if the audio session was activated in the
   foreground and the `audio` background mode is declared.
3. **Extensions have no supported API to open their containing app**
   (`NSExtensionContext.open` is for Today and iMessage extensions only).
   Keyboards that "bounce" to their app walk the responder chain to the
   application object. Apple DTS discourages this, but Wispr Flow ships it.
   The bounce is therefore **experimental**. The supported baseline is
   starting a session manually in the app.
4. **iOS gives apps no API to switch back to the previous app.** The user
   returns with the system "◀ App" control or the home-indicator swipe.
5. **The GPU is unavailable in the background.** On iOS 27, background
   Neural Engine access requires the
   `com.apple.developer.background-tasks.continued-processing.inference`
   entitlement (iOS 27 release notes, Core AI). Neural Engine memory is also
   now charged to the app process. Transcription in the background must
   therefore tolerate the loss of the Neural Engine (see "Compute policy").
6. The encoder targets the `ios19` Core ML opset, so the deployment target
   is **iOS 26.0**.

These lead to the same "Flow session" design Wispr Flow uses:

- A session starts **only in the foreground**, in one of two ways:
  - The user taps "Start session" in the app.
  - The app is opened (by the bounce or by the user) while a fresh `record`
    intent from the keyboard is waiting. The host then admits that request
    and starts recording immediately. The user swipes back.
- While the session is active, the app keeps one `AVAudioEngine` input running
  in the background, so later dictations start instantly with no app switch.
  **Between dictations, captured buffers are dropped in the tap callback and
  never retained.** The idle timeout defaults to 5 minutes. iOS shows its
  microphone indicator for the whole session, and the app explains this.
- The session ends on:
  - idle expiry
  - an audio interruption (for example a call)
  - an unrecoverable engine failure
  - device lock
  - the user tapping "End session"

  The engine stops and the audio session deactivates. The next dictation needs
  the app in the foreground again.

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

Code reused from the macOS app is compiled into the iOS app only, not the
keyboard:

- `Sources/Parakeet/*.swift`: the model runtime. It gets these additive
  changes:
  - an in-memory `transcribe(samples:)`
  - injectable compute units (default unchanged)
  - streaming SHA-256 verification, so loading never reads a whole 330 MB file
    into memory
- `Sources/LocalDictationCore.swift`: deterministic "press enter" and spoken
  delimiter formatting.

`Shared/` and `HostCore/` may import only Foundation, plus CoreFoundation for
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

The keyboard and host communicate through the App Group container plus Darwin
notifications.

**Notifications and URLs are wake-up hints only; they carry no data or
authority.** Any process on the device can post a Darwin notification or open
our URL. All authority comes from files that only the app and the keyboard can
write. Every reader also polls, so a dropped or coalesced notification only
adds latency.

The design is level-triggered: the keyboard writes the state it wants, and the
host reconciles toward it and publishes the actual state. Each file has
exactly one writer process. Every write is atomic
(`Data.write(options: .atomic)`, a temporary file plus rename), so readers
never see a partial file.

On iPhone only one keyboard instance is visible at a time. A keyboard still
re-reads `intent.json` before writing `finish` or `cancel`, and writes only if
the current intent still names the same request (stale-writer guard). The
host rejects controls for requests that are not current. Per-request
mailboxes are deferred.

Directory: `<App Group container>/Library/Caches/LocalFlowDictation/`,
created on demand and marked `isExcludedFromBackup`. Backup exclusion is
best effort. Records are JSON (`JSONEncoder`, `.secondsSince1970` dates,
sorted keys), and each carries `schema: Int` (currently `1`).

| File | Writer | Reader | Content | Protection |
| --- | --- | --- | --- | --- |
| `intent.json` | keyboard | host | `KeyboardIntent` — the latest dictation request | `.complete` |
| `presence.json` | keyboard | host | `KeyboardPresence` — a visible keyboard exists | `.completeUntilFirstUserAuthentication` |
| `status.json` | host | keyboard | `HostStatus` — run, session, capture, model and dictation state | `.completeUntilFirstUserAuthentication` |
| `result-<UUID>.json` | host | keyboard | `DictationResult` — one finished transcript | `.complete` |

The host writes results, and the keyboard claims them by deletion. Either
process may delete an expired result (see "Results").

Darwin notification names are `"\(appGroupID).intent"`, `".presence"`
(unused for now), `".status"` and `".result"`, posted after the matching
write.

### Reading records

`SharedDictationStore` returns typed outcomes, not just optionals:

```swift
enum StoreRead<Value> { case value(Value), absent, incompatible, unreadable }
```

- `absent`: the file does not exist.
- `incompatible`: the record decodes, but its schema is unknown. The keyboard
  shows "Update LocalFlow"; the host ignores the record.
- `unreadable`: corrupt JSON, the file is protected because the device is
  locked, or an I/O error. Callers treat this as absent but never crash or
  log content.

### Time

All freshness checks use `age = now - timestamp` and require
`-clockSkewTolerance <= age <= ttl`, with `clockSkewTolerance = 2 s`. A
backward clock jump therefore makes records stale (fail closed), not
fresh. All functions take `now: Date` so tests are deterministic.

### Types (normative; Shared/DictationProtocol.swift)

```swift
enum DictationProtocol {
    static let schema = 1
    static let heartbeatInterval: TimeInterval = 1          // host rewrites status at least this often while running a session
    static let livenessTimeout: TimeInterval = 3            // keyboard treats an older heartbeat as "host not running"
    static let clockSkewTolerance: TimeInterval = 2
    static let pendingRecordTTL: TimeInterval = 20          // admission window for a record intent (covers launch/bounce)
    static let startupTimeout: TimeInterval = 10            // admission -> first audio buffer, else failed(.startupTimeout)
    static let captureFreshness: TimeInterval = 1           // captureReady requires an input buffer this recent
    static let keyboardPresenceInterval: TimeInterval = 1   // keyboard rewrites presence this often while visible
    static let keyboardPresenceTimeout: TimeInterval = 15   // see "Keyboard presence"
    static let maxDictationDuration: TimeInterval = 300     // host auto-finishes a recording after this
    static let resultTTL: TimeInterval = 60                 // insertion window; expired results are deleted by either process
}

struct KeyboardIntent: Codable, Equatable {
    enum Action: String, Codable { case record, finish, cancel }
    var schema: Int
    var requestID: UUID
    var action: Action
    var keyboardInstanceID: UUID   // the UIInputViewController instance that wrote this action
    var issuedAt: Date
}

struct KeyboardPresence: Codable, Equatable {
    var schema: Int
    var keyboardInstanceID: UUID
    var seenAt: Date
}

struct HostStatus: Codable, Equatable {
    enum Session: String, Codable { case inactive, starting, active }
    enum Model: String, Codable { case unavailable, notPrepared, preparing, ready, failed }
    var schema: Int
    var hostRunID: UUID            // new for every host process launch
    var sessionID: UUID?
    var session: Session
    var captureReady: Bool         // engine running and an input buffer within captureFreshness
    var heartbeatAt: Date
    var sessionExpiresAt: Date?    // idle expiry; nil while a dictation is in progress
    var model: Model
    var dictation: DictationStatus?
    var level: Float               // 0...1, meaningful only while recording
    var error: HostErrorCode?      // content-free, most recent session-level error
}

struct DictationStatus: Codable, Equatable {
    enum Phase: String, Codable { case starting, recording, transcribing, completed, failed, cancelled }
    var requestID: UUID
    var hostRunID: UUID            // the run that admitted this request
    var phase: Phase
    var error: HostErrorCode?      // set when phase == .failed (or .cancelled by the host)
    var startedAt: Date
    var updatedAt: Date
}

enum HostErrorCode: String, Codable {
    case microphonePermissionDenied, audioSessionFailed, startupTimeout, interrupted, deviceLocked,
         keyboardDismissed, sessionInactive, modelUnavailable, modelFailed, transcriptionFailed,
         backgroundTimeExpired, notRecording, tooLong, superseded
}

struct DictationResult: Codable, Equatable {
    var schema: Int
    var requestID: UUID
    var hostRunID: UUID
    var text: String               // already post-processed by LocalDictationCore
    var pressEnter: Bool
    var createdAt: Date
}
```

### Host reconciliation (Shared/HostReconciler.swift; pure, tested)

The signature is
`HostReconciler.action(intent: StoreRead<KeyboardIntent>, current: DictationStatus?, knownRequestIDs: Set<UUID>, isForeground: Bool, sessionActive: Bool, now: Date) -> HostAction`.

`HostAction` is one of `none`, `start(UUID)`, `finish(UUID)`, `cancel(UUID)`
or `reject(UUID, HostErrorCode)`. `knownRequestIDs` holds every request this
host has admitted, plus those recovered from the previous run's status. The
controller keeps a bounded recent set (for example the last 32).

- An intent that is not `.value`: `none`.
- `record(R)`:
  - If R is in `knownRequestIDs` or `current.requestID == R`: `none`. A
    request is never restarted, even after host death.
  - If the age is outside `[-tolerance, pendingRecordTTL]`: `none`, because
    the intent is stale.
  - If neither `sessionActive` nor `isForeground`: `reject(R, .sessionInactive)`.
    Capture cannot start from the background.
  - Otherwise: `start(R)`. If another request is starting, recording or
    transcribing, the controller cancels it first with `.superseded` and
    discards its outcome.
- `finish(R)`:
  - `current` is R and recording: `finish(R)`.
  - `current` is R and starting: `cancel(R)`. No audio was captured; the
    controller reports failed `.notRecording`.
  - `current` is R in any other phase: `none`.
  - Otherwise: `reject(R, .notRecording)`, unless R is in `knownRequestIDs`,
    in which case `none`.
- `cancel(R)`: if `current` is R and starting, recording or transcribing,
  `cancel(R)`. Otherwise `none`.

The host evaluates this:

- on every `.intent` notification
- on a 0.5 s poll while a session is active or the app is in the foreground
- on launch
- on URL open
- on becoming active

**Run recovery.** On launch, the host reads the previous `status.json`. If it
holds a non-terminal dictation from another `hostRunID`, the host publishes
that request as failed with `.interrupted` and adds it to `knownRequestIDs`
before reconciling. The host also deletes every result file whose
`hostRunID` differs from its own.

### Keyboard presence

While visible, and only with Full Access, the keyboard rewrites
`presence.json` every `keyboardPresenceInterval`. While a dictation is
starting or recording, the host cancels it with `.keyboardDismissed` when two
conditions both hold:

- the app is not in the foreground, and
- presence is older than `keyboardPresenceTimeout`.

This stops forgotten recordings. The bounce is covered: the app is in the
foreground until the user swipes back, and the keyboard then reappears.

### Keyboard presentation (Shared/KeyboardPresenter.swift; pure, tested)

The signature is
`KeyboardPresenter.mode(access: KeyboardAccess, status: StoreRead<HostStatus>, intent: StoreRead<KeyboardIntent>, now: Date) -> KeyboardMode`.
`KeyboardAccess` is one of `fullAccess`, `noFullAccess` or
`containerUnavailable`.

The modes are evaluated in this order:

1. `needsFullAccess`: when access is `noFullAccess`. The keyboard can read the
   container but cannot write it. The globe, space, delete and return keys
   keep working.
2. `configurationError`: when access is `containerUnavailable` (a missing
   entitlement or App Group).
3. `incompatible`: when the status or intent is `.incompatible`.
4. The host is **alive** when the status is a `.value`, `session == .active`,
   and the heartbeat age is in `[-tolerance, livenessTimeout]`.
5. If the latest intent is R and the host is alive:
   - `status.dictation` is R and starting → `starting`.
   - It is R and recording → `recording(level:startedAt:)`.
   - It is R and transcribing → `transcribing`.

   A new keyboard instance therefore adopts a request that another instance
   started, which is what happens after the bounce.
6. `error(code)`: when `status.dictation` is R and failed, or cancelled with
   an error, and its `updatedAt` is within 5 s. The view shows it once.
7. `starting`: when the latest intent is `record(R)` with a fresh age, and
   `status.dictation` is not R. This covers launch during the bounce.
8. `ready`: when the host is alive and `captureReady`.
9. `hostUnavailable`: in every other case. A mic tap bounces, or shows
   instructions.

### Results (Shared/; pure decisions, tested)

Delivery is **at most once**, and the insertion destination is bound to the
request.

- **Binding.** When an instance writes `finish(R)`, it records
  `(R, textDocumentProxy.documentIdentifier)`. An instance also binds when
  it was displaying R (recording or transcribing) and then sees it completed:
  host auto-finish at `maxDictationDuration`, or a finish written by another
  instance. Any focus change, such as a new `documentIdentifier` in
  `textDidChange` or `viewWillAppear`, invalidates the bindings for the old
  identifier.
- **Auto-insert.** The keyboard inserts automatically only when four things
  hold:
  - this instance is bound to R
  - the bound identifier equals the current `documentIdentifier`
  - the result's age is within `[-tolerance, resultTTL]`
  - R is not in the instance's consumed set
- **Claim before insert.** The keyboard reads `result-R.json`, deletes it,
  and inserts only if the delete succeeded. It then adds R to its in-memory
  consumed set. A crash between delete and insert loses that one transcript.
  This is accepted and documented.
- **Manual insert.** A fresh, unclaimed result that cannot be auto-inserted
  (no binding, or a different field) shows an "Insert last dictation" chip.
  Tapping it claims the result and inserts it into the current field.
- **Ordering.** The host writes `result-R.json` before it publishes R as
  `completed`. The keyboard checks for results on appearance and on every
  poll, whether or not a session is live.
- **Cleanup.** Either process deletes results whose age falls outside
  `[-tolerance, resultTTL]` whenever it runs:
  - the keyboard on appearance and on each poll
  - the host on launch, on each heartbeat, and at session end
- `TextInsertionFormatter.text(for:contextBefore:)` is pure and tested. It
  trims the transcript. It adds one leading space when the context ends in a
  non-whitespace character that is not an opening bracket or quote, unless the
  transcript starts with closing punctuation (`.,;:!?)]}`). It returns `""`
  for an empty transcript. `pressEnter` inserts `"\n"` after the text.

### SharedDictationStore (Shared/SharedDictationStore.swift)

- `init?(configuration:)` resolves
  `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. It
  returns nil when the container is unavailable, which maps to
  `KeyboardAccess.containerUnavailable`.
- `init(directory:)` is for tests.
- Reads:
  - `readIntent() -> StoreRead<KeyboardIntent>`
  - `readPresence() -> StoreRead<KeyboardPresence>`
  - `readStatus() -> StoreRead<HostStatus>`
  - `readResult(requestID:) -> StoreRead<DictationResult>`
  - `resultRequestIDs() -> [UUID]`
- Writes, each throwing: `writeIntent(_:)`, `writePresence(_:)`,
  `writeStatus(_:)`, `writeResult(_:)`.
- Deletes:
  - `deleteResult(requestID:) -> Bool`, true only if this call removed the
    file
  - `purgeExpiredResults(now:)`
  - `purgeResults(where:)`, used for run recovery and session end
- File protection follows the table above. The directory is created with
  `isExcludedFromBackup`.

### DarwinNotifier (Shared/DarwinNotifier.swift)

This is a thin wrapper over `CFNotificationCenterGetDarwinNotifyCenter()`.
`post(_ signal:)` posts a signal. `observe(_ signal:, handler:) -> Observation`
registers a handler. Removing the observation unregisters it. Handlers are
delivered on the main queue.

### Shared settings

The keyboard can read these, so they live in App Group `UserDefaults`
(`LocalFlowSettings` in Shared):

- `sessionMinutes`: 5, 15 or 60; default 5
- `spokenDelimitersEnabled`: default true
- `pressEnterEnabled`: default true
- `hapticsEnabled`: default true

No transcript history is stored.

## Host app (App/, HostCore/)

- **`HostSessionController`** (`@MainActor`, `ObservableObject`):
  - Owns the run ID, session lifecycle, idle expiry, heartbeat timer, intent
    observation and polling, reconciliation, run recovery and status
    publishing.
  - Writes status after every state change, and at least every
    `heartbeatInterval` while a session is starting or active.
  - Counts idle expiry only while no dictation is starting, recording or
    transcribing.
  - Ends the session on `protectedDataWillBecomeUnavailable` (device lock),
    on an interruption, or on an engine failure it cannot recover from in the
    background.
- **`MicrophoneCapture`**:
  - Configures `AVAudioSession` as `.playAndRecord` with
    `[.mixWithOthers, .allowBluetoothHFP]`, and activates it only in the
    foreground.
  - Runs one `AVAudioEngine` input tap for the session and converts to
    16 kHz mono `Float32`.
  - Reports the last-buffer time that drives `captureReady`.
  - Handles interruptions, media-services reset and engine configuration
    changes. A restart is attempted only in the foreground; in the
    background, the session ends with a reason.
- **`DictationSampleBuffer`** (HostCore; pure, tested):
  - Thread-safe, with a single lock owning all sample mutation.
  - `begin(R)` starts accepting. Buffers outside a recording are dropped.
  - `finish(R)` stops accepting and drains under the lock in one step, so
    no callback can append after the snapshot.
  - Enforces the `maxDictationDuration` cap and computes a normalized level.
- **Generation fences.** Every asynchronous completion re-checks that
  `(hostRunID, requestID, dictation generation)` is still current before
  publishing status or a result. Examples are startup, first buffer,
  transcription and background-task expiry. A superseded or cancelled
  request's outcome is discarded. A newer request cancels a transcribing one.
- **`HostURLRoute`** (HostCore; pure, tested) parses `<scheme>://dictate`
  and rejects everything else; query parameters are ignored. Opening the URL
  only shows the app's UI and runs one reconciliation pass. **It never
  starts a session or the microphone by itself.** Only a fresh `record`
  intent, admitted while the app is in the foreground, can do that. So can
  the user's own "Start session" tap.
- **Compute policy.**
  - Transcription uses a host-owned
    `LocalParakeetService(startupStrategy: .fifteenSecondsFirst)`, which loads
    one encoder function to bound memory. Its compute units are
    `.cpuAndNeuralEngine`.
  - If a background transcription fails in a way that indicates the Neural
    Engine is unavailable, the host retries once on a lazily created `.cpuOnly`
    service, then releases it.
  - Work runs inside a UIKit background task. Expiry cancels it and reports
    `.backgroundTimeExpired`.
  - Requesting the iOS 27 inference entitlement is a follow-up. The device
    plan measures iOS 26 against iOS 27, foreground against background, and
    Neural Engine against CPU, along with latency and peak memory.
- **Memory.** Preparation starts when a session starts and during onboarding.
  Transcription waits for readiness. On a memory warning while idle, the host
  releases the model runtime. Peak memory during cold preparation and
  maximum-length transcription must be measured on a device.
- After transcription, the host calls
  `LocalDictationCore.process(text, macros: [], pressEnterEnabled:, spokenDelimitersEnabled:)`.
- **UI (SwiftUI)**:
  - Onboarding: microphone permission, steps to enable the keyboard (Settings
    → LocalFlow → Keyboards → enable, Allow Full Access), and one-time model
    preparation with progress.
  - Home: session card (start/end, idle time remaining, microphone-indicator
    explanation), model state, and settings.
  - "Try it": **two** text fields, for destination-binding tests.
  - Bounce screen: "Listening — swipe back to your app". It appears only
    once the dictation is `recording` (input buffers are flowing). Before
    that it shows "Starting…".
- **Self-test build** (`-D LOCALFLOW_SELFTEST`, never in normal builds):
  - `LOCALFLOW_SELFTEST_AUDIO=<path>` transcribes a synthetic file and prints
    only a pass/fail line and timings.
  - `LOCALFLOW_SYNTHETIC_MIC=<path>` replaces `MicrophoneCapture` with a
    real-time-paced synthetic source, so simulator end-to-end tests need no Mac
    microphone. It does not prove the background audio behavior; only a
    device test can.

## Keyboard extension (Keyboard/)

- `KeyboardViewController: UIInputViewController` hosts the SwiftUI
  `KeyboardRootView` (about 260 pt tall).
- `KeyboardDictationClient`:
  - Uses `SharedDictationStore`, `DarwinNotifier`, `KeyboardPresenter` and
    the result decisions.
  - Polls status and results every 0.2 s, only while visible.
  - Writes presence every `keyboardPresenceInterval` while visible.
  - Observes `.status` and `.result`.
  - Holds the bindings and the consumed set in memory, per instance.
- Mic tap:
  - `ready`: write `record(R)` with a new ID, then post `.intent`.
  - `hostUnavailable`: write `record(R)`, then try `HostAppLauncher` to open
    `<scheme>://dictate`. If that fails, show "Open LocalFlow to start a
    session".
  - `starting`, `recording`: re-read the intent (stale-writer guard), write
    `finish(R)`, bind it to the current `documentIdentifier`, then post.
  - Cancel: write `cancel(R)` under the same guard.
- `HostAppLauncher` walks the responder chain to the application object and
  invokes `open(_:options:completionHandler:)` dynamically. It is
  experimental and must be validated on iOS 26 and 27 devices. Call it out in
  the PR.
- **UI**: a dictation pad containing:
  - a globe key when `needsInputModeSwitchKey` (also `handleInputModeList`)
  - a large mic/stop button with live level bars and elapsed time
  - cancel
  - the "Insert last dictation" chip
  - space
  - delete with auto-repeat
  - a return key labeled from `returnKeyType`
  - a status line, plus Full Access, configuration and update banners

  Support light and dark mode. Haptics play only with Full Access and the
  setting enabled.
- The keyboard never links Parakeet, AVFoundation capture or
  LocalDictationCore. It has no network access and does not log content.

## Privacy and security invariants (review checklist)

1. Audio is never written to disk. Between dictations, capture buffers are
   dropped in the tap callback.
2. A transcript exists on disk only as one `result-R.json`. That file sits in
   the App Group `Library/Caches` (excluded from backup) and is deleted on
   claim, expiry (by either process) or run change. There is no history.
3. There are no network APIs and no telemetry. `os.Logger` messages carry only
   content-free state, never transcripts, text context or levels.
4. URLs and Darwin notifications carry no authority (see above). A URL can
   never start capture.
5. The keyboard reads `documentContextBeforeInput` only to choose spacing,
   and `documentIdentifier` only to bind a destination. It never stores or
   transmits either beyond the instance's memory.
6. Capture requires a session started in the foreground. Recording requires a
   fresh keyboard intent that the host admits. Recording ends at the maximum
   duration or when the keyboard disappears. Device lock ends the session.

## Build and test (iOS/Makefile)

- `make -C iOS` builds `iOS/build/<platform>/LocalFlow.app`, with
  `PlugIns/LocalFlowKeyboard.appex`. The default platform is the arm64
  simulator.
  - The app is compiled for `arm64-apple-ios26.0[-simulator]`.
  - The keyboard is compiled with `-application-extension`, the
    `_NSExtensionMain` entry point, and module `LocalFlowKeyboard`. Its
    principal class is `LocalFlowKeyboard.KeyboardViewController`.
  - Simulator builds embed App Group entitlements. The `.appex` is signed
    before the app.
- `PARAKEET_BUNDLE_DIR` copies the model into `LocalFlow.app/Parakeet/` and
  relabels it with `scripts/label-localflow-model.py`, as the macOS build
  does.
- `make -C iOS check` runs three steps: a simulator type-check of the app and
  keyboard with `-warnings-as-errors`, the host tests (`Shared` + `HostCore` +
  `Tests`, compiled for macOS), and `plutil -lint`.
- `make -C iOS smoke-sim` builds the self-test variant into a separate build
  dir, installs it on a dedicated `LocalFlow-` simulator, and transcribes
  `say`-generated synthetic speech.
- Device builds (`PLATFORM=device`) need `CODESIGN_IDENTITY`, `TEAM_ID` and
  two provisioning profiles with the App Group capability. See README.
- The root `make check` is unchanged in scope apart from the shared Parakeet
  changes. CI (`macos-15`) does not yet run iOS checks. Enabling that is a
  workflow change and needs approval.

## Verification plan

- **Unit tests** (host): every rule in this contract that is pure.
- **Simulator smoke**: the model loads and transcribes synthetic speech.
- **Simulator end-to-end**, run by Sol through computer use or manually,
  using the synthetic mic:
  - enable the keyboard and grant Full Access
  - first-run onboarding
  - bounce and adoption
  - dictation into "Try it" field A, then switch to field B mid-request: the
    result must not auto-insert into B, and the chip appears
  - cancel
  - host terminated during recording: on relaunch the request is reported
    interrupted and never restarts
  - idle expiry
- **Device, manual, required before merge**:
  - bounce on iOS 26 and 27
  - background capture keep-alive
  - lock during a session
  - phone-call interruption
  - Bluetooth route change
  - background transcription latency and memory, Neural Engine against CPU
  - jetsam behavior
  - result cleanup after a forced kill
