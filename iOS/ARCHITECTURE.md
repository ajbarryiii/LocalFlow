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

## Decisions recorded after Phase 1

These refine the sections above and take precedence where they differ.

- **Binding.** A keyboard binds R to the current field while it displays R as
  recording or transcribing. It does not bind at completion. After a focus
  change invalidates a binding, only an explicit `finish` rebinds it
  (`KeyboardResultLedger`).
- **Watchdog.** `HostWatchdog.stopReason` takes `lastForegroundAt`, so a
  bounce longer than 15 s is not cancelled at swipe-back, before the keyboard
  has rewritten its presence.
- **Known requests.** Run recovery marks a previous run's terminal requests as
  known too. The controller adds every **rejected** ID to `knownRequestIDs`.
- **Rejecting during another dictation.** When reconciliation yields
  `reject(R, …)` while another request S is starting, recording or
  transcribing, the host does not publish R in the single `dictation` slot,
  because that would hide S. It only marks R as known. The keyboard's intent
  then names R, which no longer matches the status, so it falls back to
  `ready`.
- **Foreground flag.** The controller passes `isForeground = true` whenever
  the scene is active, including the activation that follows a URL open.
- **Status rate.** While a dictation is starting or recording, the host
  publishes status at about 10 Hz for the level meter. Otherwise it publishes
  at the 1 Hz heartbeat.
- **File protection.** Class A (`.complete`) applies on devices only. The
  simulator and the macOS test host use class C, because macOS refuses class
  A to unentitled processes.
- **Model preparation.** The simulator runs the encoder on the CPU and
  prepares it on **every** cold launch: about 72 s, with a peak footprint of
  about 835 MB and about 1.1 s to transcribe 2.4 s of speech. Onboarding and
  the bounce screen must show preparation progress and must not promise
  "one-time". Whether Core ML caches Neural Engine specialization across
  launches on a device is part of the device plan.
- **Build.**
  - The iOS build adds `-Xcc -DACCELERATE_NEW_LAPACK`, because the iOS 26 SDK
    deprecates the CBLAS interface used by the shared decoder.
  - `make PLATFORM=device binaries` compiles and links without signing.
  - Self-test options:
    - `LOCALFLOW_SELFTEST_AUDIO` (`SMOKE_AUDIO`)
    - `LOCALFLOW_SELFTEST_EXPECTED`
    - `LOCALFLOW_SELFTEST_COMPUTE=cpuOnly` (`SMOKE_COMPUTE`)

    The result line reports pass or fail, timings, App Group state, compute
    units and peak footprint. It never includes the transcript.
- **Keyboard ASCII.** `IsASCIICapable` is NO, because the vocabulary emits
  non-ASCII tokens.
- **Diagnostics.** The app has a Diagnostics section that serves device
  experiments:
  - a compute-policy picker: Automatic (Neural Engine with a CPU retry in the
    background), Neural Engine only, or CPU only
  - content-free measurements of the last dictation, held in memory only:
    audio seconds, preparation and transcription milliseconds, compute units
    used, foreground or background, and the process footprint
- **Claim by rename, not delete.** On APFS, concurrent `unlink` calls on one
  file can each report success: two or three winners per round, measured on
  the Mac across both threads and processes. Every result removal therefore
  first renames the file to a unique private name, and only the caller whose
  rename succeeded deletes it. This covers the keyboard's claim,
  `deleteResult`, and every host purge. Measured: exactly one winner per round.
- **Staged writes.** Writes go to a `.staging-<UUID>.tmp` file in the same
  directory, carrying the destination's protection class, and are then renamed
  over the destination. The expiry purge also sweeps staging files older than
  `resultTTL`. Run recovery calls `purgeStagingFiles(olderThan: 0, now:)`
  before writing anything.

## Cursor control and editing (keyboard; added 2026-10-09)

Typos are common in dictation, so moving to a word and fixing it has to be
fast. The goal is to match the feel of Apple's keyboard trackpad mode as
closely as a third-party keyboard can.

### Platform limits (verify on device)

