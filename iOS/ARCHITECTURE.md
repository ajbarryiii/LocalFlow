# LocalFlow for iPhone: architecture contract

Status: prototype. This document is the contract between the iOS components.
Every statement in it describes the code as it is on `main`. The reasons,
measurements and review notes behind the rules are in
[ARCHITECTURE-HISTORY.md](ARCHITECTURE-HISTORY.md), which is a record, not a
contract.

## Changing this document

- A pull request that changes a rule edits the section that states it, in the
  same pull request. It does not append a dated note that supersedes an
  earlier statement.
- A rule is stated once. Other sections refer to it by name.
- Reasons, measurements and residual risks go in the pull request.
  ARCHITECTURE-HISTORY.md is not extended.
- Code comments cite sections by name. When a section is renamed, add the old
  name to the table below.

| Name cited in code comments | Where the rule is now |
| --- | --- |
| "Typing model v2", "Typing model v2: immediate execution" | [Typing model](#typing-model); late gesture reports and echoes in [Editing core](#editing-core-editingcore); a key ending the gesture and the accepted residual in [Trackpad and keys](#trackpad-and-keys) |
| "Typing model v3" | [Typing model](#typing-model) |
| "Typing model v4 and swipe typing" | key timing in [Typing model](#typing-model); the swipe gesture, the decoding pipeline (its steps 1–5), insertion, the candidate strip and the trace in [Swipe typing](#swipe-typing) |
| "Inserting a swiped word", "Candidate strip", "Swipe trace", "decoding pipeline", "Space before a tapped word" | [Swipe typing](#swipe-typing) |
| "Owned words", "Taps", "Spelling channel", "Never correct" (sub-rules of "Word autocorrect") | [Word autocorrect](#word-autocorrect) |
| "Dropped taps: reach, skids and counters", "Dropped taps" | the reach and the bar's regions in [Reach and touch regions](#reach-and-touch-regions); skids in [Swipe typing](#swipe-typing) |
| "Reach above the keys", "A stricter space bar", "A wider delete key" | [Reach and touch regions](#reach-and-touch-regions) |
| "Undo ownership v2", "Undo last dictation" | [Undo last dictation](#undo-last-dictation); attribution in [Editing core](#editing-core-editingcore) |
| "Trackpad safety", "Probes only where units can differ" | [Trackpad: units, probes and attribution](#trackpad-units-probes-and-attribution) and [Trackpad and keys](#trackpad-and-keys) |
| "Measured Apple keyboard behavior" | [Trackpad: activation and motion](#trackpad-activation-and-motion) and [Delete key](#delete-key) |
| "Field width profiles", "Field profile parameters", "Field geometry" | [Field profiles](#field-profiles) |
| "Top row", "Insert last dictation" | [Top row](#top-row) |
| "Touchable backgrounds" | [Keyboard extension](#keyboard-extension-keyboard) |
| "Device lock", "Locked means no dictation" | [Device lock](#device-lock) |
| "No compute-policy picker" | [Transcription](#transcription) |
| "Microphone choice", "Media services reset ends the session" | [Capture](#capture) |
| "Custom dictionary", "Find strength" | [Custom dictionary](#custom-dictionary) |
| "App Store packaging" | [App Store packaging](#app-store-packaging) |

## Goal

A Wispr Flow–style iPhone experience that is fully local: a custom keyboard
with a dictation button, backed by the same bundled Parakeet model the macOS
app uses. Audio, transcripts and model inference stay on the device. There is
no network code, telemetry, analytics or logging.

Custom keyboards do not appear everywhere. iOS substitutes the system keyboard
in secure text fields and phone-pad fields, and apps can reject custom
keyboards entirely. Those fields are out of scope.

## Platform constraints

1. **Keyboard extensions cannot use the microphone** and have a small memory
   limit (tens of MB). The model (about 330 MB compiled encoder) and audio
   capture live in the containing app.
2. **An app cannot start recording from the background.** It can keep
   recording in the background if the audio session was activated in the
   foreground and the `audio` background mode is declared.
3. **Extensions have no supported API to open their containing app.** The
   keyboard "bounces" to the app by walking the responder chain
   (`HostAppLauncher`). This is experimental; the supported baseline is the
   user starting a session in the app.
4. **iOS gives apps no API to switch back to the previous app.** The user
   returns with the system "◀ App" control or the home-indicator swipe.
5. **The GPU is unavailable in the background.** On iOS 27, background Neural
   Engine access requires the
   `com.apple.developer.background-tasks.continued-processing.inference`
   entitlement, which LocalFlow does not have.
6. The encoder targets the `ios19` Core ML opset, so the deployment target is
   **iOS 26.0**.

These lead to the "Flow session" design:

- A session starts **only in the foreground and unlocked**, in one of two
  ways: the user taps "Start session" in the app, or the app arrives in the
  foreground (by the bounce or by the user) while a fresh `record` intent
  from the keyboard is waiting. The host then admits that request and starts
  recording at once, and the user swipes back.
- While the session is active, the app keeps one `AVAudioEngine` input
  running, in the background too, so later dictations start with no app
  switch. **Between dictations, captured buffers are dropped in the tap
  callback, unconverted, and never retained.**
- iOS shows its microphone indicator for the whole session, and the app
  explains this on Home.
- The session ends on idle expiry, an audio interruption (for example a
  call), a media-services reset, a capture failure it cannot recover from, or
  the user tapping "End session". The engine stops and the audio session
  deactivates. A device lock does not end it ([Device lock](#device-lock)).

## Components

```
iOS/
  ARCHITECTURE.md          this contract
  ARCHITECTURE-HISTORY.md  the decision log this contract replaced (record only)
  README.md                build, run, simulator, device and manual-test instructions
  Makefile                 swiftc + make build (no Xcode project, no SwiftPM)
  Shared/                  protocol, store and settings: app, keyboard and tests
  HostCore/                host logic: app and tests
  KeyboardCore/            keyboard logic: keyboard and tests
  App/                     containing app (SwiftUI, AVFoundation, Core ML, UIKit lifecycle)
  Keyboard/                keyboard extension (UIKit key area, SwiftUI top row, Core ML swipe encoder)
  Tests/                   dependency-free executable tests run on the macOS host
  Config/                  Info.plist, entitlements and privacy manifest templates
  scripts/                 build helpers and the App Store bundle checker
```

- `Shared/`, `HostCore/` and `KeyboardCore/` import only Foundation, plus
  CoreFoundation for Darwin notifications in `Shared/` and Accelerate for the
  tap and word models in `KeyboardCore/`, so they compile for the macOS test
  runner. UIKit, SwiftUI, AVFoundation and Core ML belong in
  `App/` and `Keyboard/`.
- The app is compiled from `App/`, `Shared/`, `HostCore/` and these macOS
  sources:
  - `Sources/Parakeet/*.swift`: the model runtime (`LocalParakeetService`).
  - `Sources/Dictionary/*.swift`: the custom dictionary
    ([Custom dictionary](#custom-dictionary)).
  - `Sources/LocalDictationCore.swift` and
    `Sources/SpokenNumberFormatter.swift`: "press enter", spoken delimiters
    and spoken numbers.
- The keyboard is compiled from `Keyboard/`, `Shared/` and `KeyboardCore/`
  only. It never links Parakeet, the dictionary, `LocalDictationCore` or
  `HostCore`, and it never captures audio.

## Identifiers

The Makefile injects these into both Info.plists:

| Variable | Default (`CHANNEL=dev`) | `CHANNEL=appstore` |
| --- | --- | --- |
| `BUNDLE_ID` | `com.ajbarryiii.localflow.ios.dev` | `com.ajbarryiii.localflow.ios` |
| keyboard bundle ID | `$(BUNDLE_ID).keyboard` | `$(BUNDLE_ID).keyboard` |
| `APP_GROUP` | `group.$(BUNDLE_ID)` | `group.$(BUNDLE_ID)` |
| `URL_SCHEME` | `localflow-dev` | `localflow` |
| `DISPLAY_NAME` | `LocalFlow Dev` | `LocalFlow` |

Both Info.plists carry `LocalFlowAppGroupIdentifier` and `LocalFlowURLScheme`.
`LocalFlowConfiguration.main` (Shared) reads them and rejects an empty value,
an unexpanded `$(VARIABLE)` and an invalid URL scheme, so no Swift file
hardcodes an identifier.

## Shared store and protocol (Shared/)

### Principles

- The keyboard and host communicate only through files in the App Group
  container plus Darwin notifications.
- **Notifications and URLs are wake-up hints only.** They carry no data and no
  authority: any process can post a Darwin notification or open the URL. All
  authority comes from files that only the app and the keyboard can write.
  Every reader also polls, so a dropped notification only adds latency. The
  keyboard reads result files on `.result`, and also when the polled status
  reports a completion it has not read for.
- The design is level-triggered: the keyboard writes the state it wants, and
  the host reconciles toward it and publishes the actual state.
- Each file has exactly one writer process.
- On iPhone only one keyboard instance is visible at a time. There are no
  per-request mailboxes; the stale-writer guard
  ([Keyboard presentation](#keyboard-presentation)) protects `finish` and
  `cancel`.

### Files

Directory: `<App Group container>/Library/Caches/LocalFlowDictation/`,
created on first write and marked `isExcludedFromBackup` (best effort).
Records are JSON (`JSONEncoder`, `.secondsSince1970` dates, sorted keys), and
each carries `schema: Int` (currently `1`).

| File | Writer | Reader | Content | Protection (device) |
| --- | --- | --- | --- | --- |
| `intent.json` | keyboard | host | `KeyboardIntent`: the latest dictation request | class A, `.complete` |
| `presence.json` | keyboard | host | `KeyboardPresence`: a visible keyboard with Full Access | class C, `.completeUntilFirstUserAuthentication` |
| `status.json` | host | keyboard | `HostStatus`: run, session, capture, model and dictation state | class C |
| `result-<UUID>.json` | host | keyboard | `DictationResult`: one finished transcript | class A |

- Class A applies on devices only. The simulator does not enforce data
  protection and macOS refuses class A to unentitled processes, so both use
  class C.
- **Staged writes.** Every write goes to a uniquely named
  `.staging-<UUID>.tmp` file in the same directory, written with the
  destination's protection class, then renamed over the destination. A reader
  sees the old or the new record, never part of one. Foundation's `.atomic`
  option is not used, because its temporary file escapes the staging sweeps.
- **Claim by rename.** Every result removal (the keyboard's claim, and every
  purge) first renames the file to a private staging name and deletes it from
  there. Only one rename of a name can succeed, so exactly one caller sees
  `.removed`. Concurrent `unlink` calls on APFS can all report success, so
  they are not used to decide a claim.
- **Staging sweeps.** `purgeExpiredResults` also deletes staging files older
  than `resultTTL`. At launch, before writing anything, the host deletes
  staging files of any age (`purgeStagingFiles(olderThan: 0, now:)`): a
  writer that died before renaming may have left a transcript in one.
- Darwin notification names are `"\(appGroupID).intent"`, `.presence` (never
  posted), `.status` and `.result`, each posted after the matching write.

### Reading records

`SharedDictationStore` returns `StoreRead<Value>`: `value`, `absent`,
`incompatible` or `unreadable`.

- `absent`: the file does not exist.
- `incompatible`: the record has an unknown `schema`. The schema is checked
  before the rest is decoded. The keyboard shows "Update LocalFlow"; the host
  ignores the record.
- `unreadable`: corrupt JSON, a file protected because the device is locked,
  an I/O error, or a result file whose `requestID` differs from its name.
  Callers treat it as absent, never crash and never log content.

### Time

Every freshness check is `DictationProtocol.isFresh`: with
`age = now - timestamp`, it requires `-clockSkewTolerance <= age <= ttl`, with
`clockSkewTolerance = 2 s`. A backward clock jump makes a record stale (fail
closed), never fresh. Every rule takes `now` as a parameter, so tests are
deterministic.

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

struct KeyboardIntent: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case record, finish, cancel }
    var schema: Int = DictationProtocol.schema
    var requestID: UUID
    var action: Action
    var keyboardInstanceID: UUID   // the UIInputViewController instance that wrote this action
    var issuedAt: Date
}

struct KeyboardPresence: Codable, Equatable, Sendable {
    var schema: Int = DictationProtocol.schema
    var keyboardInstanceID: UUID
    var seenAt: Date
}

struct HostStatus: Codable, Equatable, Sendable {
    enum Session: String, Codable, Sendable { case inactive, starting, active }
    enum Model: String, Codable, Sendable { case unavailable, notPrepared, preparing, ready, failed }
    var schema: Int = DictationProtocol.schema
    var hostRunID: UUID            // new for every host process launch
    var sessionID: UUID?
    var session: Session
    var captureReady: Bool         // engine running and an input buffer within captureFreshness
    var heartbeatAt: Date
    var sessionExpiresAt: Date?    // idle expiry; nil while a dictation is in progress
    var model: Model
    var dictation: DictationStatus?
    var level: Float = 0           // 0...1, meaningful only while recording
    var error: HostErrorCode?      // content-free, most recent session-level error
}

struct DictationStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case starting, recording, transcribing, completed, failed, cancelled }
    var requestID: UUID
    var hostRunID: UUID            // the run that admitted this request
    var phase: Phase
    var error: HostErrorCode?      // set when phase == .failed (or .cancelled by the host)
    var startedAt: Date
    var updatedAt: Date
}

enum HostErrorCode: String, Codable, Sendable {
    case microphonePermissionDenied, audioSessionFailed, startupTimeout, interrupted, deviceLocked,
         keyboardDismissed, sessionInactive, modelUnavailable, modelFailed, transcriptionFailed,
         backgroundTimeExpired, notRecording, tooLong, superseded
}

struct DictationResult: Codable, Equatable, Sendable {
    var schema: Int = DictationProtocol.schema
    var requestID: UUID
    var hostRunID: UUID
    var text: String               // already post-processed by LocalDictationCore
    var pressEnter: Bool
    var createdAt: Date
}
```

`writeStatus` clamps `level` to 0...1 and writes 0 for a non-finite level, so
a heartbeat never fails to encode.

### Host reconciliation (Shared/HostReconciler.swift; pure, tested)

`HostReconciler.action(intent:current:knownRequestIDs:isForeground:sessionActive:now:)`
returns `none`, `start(R)`, `finish(R)`, `cancel(R)` or `reject(R, code)`.

- An intent that is not a `.value` of the current schema: `none`.
- `record(R)`:
  - R is in `knownRequestIDs` or is `current` in any phase: `none`. A request
    is never restarted, even after host death.
  - The intent is not fresh within `pendingRecordTTL`: `none`.
  - Neither `sessionActive` nor `isForeground`: `reject(R, .sessionInactive)`.
  - Otherwise: `start(R)`.
- `finish(R)`:
  - `current` is R and recording: `finish(R)`.
  - `current` is R and starting: `cancel(R)`. Nothing was captured, so the
    host reports it failed with `.notRecording`.
  - `current` is R in any other phase: `none`.
  - Otherwise `reject(R, .notRecording)`, or `none` if R is known.
- `cancel(R)`: `cancel(R)` if `current` is R and starting, recording or
  transcribing; otherwise `none`. A keyboard `cancel` is reported as a plain
  cancellation.

How the host applies the actions is in [Admission](#admission).

### Keyboard presence

While visible, and only with Full Access, the keyboard rewrites
`presence.json` every `keyboardPresenceInterval`. The host's watchdog uses it
([Recording](#recording)).

### Keyboard presentation (Shared/KeyboardPresenter.swift; pure, tested)

`KeyboardPresenter.mode(access:status:intent:now:)`, with `KeyboardAccess` one
of `fullAccess`, `noFullAccess` or `containerUnavailable`. The modes, in order:

1. `needsFullAccess`: access is `noFullAccess`. The keys keep working;
   dictation does not.
2. `configurationError`: access is `containerUnavailable` (a missing
   entitlement or App Group).
3. `incompatible`: the status or the intent is `.incompatible`.
4. The host is **alive** when the status is a `.value`, `session == .active`,
   and the heartbeat is fresh within `livenessTimeout`.
5. If the host is alive and `status.dictation` is the latest intent's request
   R: starting → `starting`; recording → `recording(level:startedAt:)`;
   transcribing → `transcribing`. The intent, not the keyboard instance,
   names the request, so a new keyboard instance adopts a request another
   instance started (as after the bounce).
6. `error(code)`: `status.dictation` is R and failed, or cancelled with an
   error, and its `updatedAt` is fresh within 5 s. A missing code reads as
   `.transcriptionFailed`.
7. `starting`: the latest intent is a fresh `record(R)` and
   `status.dictation` is not R (launch during the bounce).
8. `ready`: the host is alive and `captureReady`.
9. `hostUnavailable`: everything else. A mic tap bounces.

**Stale-writer guard.** Right before writing `finish` or `cancel`, the
keyboard re-reads `intent.json` and writes only if it still names the request
the keyboard is showing (`KeyboardPresenter.mayWrite`). `record` starts a new
request and is always written.

### Results (Shared/KeyboardResults.swift, TextInsertionFormatter.swift; pure, tested)

Delivery is **at most once**, and automatic insertion is bound to the field
the request belongs to. `KeyboardResultLedger` holds, per keyboard instance
and in memory only, the bindings (request → `documentIdentifier`), the
invalidated requests and the consumed requests.

- **Binding.**
  - Writing `finish(R)` binds R to the current field, even if a focus change
    had invalidated an earlier binding (`bindFinish`).
  - An instance displaying R as recording or transcribing binds R to the
    current field, unless R is already bound, invalidated or consumed
    (`noteDisplayed`). So a host auto-finish, or another instance's finish,
    still lands in the field where the user was dictating. There is no
    binding at completion.
  - A nil `documentIdentifier` never binds and never matches.
- **Invalidation.** A different `documentIdentifier` (seen on
  `viewWillAppear`, `textDidChange` or any pass) invalidates every binding to
  another field. Hiding the keyboard invalidates every binding. Only an
  explicit `finish` rebinds an invalidated request; displaying it again does
  not.
- **Auto-insert.** A result is inserted automatically only when its schema is
  current, R is not consumed, the result is fresh within `resultTTL`, and R is
  bound to the current field. At most one result is inserted per pass, oldest
  first, and none while a trackpad gesture runs or settles: results stay in
  the shared files until then.
- **Claim before insert.** The keyboard inserts a result only if its own
  removal of `result-R.json` returned `.removed`. R is then consumed whoever
  removed the file. A failed removal leaves everything as it was for a later
  pass. A crash between the removal and the insertion loses that one
  transcript; this is accepted.
- **Manual insert.** The newest fresh, unconsumed result that cannot be
  auto-inserted (no binding, or another field) is offered as "Insert last
  dictation", unless it would insert nothing. Tapping it claims the result and
  inserts it into the current field.
- **Ordering.** The host writes `result-R.json` before it publishes R as
  `completed`. The keyboard checks for results on appearance and whenever a
  result may have arrived, whether or not a session is live.
- **Reads** (`KeyboardResultInbox`, Shared/KeyboardResultInbox.swift; pure,
  tested). Reading purges expired results, then lists and decodes every
  result file. The keyboard reads only when a read is due, and otherwise
  decides from the results it read last, so the status passes that drive the
  level meter (about 10 Hz while recording) never touch the result files. A
  read is due:
  - on the first pass after appearing (no notification is observed while
    hidden);
  - after a `.result` notification (deliveries coalesce, so a read lists every
    file);
  - when the status reports a completed request the last read did not list,
    once per request (by the ordering above, its result is on disk, so a
    missed `.result` only adds a poll's latency);
  - when the status names a host run other than the last read's (a new run
    deletes other runs' results at launch);
  - once a file the last read listed, and not yet consumed, can be purged: a
    decoded result past `resultTTL`, or `resultTTL` after the first read that
    found a file it could not decode. A file still there after the read that
    should have purged it (a failed removal) is purged again after
    `cleanupRetryInterval` (5 s);
  - every `retryInterval` (1 s) while the last read found an unreadable file;
  - when the clock is more than `clockSkewTolerance` before the last read.

  A read whose directory listing fails acknowledges nothing and keeps what was
  read before. It is retried every `retryInterval` until a listing succeeds,
  even if what triggered it no longer shows. Only a directory that does not
  exist (`stat` fails with `ENOENT`) counts as a successful listing of no
  results; any other failure, such as a parent that cannot be searched, is a
  failed listing.

  A result that is not inserted on the pass that read it (a trackpad gesture,
  one result per pass, or one offered as "Insert last dictation") stays in
  memory for later passes. A result leaves memory once it is no longer fresh
  within `resultTTL`, whether or not its file could be purged, and when its
  file is gone: its request was consumed, or tapping "Insert last dictation"
  found the file absent, so an older result can be offered instead. Hiding
  drops everything, so no transcript stays in memory while hidden.
- **Cleanup.** Either process deletes results that are not fresh within
  `resultTTL` (judged by `createdAt`, or by the file's modification date when
  the record cannot be read): the keyboard on every read with Full Access; the
  host at launch, on every heartbeat while live, and at session end.
- **Bounded bookkeeping.** `prune` retires a binding or invalidation after
  `maxDictationDuration + 120 s + resultTTL + 2 × clockSkewTolerance`, and a
  consumed request after `resultTTL + 2 × clockSkewTolerance + 10 s`, never
  for the current intent's request.
- **Formatting** (`TextInsertionFormatter.text(for:contextBefore:)`):
  - The transcript is trimmed of whitespace and line breaks.
  - With `pressEnter`, `"\n"` follows it; an empty transcript with
    `pressEnter` inserts just `"\n"`, and without it inserts `""` (the
    keyboard then shows a "no speech" notice).
  - One leading space is added when the context before the caret ends in a
    non-whitespace character, unless the transcript starts with closing
    punctuation (`.,;:!?)]}`) or the context ends with an opening bracket or
    quote (`( [ { “ ‘ «`). A straight quote (`"` or `'`) gets a space only
    when it closes a word: a character other than whitespace or an opener
    precedes it.
  - The context only chooses spacing and is never stored.

### Shared settings (Shared/LocalFlowSettings.swift)

The keyboard reads these, so they live in the App Group's `UserDefaults`
suite. Every boolean defaults to on.

| Setting | Values | Use |
| --- | --- | --- |
| `sessionMinutes` | 5, 15 or 60; default 5 | idle expiry |
| `spokenDelimitersEnabled` | Bool | post-processing |
| `spokenNumbersEnabled` | Bool | post-processing |
| `pressEnterEnabled` | Bool | post-processing |
| `hapticsEnabled` | Bool | dictation haptics and the trackpad-mode tap |
| `keyHapticsEnabled` | Bool | a light haptic on each key touch-down ("Typing haptics") |
| `cursorSensitivity`, `cursorAcceleration` | 0.25...4; default 1 | trackpad tuning (Diagnostics) |
| `cursorTouchRate`, `cursorEventStepScale` | 1...1000 and 0.5...2.5 | the keyboard's measured touch rate, for Diagnostics |
| `fieldLayoutOverrides` | at most 64 fingerprint keys → `messages` or `fullWidth` | [Field profiles](#field-profiles) |
| `softKeyEdgesEnabled` | Bool | [Soft key edges](#soft-key-edges) ("Soft key edges" on Home) |
| `autocorrectEnabled` | Bool | [Word autocorrect](#word-autocorrect) ("Autocorrect" on Home) |

Out-of-range or malformed values read as the default and are not written. No
transcript history is stored. The words autocorrect must never correct are a
file in the App Group, not a setting ("Never correct",
[Word autocorrect](#word-autocorrect)).

### DarwinNotifier (Shared/DarwinNotifier.swift)

A thin wrapper over `CFNotificationCenterGetDarwinNotifyCenter()`.
`post(_:)` posts a signal; `observe(_:handler:)` returns an `Observation` that
unregisters on `cancel()` or deallocation. Handlers run on the main queue, and
none runs after `cancel()` returns on main.

## Host core (HostCore/)

`HostSessionCore` (`@MainActor`) is the host side of the protocol: session
lifecycle, idle expiry, reconciliation, run recovery, the watchdog, capture
supervision, transcription and status publishing. It is Foundation-only and
tested on the Mac. Platform hooks (`HostEnvironment`: the clock, foreground
state, protected-data availability, UIKit background tasks and
`LocalDictationCore` formatting) are injected. `HostSessionController` (App)
drives it ([Host app](#host-app-app)).

### Session

- **Start.** `userStartSession` (foreground and unlocked only) and the
  admission of a request without a session start one. Capture starts only in
  the foreground and unlocked; otherwise the start waits (`pendingStart`)
  while a request is in progress, and with none in progress it ends as a
  failed start (`.audioSessionFailed`). The session is `starting` until
  capture is running, then `active`. Model preparation starts with the
  session, in parallel with audio startup.
- **Microphone permission.** Granted: capture starts. Denied: the session
  ends with `.microphonePermissionDenied`. Undetermined: the system prompt is
  shown, and capture starts if it is granted while the app is still in front
  and unlocked.
- **Idle expiry.** `idleSince` is the session start or the end of the last
  dictation, and is nil while a dictation is starting, recording or
  transcribing, so expiry never interrupts one. The session ends when
  `idleSince` is no longer fresh within `sessionMinutes` (fail closed: a
  backward clock jump expires it). `sessionExpiresAt` is published. Expiry is
  checked on every tick and before every reconciliation pass, so a request
  read after the deadline (as after a resume) never joins the expired
  session.
- **End.** Reasons: the user, idle expiry, an interruption, a media-services
  reset, an engine failure, or a failed start. A request in progress ends as
  follows:

  | Reason | Starting or recording | Transcribing |
  | --- | --- | --- |
  | user, idle expiry | cancelled `.sessionInactive` | continues |
  | interruption | failed `.interrupted` | continues |
  | engine failure, media-services reset | failed `.audioSessionFailed` | continues |
  | failed start | failed with the start's code | continues |

  The session-level `HostStatus.error` becomes `.interrupted`,
  `.audioSessionFailed` or the start's code for those reasons, and nil for the
  user and idle expiry. A finished recording still waiting for its tail is
  transcribed with what arrived. Capture stops, the sample buffer is emptied,
  and expired results are purged.
- **Status cadence.** The core writes `status.json` after every change, and
  while a session is live, the app is in front, or a dictation is in progress
  it rewrites it every `heartbeatInterval` (1 s), or about every 0.1 s while
  a dictation is starting or recording (the level meter). A failed write is
  retried by the next heartbeat. Each successful write posts `.status`.
- **Timer.** The controller ticks the core every 0.1 s
  (`HostSessionPolicy.tickInterval`). Watchdog, idle expiry, polling and
  status cadence are evaluated on the tick. A periodic action is due half a
  tick early, so jitter cannot stretch a 1 s heartbeat, and a backward clock
  jump makes it due at once.

### Device lock

- **At lock** (`protectedDataWillBecomeUnavailable`): the core latches a
  locked state. A dictation that is starting, recording or transcribing is
  cancelled with `.deviceLocked`, because intents and results are class A and
  could not be read or written. The session, the audio session and the engine
  keep running; buffers are dropped in the tap as between dictations, and
  `status.error` stays nil.
- **While locked, no dictation.** No intent is admitted and no session,
  pending start or dictation starts, even if the intent file is still
  readable (iOS posts the notification before files become inaccessible). A
  record intent read while locked is refused with `.deviceLocked` and is never
  admitted later. An intent the host could not read while locked gets only the
  normal freshness check after unlock.
- **Locked at launch.** The controller checks `isProtectedDataAvailable` at
  launch, so an app launched while locked starts latched.
- **Unlatching.** The latch clears on `protectedDataDidBecomeAvailable`, and
  on the `willEnterForeground` and `didBecomeActive` events themselves when
  protected data is available then, before anything reconciles (a suspended
  app can miss the unlock notification). It is never cleared by polling.
- **A late intent proves the unlock.** A record intent issued more than
  `lockWriteWindow` (20 s) after the latch was set clears the latch and is
  admitted normally: no keyboard runs on the lock screen, and the class A
  intent cannot be written once that window has passed.
- **Idle expiry still applies** while locked, counted as usual.
- **Capture recovery while locked** rebuilds the engine inside the running
  audio session (`restart()`) and never reactivates the audio session.
- **Status heartbeat** continues while locked: `status.json` is class C.
- The orange microphone indicator stays on, the lock screen included, until
  the session ends. The battery cost of an open microphone at the lock screen
  is accepted.

### Admission

The core reconciles:

- on every `.intent` notification;
- every 0.5 s while a session is not inactive or the app is in the
  foreground;
- at launch, on a URL open, and when the app arrives in the foreground or
  becomes active.

"Foreground" means the application state is not `.background`, so
`.inactive` counts. A URL open is only a hint: before the app actually arrives
in the foreground it does nothing, and the arrival reconciles with freshness
judged at that moment. A process that has never been in the foreground (a
prewarmed launch) skips reconciliation.

Applying the reconciler's actions:

- `start(R)`: the request in progress, if any, is cancelled with
  `.superseded` and its outcome discarded. R is admitted as `starting`; with
  no session, one starts. With no model bundle in the build, R fails at once
  with `.modelUnavailable`.
- `finish(R)`: [Recording](#recording).
- `cancel(R)`: R ends cancelled, or failed `.notRecording` when the intent's
  action was `finish`.
- `reject(R, code)`: R becomes known. It is published as failed in the single
  `dictation` slot only when nothing is in progress, so a rejection never
  hides a request that is starting, recording or transcribing; the keyboard
  then falls back to `ready`.
- **Known requests.** Every admitted or rejected request joins
  `knownRequestIDs`, which keeps the 32 most recent (`RecentRequestIDs`).
- **Run recovery.** At launch the core reads the previous `status.json`. Its
  dictation becomes known whatever its phase. If that dictation is not
  terminal and belongs to another `hostRunID`, it is published as failed with
  `.interrupted` before anything is reconciled. The core also deletes every
  result whose `hostRunID` is not its own or cannot be read, and every
  staging file.
- **Generation fences.** Every asynchronous completion (startup, first
  buffer, transcription, background-task expiry) carries a `DictationTicket`,
  a session generation or an engine generation, and is dropped unless it is
  still current.

### Recording

- `DictationSampleBuffer` collects 16 kHz mono `Float32` samples for the one
  request that is recording. One lock owns all sample mutation. Appends while
  no request is recording are dropped on the spot. It enforces the
  `maxDictationDuration` cap by sample count and computes the level.
- `CapturePipeline` (the capture thread's side, shared by the microphone and
  the synthetic input) records each buffer's arrival time, drops buffers
  unconverted while idle, and trims frames captured before the recording's
  begin or after its end boundary, by the buffer's host time, before
  converting. The converter is reset or replaced at every begin, finish and
  cancel, so no audio-derived state crosses a dictation boundary.
- The first buffer moves the request from `starting` to `recording`.
- **Finish.** The recording stops at the current capture time and is
  published as `transcribing`. The samples are drained when the capture
  reports the tail (frames captured before the finish, still in flight)
  complete, after `tailTimeout` (1 s), at once if the cap was reached or the
  engine is not running.
- **Watchdog** (`HostWatchdog`, checked every tick while starting or
  recording):
  - starting with no audio within `startupTimeout`: failed `.startupTimeout`;
  - in the background with neither a keyboard presence nor the app's last
    foreground moment fresh within `keyboardPresenceTimeout`: cancelled
    `.keyboardDismissed`. Counting the last foreground moment means a long
    bounce is not cancelled before the keyboard rewrites its presence after
    the swipe back.
- **Maximum duration.** A recording is finished when the buffer reaches the
  cap or when `maxDictationDuration` has passed since it started (fail
  closed on a backward clock jump).
- **Starvation.** A recording whose sample count has not grown for 2 s
  (`captureStarvationTimeout`), or whose buffers keep failing to convert (5
  in a row), fails with `.audioSessionFailed` and counts as a capture failure.
- The bounce screen's Stop finishes a recording and cancels a request that is
  still starting.

### Capture

`HostCapture` is the session's input: `MicrophoneCapture` in the app, a
synthetic source in self-test builds, a fake in tests.

- `start()` configures and activates the audio session and starts the
  engine; it is foreground-only and is what starts a session.
- `restart()` rebuilds the engine inside the audio session that is already
  active, without activating anything, so it is allowed in the background and
  while locked. It throws when that audio session is gone.
- **Supervision.** A stopped engine, no input for
  `captureStarvationTimeout`, a reported engine failure or configuration
  change, or a recording's conversion failure, waits out
  `captureStallGrace` (0.5 s), so an interruption arriving meanwhile wins and
  is reported as `.interrupted`. Then the engine is recovered: in the
  foreground and unlocked by a full stop and `start()`, otherwise by
  `restart()`. After `maxRecoveriesWithoutInput` (2) recoveries in a row that
  produce no input, or when a recovery throws, the session ends as an engine
  failure. Failure reports carry the engine generation, and one for a
  replaced engine is ignored.
- **Interruption** (for example a call) ends the session.
- **Media services reset ends the session.** Every audio object is invalid,
  so nothing is restarted; capturing again needs a new foreground start. A
  recording fails with `.audioSessionFailed`; a finished recording is still
  transcribed.
- **Microphone choice** (`MicrophoneRoute`, pure, tested). "Use iPhone
  microphone" is on by default and stored in the app's own `UserDefaults`,
  not shared with the keyboard.
  - The session is `.playAndRecord`. On: options
    `[.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]`, with no
    hands-free profile, and the built-in microphone is the preferred input
    (re-requested on every route change, which also overrides a wired or USB
    headset microphone). Off: `[.mixWithOthers, .defaultToSpeaker,
    .allowBluetoothHFP]`, with the system choosing the input.
  - A change applies at the next session start, at once when made in the
    foreground during a session (new category, input and engine, without
    deactivating the audio session), or when the app next arrives in the
    foreground. It is never applied in the background.
  - When the built-in microphone cannot be selected, dictation continues with
    the other input and Home shows a content-free note. Home shows the input
    kind in use (iPhone microphone, Bluetooth, headset, USB, other).

### Transcription

- **No compute-policy picker.** The live app always loads the model with
  `.cpuAndNeuralEngine` (`ComputePolicy.units`). There is no CPU fallback and
  no retry on another runtime: the CPU runtime peaks at about 3.2 GB and
  would be terminated in the background. CPU-only runs exist only in the
  self-test (`LOCALFLOW_SELFTEST_COMPUTE=cpuOnly`).
- A model or transcription failure in the background on iOS 27 or later fails
  the request and records the content-free hint
  `backgroundNeuralEngineNeedsEntitlement`, which the model status row on
  Home shows until the next successful dictation.
- `TranscriptionEngine` owns preparation, readiness and transcription. At
  most one runtime is alive: it is released only while nothing prepares,
  transcribes, runs a "Find strength" check or drains a stream, and a new one
  is created only after that. A failed preparation is retried by the next
  `prepare()` or transcription.
- **Transcription while recording.** When the model is ready as a request is
  admitted, the sample buffer feeds a streaming session exactly the samples it
  collects, so each complete chunk is encoded and decoded during the recording
  and only the last partial chunk remains at the end. The result equals the
  batch transcription of the same samples. If the stream fails (other than by
  cancellation), the drained samples are transcribed in one batch.
  Cancellation, supersession, lock, session end and background-time expiry
  cancel the stream.
- Waiting for readiness is cancellation-aware, and a cancelled request never
  starts model work.
- Each transcription runs inside a UIKit background task; expiry fails the
  request with `.backgroundTimeExpired`.
- After transcription, the core formats the text with
  `LocalDictationCore.process(text, macros: [], pressEnterEnabled:,
  spokenDelimitersEnabled:, spokenNumbersEnabled:)`, writes `result-R.json`,
  posts `.result`, then publishes `completed`. A failed result write fails the
  request with `.transcriptionFailed`.
- **Memory.** On a memory warning the model runtime is released as soon as
  nothing uses it; a warning during preparation or transcription is
  remembered until then.

### URL route (HostCore/HostURLRoute.swift; pure, tested)

The host accepts exactly `<scheme>://dictate`: no user, password, port, path
or fragment; any query is ignored. Opening it brings the app forward and runs
one reconciliation pass. **It never starts a session or the microphone by
itself.** Only a fresh `record` intent admitted in the foreground, or the
user's own "Start session" tap, does.

### Custom dictionary

The macOS custom dictionary (`Sources/Dictionary`: a fixed bonus per entry
with a strength) decodes iPhone dictations too. There is no correction
detection on iOS: entries are added by hand.

- **Storage.** The host app's own `UserDefaults.standard`, never the App
  Group, with the macOS keys and payloads (`custom_dictionary`,
  `custom_dictionary_ignore`, `DictionaryStorage` JSON version 1). The iOS UI
  shows no ignore list but keeps what is stored.
- **`DictionaryLibrary`** (HostCore, `@MainActor`, tested) owns loading,
  edits and persistence. Every edit is validated, persisted, then published,
  and raises `revision`. Without a vocabulary nothing can be edited. Saved
  data that fails validation makes the dictionary empty for decoding and
  refuses edits; it is never overwritten, and only an explicit reset removes
  it.
- **Strength arrows.** ▲ and ▼ step through `DictionaryValidation.presets`
  (×0.5 to ×8) and save at once. From a value between presets they move to
  the next preset in that direction; at either end the arrow is disabled.
- **Decoding.** Each transcription decodes with one immutable
  `DictionarySnapshot` taken when its decoding starts (a streaming session:
  at admission). An edit made after that applies from the next dictation; a
  stream whose snapshot is outdated at the end falls back to the batch path.
  An empty dictionary takes the unbiased path.
- **Find strength.** The app records one sentence of at most 15 s, in the
  foreground only and in memory only, with its own `MicrophoneCapture` and
  `DictationSampleBuffer`. A running Flow session is ended first and started
  again when the sheet closes, if the app is still in front; it is not offered
  while a dictation is in progress. `LocalParakeetService.probeStrength`
  transcribes the samples with the dictionary minus the word, then re-decodes
  the same encoder output with the word at each of `VerifyDecision.strengths`
  (×1 to ×8). `StrengthProbe` (pure, `Sources/Dictionary`) decides "already
  recognized", "recognized at ×n" (the decode contains the word, and every
  difference from the unboosted transcript is a block whose new side is
  exactly the word and whose old side has at most two words more), or "not
  recognized". The samples and the encoder output are released when the check
  finishes (`probeStrength` returns); the sheet keeps only the result (the
  outcome and the unboosted and boosted texts) until it closes. Leaving the
  foreground discards a recording in progress, and closing the sheet cancels
  any work still running. Nothing changes until the user taps "Use ×n". A
  check that has started may finish in the background. It runs through
  `TranscriptionEngine.withReadyRuntime` and is not reported as a dictation.
- **Privacy.** Entries are user content: never logged, never in a bug report
  and never in the App Group. Test recordings follow invariant 1, and the
  transcripts shown in the sheet are never stored.

### Bug report (HostCore/BugReportEmail.swift)

"Report a bug" builds a `mailto:` draft to `localflow@wildernesslabs.ai` that
the user reviews in their email app. It contains only the app version and
build, the iOS version and the generic device type, with no logs, audio,
transcripts or other user data.

## Host app (App/)

- **`HostSessionController`** (`@MainActor`, `ObservableObject`) is the UIKit
  adapter around `HostSessionCore`. It builds the store, settings, capture and
  transcriber; runs the 0.1 s timer; observes `.intent`; forwards URL opens,
  `willEnterForeground`, `didBecomeActive`, `didEnterBackground`, the
  protected-data notifications and memory warnings; and mirrors the core's
  state into SwiftUI. It decides when the bounce screen shows and plays the
  bounce screen's recording haptic.
- **`MicrophoneCapture`** implements `HostCapture` with one `AVAudioEngine`
  input tap for the whole session ([Capture](#capture)).
  - It requests a 0.2 s (else 0.1 s) I/O buffer, a 16 kHz sample rate, mono
    input where the route allows, and a 0.2 s tap buffer, so an idle session
    wakes the app rarely. What iOS granted is read back and shown in
    Diagnostics.
  - It calls `setAllowHapticsAndSystemSoundsDuringRecording(true)`, because
    iOS otherwise mutes the keyboard's haptics for the whole session.
  - Audio is never written to disk or logged.
- **`ParakeetTranscriber`** wraps `TranscriptionEngine` with the Parakeet
  runtime, `LocalParakeetService`, which loads only the 15 s encoder function
  (as on macOS) to bound memory. The model loads from the app
  bundle (`LocalFlow.app/Parakeet/`). It keeps the last 10 dictation
  measurements in memory for Diagnostics.
- **App-only preferences** (`AppPreferences`, the app's own `UserDefaults`):
  onboarding completion, "Use iPhone microphone", and the last model
  preparation's duration (for a progress estimate). None holds user content.
- **UI (SwiftUI):**
  - Onboarding: the privacy promise, microphone permission, enabling the
    keyboard and Full Access, and model preparation with progress and an
    estimate from the last preparation; the user can finish onboarding while
    it continues.
  - Home: the session card (start or end, idle time left, the
    microphone-indicator explanation), model state, session length, the
    dictation settings, "Use iPhone microphone", a "Keyboard" section with
    "Autocorrect", "Soft key edges" and "Typing haptics", and links to Try
    it, keyboard setup, Dictionary, Diagnostics, Report a bug and the public
    privacy policy (opened in the browser only on a tap).
  - Try it: two plain text fields for the destination-binding test and a
    multi-line cursor practice field with invented text. The text lives in
    view state only.
  - Bounce screen: "Starting…" until the dictation is `recording` (input is
    flowing), then "Listening — swipe back to your app", with Stop and
    Cancel. It stays up after the swipe back only while its dictation is in
    progress, so a later return to LocalFlow shows Home, not an old outcome.
    It is not shown while Try it has the keyboard.
  - Diagnostics: the trackpad sensitivity and acceleration sliders, the
    keyboard's measured touch rate, the compute units in use (read-only),
    "Release model now", the last preparation, and the last dictations'
    content-free measurements (audio seconds, wait and transcription time,
    compute units, foreground or background, memory footprint), held in
    memory only. Its "Autocorrect" section has only "Forget never-correct
    words (N)" ("Never correct", [Word autocorrect](#word-autocorrect)).
- **Self-test build** (`-D LOCALFLOW_SELFTEST`, never in normal or App Store
  builds). Environment variables: `LOCALFLOW_SELFTEST_AUDIO`,
  `LOCALFLOW_SELFTEST_EXPECTED`, `LOCALFLOW_SELFTEST_COMPUTE`,
  `LOCALFLOW_SYNTHETIC_MIC`, `LOCALFLOW_SELFTEST_SKIP_ONBOARDING`,
  `LOCALFLOW_SELFTEST_SCREEN` and `LOCALFLOW_SELFTEST_START_SESSION`.
  - It prints only content-free `LocalFlow self-test:` lines (pass or fail,
    timings, App Group state, compute units, footprint), never a transcript.
  - `LOCALFLOW_SYNTHETIC_MIC` replaces the microphone with a real-time-paced
    synthetic source. A requested but unusable synthetic source fails closed
    and never constructs real capture. It does not prove background audio
    behavior; only a device test can.

## Keyboard extension (Keyboard/)

- **`KeyboardViewController`** (`UIInputViewController`, principal class
  `LocalFlowKeyboard.KeyboardViewController`) hosts a SwiftUI
  `DictationBarView` (the top row) in a `UIHostingController`, above the UIKit
  `KeyAreaView`, plus a SwiftUI `MenuPanelView` over the key area when the
  menu is open.
  - Heights (`KeyboardMetrics`): the top row is 48 pt in portrait and 40 pt
    in compact height, with its controls 38 pt and 32 pt tall, centred in
    it; the key area is 216 pt and 162 pt.
  - Its input view adopts `UIInputViewAudioFeedback`, so key presses play the
    system click, which follows the user's Keyboard Clicks setting.
  - It sets `hasDictationKey = true` in `viewDidAppear`, so iOS drops its own
    dictation microphone from the bar below the keyboard on Face ID iPhones.
  - **Touchable backgrounds.** The key area, the top row's hosting view and
    the menu panel's hosting view use `KeyAreaView.touchableBackground`, grey
    at 2% alpha, because in a keyboard extension iOS ignores touches on fully
    transparent points. A tap in a gap reaches the key area, whose nearest-key
    hit testing covers every point, and a tap in the bar outside its controls
    goes to the keys ([Reach and touch regions](#reach-and-touch-regions)).
- **`KeyboardDictationClient`** runs the keyboard's side of the protocol while
  visible:
  - With Full Access it polls the status and the intent every 0.2 s, observes
    `.status` and `.result`, and writes presence every
    `keyboardPresenceInterval`. It reads the result files only when
    `KeyboardResultInbox` says a read is due
    ([Results](#results-sharedkeyboardresultsswift-textinsertionformatterswift-pure-tested)).
    Without Full Access it neither polls nor writes.
  - It holds the `KeyboardResultLedger` per instance, in memory.
  - **Mic tap.** `ready`: write `record(R)` with a new ID, then post
    `.intent`. `hostUnavailable`: write `record(R)` and open
    `<scheme>://dictate` with `HostAppLauncher`, without posting `.intent` (a
    background host without a session would reject it before the app reaches
    the foreground); if the launcher fails, show "Open LocalFlow". After an
    error the tap starts the way the host's current state allows.
    `starting` or `recording`: write `finish(R)` under the stale-writer guard,
    bind R to the current field, then post `.intent`.
  - **Cancel** writes `cancel(R)` under the same guard while starting,
    recording or transcribing.
  - "Open LocalFlow" in the menu uses the same launcher without a request.
- **`HostAppLauncher`** walks the responder chain to the `UIApplication` object
  and calls `open(_:options:completionHandler:)` through the Objective-C
  runtime. It is experimental and an App Review gray area: validate it on
  iOS 26 and 27 devices and call it out in any pull request that touches it.
- **`KeyboardInput`** adapts `KeyboardEditor` (KeyboardCore) to the key area,
  the text proxy and timers. **`TrackpadDriver`** runs `TrackpadController`
  on a `CADisplayLink` (60–120 Hz) while a gesture is active and builds the
  TextKit layout of the field's profile (`TextKitAdapters`). **`SwipeEngine`**
  loads the swipe bundle and runs the Core ML encoder
  ([Swipe typing](#swipe-typing)). `KeyboardInput` also loads the soft key
  edges model and, through **`AutocorrectLoader`**, the corrector from the
  same bundle ([Soft key edges](#soft-key-edges),
  [Word autocorrect](#word-autocorrect)).
- **Feedback.** Haptics play only with Full Access and the matching setting:
  `keyHapticsEnabled` for a light impact on every key touch-down,
  `hapticsEnabled` for dictation (the mic, cancel and Undo taps, recording
  start, insertion, failures) and the trackpad-mode activation tap. A keyboard extension
  cannot read the iOS keyboard-feedback setting, so LocalFlow has its own.
- The keyboard has no network access and does not log.

### Top row

`DictationBarView` (SwiftUI) renders `KeyboardDictationClient.state`, the
candidate strip and the "Never correct" offer only, so typing never
re-renders it. It reports its controls' frames to the key area, which takes
every other point of the bar
([Reach and touch regions](#reach-and-touch-regions)).

- **Right:** a "Start" capsule with a waveform glyph (`lf.mic`), the primary
  dictation control. While starting or recording it is a red "Stop" capsule
  with live level bars and the elapsed time, with a small cancel button
  (`lf.cancel`) beside it. While transcribing it shows a spinner. When
  dictation cannot run here (no Full Access, configuration, versions), it
  explains why.
- **Left:** a menu button (`lf.menu`) that opens a panel over the key area
  with the session status, "Open LocalFlow", the field's layout and a Switch
  ([Field profiles](#field-profiles)), the trackpad tip, the field's
  content-free fingerprint, and details of anything that keeps dictation from
  working. A tap outside the panel's card, or on the button, closes it.
- **Middle:** chips for Undo (`lf.undo`) and "Insert last dictation"
  (`lf.insertLast`) when there is something to act on, otherwise a one-line
  status (model preparation, errors, notices). The candidate strip, after a
  swipe ([Swipe typing](#swipe-typing)) or a commit key
  ([Word autocorrect](#word-autocorrect)), replaces the chips while it shows.
  The "Never correct" chip after an autocorrect revert replaces both while it
  shows ([Word autocorrect](#word-autocorrect)).
- The space bar reads "LocalFlow".
- While the trackpad runs, the top row fades to 30% opacity and the key caps
  go blank.

## Keyboard core (KeyboardCore/)

Everything here is Foundation-only (plus Accelerate for the tap and word
models), pure where possible, and tested on the Mac through the same entry points the UIKit layer calls. Context read from the
proxy (`documentContextBeforeInput`, `documentContextAfterInput`,
`documentIdentifier`, whether text is selected) is held in memory only, never
stored, logged or transmitted, and dropped when the operation ends or the
keyboard hides.

### Layout and keys (KeyboardLayout, KeyTouchModel)

- Three layers: letters (QWERTY with shift and delete), `123` and `#+=`. The
  bottom row has the layer key, the globe (only when
  `needsInputModeSwitchKey`, which also handles the input-mode list), space and
  return. The return key's label follows `returnKeyType`.
- `KeyTouchModel` tracks every touch: one view, nearest-key hit testing, no
  dead gaps. Keys are tracked by action, never by index; a rebuild (layer,
  shift or size change) remaps held function-key and slide fingers onto the
  new keys or drops them, and a held character keeps the key it touched down
  on.
- Key callouts show a character from its touch-down while the finger is down;
  a swipe shows none.
- `IsASCIICapable` is false, because dictation emits non-ASCII text.

### Reach and touch regions

Every point of the keyboard is a key's or a top-row control's; none is dead.
The views are touchable ("Touchable backgrounds",
[Keyboard extension](#keyboard-extension-keyboard)).

- **Reach above the keys.** The key area also takes touches up to
  `KeyboardMetrics.reachAboveKeys(compact:)` above it: the strip of the bar
  below its controls, (bar height − control height) / 2, 5 pt in portrait and
  4 pt in compact height. Such a touch is an ordinary key touch, and its
  nearest key is in the top row. While the menu panel is open the reach
  is 0.
- **The bar outside its controls.** The key area also takes any touch in the
  bar outside every control's frame
  (`KeyboardMetrics.barPointGoesToKeys(x:y:barHeight:compact:controls:)`, in
  the bar's own coordinates; a point on a frame's edge is the control's). It
  types the top-row key nearest it.
  - The controls are the menu button, the Cancel button, the Start capsule,
    the Undo and "Insert last" chips, the candidate strip and the "Never
    correct" chip. The bar reports their frames as they lay out and forgets
    them as they go (`BarControlFrames`).
  - Each control's tap area is exactly the rectangle it reports
    (`contentShape(Rectangle())`), so every point of the bar is a control's
    or the keys'.
  - The Start/Stop capsule's tap area, and the frame it reports, is its frame
    inset by `StartCapsule.hitInset` (6 pt) on every side; it looks the same,
    and the keys take the ring around it.
  - Two places inside a control's frame take no tap: the 1 pt dividers
    between candidates, and the Start capsule while it shows the transcribing
    spinner.
  - Until the bar has reported any frame, only the reach above the keys goes
    to them.
  - **Linger.** A control that moves or goes also keeps its previous frame
    for `BarControlRegions.linger` (0.6 s) (`BarControlRegions`, pure),
    because the bar animates its controls and reports their destination
    frames.
- **Callouts.** A top-row key's callout bubble stays below the keyboard's
  top, where iOS clips an extension's drawing: its gap above the key is 4 pt
  in portrait and 6 pt in compact height.
- **A stricter space bar.** `KeyboardLayout.nearestKey` counts a point outside
  the space bar's frame as `KeyboardLayout.spaceMissPenalty` (8 pt) farther
  from it than it is. Inside its frame the space bar is unchanged, and so is
  every other key. In portrait the space bar gets 2 pt of the 12 pt gap above
  it and the bottom letter row 10 pt. It gets none of the gap to `123`, the
  globe or Return, nor of the row gap in compact height, and still takes the
  bottom padding.
- **A wider delete key.** For the nearest key, the delete key's frame reaches
  `KeyboardLayout.deleteReachLeft` (8 pt) further left, towards M; it looks
  the same. A point inside M's frame is never within 8 pt of delete, so M
  keeps its whole frame. Ties among keys at distance 0 go to the nearer
  centre, then the earlier key.
- **The globe** is a system button. It takes every touch whose nearest key is
  the globe, including points outside its frame; the key area ignores those
  touches.
- Every user of the nearest key follows these rules: taps, the space bar's
  hold, slides and soft key edges ([Soft key edges](#soft-key-edges)). So
  does the reference: localflow-swipe `tap/geometry.py` `nearest_key` and
  `tap/decide.py` `nearest_keys`, pinned by its Swift-generated layout
  fixture.

### Typing model

- **Touch-down.** Every key's touch-down except the globe emits `.keyDown`
  first (click, haptic, a character's callout), which ends any trackpad
  settlement on the spot ([Trackpad and keys](#trackpad-and-keys)). Shift and
  layer keys act on touch-down. Delete starts its deletion schedule on
  touch-down ([Delete key](#delete-key)).
- **Characters** type at release, or at rollover. The key is the one nearest
  the touch-down point, or the one soft key edges decided at touch-down
  ([Soft key edges](#soft-key-edges)), and is never hit-tested again, so a tap that rolls onto
  space, delete or Shift still types its own key. A system-cancelled touch
  types nothing.
- **Space and Return** type at release or rollover, so a held space can
  become the trackpad without typing, and Return types only if the finger
  lifts over it. A slide from a layer key types the character under the
  finger at release, then returns to letters.
- **Rollover.** A new finger first commits every key still held by earlier
  fingers, in press order: characters, space, return and slides alike. A
  committed space no longer becomes the trackpad.
- **Immediate execution.** A key edits through the proxy the moment it acts.
  Keys are never queued, delayed or batched; the proxy applies edits in the
  order they are issued, so hiding loses nothing that was typed.
- **Field binding.** Each finger keeps the field the keyboard served at its
  touch-down (or, before any identity, the first identified after). What it
  types carries that field and is refused only when that field and the
  current one are both identified and differ; a nil identity never blocks a
  key. A change to another identified field drops held, uncommitted keys and a
  running swipe.
- Keys are ignored while the trackpad runs or a swipe that is not a skid is
  in progress ([Swipe typing](#swipe-typing)).
- The only predictions are soft key edges' and autocorrect's, from fixed
  models ([Soft key edges](#soft-key-edges),
  [Word autocorrect](#word-autocorrect)). Nothing is learned from typing.

### Shift, caps lock and spacing (TypingRules)

- One Shift tap shifts the next letter; two taps within 0.35 s turn on caps
  lock.
- Auto-capitalization follows the field's `autocapitalizationType` (none,
  words, sentences, all characters) from the text before the caret, reading
  the visible context as starting a sentence or line.
- Two spaces within 3 s insert ". ", as on Apple's keyboard.
- Every host callback that is not a recognized echo of the keyboard's own
  edits, or of a trackpad adjustment, restarts the space timing and derives
  the shift from the text again. For `contextWatch` (0.5 s) after each own
  edit, the shift follows the proxy every frame, since the proxy can show an
  edit late and with no callback.
- While the proxy has not shown the keyboard's own edits yet, the text before
  the caret is read from the typing tail (`ContextTail`), which is dropped on
  hiding.

### Delete key

Values measured on Apple's keyboard (`DeleteRepeatParameters`):

- The first deletion happens 0.12 s after touch-down, or at lift if that is
  sooner. A system-cancelled touch deletes nothing.
- The first repeat follows 0.50 s later; after that a character every 0.10 s.
- After 21 character deletions (about 2.5 s after touch-down) it switches to
  word mode: 2 words every 0.354 s, each word with the space before it. Word
  boundaries follow `WordBoundaries`.
- Each deletion is bound to the press and its field.

### Editing core (EditingCore)

- **Field identity.** A nil `documentIdentifier` never matches anything; a
  different one ends everything that belonged to the old field.
- **Edit generation.** It advances on every edit the current owner did not
  make: typing, each delete, a dictated insertion, a focus change, hiding, and
  any host callback nothing of the keyboard's explains. Owners (a trackpad
  gesture, a dictated insertion) remember the generation they started at.
- **Attribution.** A callback is the trackpad's only if it matches the
  expected outcome of an adjustment still owed one, consumed once
  ([Trackpad: units, probes and attribution](#trackpad-units-probes-and-attribution)).
  A callback that shows the context one of the keyboard's own recent inserts
  or deletes left is a report of that edit (`ownEdit`: at most one per edit,
  at most 32 edits, within 1 s). It is never an outside change, so it never
  ends a gesture or anything typed. Anything else is an outside change.
- **Late gesture reports are never echoes.** While a finished gesture still
  owes reports, no callback is taken as the echo of a later edit; while a
  gesture runs, only edits made before its first adjustment can be echoed.
  `ReportDebt` counts the reports owed ([Trackpad: units, probes and
  attribution](#trackpad-units-probes-and-attribution)).
- Measured: neither UIKit nor WKWebView reports the keyboard's own inserts
  and deletes, so in practice every callback resets the shift and spacing
  timing.

### Undo last dictation

After a dictation is inserted, automatically or by the chip, the top row
offers **Undo**, which removes exactly what was inserted, a trailing `"\n"`
from "press enter" included (`UndoTracker`, owned by `EditingCore`).

- **Anchors.** At insertion the keyboard records up to 24 characters of the
  context before the caret (read before inserting) and up to 24 after it.
- **Proof of ownership**, never timing:
  - The current after-context must start with the after-anchor, as far as
    both are visible.
  - The current before-context must end with before-anchor + insertion. If
    the context is truncated, its visible part may instead be a suffix of the
    insertion at least 16 characters long, and deletion then proceeds
    progressively.
  - Shorter insertions, such as a lone `"\n"`, need both anchors in full;
    with an empty document, the exact whole context.
  - Both ends of what is deleted must be character boundaries in the current
    context (CRLF, combining marks).
  - No proof, no Undo.
- **Execution.** Undo deletes with `deleteBackward()` only the part of the
  insertion the current context proves, waits for the context to update
  (at most 0.5 s per step), re-verifies that the remaining inserted prefix is
  the context's suffix, and repeats. It stops at the first mismatch or
  timeout.
- **Invalidation.** Undo is gone for good after any typing, delete (each
  repeat included), trackpad movement or other insertion, a focus change,
  hiding the keyboard, 30 s, or any callback that is not a pending trackpad
  adjustment's own (the keyboard's own edits' reports included). It is never
  offered while text is selected.
- **Lifetime.** The inserted text and anchors are held in memory only, for at
  most 30 s.
- A host that edits text without sending callbacks is a residual risk the
  anchors mitigate.

### Trackpad: activation and motion

Values measured on Apple's keyboard, device values first
(`TrackpadParameters`):

- **Activation.** Touch and hold space: trackpad mode begins 0.40 s after
  touch-down if the finger is then within 16 pt (straight line) of its
  touch-down point. Only the timer activates it; movement before activation
  is discarded. With Full Access and `hapticsEnabled` a light haptic plays.
  The whole key area then moves the cursor until the finger lifts.
- **Gain.** Per delivered touch event, with s the finger's 2D step in points
  scaled to a 60 Hz event (`eventStepScale`), one gain applies to both axes
  and both directions:

  ```
  g(s) = 1 + 0.04·s²                 for s ≤ 2
       = 1.16 + 0.16·(s − 2)         for 2 < s ≤ 5.92
       = 1.787·(s / 5.92)^0.389      for s > 5.92
  ```

  The point moves `sensitivity · (1 + (g(s) − 1) · acceleration) · Δ` per
  event. `sensitivity` and `acceleration` are the user's multipliers (default
  1, clamped to 0.25...4), read when a gesture starts.
- **Touch rate.** `TouchRateEstimator` measures the extension's own touch
  interval and sets `eventStepScale = (1/60 s) / median interval`, within
  0.5...2.5 (2 at 120 Hz). The keyboard records the measurement for
  Diagnostics at most once per gesture.
- **Point model.** A 2D floating point starts exactly at the caret, in an
  emulated layout of the visible text ([Field profiles](#field-profiles)).
  The caret is the character boundary nearest the point on the line whose
  center is nearest the point's y.
  - Line ends do not wrap; only vertical motion changes lines. The column
    is kept in points across lines.
  - The point is clamped to [1.0, width − 1.5] horizontally and to
    [first line center − 7, last line center + 8] vertically, and overshoot
    is not remembered.
  - There is no dead zone, hysteresis, momentum or axis lock.
  - After the lift, the target stays where the point is and settling
    continues until the caret is there (`settleTimeout`, 0.5 s after the lift
    or the last adjustment).

### Trackpad: proxy and snapshots

- A keyboard can move the caret only with
  `adjustTextPosition(byCharacterOffset:)`. It cannot select text or read the
  field's layout, font or width, and it sees only the context the proxy
  exposes, which updates asynchronously after each adjustment.
- Measured in UIKit: the before-context reaches a sentence or two back across
  line breaks and often starts mid-line; the after-context stops at the end of
  the sentence or line. Right after an adjustment the proxy first answers
  provisionally (its last-reported text with the caret moved and clamped),
  and the host's own context arrives with `textDidChange` about 10 ms later.
- `TrackpadSession` takes a snapshot of the context, moves the caret
  virtually inside it, and issues at most one adjustment per display frame.
- It re-snapshots when the caret comes within 6 characters of the snapshot's
  edge and the host shows more, re-anchoring the point to the caret's line. It
  never re-snapshots from a context that does not show the caret where the
  session put it (an adjustment has not landed yet).
- A line beyond the snapshot is reached by one jump just past the snapshot's
  edge (an edge probe). At the document's edge the host ignores the offset
  and the caret stays. A context that shows the caret exactly at the
  snapshot's edge is never read as a crossing, and an unchanged context after
  an edge probe is ambiguous (an ignored step and a move between blank lines
  look alike), never a boundary. After 8 ambiguous probes at an edge the edge
  holds like Apple's last line; each half line of new finger travel past it
  allows one more.
- Columns are real only on lines whose start the snapshot shows.
- Hard line breaks are exact; soft wraps are an estimate, so fields with a
  custom font or width drift by a few characters.

### Trackpad: units, probes and attribution

- **Offset units.** UIKit counts offsets in UTF-16 code units, WebKit in
  grapheme clusters. Moves across single-code-unit characters need no probe,
  because both units count them alike. Only crossing a multi-unit cluster with
  the unit unknown probes, by the cluster's UTF-16 length (or by the
  crossing-side scalar when the snapshot has too few clusters, never into a
  surrogate pair's middle).
- **Learning.** A probe is read only once its callback matched, or after
  `syncTimeout` (0.3 s): the proxy's immediate answer is provisional. Its
  outcome is placed through overlapping local anchors, and the unit is learned
  only when exactly one unit explains it. A caret shown inside a cluster means
  UTF-16.
- **Completion and rollback.** An outcome inside a cluster is completed to the
  cluster's edge in the direction of travel; one that cannot be placed is
  rolled back to where the probe started. Probes whose outcome could not be
  placed are retried at most twice without new finger travel. A probe the
  host verifiably ignored is retried with the smallest step.
- **Repairs.** A caret the context shows inside a cluster is repaired to the
  cluster's edge in the direction of travel, at most 4 times in a row. Between
  the halves of a surrogate pair (two U+FFFD in the context) the repair moves
  one unit, which may stop inside the cluster and is then repaired again.
- **Expectations.** Each adjustment carries consumable expectations
  (`CaretExpectation`): the contexts it may leave. A host callback counts as
  the gesture's own only if it matches one; anything else is an outside
  change. Reports are attributed oldest first. An expectation not reported
  within `syncTimeout` is retired, so a later change that looks like it is an
  outside change. Time retires an expectation; it never makes a callback the
  gesture's own. Outcomes with unknowns (a jump past the edge) need
  affirmative evidence: an emptied field matches nothing. A
  `selectionDidChange` fits only an adjustment still owed a callback.
- **Double reports.** WebKit reports every adjustment twice: first with the
  context it was issued in, then where it landed. The first report is
  accepted once per adjustment and confirms nothing; no adjustment is issued
  until the second arrives. If it never does, the session is ambiguous and
  ends without another adjustment. Whether a field reports twice is learned
  per field, like the unit.
- **Report debt.** `ReportDebt` (held by `TrackpadController`, current field
  only, at most 64 entries) counts every report the field still owes for any
  adjustment issued there: one each, or two where the field reports twice or
  is not yet known to report once. Rollbacks and repairs count. Every non-echo
  `textDidChange` pays the oldest. A report stays owed however late it is. A
  new gesture inherits the debt it is sure of and moves nothing until those
  reports have shown where the caret is (or their time is up).
- **Validation.** Before every adjustment `TrackpadController` re-validates
  the field identity and the edit generation; anything else ends the session
  without another adjustment.
- **Learned state.** The unit and whether the field reports twice are cached
  for the current field only and forgotten on hiding.

### Trackpad and keys

- **A key ends the gesture on the spot.** Any key's touch-down
  (`TrackpadController.interrupt`) ends any gesture or settlement: nothing
  more is issued, and a probe's outcome is abandoned. The caret is wherever
  the host has it once what was already issued lands. The trackpad never
  delays, queues or reorders a key.
- **Accepted residual.** A key typed in the same instant as a probe crosses a
  multi-unit cluster, or while a repair is out, may land inside that cluster.
  One delete restores the cluster (tested for surrogate pairs and skin-tone
  modifiers; combining marks are unmeasured).
- **Outside change.** An outside change (or an ambiguous report) ends the
  gesture without another step toward the target. If the caret may be inside
  a cluster, the session first guards the field for at most twice
  `syncTimeout`, repairing a split it shows to a whole-cluster boundary, only
  from a context that shows everything issued so far, and at most once per
  context (`abortGuarding`). A key ends the guard at once.
- **Cancel and hide.** A system cancellation, and the keyboard hiding, drop
  the snapshot, its laid-out TextKit copy and every expected context at once,
  and roll an outstanding unit probe back (the same count back returns to
  where it started, in either unit). A jump past the snapshot's edge that is
  still out is watched until `syncTimeout` after it was issued: a caret it
  left inside a hidden cluster is moved back to the cluster's edge on the side
  the jump came from, only from a context that shows everything issued, at
  most 4 times. Hiding keeps the text-free session (and the field identity)
  until that watch ends, even if the keyboard reappears in the same field.
- **Cancel during a surrogate-pair repair.** A repair out of a surrogate
  pair's middle that is still out when the gesture is cancelled or the
  keyboard hides is watched the same way, and a caret it leaves inside the
  cluster goes on to the cluster's edge in the repair's direction.
- **Known limits.** Hosts whose reports arrive later than `syncTimeout` are
  outside these guarantees: a probe resolved by timeout may learn the wrong
  unit, and a jump on such a host can stop inside a hidden cluster.

### Field profiles

The trackpad lays out the snapshot with TextKit 1, the body font at the
current Dynamic Type size and line-fragment padding 0, at one of two emulated
widths (`FieldLayoutParameters`):

- **Messages:** keyboard width − (2·m + 117.33), with m = 16 pt below a
  414 pt keyboard and 20 pt otherwise (243.7 pt on a 393 pt iPhone 15 Pro).
- **Full width** (Notes, Mail and similar fields): keyboard width − 40 on
  16 pt-margin phones and − 48 on 20 pt-margin phones.
- The line pitch in both is the layout's real line advance, lineHeight +
  leading (24 pt at the default size).
- **Choosing a profile.** A field's content-free fingerprint is its
  `UITextInputTraits` raw values (keyboard appearance excluded; a content
  type other than Apple's constants reads as "custom") plus the unit the
  trackpad learned, hashed with 64-bit FNV-1a. The user's remembered choice
  for the fingerprint (with the unit, then without) wins. Otherwise a field
  with Messages' measured trait signature, in a field not learned as grapheme
  (WebKit), gets Messages, but only in portrait at the measured widths 390,
  393, 402, 420 and 440 pt (±1). Everything else gets full width.
- **Manual choice.** The menu shows the layout and a Switch. With Full Access
  the choice is remembered per fingerprint in `fieldLayoutOverrides` (at most
  64 entries); without it, it holds for the keyboard instance only. Only the
  keyboard writes `fieldLayoutOverrides`; it reads them from the App Group
  once each time it appears and again after its own Switch, not at every
  host callback.
- Traits are read at every host callback, on appearance and at each
  gesture's start; a gesture's layout is fixed until it ends. A reading
  without a field identity (the proxy's placeholder at first appearance) is
  ignored.

### Swipe typing

**Gesture** (`KeyTouchModel`):

- A touch becomes a swipe when all of these hold: swipe typing is enabled
  (`swipeEnabled`: the swipe engine has loaded and the field is not secure
  text entry), the layer is letters, the touch started on a character key,
  it is not committed, no other finger is held, and a move (not the lift)
  has taken the finger at least `swipeThreshold` (half a letter-key pitch,
  `(letterWidth + keyGap) / 2`, about 20 pt in portrait) from its touch-down
  point. A touch that first reaches the threshold at its lift is a tap of its
  touch-down key.
- Once a swipe, the touch types nothing, its callout ends, and other touches
  are ignored until it ends, unless it is a skid.
- **Skids.** A swipe is a skid while it is younger than
  `KeyTouchModel.skidDuration` (0.15 s from its touch-down timestamp) and none
  of its samples so far, the lift included, is a full letter pitch
  (2 × `swipeThreshold`) or more from its touch-down point.
  - A released skid types its touch-down key as a tap would (a soft tap when
    soft taps are on, [Soft key edges](#soft-key-edges)), with the swipe's
    field, instead of emitting `.swipe`.
  - A new finger touching down during a skid first commits it as that tap, in
    press order (rollover), and is then handled as usual. The skid's finger
    stays as a committed character, so its moves and lift do nothing.
  - A cancelled skid types nothing, as a cancelled swipe does.
  - Timing uses the touch timestamps (the `t` of samples and events).
- Samples are `SwipeSample(x:y:t:)`: key-area points and touch timestamps in
  seconds, from the touch-down point and every coalesced move, through the
  lift. At release the model emits `.swipe([SwipeSample], field:)`; a
  system-cancelled swipe emits nothing.

**Decoding pipeline.** The reference implementation, and the authority for
every detail, is the private repository `ajbarryiii/localflow-swipe`; its
module docstrings are the contract, and `iOS/Tests/SwipeFixtures.swift` is
generated from it.

1. **Frame** (`SwipeFrame`). From the letters layer's key centers: `W` =
   (largest minus smallest top-row center x) / 0.9; `ox` = smallest top-row
   center x − 0.05 W; `R` = (bottom-row center y − top-row center y) / 2;
   `oy` = top-row center y − R / 2. A point maps to ((x − ox) / W,
   (y − oy) / W).
2. **Resample** (`SwipeResampler`, `swipe/features.py`): timestamps in
   milliseconds, made non-decreasing and shifted to start at 0. If the
   duration exceeds 1 ms, keep the last sample per timestamp and interpolate
   at `max(2, floor(duration × 60 / 1000 + 0.5) + 1)` evenly spaced times;
   then interpolate by index to 64 points. Float64 arithmetic, Float32
   output.
3. **Encoder** (Core ML `SwipeEncoder.mlmodelc`, CPU only): input `traj`
   Float32 [1, 64, 2] and `keys` Float32 [1, 26, 2] (a–z centers in the same
   frame); output `log_probs` Float32 [1, 32, 27]. Column 0 is the blank;
   column 1 + i is letter i.
4. **Lexicon** (`SwipeLexicon`, `swipe/lexicon_bin.py`): the binary "LFLX"
   version 1 trie, read in place from a memory-mapped `Data`. Keys are words
   lowercased, apostrophes removed and repeated letters collapsed.
5. **Decoder** (`SwipeDecoder`, `swipe/decode.py`): CTC prefix beam search
   over the trie in Float64, with `logaddexp(a, b) = max + log1p(exp(−|a −
   b|))`. Each frame keeps the `beam` best prefixes (ties: the smaller key).
   Final score = ctc / len(key)^length_power + freq_weight × freq +
   length_bonus × len(key). Words are unique ignoring case, best first, and
   ties order by Unicode scalar values.

**Bundle.** `SWIPE_BUNDLE_DIR` holds `SwipeEncoder.mlmodelc/`, `lexicon.bin`
and `bundle.json` (`format` 1; `decode`: `beam`, `top_k`, `length_power`,
`freq_weight`, `length_bonus`; a SHA-256 for every other file; optional `tap`
and `autocorrect` sections, [Soft key edges](#soft-key-edges) and
[Word autocorrect](#word-autocorrect)). The build
copies exactly the listed files into `LocalFlowKeyboard.appex/Swipe/`, checks
each hash, and adds `bundle.json` and the licenses in `Resources/Swipe/`.
Without `SWIPE_BUNDLE_DIR` the keyboard has no swipe typing and long drags
across the letters are taps. The keyboard loads the bundle off the main
thread when it starts; any missing or invalid file, or decode settings out of
range, leaves swipe typing off.

**Inserting a swiped word** (`KeyboardEditor.insertSwipe`):

- The best candidate is inserted; with no candidate nothing happens.
- A space goes before the word unless the text before the caret is empty or
  ends with whitespace or one of `( [ { " ' “ ‘ / - @ #`. No space goes after
  it.
- **Space before a tapped word.** After a swiped word, the next tapped
  character that is a letter or digit gets a space inserted before it in the
  same edit; punctuation and symbols attach directly. This pending space
  survives Shift and layer keys and a candidate replacement. It ends on any
  other key action, a dictation insert, a field change, the trackpad, an
  outside text change, or when the text before the caret no longer ends with
  the swiped word. The tapped letter's case is decided as if the space had
  been typed.
- Case: caps lock uppercases the word; a one-shot or automatic shift
  uppercases its first letter and is consumed. Case only rises, so "I" and
  proper nouns keep their capitals.
- The word is refused in another identified field, as typed keys are.

**Candidate strip.** After a swipe, the middle of the top row shows up to
three candidates, cased the same way, the inserted word emphasized.
Autocorrect shows its choices in the same strip after a commit key
([Word autocorrect](#word-autocorrect)).

- Tapping another candidate replaces the inserted word, but only while the
  text before the caret still ends with it and nothing else has edited the
  field (the edit generation). Otherwise the tap does nothing and the strip
  closes.
- The strip closes on any other key action, a dictation insert, a field
  change, the trackpad, an outside text change, or hiding.
- While the strip shows after a swipe, the first deletion (a tap, or a held
  delete's first deletion) removes the whole swiped word, leaving the space
  before it. Repeats continue as usual.

**Swipe anchors** (`KeyboardEditor`, `ExpectedDocument`). The edit that put
the swiped word in (an insertion, or a candidate's replacement) is recorded
in the editor's `ExpectedDocument`: window rule, the word as its witness, no
time limit. The strip and the pending space refer to that one record, and the
editor holds at most one between calls. "Still ends with it and nothing else
has edited the field", above, means the record holds:

- the same field, the edit generation unchanged, and nothing selected;
- the editor's text before the caret ends with the word;
- the proxy shows the text after the caret the edit left and, before the
  caret, either the text the edit left (confirmed) or, until the proxy has
  been seen showing the edit, exactly its reading before the edit (pending).
  Anything else contradicts it.

Autocorrect's commits use the same record ("Commit record",
[Word autocorrect](#word-autocorrect)).

**Swipe trace** (`SwipeTrail`). While a touch is a swipe, the key area draws
a trail of the last 0.15 s of samples (at least the last two), above the keys
and taking no touches: a round-capped stroke in the tint color that tapers
from 8 pt at the finger to nothing and fades from 45% opacity to transparent.
It follows every move, and fades out over about 0.15 s when the swipe ends or
is cancelled (at once with Reduce Motion). It is drawn from the samples in
memory only.

**Privacy.** Swipe samples, candidates and decoder state stay in memory. They
are never logged, stored or sent, and nothing is learned from them.

### Soft key edges

A tap near a key's edge may type the likelier neighbour, which a small
character model predicts from the text before the caret. A tap near a key's
centre always types that key.

- **When.** On while `softKeyEdgesEnabled` is on (default on;
  [Shared settings](#shared-settings-sharedlocalflowsettingsswift)) and the
  bundle has a valid `tap` section whose default model has loaded. The
  keyboard reads the switch when it appears. Without Full Access it cannot
  read settings, and soft key edges are off. They are also off in secure
  text entry. While they are off, a tap types its nearest key.
- **Which taps.** Only a character tap on the letters layer by a finger that
  touched down on a letter key (`Role.character`, not a slide). A skid is a
  tap here ([Swipe typing](#swipe-typing)); swipes are not affected. Space,
  delete, Return, Shift, the layer keys and the globe are never re-decided,
  and taps on them never become letters. A re-decided tap types a letter or
  a space.
- **Soft taps.** `KeyTouchModel.softTapsEnabled` is true while soft key edges
  or autocorrect has its model loaded, outside secure text entry. Such a
  tap carries its touch-down point. With soft key edges off it types its
  nearest key; autocorrect still records the point
  ([Word autocorrect](#word-autocorrect)).
- **Decided at touch-down.** The key is decided right after the touch-down's
  effects, once earlier fingers have committed (rollover). The key area asks
  `KeyAreaViewDelegate.keyArea(_:decideTap:x:y:field:)` and records the
  answer with `KeyTouchModel.decideTap(_:as:)`.
  - The callout shows the decided key, over that key. A space has no
    callout.
  - At release or rollover the tap emits `.typeDecided(key, x:, y:, field:)`.
  - A tap with no decision emits `.tap(KeyAction, x:, y:, field:)` with its
    nearest key and touch-down point, and is decided when it types. If soft
    taps are off by then (a secure field), the nearest key types.
  - If the keys move under the touch-down point before the tap types (a
    resize or a rebuild of the letters layer), so that its nearest key is no
    longer the one recorded at touch-down, the recorded key types. A decision
    goes back to the recorded key, which the callout then shows too.
  - A finger held through a change of the letters layer's geometry keeps its
    key (or decision) but types with no point (`.type`), and is not
    re-decided.
- A tap bound to another identified field is not predicted (the editor
  refuses it).

**Decision** (`TapDecoder`, pure; reference: localflow-swipe `tap/decide.py`,
rule "strict", and `tap/touch.py`). Lengths are in letter pitches: the
distance between neighbouring top-row letter centres. The touch model and the
rule are the bundle's `tap` section's.

- **Centre box.** If the touch-down point is inside the nearest key's frame
  shrunk about its centre to `centre` of its width and height, the nearest
  key types. The nearest key and its frame follow
  [Reach and touch regions](#reach-and-touch-regions).
- **Otherwise** score = log prior + log touch likelihood for every letter and
  the space bar, and the best replaces the nearest key only if:
  - its score beats the nearest key's by at least log(`margin`) (posterior
    odds of `margin`:1)
  - the recent surprise is at most `max_surprise`
- **Touch likelihood.** A tap aimed at a key lands at its centre plus
  (0, `offset_y`) plus noise. The noise is a mixture: weight
  1 − `tail_weight` of a Gaussian with sd (σ, σ·`ratio`), and `tail_weight`
  of the same scaled by `tail_scale`. For the space bar the target is uniform
  along the middle `space_spread` of its width. The likelihood ignores the
  nearest-key penalties, so a tap in the gap above the space bar may still
  type a space when the text strongly predicts one.

**Prior** (`TapPrior`, pure; reference: localflow-swipe `tap/neural.py` and
`tap/export_ios.py`):

- **Context.** The text the character would follow
  (`KeyboardEditor.tapPriorContext`): the text before the caret as the editor
  knows it, plus the space the editor would insert first after a swiped word
  ("Space before a tapped word", [Swipe typing](#swipe-typing)). That text is
  the proxy's `documentContextBeforeInput`, or the typing tail while the
  proxy has not yet shown the keyboard's own edits, so a tap decided right
  after a rollover follows the letter just typed.
  - The typing tail counts only in the field it was typed in: if the proxy
    already serves another field, before any callback reports it, the
    proxy's text is the context. Fields without an identity cannot be told
    apart, as everywhere in the keyboard: while neither has one, the tail
    counts.
  - It is normalized as `normalize_context`: only the current line counts
    (after the last line break); accents are dropped (NFKD, combining marks
    removed), the text is lowercased, and curly apostrophes and backticks
    become "'"; a–z, space and "'" stay, any digit becomes "0", `. ! ?`
    become "." and anything else becomes "#"; whitespace runs become one
    space, leading whitespace is dropped, and trailing whitespace stays as
    one space.
- **Model.** A one-layer character GRU in the "LFTP" version 1 file format
  (`tap/export_ios.py`). A context shorter than its `context_length` is read
  as BOS then the context; a longer one as its last `context_length` symbols
  from a zero state. The prior is log_softmax(logits / temperature) over a–z
  and space.
- **Recent surprise.** The mean, over the context's last `surprise_window`
  letters and spaces, of −log2 P(that character | the context before it),
  each computed the same way; 0 when there are none.
- **Running.** The prior runs on the main thread when a tap is decided. It
  caches log probabilities by normalized prefix in memory (at most
  `TapPrior.cacheLimit`, 64 entries), bound to the field they came from, so a
  typical tap costs one GRU step. Matrix products use Accelerate.
- **Parity.** `iOS/Tests/TapFixtures.swift` is generated by
  `python -m tap.export_ios fixtures` from synthetic weights, contexts and
  taps.

**Bundle** (`SoftKeyEdgesManifest`). The models ride in the swipe bundle as
`tap/gru-*.bin`, listed with their SHA-256 in `bundle.json` like every other
file, with an optional `tap` section:

- `format` 1
- `models`: size name to path, e.g. `"67k": "tap/gru-e32-h128.bin"`; at least
  one, each path inside the bundle
- `default_model`: one of `models`
- `touch`: `sigma`, `ratio`, `offset_y`, `tail_weight`, `tail_scale` and
  `space_spread`; all finite, `sigma`, `ratio` and `tail_scale` above 0,
  `tail_weight` in [0, 1), `space_spread` in (0, 1]
- `rule`: `centre` (0.3–0.9), `margin` (1–10), `max_surprise` (2–8 bits) and
  `surprise_window` (1–64)

The keyboard runs `default_model` with the touch model and rule as given;
there are no settings for them. A bundle without the section has no soft key
edges, and an invalid section, or a model file that is missing or invalid,
turns off soft key edges only, never the swipe bundle. The default model
loads off the main thread when the keyboard appears with the switch on; until
it has loaded, taps type the nearest key. The load is bookkept by
`ModelLoadSlot` (KeyboardCore): appearing again while it is in flight, as when
switching to the emoji keyboard and back, starts no second load. Turning the
switch off drops the model and discards a load that ends while it is off; a
load still in flight when the switch comes back on is kept and installed. A load
that failed or was discarded is tried again the next time the keyboard
appears with the switch on.

**Privacy.** The context, its normalized form, the cache and every prediction
stay in the instance's memory. They are dropped when the keyboard hides or the
field changes, and are never logged, stored, sent or learned from. The models
are fixed; nothing on the device trains them.

### Word autocorrect

When a commit key types right after a word the keyboard typed, the word may
first be replaced by a lexicon word. A Delete right after puts the typed word
back.

- **When.** On while `autocorrectEnabled` is on (default on;
  [Shared settings](#shared-settings-sharedlocalflowsettingsswift)) and the
  bundle has a valid `autocorrect` section whose default model has loaded.
  The keyboard reads the switch when it appears. Without Full Access it
  cannot read settings, and autocorrect is off. Until the model has loaded,
  words commit as typed.
- **Commit keys.** Space, Return, or one of `. , ! ? ; :` (from any layer).
- **The word** is the keyboard's own ("Owned words" below): the run of letters
  and apostrophes it typed, without leading or trailing apostrophes
  (`tap/words.py` `tokens`).
- **Not corrected** when:
  - the keyboard does not own it: text it did not type, a swipe, or anything
    in between that could have moved the caret;
  - it holds a character other than a–z, A–Z and apostrophes;
  - it was reverted earlier in this keyboard instance ("Revert" below), or it
    is a never-correct word ("Never correct" below);
  - text is selected (the commit key replaces the selection);
  - the field is secure text entry, or turns autocorrection off
    (`autocorrectionType == .no`, as SwiftUI's `.autocorrectionDisabled()`
    does). `.default` and `.yes` are corrected.

**Owned words** (`WordTapRecord`). A word is corrected only if this keyboard
typed every character of it, in this keyboard appearance and this field,
right after a space or commit key (any character other than a letter or
apostrophe) it also typed. Nothing may come in between: no caret move,
trackpad gesture, selection change, host-reported text change it did not
make, swipe, dictation, undo, or hiding and showing.

- **Field start.** The start of a field counts as such a boundary only where
  the keyboard sees the field empty (nothing before or after the caret,
  nothing selected): when it appears, when another field becomes current, and
  after a host-reported change (a field the host emptied).
- **The record is the word.** The record holds the word's characters as
  typed, outer apostrophes included, each with the touch-down point of the
  tap that typed it (key-area points), or none (another layer). It is the
  source of truth: the word is never read from the proxy. Only the text
  before it, for the word model's context, comes from the editor's text
  before the caret.
- **Points.** A tap is recorded with the key it typed, after soft key edges
  decided it. With autocorrect on, letter taps are soft taps and carry their
  point ([Soft key edges](#soft-key-edges)). When the letters layer's
  geometry changes between the taps and the commit key (a resize, a
  rotation, the globe key shown or hidden), the record keeps its characters
  and every recorded point becomes none, as do the points a pending revert
  would restore. Points are never rebased.
- **Deletion.** Delete within the word removes its last characters. Deleting
  past the word's start, or any other edit, leaves no word owned until the
  keyboard's next own separator.
- **Owned and shown by the host.** A correction also needs the proxy's current
  `documentContextBeforeInput` to end with exactly the owned word, because a
  host may reject typed characters (HTML `maxlength`, a native length limit).
  If the word did not start at the field's start, the character before it
  must be the separator the keyboard typed; at a field's start, the reading
  must be exactly the word. A missing, lagging or different reading vetoes
  the correction: the commit key types as usual and the word is disowned.
  This check only ever blocks a correction. **A lagging proxy means a missed
  correction, never a wrong one.**
- **Replacement.** The correction deletes exactly the word's characters the
  keyboard typed (and any apostrophes after them), counted from the record,
  so it never touches text the keyboard did not type, wherever the host has
  the caret. Trailing apostrophes stay after the replacement. The correction
  is inserted first, then the commit key's text as its own `insertText`, so a
  host that acts on `text == "\n"` (Send, Next) still sees Return alone.

**Correction** (`Autocorrector`, pure; reference: localflow-swipe
`tap/autocorrect.py`, the contract there, which this port matches on the
generated fixtures). Inputs: the normalized context before the word
(`TapPrior.normalizeContext`), the word lowercased (a curly apostrophe as
"'"), its points (none for characters without one), the letters layout
(`[PlacedKey]`), the touch model (`TapDecoder.TouchModel`) and
`AutocorrectParams`. Output: the word to commit, the typed word itself (keep)
or a lexicon form.

- **Candidates:** lexicon keys within optimal-string-alignment distance
  `maxEdits` (`maxEditsShort` for words of at most `shortLength` letters).
- **Score:** channel (touch likelihood of each tap at the aligned letter, plus
  omission, insertion and transposition costs; insertions expect a repeat of
  the previous letter or a slip onto its neighbours; with `wSpelling` > 0
  each edit may also be a spelling error, "Spelling channel" below) +
  `lmWeight` × word-model log probability given the sentence's previous
  words.
- **Margin:** the best replaces the word only if it beats keeping the word by
  log(margin): `marginOOV` for a word outside the lexicon, `marginKnown` for a
  lexicon word, `marginApostrophe` when the best is the same word with
  apostrophes ("cant" → "can't"). An infinite margin never replaces.
- **Keep.** A result equal to the typed word ignoring case keeps the word.
- **Case.** The result is lowercased, then takes the typed word's case: all
  capitals (two letters or more) → all capitals; a capital first letter →
  capital first letter; otherwise lowercase.

**Word models** (`WordModel`; reference: `tap/wordlm.py`, `tap/wordlstm.py`).
All give log P(word | the sentence's previous words) over the lexicon's forms
plus "<unk>" and "</s>", and cache by sentence context:

- `unigram` (W0): the lexicon's AOSP frequencies; no file.
- `ngram` (W1): an interpolated Kneser-Ney word trigram, pruned to a size
  budget; "LFWN" file.
- `lstm` (W2): a small word LSTM with tied embeddings; "LFWR" file. Matrix
  products use Accelerate.

The binary formats ("LFWL" lexicon, "LFWN", "LFWR", "LFWE" spelling tables)
are defined in localflow-swipe `tap/export_word_ios.py`, little-endian, and
read by mapping the file (the tables are not copied into memory; the small
LFWE tables are widened to Double once). Parity:
`iOS/Tests/AutocorrectFixtures.swift` is generated by
`python -m tap.export_word_ios fixtures` from synthetic lexicons and models.

**Spelling channel.** The channel above models the finger: a tap far from the
intended key, a doubled or slipped letter. The spelling channel adds a second
explanation of each edit: the writer misspelled the word and the finger typed
it as aimed. Reference: localflow-swipe `tap/autocorrect.py` ("Spelling
channel") and `tap/spelling.py` (`SpellingTables`); this port matches it on
the fixtures and on a brute-force transcription in the tests.

- **Tables** (`SpellingTables`): natural-log edit probabilities, letters a–z
  0–25 and 26 for the start of a word (START): `sub[c, x]` (x typed for
  intended c), `dele[p, c]` (c left out after p), `ins[p, x]` (x typed extra
  after p), `trans[c, d]` ("dc" typed for "cd"). The `sub` and `trans`
  diagonals are −∞; every other entry is finite and at most 0.
- **Score.** With `wSpelling` > 0 and tables, each step of an alignment that
  is an edit scores logaddexp(motor, log `wSpelling` + spelling), motor its
  score above and, with m = log(1 − pOmit − pInsert − pTranspose) and t(x)
  the step's tap's touch log likelihood at key x (0 for a letter without a
  tap typed as x):
  - typed x at candidate letter c ≠ x: m + `sub[c, x]` + t(x) (a letter
    without a tap can be a substitution through this term only);
  - candidate letter c omitted after candidate letter p (START for the
    first): `dele[p, c]`;
  - typed x inserted after candidate letter c (START before the first; the
    motor term still judges it against the first): m + `ins[c, x]` + t(x);
  - candidate letters p, c typed as c, p: 2m + `trans[p, c]` + the motor
    term's two touch log likelihoods.

  A match has no spelling alternative, so keep's score is unchanged. Edits
  count against the limit as before. Suggestions rank the same scores.
- **Off is exact.** `wSpelling` 0 (the default) ignores the tables: the
  scores are the motor channel's, bit for bit.
- **Invalid weights.** A negative, NaN or infinite `wSpelling` keeps every
  word. A corrector without tables ignores `wSpelling` and scores motor-only;
  the bundle checks keep a preset from reaching that.
- **Data.** The tables are aggregated edit probabilities learned in
  localflow-swipe from Wikipedia's "Lists of common misspellings/For
  machines" (CC BY-SA 4.0) and the Aalto typing37k dataset (Palin et al.
  2019). No word or sentence of either ships.
  `Resources/Swipe/LICENSE-spelling-data.txt` credits both and rides in the
  bundle with the other licences.
- **Cost.** The omission and transposition terms mixed with the motor costs
  are computed once per parameters and cached, and three rows of 26 per typed
  letter once per word, before the candidates are scored. The alignment's
  inner loops only read them, with no allocation.

**Commit record.** A commit that shows the strip or arms a revert (below)
records its edit in the editor's `ExpectedDocument`, the same record as a
swiped word's ("Swipe anchors", [Swipe typing](#swipe-typing)): the deleted
word and the inserted correction (or nothing), then the commit key's text,
witnessed by the strip's word (the correction when one was made) followed by
the commit key's text. The strip and the pending revert share that one
record, so the editor holds at most one between calls, the swipe anchors'
included. "The record holds" below means the swipe anchors' rule for it.

**Revert.** Delete pressed right after an autocorrection, with nothing typed
or moved in between, replaces the correction and its commit key's text with
the typed word, the caret right after it. It deletes only what the keyboard
inserted.

- It applies only in an identified field with the identity the correction
  was made in, while the commit record holds. Return never arms a revert, as
  it can move focus before the proxy reports the next field. Otherwise Delete
  is a plain Delete.
- A revert restores the word's record, owned, and remembers the typed word,
  lowercased, as reverted for the life of the keyboard instance (in memory,
  across hiding). Reverted words are checked before the corrector is asked.
- Any other key action (Shift and layer keys included), a swipe, dictation, a
  caret move, the trackpad, a field change and hiding end the pending revert.
- A revert never stores the word; it makes the "Never correct" offer (below).

**Suggestion strip.** After a commit key other than Return (which may move
focus), the candidate strip ([Swipe typing](#swipe-typing)) shows what
autocorrect considered:

- **Its words:** the typed word first, then the correction (if any), then the
  corrector's suggestions, up to three, each in the typed word's case with
  its trailing apostrophes. The word in the field is emphasized.
- **When:** only when there is a choice: a correction was made, or the word
  is outside the lexicon and has suggestions. A lexicon word kept as typed
  shows no strip, so ordinary typing keeps the chips.
- **Suggestions** (`WordCorrecting.suggestions`): the lexicon forms ranked
  exactly as the correction ranks its candidates (channel + `lmWeight` ×
  model log probability; ties to the higher frequency, then the first form),
  with no margin. None for a lexicon word, or where the corrector keeps the
  word without looking. The best suggestion is the correction whenever there
  is one.
- **A choice** replaces the word and puts the commit key's text back after
  it, while the commit record holds; otherwise the tap does nothing and the
  strip closes. Choosing the typed word over a correction is a revert (it is
  remembered as one); choosing the correction back undoes that. A choice ends
  the pending revert. The next word is still the keyboard's own.
- **Closing:** any key closes it, as after a swipe. Delete deletes one
  character (or reverts a correction), never the whole word.

**Never correct.** A revert offers to keep the word uncorrected for good, and
nothing is stored unless the user accepts:

- **The offer** (`KeyboardEditor.neverCorrectOffer`): right after a revert (a
  Delete right after a correction, or the typed word chosen on the strip),
  the top row shows a chip, `Never correct “Kanye”`: the word as typed,
  without trailing apostrophes. Only with a store bound (below) and a word
  the store can keep.
- **Where:** in the middle of the top row, over the chips, the status line
  and the candidate strip, which after a strip revert stays open underneath
  and shows again only if the offer goes without anything else closing it.
  Dictation's own UI wins (`NeverCorrectOffer.barShows`): while a dictation
  is starting, recording or transcribing, or its Undo chip shows, the offer
  is not shown, and it still ends as below.
- **Accepting** (`acceptNeverCorrect`) adds the word to the store, makes the
  words in memory what the store now holds, ends the offer and closes the
  strip. The word is then never corrected or offered, in this instance and
  every later one, in any case, and the corrector is not asked.
- **Ending without storing:** any key action (a Delete after the revert,
  Shift and layer keys included), another strip choice (the correction chosen
  back), a swipe, dictation or its undo, the trackpad, a caret move or outside
  edit, another field, and hiding. A rotation and the host's echoes of the
  revert do not end it. It has no timeout.
- **The store** (`NeverCorrectStore`, Shared): one JSON file,
  `{"schema": 1, "words": [...]}`, least recently added first, at
  `<App Group container>/Library/Application Support/LocalFlowAutocorrect/never-correct-words.json`.
  The directory is created excluded from backup (best effort, as for the
  dictation store), so the words stay on this iPhone. Data protection class A
  on devices: while locked a read gives no words and a write fails, leaving
  the file as it was.
- **Bounds:** at most 1,000 words (`NeverCorrectWords.limit`); adding one past
  that drops the least recently added, and adding a stored word again makes
  it the most recent. Only words as the corrector sees them: 1–48 characters
  of lowercase a–z and `'`, starting and ending with a letter. A longer word
  is reverted for the instance, without an offer.
- **Robust:** writes go to a staging file renamed over the file, so a reader
  sees the old or the new list; a failed write leaves the file as it was, and
  the words in memory still hold the accepted word. A missing, unreadable,
  corrupt or oversized (over 256 KB) file, or another schema, reads as no
  words, and the next accepted word replaces it; invalid or repeated entries
  in a valid file are dropped. A write first reads the file, so a clear made
  since is kept. Staging files a crashed write left (older than a minute) go
  at the next write.
- **Serialized:** an add (its read, change and write) and a clear each hold
  an exclusive advisory `flock` on
  `Library/Application Support/.never-correct.lock`, beside the store's
  directory, so a clear (which removes the directory) keeps it. The app and
  the keyboard open the same file in the App Group, so a clear never lands
  between an add's read and its write, and a cleared word comes back only
  with a new tap. The lock is held for one small read and write, never across
  a suspension; if the lock file cannot be opened the operation runs
  unlocked. Reads take no lock.
- **Loading:** the keyboard binds the store (`useNeverCorrectStore`) each time
  it appears with autocorrect on, which loads the words and replaces those in
  memory. With autocorrect off or without Full Access it binds none and holds
  none of them.
- **Clearing:** Diagnostics' "Autocorrect" section has "Forget never-correct
  words (N)", with N the stored count. The app reads only the count, never
  the words, when the section appears and each time the app becomes active.
  The button is enabled even at a count of 0 (whenever the App Group is
  available), since the count can be stale and a clear also removes a corrupt
  or staging file that reads as no words. It removes the
  store's directory. The keyboard is the file's only writer and the app only
  removes it. A keyboard instance still in memory picks the clear up the next
  time it appears; its own reverted words hold until the instance ends.

**Bundle** (`AutocorrectManifest`, `AutocorrectLoader`). The files ride in the
swipe bundle like the tap models, listed with their SHA-256 in `bundle.json`,
with an optional `autocorrect` section:

- `format` 1
- `lexicon`: path of the LFWL file
- `models`: name to `{"kind": "unigram" | "ngram" | "lstm", "path": ...}`;
  `default_model`, one of them
- `presets`: model name to preset name to a params object (`p_omit`,
  `p_insert`, `p_transpose`, `max_edits`, `max_edits_short`, `short_length`,
  `min_length`, `lm_weight`, `log_oov`, `margin_oov`, `margin_known`,
  `margin_apostrophe`, `w_repeat`, `w_slip`, optionally `w_spelling`;
  `null` margins are infinite, and a missing `w_spelling` is 0);
  `default_preset`
- `touch`: optional; the touch model the corrector assumes, else the `tap`
  section's, else `TapDecoder.TouchModel.standard`
- `spelling`: optional; path of the LFWE spelling tables

The keyboard runs `default_model` with its `default_preset` preset as given;
there are no settings for the model, the preset or the parameters. The
section's checks:

- Every path stays inside the bundle. A `unigram` model has no path; the
  others must have one.
- Every model has presets, which include `default_preset`, and no preset
  names a model the section lacks.
- Each preset's values are in their domains: probabilities in (0, 1),
  margins ≥ 1 or null, edits 0–3, lengths 1–32, `log_oov` < 0, `w_repeat` +
  `w_slip` at most 1, `w_spelling` finite and ≥ 0.
- A preset with `w_spelling` > 0 needs a `spelling` file.
- The loader reads the LFWE file strictly (magic, version, exact length,
  every value in the tables' domain).

An invalid section, or a named file that is missing or invalid, means no
corrector. It never turns off the swipe bundle or soft key edges. The default
model loads off the main thread when the keyboard appears with the switch on,
at most once at a time, like the soft key edges model (`ModelLoadSlot`,
[Soft key edges](#soft-key-edges)).
A correction runs on the main thread at the commit key.

**Privacy.** The context, the word, its points, the strip's words, the
reverted words and a "Never correct" offer stay in the instance's memory. They
are dropped when the keyboard hides (the reverted words when the instance
ends), and are never logged, stored, sent or learned from, with one
exception: a word the user taps "Never correct" for is stored on this iPhone
only, in the never-correct store, until the user clears it in Diagnostics. The
app reads only the count. The models are fixed.

## Build and targets (iOS/Makefile)

- `make -C iOS` builds `iOS/build/<platform>/LocalFlow.app` with
  `PlugIns/LocalFlowKeyboard.appex`. The default platform is the arm64
  simulator; `PLATFORM=device` builds for arm64 devices.
  - Both are compiled for `arm64-apple-ios26.0[-simulator]` with
    `-Xcc -DACCELERATE_NEW_LAPACK`, because the iOS 26 SDK deprecates the
    CBLAS interface the shared decoder uses.
  - The keyboard is compiled with `-application-extension`, the
    `_NSExtensionMain` entry point and module `LocalFlowKeyboard`.
  - Simulator builds embed the entitlements in each executable's
    `__TEXT,__entitlements` and `__TEXT,__ents_der` sections. The `.appex` is
    signed before the app.
  - Every build compiles the app icon into `Assets.car` with `actool`,
    records Xcode's build metadata (`DTXcode`, `DTSDKBuild` and the rest) in
    both Info.plists, and copies each target's privacy manifest.
- `PARAKEET_BUNDLE_DIR` copies the model into `LocalFlow.app/Parakeet/` and
  relabels it with `scripts/label-localflow-model.py`; repeat builds keep an
  unchanged copy. `SWIPE_BUNDLE_DIR` adds swipe typing
  ([Swipe typing](#swipe-typing)).
- `make -C iOS check` runs:
  1. a simulator type-check, with `-warnings-as-errors`, of the app, the app's
     self-test variant and the keyboard;
  2. the host tests ([Testing and verification](#testing-and-verification));
  3. lint: `plutil -lint` of the plists, entitlements and privacy manifests,
     and `sh -n` of `scripts/*.sh`.
- `make PLATFORM=device binaries` compiles and links without signing. Device
  builds need `CODESIGN_IDENTITY`, `TEAM_ID` and two provisioning profiles
  with the App Group; the build checks each profile's App ID and App Group
  (README).
- The app declares the `audio` background mode, is iPhone-only
  (`UIDeviceFamily` 1) and arm64-only. The keyboard is universal (1 and 2),
  because App Review requires every extension to be universal, and requests
  Full Access (`RequestsOpenAccess`).
- The repository's CI runs the macOS `make check` only. The iOS checks run
  locally.

### App Store packaging

`CHANNEL=appstore` builds the production app, still with `swiftc` and Make.

- **Identity.** The production identifiers ([Identifiers](#identifiers)), the
  production icon and a device build into `build/appstore/`. It refuses the
  self-test variant and a build without the model, and accepts only App Store
  distribution profiles (no devices, no `get-task-allow`). The bundle ID is
  permanent from the first upload.
- **Signing.** Entitlements come from the profile, plus
  `beta-reports-active` when the profile grants it (TestFlight needs it),
  signed with an Apple Distribution identity.
- **Versions.** `CFBundleShortVersionString` stays in the Info.plist
  templates, the same for app and keyboard. `BUILD_NUMBER` sets
  `CFBundleVersion` for both and must grow with each upload.
- **Metadata.** `ITSAppUsesNonExemptEncryption` is false: the only
  cryptography is SHA-256 for model verification. Both executables require
  `arm64` in `UIRequiredDeviceCapabilities`.
- **Icon.** The build flattens the production icon source, a full-bleed
  square in `Resources/` ([Resources/ICON.md](Resources/ICON.md)), and scales
  it to one opaque 1024-pixel image.
- **Privacy manifests** (`Config/*-PrivacyInfo.xcprivacy`, one per target):
  no tracking, no tracking domains, no collected data. Required-reason APIs:
  UserDefaults (`CA92.1` for the app's own preferences, `1C8F.1` for the App
  Group settings; the keyboard declares only `1C8F.1`), system boot time
  (`35F9.1`, elapsed-time measurement) and file timestamps (`C617.1`,
  expiring the App Group's dictation files and the never-correct store's
  leftover staging files). A new use of a required-reason
  API must be added to the manifest and to the checker's required reasons.
- **Packaging.** `make ipa` zips exactly the signed app under `Payload/`.
  `make appstore-check` runs `scripts/check-appstore-bundle.sh` on the app
  inside the `.ipa`; that script is the packaging contract. It reads only the
  build and lists every failure (README lists what it checks).
  `appstore-validate` and `appstore-upload` run `xcrun altool` with an App
  Store Connect API key that is never stored in the repository. They are the
  only targets that contact Apple, and no other target runs them.
- **Not covered here:** the App Store listing, the privacy label, review
  notes on the keyboard opening the app and on the background microphone, and
  the account steps (App IDs, distribution certificate, profiles, app
  record).

## Privacy and security invariants (review checklist)

1. Audio is never written to disk. Between dictations, capture buffers are
   dropped in the tap callback. "Find strength" recordings stay in memory.
2. A transcript exists on disk only as one `result-R.json` (or, for the
   moment between write and rename, its staging file) in the App Group's
   `Library/Caches`, excluded from backup, and is deleted on claim, on expiry
   by either process, or on a run change. There is no history.
3. There are no network APIs, no telemetry and no logging in any iOS target.
   The only output is the self-test build's content-free `LocalFlow
   self-test:` lines.
4. URLs and Darwin notifications carry no authority. A URL can never start
   capture.
5. The keyboard reads `documentContextBeforeInput`,
   `documentContextAfterInput`, `documentIdentifier` and whether text is
   selected in memory only, for spacing, result binding, shift, cursor
   movement, word deletion, Undo, swipe insertion, predicting the next letter
   (soft key edges) and correcting the word before the caret (autocorrect).
   It never stores, logs or transmits them, and drops them when the operation
   ends or the keyboard hides. What it persists about fields is content-free:
   trait fingerprints and layout choices.
6. Capture requires a session started in the foreground. Recording requires a
   fresh keyboard intent that the host admits. Recording ends at the maximum
   duration or when the keyboard has been gone too long. Device lock cancels
   a dictation in progress and admits none until unlock; the session ends at
   idle expiry.
7. Custom dictionary entries live only in the host app's own `UserDefaults`,
   never in the App Group, a log or a bug report.
8. A bug report is a draft the user reviews and sends; it carries only version
   and generic device metadata.
9. The only words the keyboard stores are those the user taps "Never correct"
   for, in the never-correct store on this iPhone until the user clears it;
   the app reads only their count ("Never correct",
   [Word autocorrect](#word-autocorrect)).

## Testing and verification

### Host tests (`make -C iOS test`)

- The host test binary is compiled for macOS from `Shared/`, `HostCore/`,
  `KeyboardCore/`, `Keyboard/SwipeEngine.swift` (with a fake encoder),
  `Keyboard/AutocorrectLoader.swift`, `Sources/Dictionary/*.swift`,
  `Sources/Parakeet/LocalParakeetCore.swift`,
  `Sources/Parakeet/ParakeetSilenceCompactor.swift` and `Tests/`. Every pure
  rule in this contract has tests there. They use synthetic fixtures only.
- `FakeTextHost` models the measured proxy: UTF-16 or grapheme offsets,
  offsets past either end ignored, context windows (whole, UIKit's sentences,
  line-break-only, or a fixed grapheme window), lagging adjustments,
  provisional contexts, WebKit's double reports, and a lone surrogate half
  shown as U+FFFD.
- **Typing torture** (`TypingTorture`, in the KeyboardEditor suite) runs
  seeded scripts of taps, holds, rollover, Shift, layers, delete, trackpad
  gestures (with keys, outside changes and hiding while they settle), focus
  changes, hiding and the host app's own edits, against hosts with lagging
  adjustments, late or missing callbacks, WebKit's double reports and lagging
  contexts, checked by an independent oracle. The document must equal the keys applied in
  the order they act (characters, space and Return at release or rollover),
  each edit is asserted right after the event that typed it, and every
  gesture no key interrupted must end on a character boundary. `make check`
  runs seeds 1–60 plus the seeds earlier stress runs found failing;
  `TORTURE_SEEDS=first-last` runs another range.

### Simulator

- `make -C iOS smoke-sim` builds the self-test variant, installs it on a
  dedicated simulator and transcribes `say`-generated synthetic speech
  (README).
- `make -C iOS e2e-sim`, `e2e-sim-probe` and `e2e-sim-scenarios` drive the
  protocol end to end with the synthetic microphone: the keyboard's side is
  played through the App Group files, and the scenarios cover cancel,
  kill-and-relaunch (the request is reported interrupted and never restarts),
  and fresh and stale URL hints. The Mac microphone is never used.
- With the synthetic microphone, Sol through computer use or a person at the
  simulator covers: enabling the keyboard and Full Access, first-run
  onboarding, the bounce and adoption, field binding (Try it field A, then
  field B mid-request), cancel, the host terminated during recording, and
  idle expiry.
- The simulator has no Neural Engine; it runs the encoder on the CPU and
  prepares it on every cold launch (about 72 s and 840 MB), so simulator
  timings say nothing about devices.

### Manual verification

These need a person at a device. The checklist with results is in the
README's "Manual tests"; changes touching these areas must record them before
merge (AGENTS.md).

- **Session and protocol:** onboarding; the bounce on iOS 26 and 27
  ("Listening" only once audio flows, swipe back, the dictation inserts);
  session keep-alive and idle expiry; field binding (dictate into Try it field
  A, switch to field B mid-request: no auto-insert into B, and the chip
  appears); kill during recording; a phone-call interruption; a Bluetooth
  route change; device lock (indicator on the lock screen, a dictation
  cancelled at lock, dictation from another app after unlock without opening
  LocalFlow, a session that idles out while locked, then the first bounce
  after unlock starting a new session).
- **Resources:** background transcription latency and peak memory, Neural
  Engine against CPU (CPU through the self-test); no jetsam in the
  background; battery over 30 minutes, idle session against no session
  (and against Wispr Flow if installed); result cleanup after a forced kill.
- **Keyboard** (side by side with Apple's keyboard in Try it → Cursor
  practice): hold-to-trackpad delay; slow drags landing between each pair of
  letters and fast swipes travelling similar distances; vertical moves across
  soft-wrapped, short and blank lines keeping the column; held delete
  switching to words; shift, caps lock, auto-capitalization, the double-space
  period, `123`/`#+=`, emoji and accent deletion; two-thumb rollover; Notes,
  Messages, Mail and Safari fields (trackpad units, context windows, Undo);
  trackpad cancel and hide over emoji and combining marks; haptics only with
  Full Access; VoiceOver labels; dark mode; landscape; SE-size layout; iPad
  (the keyboard is universal, the app runs in iPhone compatibility mode).
- **Swipe typing:** recognition, the candidate strip, the trace, and spacing
  around tapped words.
- **Touch regions:** fast taps on the top and bottom rows, and taps in the bar
  outside its controls, type without dropped letters; the Start capsule and
  the chips still take their taps; a quick skid types its key; a low tap
  above the space bar types the bottom row; delete takes taps just right
  of M.
- **Soft key edges and autocorrect:** the Home switches (applied when the
  keyboard next appears; off without Full Access); edge taps typing the
  likelier neighbour and centre taps never re-decided; corrections at each
  commit key and their case; revert, the strip after a commit key, the
  "Never correct" offer, a kept word surviving a keyboard restart, and the
  Diagnostics forget button; swiped words and password fields left alone;
  Notes, Messages, Safari and a WebKit field with a lagging proxy.
- **App:** privacy policy link; Report a bug draft and its no-email-app
  fallback; dictionary edits and "Find strength".

### Reference measurements

iPhone 15 Pro, iOS 26.6.2, 2.42 s of invented synthetic speech:

| Compute | Preparation | Transcription | Peak footprint |
| --- | --- | --- | --- |
| Neural Engine, first launch after install | 67.2 s | 0.049 s | 165 MB |
| Neural Engine, later launch | 0.69 s | 0.040 s | 166 MB |
| CPU only (self-test only) | 60.7 s | 0.519 s | 3229 MB |

Neural Engine specialization is cached across launches of one install, so the
cold cost is paid once per install, and onboarding shows it.