- A keyboard can move the cursor only with
  `textDocumentProxy.adjustTextPosition(byCharacterOffset:)`. It cannot
  select text, it cannot read the host field's layout, font or width, and it
  sees only the context the proxy exposes. That context is
  `documentContextBeforeInput` / `AfterInput`, typically a paragraph or a few
  hundred characters, and it updates asynchronously after each adjustment.
- So **horizontal** movement is exact, measured in grapheme clusters, with
  offsets in the units `adjustTextPosition` uses. **Vertical** movement is
  emulated:
  - The keyboard lays out its context snapshot with TextKit, using the
    system body font at an estimated container width (the keyboard's width
    minus typical field insets).
  - It keeps the cursor's x position (the column, in points) while moving
    between visual lines.
  - Hard line breaks are exact; soft wraps are an estimate. Fields with a
    custom font or width will drift by a few characters.

### Trackpad mode

- **Activation**: as on Apple's keyboard, touch and hold the space bar. The
  hold threshold matches Apple's, with the value measured or researched and
  recorded here. The pad dims its other controls, plays a light haptic (with
  Full Access and the haptics setting), and the whole keyboard surface
  becomes a trackpad until the finger lifts. A drag that starts on the space
  bar and passes a small slop distance after the hold also activates it.
- **Motion model** (`KeyboardCore/CursorMotion`; pure, tested):
  - The finger delta (points) is multiplied by an acceleration gain that
    depends on finger speed. The gain is 1 below a low-speed threshold and
    rises smoothly to a capped maximum at high speed. The curve's shape and
    constants approximate Apple's trackpad mode; how they were derived is
    documented next to the code.
  - Horizontal: the accelerated delta is consumed by the advances of the
    actual characters being crossed, measured in the body font. Crossing
    "mmm" takes more travel than "iii", as in Apple's position-based
    tracking. A fallback average advance applies when no context is visible.
  - Vertical: the accelerated delta crosses one visual line per body-font
    line height. The column is preserved.
  - Residuals carry over between touch events so slow drags stay precise.
    No step overshoots the context snapshot, so the snapshot refreshes when
    the proxy catches up.
- **Snapshot handling** (`KeyboardCore/TextNavigator`; pure, tested):
  - At gesture start, take `before + after` plus the cursor index, then move
    a virtual cursor inside that snapshot.
  - Issue `adjustTextPosition` with grapheme-safe deltas, coalesced to at
    most one call per display frame.
  - Re-snapshot when the virtual cursor nears a snapshot edge and the proxy
    has caught up.
  - Never split a grapheme cluster (emoji, combining marks). Handle UTF-16
    and grapheme counts explicitly.
- **Tuning**: the sensitivity and acceleration multipliers are in
  `LocalFlowSettings`. The app's Diagnostics screen exposes them for device
  side-by-side comparison with Apple's keyboard. "Try it" includes a
  multi-line field with invented sample text for vertical tests.

### Word editing

- Delete key behaves like Apple's. A tap deletes one character. Holding
  repeats with acceleration, and after a threshold (Apple's behavior,
  documented in code) the key deletes whole words, using the context before
  the cursor.
- Word boundaries use the same rules as `TextNavigator`
  (`KeyboardCore/WordBoundaries`; pure, tested).

### Privacy update (supersedes invariant 5)

The keyboard reads `documentContextBeforeInput`, `documentContextAfterInput`
and `documentIdentifier` in memory only. It uses them for spacing, result
binding, cursor movement and word deletion. They are never stored, logged or
transmitted, and are dropped when the gesture or operation ends.

### Typing keys (user decision 2026-10-09)

The keyboard gets a basic QWERTY layer, so a typo can be fixed in place right
after moving the cursor. Dictation stays primary.

- **Layout:**
  - A dictation bar on top: status line, mic/stop capsule with the level
    meter, cancel, and the "Insert last dictation" chip.
  - An Apple-like key area below:
    - three letter rows with shift and delete
    - a bottom row of `123`, globe (only when `needsInputModeSwitchKey`),
      space and return
    - a `123` layer and a `#+=` layer
  - Total height is about the system keyboard's height plus the dictation
    bar.
- **Behavior:**
  - Shift: one tap for a single shifted letter; double-tap for caps lock.
  - Auto-capitalization at the start of a sentence, honoring the proxy's
    `autocapitalizationType`.
  - Double-space inserts ". ", as on Apple's keyboard.
  - Key callouts on press.
  - No autocorrect, predictions or learned words.
- **Touch handling:** the key area is one UIKit touch-tracking view with
  nearest-key hit testing (no dead gaps). It highlights on touch-down and
  inserts on touch-up, which keeps typing latency low in the extension. The
  same view runs trackpad mode: touch and hold the space bar, and the letters
  blank out, as on Apple's keyboard.

## Host decisions after the host review (2026-10-09)

- **What counts as foreground.** "Foreground" means the application state is
  not `.background`, so `.inactive` counts, per UIKit. A URL open is only a
  hint: it never forces foreground. Admission waits for actual foreground
  arrival, which re-reads the intent and reconciles; freshness is checked at
  that moment. A prewarmed launch that has never been in the foreground skips
  reconciliation until it first arrives there.
- **Audio boundary.** Each dictation's samples carry a recording token, and
  appends must match it **under the buffer lock**. The tap does no conversion
  while idle. The sample-rate converter is reset or replaced at every begin,
  finish and cancel, so no audio-derived state crosses a dictation boundary.
- **Capture liveness.** A recording ends with `.audioSessionFailed` after
  sustained input starvation or repeated conversion failures, or the startup
  timeout applies if no first buffer ever arrives. The maximum duration is
  enforced by elapsed time as well as by sample count.
- **Engine recovery.** While the audio session is still active (not
  interrupted), an engine configuration change or a stopped engine may be
  restarted **in the background too**. Background starts of a new session
  stay forbidden. All failure notifications go through the same 0.5 s grace,
  and queued engine notifications are fenced by engine generation. The
  session ends only if the restart fails.
- **Audio session options.** `.playAndRecord` with
  `[.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]`, so other apps'
  audio never moves to the earpiece.
- **Compute fallback.** Automatic uses the Neural Engine. A CPU retry happens
  only when all of these hold:
  - the OS is iOS 27 or later, where background Neural Engine access needs an
    entitlement
  - the app is in the background
  - the failure is a model or transcription failure

  Before loading the CPU runtime, the primary runtime is quiesced and
  released, so at most one runtime is alive. On iOS 26 there is no automatic
  CPU retry. The Diagnostics "Neural Engine only" and "CPU only" policies
  remain for experiments.
- **Cancellation.** Waiting for model readiness is cancellation-aware. A
  cancelled, superseded, locked or expired request releases its samples
  immediately and never starts fallback work.
- **Memory warnings.** A warning that arrives during preparation is
  remembered, and the runtime is released once it becomes idle.
- **Synthetic input fails closed.** In self-test builds, a requested but
  unusable synthetic microphone fails the session and never constructs real
  capture.
- **Persistence exception.** The app's own UserDefaults stores the last
  model-preparation duration (content-free), to show an estimate. Nothing
  else about dictations is persisted by the host.
- **Keyboard-connected indicator.** It uses presence freshness
  (`keyboardPresenceTimeout`), not the file's mere existence.

## Device measurements (iPhone 15 Pro, iOS 26.6.2, 2026-10-09)

Self-test with invented synthetic speech (2.42 s):

| Compute | Preparation | Transcription | Peak footprint |
| --- | --- | --- | --- |
| Neural Engine, first launch after install | 67.2 s | 0.049 s | 165 MB |
| Neural Engine, later launch | 0.69 s | 0.040 s | 166 MB |
| CPU only | 60.7 s | 0.519 s | 3229 MB |

- Neural Engine specialization is cached across launches of one install, so
  the cold cost is paid once per install. Onboarding must still show it.
- **There is no automatic CPU fallback.** It peaks at about 3.2 GB and would
  be jetsammed in the background. "Automatic" means Neural Engine only. A
  background failure on iOS 27 or later, which likely means the missing
  inference entitlement, fails the request and shows a content-free hint in
  Diagnostics. The "CPU only" policy stays in Diagnostics for foreground
  experiments only. This supersedes "Compute fallback" above.
- **Battery.** An idle session keeps the audio hardware and the app awake, so
  idle cost is kept to a minimum:
  - request a large I/O buffer (about 0.1–0.2 s) and 16 kHz mono input
  - do no conversion or allocation in the idle tap
  - keep the 5-minute default timeout

  The device plan includes battery drain over 30 minutes, comparing an idle
  session against no session, and against Wispr Flow if it is installed.

### Layout and undo (user feedback 2026-10-09; the user dictated it with the prototype)

- **Compact key row** (dictation pad, and any non-QWERTY row): delete is the
  wide key and return is the compact key at the right edge. The QWERTY area
  follows Apple's layout.
- **Undo last dictation.** After an insertion, auto or manual, the dictation
  bar shows **Undo**, which removes exactly what was inserted, including a
  trailing `"\n"` from "press enter". It is offered only while all of the
  following hold:
  - the `documentIdentifier` is unchanged
  - `documentContextBeforeInput` still ends with the inserted text
  - no other edit or cursor movement happened since: no typing, trackpad
    movement or another insertion
  - fewer than 30 s have passed

  Removal uses `deleteBackward()` once per inserted grapheme. The inserted
  text is held in instance memory only during that window, then dropped
  (`KeyboardCore/UndoTracker`; pure, tested).
- **No compute-policy picker (after the second host review).** The live app
  always uses the Neural Engine. CPU-only remains measurable through the
  self-test (`SMOKE_COMPUTE=cpuOnly` / `LOCALFLOW_SELFTEST_COMPUTE`).
  Removing runtime policy switching removes its races: a preparation deadlock,
  a revived retired runtime, and CPU inference after backgrounding.
  Diagnostics shows the compute units in use as read-only information.
- **Boundaries use capture time.** Each tap buffer carries its `AVAudioTime`
  host time. Frames captured before a recording's begin boundary, or after
  its finish boundary, are trimmed before conversion, so idle audio never
  enters a dictation even with 0.2 s buffers. Converter cleanup at
  finish/cancel happens immediately, serialized with conversion. It never
  waits for the next callback.
- **Media services reset ends the session.** This follows Apple's guidance:
  audio-session state is invalid, so resuming requires a new foreground
  start. Background engine restarts remain only for configuration changes
  within a surviving session.
- **Undo ownership (after the keyboard-round review).** A suffix match alone
  never authorizes deletion.
  - **Invalidation.** Undo is permanently invalidated by any
    `selectionDidChange` or `textDidChange` callback that our own pending
    operation did not cause (an edit-generation token), by any typing, delete
    (including each repeat), trackpad movement or insertion, by a focus
    change, and by hiding the keyboard.
  - **Execution.** Undo deletes progressively. It deletes only the portion of
    the inserted text that the current context proves, then waits for the
    context to update. It re-verifies that the remaining inserted prefix is
    now the context's suffix, and repeats. It stops at the first mismatch or
    timeout. It is never offered when the context shows none of the
    insertion.
  - **Lifetime.** The inserted text and any typing-context tail are cleared
    when the keyboard hides or the 30 s window ends, whichever comes first.
- **Trackpad safety.** Every adjustment re-validates the document identifier
  and edit generation, and a stale session terminates. System cancellation
  rolls back an outstanding one-unit probe before ending. Unit learning needs
  fresh, discriminating evidence; ambiguous probes are not cached. Unchanged
  context is ambiguous, never a document boundary, so further movement needs
  new finger travel. The unit cache holds only the current field.

### Top row (user decision 2026-10-09, modeled on Wispr Flow's keyboard)

- **Right:** a prominent capsule button labeled "Start" with a waveform glyph
  (`lf.mic`). This is the primary dictation control.
  - While starting or recording, it becomes a red "Stop" capsule with live
    level bars and elapsed time, with a small ✕ cancel beside it (`lf.cancel`).
  - While transcribing, it shows a spinner.
  - When the host is unavailable, it still reads "Start" and bounces.
- **Left:** a menu button (`lf.menu`) opens a compact panel over the key area.
  It contains:
  - session status (idle time left, or no session)
  - "Open LocalFlow", the same launcher as the bounce
  - a one-line trackpad tip

  Tapping outside the panel or the button again closes it.
- **Middle:** contextual chips for Undo (`lf.undo`) and "Insert last
  dictation" (`lf.insertLast`), with a one-line status ("Preparing model…",
  errors, banners) when no chip is shown.
- **Space bar label:** "LocalFlow".
- This supersedes the earlier dictation-bar layout. The key area is
  unchanged (Apple's layout).

### Measured Apple keyboard behavior (simulator, iOS 26.4, XCUITest, 2026-10-09)

The values below come from velocity-controlled XCUITest drags against Apple's
keyboard, with the floating cursor logged through UITextInput. They replace
the researched defaults in `TrackpadParameters` and `DeleteRepeatParameters`.
The harness lives outside the repository
(`/Users/ajbarry/localflow-ios/cursor-calibration/`).

- **Activation:** trackpad mode begins **0.381 s** after touch-down on space
  (±0.002, n=85). Movement up to **16 pt** in either axis before then is
  tolerated; 18 pt or more cancels.
- **Gain** depends on the **2D finger step per delivered touch event**,
  s = |Δ| in points. One gain applies to both axes, the same for both
  directions, and is independent of the time between events:

  ```
  g(s) = 1 + 0.04·s²                 for s ≤ 2
       = 1.16 + 0.16·(s − 2)         for 2 < s ≤ 5.92
       = 1.787·(s / 5.92)^0.389      for s > 5.92
  ```

  The maximum absolute residual is 0.034. The cursor moves `g(s)·Δ` per
  event.
- **Snapping:** on lift, horizontal motion snaps to the nearest character
  boundary. Vertical motion snaps to the line whose center is nearest the
  floating cursor's y (252 of 256 trials), keeping the column in points.
- **Delete key:**
  - The first deletion happens at touch-down.
  - The first repeat follows **0.50 s** later; after that, characters repeat
    every **0.10 s**.
  - After **21 characters** (about **2.52 s**), it switches to word mode,
    deleting **2 words every 0.354 s**.
- **Open question, settled only by the device sweep:** the simulator delivers
  60 events/s. A 120 Hz device may deliver smaller steps per event. If
  Apple's device curve is per event, as it is in the simulator, our keyboard
  matches automatically by applying `g` per delivered event.
  `TrackpadParameters.eventStepScale` (default 1.0) is the correction knob if
  the device shows otherwise.
- **Trackpad model (supersedes "Motion model").** Apple's trackpad is a 2D
  floating cursor. A virtual point in the emulated text layout starts exactly
  at the caret (relative mapping). Each delivered touch event moves it by
  `g(|d|)·d`, using one gain for both axes. The caret is the character
  boundary nearest the point, on the line whose center is nearest the point.
  - Pushing past a line's start or end keeps the caret at that end of the
    line: there is no wrapping. Only vertical motion changes lines.
  - On the first and last lines, the caret stays on the line and keeps its
    column.
  - The point is clamped to [1.5, width − 1.5] × [first line center − 7, last
    line center + 8]. Overshoot is not remembered.
  - There is no dead zone, hysteresis or momentum.
  - Only the 0.381 s timer starts trackpad mode; movement before it is
    discarded.
  - The first deletion happens 0.087 s after touch-down, or at lift if that
    comes sooner.

  Full report: `/home/aj/.cache/localflow-ios/calibration/REPORT.md`, outside
  the repository.
- **Proxy context, as measured in the simulator (UIKit hosts).**
  - **Spans line breaks:** the before-context reaches across line breaks, a
    sentence or two back, and often starts mid-line. Only the after-context
    stops at a line break.
  - **Provisional context:** right after an `adjustTextPosition`, the proxy
    first reports a provisional context: its last-reported text, with the
    caret clamped to that text. The host's own context arrives with
    `textDidChange` about 10 ms later. The trackpad trusts a probe or crossing
    only once every adjustment has been answered by `textDidChange`, or after
    a 0.3 s timeout. A caret shown exactly at the snapshot's edge is never
    taken as a line crossing.
  - Whether devices behave the same is part of the device plan.
- **Device calibration (iPhone 15 Pro, iOS 26.6.2) confirms the per-event law
  and curve.** Device values supersede the simulator's:
  - Activation is **0.40 s** after touch-down; slop stays 16 pt.
  - The first deletion comes **0.12 s** after touch-down.
  - The left clamp is x = 1.0.
  - There is no axis lock.

  The keyboard normalizes each touch step to a 60 Hz event: `eventStepScale`
  is `(1/60 s) / median touch interval`, measured from the extension's own
  touches. Apple's behavior in 120 Hz (ProMotion) host apps is still
  unmeasured; a test variant is ready.
- **Undo ownership v2 (after the third keyboard review; supersedes v1).**
  Ownership is proven by anchors, never by timing.
  - **Anchors:** at insertion, the keyboard records a before-anchor (up to
    24 characters of `documentContextBeforeInput`) and an after-anchor (up to
    24 characters of `documentContextAfterInput`).
  - **When Undo is offered:**
    - The current after-context must start with the after-anchor, as far as
      both are visible.
    - The current before-context must end with before-anchor + insertion. If
      the context is truncated, its visible part must instead be a suffix of
      the insertion at least 16 characters long, and deletion then proceeds
      progressively, re-verifying continuity each step.
    - Insertions shorter than 16 characters, such as a lone `"\n"`, need the
      full before-anchor + insertion and the after-anchor to match. With an
      empty document, they need the exact whole context.
  - **Callback attribution:** a callback counts as ours only if it matches
    the expected outcome of a specific pending operation we issued (a
    consumable expectation). Anything else invalidates Undo permanently.
    There are no time windows.
  - **No proof, no Undo.** When ownership cannot be proven, Undo is not
    offered. A host that edits text without sending callbacks remains a
    documented residual risk, mitigated by the anchors.
- **Queued edits are bound to a field.** Each queued edit carries its field
  identity and edit generation. An aborted trackpad session discards its
  queue, and only a successful completion flushes it. A nil
  `documentIdentifier` never matches anything.
- **Probes only where units can differ.** Moves that cross only
  single-code-point BMP characters need no unit probe, because UTF-16 and
  grapheme counts agree there. Probes happen only when crossing clusters, and
  always finish or roll back to a real cluster boundary.
- **Microphone choice (user request 2026-10-09).** The setting "Use iPhone
  microphone" is on by default and stored in the app's own UserDefaults; it
  is not shared with the keyboard.
  - **When on:** the session uses `.playAndRecord` with
    `[.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]` and **no**
    `.allowBluetoothHFP`. Bluetooth headphones therefore stay in A2DP
    playback, with no hands-free switch, its lower quality or its added
    latency. `setPreferredInput` picks the `.builtInMic` port and re-asserts
    it on every route change, which also overrides a wired or USB headset
    microphone.
  - **When off:** the previous behavior, `.allowBluetoothHFP` with the
    system-chosen input.
  - A change applies at the next session start, or immediately when it is
    made in the foreground during a session, by reconfiguring and restarting
    the engine.
  - The selection logic is pure in HostCore and tested. Home shows the input
    port type in use (content-free: iPhone microphone, Bluetooth, headset,
    USB).
- **Field width profiles (user decision 2026-10-09).** The trackpad's
  emulated layout uses one of two per-device profiles.
  - **Messages** is the default and is optimized for. It reproduces the
    compose bubble's measured wrap width and insets, expressed as screen
    width minus fixed chrome so it carries across iPhone sizes.
  - **Full width** applies to Notes, Mail, T3 Code-style inputs and similar
    fields.
  - **Selecting a profile:** a content-free trait fingerprint of the field
    picks the profile. The fingerprint uses the keyboard type, return-key
    type, autocapitalization, autocorrection, smart-text settings, text
    content type, and the unit mode the trackpad learned.
  - **Fallback:** when Messages cannot be told apart from full-width fields,
    the Messages profile is used everywhere.
  - **Measurement:** Messages geometry is measured with XCUITest across
    simulator sizes, and on the user's device only with their consent, using
    an unsent draft that is cleared afterwards. The fingerprints come from a
    debug readout in the keyboard menu.
  - **Later:** learning a width correction from the user's sideways nudges
    may come as a third layer.
  - **Update (user, 2026-10-09):** the full-width profile is the current
    tuning, unchanged; it already works well in T3 Code. Only Messages gets a
    new measured profile. If the trait fingerprints cannot distinguish
    Messages from full-width fields, the default is decided with the user
    once the data is in. It is not automatically Messages.
- **Keyboard round 4 notes.**
  - **One callback per adjustment:** each `adjustTextPosition`,
    `insertText` and `deleteBackward` is expected to produce one callback.
    Hosts may coalesce them, and attribution accepts that only when the
    callback matches the expected outcome.
  - **Hiding unbinds fields:** a request bound to a field before the
    keyboard hides is no longer auto-inserted after it reappears. Its result
    is offered as "Insert last dictation".
  - **Tests match measurement:** `FakeTextHost` models the measured UIKit
    context: two sentences back across line breaks, and forward to the end of
    the sentence or line.
- **Field profile parameters (measured, iOS 26.4 simulators).**
  - **Messages profile:** wrap width = keyboard width − (2·m + 117.33), with
    m = 16 below 414 pt and 20 otherwise. That is 243.7 pt on a 393 pt
    iPhone 15 Pro. It uses the Dynamic Type body font, TextKit 1 and
    line-fragment padding 0.
  - **Full-width profile:** the current chrome of 40 total on 16 pt-margin
    phones, and 48 on 20 pt-margin phones.
  - **Line pitch in both profiles** is the layout's real line advance,
    lineHeight + leading (24.00 pt at the default size), not
    `font.lineHeight`. The 22.29 pt used before made every vertical step
    7.7 % short.
- **Field fingerprints (simulator, iOS 26.4).**
  - **Contents:** a fingerprint holds the public `UITextInputTraits` raw
    values plus the trackpad's learned unit mode. Keyboard appearance is
    excluded, because it flips with system appearance and focus.
  - **Messages signature:** the compose field turns smart quotes and smart
    dashes off (raw 1) while autocorrection and spell checking stay at their
    defaults (0), with no content type. None of the fields sampled matches it:
    - default UITextView and UITextField
    - the Messages "To:" field
    - Safari and WKWebView textareas
    - the address bar, search fields, and the number pad
  - **WebKit fields:** a field whose learned unit is grapheme (WebKit) is
    never treated as Messages.
  - **Default:** full width.
  - **Manual override:** the keyboard menu shows the active layout and a
    Switch. The choice is stored per fingerprint hash in App Group
    UserDefaults (at most 64 entries, content-free). Lookup tries the key
    with the learned unit first, then the key with traits alone.
  - **Risk:** apps that also disable smart punctuation, such as code-oriented
    inputs, may be detected as Messages. The override fixes that in one tap.
- **Keyboard round 6 notes (host behavior measured in the simulator).**
  - **WebKit double-reports moves:** WebKit reports every caret move twice,
    first with the pre-move text and then where the caret landed. The first
    report is accepted once per move and confirms nothing. Whether a field
    double-reports is learned and cached per field, like the unit.
  - **UIKit reports moves as text changes:** UIKit sends no callback for the
    keyboard's own inserts and reports host caret moves as `textDidChange`.
    The allowance for a callback caused by our own insert or delete therefore
    expires after 0.3 s. This only makes Undo stricter. A selection callback
    counts as ours only for a still-pending trackpad adjustment.
  - **Undo boundaries:** Undo requires both ends of the deletion to be
    grapheme boundaries in the current context (CRLF, combining marks).
  - **Re-checks:** queued edits drain one per frame, and auto-inserted
    results go in one per pass. Each is re-validated against the field and
    the edit generation. Held keys and deletes are bound to their press and
    field.
  - **Placeholder traits:** at first appearance the proxy reports default
    traits and no field identity. Such readings are ignored, and traits are
    re-read on every text or selection callback, on menu open, and at each
    gesture start. The layout is fixed per gesture.
  - **Measured widths:** the Messages layout is chosen automatically only in
    portrait at measured widths of 390, 393, 402, 420 and 440 pt (±1). A
    manual choice applies everywhere.
- **Typing correctness is paramount (after the round-6 review).** A typed
  key (character, shift, space, return, delete) is never dropped, reordered
  or re-cased because of trackpad bookkeeping.
  - **Pending settlement:** if trackpad settlement or verification is pending
    when a key is pressed, the settlement resolves immediately. It accepts the
    current caret, repairing a split cluster if one is known, and the key then
    executes in press order. Queuing typed keys behind settlement is avoided.
    Where some ordering is unavoidable, each key's resolved text and modifier
    state are captured at press time.
  - **Field binding:** every key is bound to the field identity at press
    time and validated at release, so a key never lands in a different field.
  - **Own edits:** callbacks from our own inserts and deletes are never
    treated as outside changes that discard typing.
  - **Undo fails closed:** any callback whose provenance is ambiguous
    invalidates Undo. UIKit inserts and deletes owe no callback, so no
    allowance is created for them.
- **Keyboard round 7 notes.**
  - **New core files:** the typing path is now in `KeyboardCore/KeyboardEditor`
    and `KeyboardCore/TrackpadController`, both Foundation-only and tested
    through the real press path. `KeyboardInput` and `TrackpadDriver` are thin
    UIKit wrappers.
  - **When keys wait:** a key press settles the trackpad at once. Keys wait
    (at most 0.3 s) only for an outstanding probe, an edge jump, a previous
    gesture's owed reports, or a split-cluster repair. A waiting key keeps the
    text and shift state captured at press. After a Return, the remaining
    waiting keys run on the next frame.
  - **Own edits:** reports of our own edits are recognised from the context
    fingerprint each edit leaves (at most one per edit, within 1 s) and are
    checked before trackpad expectations.
  - **Measured in the simulator:** neither UIKit nor WKWebView reports the
    keyboard's own inserts and deletes.
  - **Report ordering:** reports are attributed oldest-first. A pre-move
    report is accepted only for the oldest owed adjustment. Expectations
    expire after 0.3 s, and an unresolved pre-move report ends the session as
    ambiguous. A new gesture waits for the previous gesture's owed reports.
  - **Field binding and context:** each key is bound to the field it touched
    down in. Cancel and hide release the layout's laid-out text.
  - **Torture test:** `typingTorture` interleaves random typing with
    gestures, probes, lag and WebKit double reports. It asserts the document
    equals the keys applied in press order and that every completed gesture
    ends on a character boundary.
- **Keyboard round 8 notes and residual risks.**
  - **Key waits:** keys wait (one deadline, 0.4 s from the earliest waiting
    key) for an identity, the Return barrier, a probe, a jump past the
    visible text, or a cluster repair. A probe or jump that a key waits on is
    resolved by its report, not by timeout.
  - **Snapshots:** the snapshot is never retaken from a view that does not
    show where the caret was put. Hosts that report each move twice are owed
    both reports.
  - **Shift:** shift is re-checked every frame for 0.5 s after each edit.
  - **Residual risks:**
    - Host reports later than 0.3 s are outside the trackpad's guarantees:
      a probe resolved by timeout may learn the wrong unit, so on-device
      latency under load needs measuring.
    - Auto-capitalization assumes the visible context starts a sentence or
      line, as measured in UIKit.
    - Fields not yet known to report once are assumed to double-report, so
      for about 1 s after a gesture one outside change can be mistaken for
      ours.
    - Hiding drops keys still waiting behind the Return barrier or without
      an identity.
  - **Torture coverage:** `TypingTorture` passes seeds 1–6000, with report
    delays capped at 30 frames.
