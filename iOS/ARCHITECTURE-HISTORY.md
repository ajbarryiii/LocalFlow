# LocalFlow for iPhone: architecture history

This file is a record, not a contract. [ARCHITECTURE.md](ARCHITECTURE.md) is
the contract and states every rule as it holds now; where this file and the
contract differ, the contract wins.

Until 2026-10-19, ARCHITECTURE.md grew as a chronological log: dated
decisions, review-round notes and contract changes were appended, and later
entries superseded earlier ones without editing them. When ARCHITECTURE.md was
rewritten as a current-state contract, those entries moved here verbatim, in
their original order, so the reasons, measurements and residual risks behind
each rule are kept. The only edits are two local filesystem paths of the
calibration harness and report, which are redacted. Section references inside them ("see above", "supersedes
...") point at the old document, which is in Git history as
`iOS/ARCHITECTURE.md` at commit `dda2f72`.

New entries are not added here. A change that supersedes a rule edits the
contract section that states it, and its pull request carries the reasons.


### Device lock (contract change, 2026-10-13)

The session survives a lock until idle expiry, as Wispr Flow's does. Before
this change a lock ended the session.

- **At lock** (`protectedDataWillBecomeUnavailable`): a dictation that is
  starting, recording or transcribing is cancelled with `deviceLocked`.
  Intents and results are class A and unavailable while locked, so it could
  not finish. The session, the audio session and the engine keep running.
  Buffers are dropped in the tap, as between dictations. `status.error` stays
  nil.
- **Idle expiry still applies.** The countdown is unchanged: it runs from the
  end of the last dictation (or the session start) and restarts with each
  dictation, never from the lock. A locked session ends at
  `idleSince + sessionDuration` like any other. Expiry is checked on every
  tick and before every reconciliation, so a request read after the deadline
  (as after a resume) never joins the expired session. Interruptions,
  unrecoverable engine failures and End session also still end it.
- **Capture recovery while locked** rebuilds the engine within the running
  audio session (`restart()`), as in the background, even if the app still
  reads as foreground during the lock window. The audio session is never
  reactivated while locked.
- **Locked means no dictation.** The lock notification latches a locked
  state. While locked, no intent is admitted and no session, pending capture
  or dictation starts, even if the intent file is still readable: iOS posts
  the notification before files become inaccessible. An intent read while
  locked is refused with `deviceLocked` and never admitted later. An intent
  the host could not read while locked gets only the normal freshness check
  after unlock; there is no "issued before unlock" rule, because the
  keyboard writes an intent before the host comes forward. The app checks
  `isProtectedDataAvailable` at launch, so an app launched while locked
  starts latched.
- **Unlatching.** The latch clears on `protectedDataDidBecomeAvailable`, and
  also on the `willEnterForeground` and `didBecomeActive` events themselves
  (not a derived foreground state, which can still read background during
  `willEnterForeground`) when protected data is available, before any
  admission runs, because a suspended app can miss the unlock notification.
  It is never cleared by polling during the will-become-unavailable window,
  where UIKit still reports data as available.
- **A late intent proves the unlock** (contract change, 2026-10-15). A record
  intent issued more than `lockWriteWindow` (20 s) after the latch was set
  lifts the latch and is admitted normally. No keyboard runs on the lock
  screen, and the class A intent cannot be written about 10 s after the lock
  notification, so such an intent was written on an unlocked iPhone. This
  covers a session that idles out while locked: iOS then suspends the app,
  which misses the unlock. On resume UIKit can still report protected data as
  unavailable at `willEnterForeground` and `didBecomeActive` and post
  `protectedDataDidBecomeAvailable` after them. Before this rule the bounce's
  intent was refused with `deviceLocked`, so the user had to bounce twice.
  Intents issued within the window are still refused for good.
- **Unlock: dictation continues instantly.** Nothing about the session
  restarts. The next record intent from the keyboard in any app is admitted
  into the same session without opening LocalFlow.
- **Status heartbeat:** it continues while locked. `status.json` is class C,
  so it is writable after first unlock.
- **Indicator:** iOS shows its orange microphone indicator throughout,
  including on the lock screen, until the session ends.
- **Costs accepted.** The microphone stays open at the lock screen for up to
  the session length after the last dictation, so the battery cost is higher
  than ending at lock. iOS may still terminate the backgrounded app for
  memory (jetsam), since the model stays loaded; the next dictation then needs
  the app in the foreground again.

### App Store packaging (user decision 2026-10-13)

The user wants to share v0.1 with non-technical friends through the App Store
rather than TestFlight or registered devices. Still with `swiftc` and Make, and
no Xcode project:

- **Channel.** `CHANNEL=appstore` presets the production identity:
  `com.ajbarryiii.localflow.ios` (keyboard `com.ajbarryiii.localflow.ios.keyboard`),
  App Group `group.com.ajbarryiii.localflow.ios`, URL scheme `localflow`,
  display name "LocalFlow", the production icon, and a device build into
  `build/appstore/`. It follows the macOS pattern (`.dev` for development).
  It refuses the self-test variant and a build without the model. It accepts
  only App Store distribution profiles: no devices, no `get-task-allow`.
  The bundle ID becomes permanent at the first upload.
- **Signing.** Entitlements come from the profile as for development builds,
  plus `beta-reports-active` when the profile grants it (App Store profiles do;
  TestFlight needs it). Signing uses an Apple Distribution identity, which the
  user creates in their account.
- **Versions.** `CFBundleShortVersionString` stays in the Info.plist templates
  (0.1.0), the same for app and keyboard as App Store Connect requires.
  `BUILD_NUMBER` sets `CFBundleVersion` for both, since it must grow with each
  upload.
- **Device family.** The app stays iPhone-only (`UIDeviceFamily` 1). The
  keyboard is universal (1 and 2), because App Review requires every app
  extension to be universal whatever its app's family. On an iPad it runs
  natively, while the app runs in iPhone compatibility mode, so the keyboard's
  iPad layout needs its own manual test. Both executables are arm64 only, so
  both Info.plists require `arm64` in `UIRequiredDeviceCapabilities`.
- **Metadata.** `ITSAppUsesNonExemptEncryption` is false: the only
  cryptography is SHA-256 for model verification. Both Info.plists carry the
  toolchain keys Xcode would write, from `xcodebuild -version`, the SDK and the
  build machine.
- **Icon.** The production icon source has a transparent margin and an alpha
  channel. The build crops the opaque square, flattens it (JPEG at the best
  quality) and scales it to one 1024-pixel image in an asset catalog. The
  crop is 788 pixels, so the store icon is upscaled. A source drawn at 1024
  pixels without margins would be sharper.
- **Privacy manifests** (`Config/*-PrivacyInfo.xcprivacy`, one per target):
  no tracking, no tracking domains, no collected data. Required-reason APIs:
  - UserDefaults: `CA92.1` for the app's own preferences, `1C8F.1` for the
    App Group settings. The keyboard declares only `1C8F.1`.
  - System boot time, `35F9.1`: elapsed-time measurement.
  - File timestamps, `C617.1`: expiring the App Group's dictation files.

  A new use of a required-reason API must be added to the manifest and to the
  checker's required reasons. The checker accepts only the reasons Apple
  defines for each category.
- **Packaging.** `make ipa` zips exactly the signed app under `Payload/`.
  `make appstore-check` runs `scripts/check-appstore-bundle.sh` on the app
  inside the `.ipa`, which is what Apple receives. That script is the packaging
  contract: it reads only the build and lists every failure. It also checks
  that each embedded profile is an unexpired App Store profile of the team that
  authorizes the signing certificate and grants the signed entitlements. `appstore-validate` and `appstore-upload` run
  `xcrun altool` with an App Store Connect API key, never stored in the
  repository. They are the only targets that contact Apple, and no other
  target runs them.
- **Not covered here:** the App Store listing, the privacy policy URL, the
  "Data Not Collected" privacy label, review notes on the keyboard opening the
  app and on the background microphone, and the account steps (App IDs,
  distribution certificate, profiles, app record).


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
  - No autocorrect, predictions or learned words. The one exception is swipe
    typing's candidate strip ("Typing model v4 and swipe typing").
- **Touch handling:** the key area is one UIKit touch-tracking view with
  nearest-key hit testing (no dead gaps). Characters insert on release or
  rollover, typing the key nearest the touch-down point; space and Return
  insert on touch-up ("Typing model v4 and swipe typing"). The
  same view runs trackpad mode: touch and hold the space bar, and the letters
  blank out, as on Apple's keyboard.
- **Key feedback:** every key touch-down plays the system click, which follows
  the iOS Keyboard Clicks setting. With Full Access and `keyHapticsEnabled`
  ("Typing haptics" in the app's Keyboard section), it also plays a light
  impact haptic. A keyboard extension cannot read the iOS Keyboard Feedback
  haptic setting, so LocalFlow has its own.

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
(local path redacted when this entry moved here).

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

  Full report: `calibration/REPORT.md` on the development machine (local path
  redacted when this entry moved here), outside the repository.
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

### Typing model v2: immediate execution (contract change, 2026-10-10)

This supersedes the waiting and queuing parts of "Typing correctness is
paramount" and the round 7 and 8 notes.

**Why.** Every P1 found since round 6 lived in the machinery that made typed
keys wait for trackpad verification: queues, Return barriers, identity
waits and deadlines. Each fix added more of it.

**New contract:**

- **Execution:** a key executes immediately when it is released, through
  the proxy, as on every other iOS keyboard. Keys are never queued, delayed
  or batched. The proxy serializes edits in the order they are issued.
  **Rollover** (clarified after the round-9 review): when another key
  touches down while a character key is still held, the held key commits
  first, in press order, as on Apple's keyboard. "Release order" means this
  commit order.
- **Trackpad interaction:** the touch-down of any key ends any trackpad
  settlement or verification on the spot. That includes Shift, layer keys,
  delete and Return, not only character keys. No further adjustments are
  issued for that gesture, and any probe outcome is abandoned. A held
  character still inserts at its release.
- **Late gesture reports are never echoes.** A host report that an
  interrupted or finished gesture still owes is never taken as the echo of
  a later insertion, even if the text matches.
- **Accepted residual:** if a key is typed in the same instant a probe is
  crossing a multi-code-unit cluster, the key may land inside that cluster.
  It is visible, and one delete fixes it (tested: deleting the inserted
  character restores the original cluster). This replaces the old guarantee
  that typing is never released inside a cluster.
- **Field binding:** a key goes to the field current at release. If both
  the press-time and release-time field identities are known and differ, the
  key is cancelled. A nil identity on either side does not block the key.
- **Hiding and dictation:** nothing is pending, so hiding loses nothing that
  was released. Dictation results are claimed only at the moment of
  immediate insertion.
- **Shift and double-space:** any host callback that is not a recognized
  echo of our own edit resets double-space timing and re-derives shift from
  context. UIKit and WKWebView send no echoes for our edits (measured), so in
  practice any callback resets them.
- **Undo:** unchanged and fail-closed.
- **Trackpad gestures:** the gesture keeps its internal safety machinery
  (probes, attribution, cluster repair while no key interrupts), but that
  machinery can never delay or reorder typing.

**Torture-test contract:** the document equals the keys applied in release
order at the caret positions implied by the script, with an independent
oracle. Cluster-boundary assertions apply only to gestures that no key
interrupted. Each edit is asserted right after its release, not only once
the host is quiet. For an interrupted gesture, only the first key's
position may be taken from the host's observable insertion point. Every
later key is checked exactly, case included, relative to it.

### Keyboard round 9 notes (typing model v2, 2026-10-10)

- **Implemented.** The key queue, the Return barrier, identity waits, the
  batch deadline and every wait on probes, edge jumps and cluster repairs
  are deleted (production net −286 lines). Keys run on release, and a key
  ends the gesture on the spot.
- **Field binding.** A touch or delete press made before any identity binds
  to the first field that becomes current. A later, different field ends it.
- **Late reports are not ours.** A report of a finished gesture is a
  non-echo callback: it resets shift and double-space timing.
- **Deleting past an empty model.** If the proxy still shows text this
  keyboard deleted, the typing tail stays empty rather than falling back to
  the stale reading (casing at a field's start).
- **Guard repairs only from a landed context.** The boundary guard repairs
  only once every adjustment issued so far has been reported or is overdue.
- **Torture test.** It checks release order and immediate execution. For a
  gesture a key interrupted, the caret and keys may be inside a cluster (the
  accepted residual). Letters typed into a free gesture are compared
  ignoring case, because their casing depends on where an abandoned probe
  landed. Seeds 1–12000 pass. All 18 mutations are killed.
- **Residual risks:**
  - In a field whose proxy context starts mid-text, a letter typed while
    the proxy lags, right after deleting past what it showed, is
    capitalized as at a sentence start until the proxy catches up.
  - After an outside change with a repair in flight, the guard may wait up
    to 0.3 s before repairing. A key typed then lands where the caret is.
  - The edge watch after a system cancel or hide still uses the
    once-per-context repair rule without the in-flight check (same class,
    not hit by any seed).
  - Device testing of v2 typing is pending.

### Keyboard round 10 notes (2026-10-10)

- **Key-down ends settlement.** Every accepted key except the globe emits
  `.keyDown` at touch-down. That covers Shift, layer keys, delete and Return,
  and also presses without a touch (VoiceOver). It interrupts the trackpad
  before anything else. Characters still insert at release.
- **Late reports.** A finished or interrupted session keeps the reports it
  still owes, for at most 1 s. They include double reports, rollbacks and
  repairs, and reports retired as overdue. An edit counts as an echo only if
  it predates the oldest owed report. While a gesture owes reports, a genuine
  echo counts as an outside change. That only resets timing, and no measured
  host echoes our edits.
- **Unverified readings.** After a key abandons a probe, the typing tail
  marks the proxy reading as unverified. A proxy showing what was typed
  supersedes it, and deleting into it drops it. A reading recorded before
  an edit never counts as showing that edit.
- **Edge watch.** It repairs only from a landed context, and it outlives the
  keyboard reappearing in the same field.
- **Accepted residual, tested.** One delete after a key lands inside a
  surrogate pair, or inside an emoji with a skin-tone modifier, restores
  the cluster. The fake host stores UTF-16 units and shows a lone half as
  U+FFFD, as the proxy does. Combining marks are not covered: UIKit's
  `deleteBackward` there is unmeasured.
- **Torture oracle.** Each edit is checked right after its release, and
  every key is checked exactly, case included. After an interrupted free
  gesture, only the first key's insertion point comes from the host. The
  limits:
  - Text before that point that no keyboard has seen is cased from the
    proxy.
  - Keys after free gestures are checked only on hosts that report within
    `syncTimeout` and show edits immediately.
  - The boundary check for gestures without a key is skipped on hosts
    reporting after `syncTimeout`. Those hosts are outside the trackpad's
    guarantees (round 8 residuals). The coordinator accepted this on
    2026-10-10.

  Seeds 1–12000 pass, and all 33 mutations are killed.
- **Residual risks:**
  - A jump past the window edge on a late-report host can stop inside a
    hidden cluster.
  - On hosts that show edits late, keys typed right after a key abandons a
    probe can't see the text before the insertion point.
  - The unit inference ("caret shown inside a cluster means UTF-16") can
    mislearn on a grapheme host after the accepted residual.
  - Device testing of `.keyDown` and v2 typing is pending.

### Keyboard round 11 notes (2026-10-10)

This supersedes the 1 s report retention in the round 10 notes.

- **Exact report debt.** `ReportDebt`, held by the trackpad controller,
  records every adjustment issued in a field, including rollbacks and
  repairs. Each owes one host report, or two where the host reports twice
  or is not yet known to report once. Every non-echo `textDidChange` in the
  field pays the oldest. A new gesture inherits the debt it is sure of. A
  report stays owed however late it is: there is no time-based expiry. The
  ledger is bounded at 64 entries, current field only.
- **Echo rule.** While a finished gesture still owes reports, nothing is an
  echo. While a gesture runs, only edits made before its first adjustment
  can be.
- **Oracle independence.** At an interruption, the torture oracle takes the
  field's text from the live proxy window the fake host showed, never from
  production's landing.
- **Slow hosts.** Keys around interrupted free gestures are scripted on
  late-report and late-edit hosts too. Position, count, order and text are
  checked exactly at each release. Only casing that depends on text never
  shown is taken from the host.
- **Pinned accepted risk.** A slow host can leave a jump between the halves
  of an emoji. A letter typed then lands inside it, and one delete restores
  the field. Fixtures pin this behavior.
- **Residual risks:**
  - An outside change while reports are owed pays one, so the report it
    displaced counts as outside. That only resets timing.
  - A field never learned to report once keeps phantom second reports,
    which only suppress echoes.
  - Device latency under load is unmeasured.

### Typing model v3: characters on touch-down (contract change, 2026-10-13)

This supersedes the "Execution" timing in "Typing model v2" for character
keys. Everything else in v2 stands.

**Why.** On device the keyboard often dropped letters. A character typed on
release took the key nearest the finger's last position, with no hysteresis.
A tap that rolled a few points onto space, Shift, delete, a layer key or
Return typed nothing. The bottom letter row sits 6 pt from the space bar's
hit boundary.

**New contract:**

- **Characters** insert at touch-down, after `.keyDown` and after any
  rollover commits of earlier fingers. The key is the one nearest the
  touch-down point. Moving the finger afterwards changes nothing, so a tap
  cannot drift off its key or onto a function key, and sliding to correct a
  letter is no longer possible.
- **Space and Return** still act on release (or on rollover, in press
  order). Holding space must be able to become the trackpad without typing,
  and Return still types only if the finger lifts over it.
- **Slides from a layer key** still type the character under the finger at
  release, then return to letters. The slide picks the character.
- **Field binding:** a character binds to the field current at touch-down
  and is typed there at once. Fingers already typed are never ended by a
  later field change.
- **Callouts** show the character as typed, held while the finger is down.
- **Unchanged:** Shift and layer keys on touch-down, delete repeating from
  touch-down, the trackpad hold, rollover order, and keys ignored while the
  trackpad runs.

**Torture-test contract:** "release order" now means the order keys act:
characters at touch-down, space and Return at release or rollover. Each edit
is asserted right after the event that typed it.

### Typing model v4 and swipe typing (contract change, 2026-10-15)

This supersedes the character timing of "Typing model v3". Everything else in
v3 stands.

**Why.** Swipe typing needs to tell a tap from a swipe before anything is
typed. Typing a letter at touch-down and deleting it when the touch turns out
to be a swipe would flash a letter on screen, and the user rejected that.
v3's real fix stays: the key is chosen from the touch-down point, so a tap
that drifts onto space, delete or Shift still types its own key.

**Characters (v4):**

- Touch-down on a character key emits `.keyDown` (click, haptic, callout)
  but types nothing. The key is the one nearest the touch-down point and never
  changes afterwards.
- The character types at release, or at rollover when another finger touches
  down (earlier fingers commit in press order, as before). A system-cancelled
  touch types nothing.
- **Field binding:** the character carries the field current at touch-down.
  A field change drops held, uncommitted characters (as `fieldChanged`
  already drops held fingers).
- Unchanged: space, Return, slides from layer keys, Shift and layer keys on
  touch-down, delete repeating from touch-down, the trackpad hold, rollover
  order, and keys ignored while the trackpad runs.

**Swipe gesture:**

- A touch becomes a swipe when all of these hold: swipe typing is enabled
  (`KeyTouchModel.swipeEnabled`), the layer is letters, the touch started on
  a character key, it is not committed, no other finger is held, and the
  finger has moved at least `swipeThreshold` from its touch-down point. The
  threshold is half a letter-key pitch (`(letterWidth + keyGap) / 2`, about
  20 pt in portrait).
- Once a swipe, the touch types nothing, its callout ends, and new touches are
  ignored until it ends (as during the trackpad).
- Samples are `SwipeSample(x:y:t:)`: key-area points and `UITouch`
  timestamps in seconds. They start with the touch-down point and include
  every coalesced touch of each move, in order.
- At release the model emits `.swipe([SwipeSample], field: UUID?)`. A
  system-cancelled swipe emits nothing and types nothing.
- `swipeEnabled` is true only when the swipe engine has loaded and the field
  is not secure text entry.

**Decoding pipeline** (reference implementation and the authority for every
detail: the private repository `ajbarryiii/localflow-swipe`; its module
docstrings are the contract, and `iOS/Tests/SwipeFixtures.swift` is generated
from it):

1. **Frame.** From the letters layer's key centers: `W` = (largest minus
   smallest top-row center x) / 0.9; `ox` = smallest top-row center x −
   0.05 W; `R` = (bottom-row center y − top-row center y) / 2; `oy` = top-row
   center y − R / 2. A point maps to ((x − ox) / W, (y − oy) / W). On the
   portrait iPhone layout this puts q at x 0.05 and p at 0.95, matching the
   training data.
2. **Resample** (`swipe/features.py`): timestamps in milliseconds (t × 1000),
   made non-decreasing with a running maximum and shifted to start at 0. If
   the duration exceeds 1 ms, keep the last sample per timestamp and
   interpolate at `n60 = max(2, floor(duration × 60 / 1000 + 0.5) + 1)`
   evenly spaced times (60 Hz); otherwise keep the samples. Then interpolate
   by index to 64 points. The arithmetic is Float64 and the output is
   rounded to Float32, as in the reference.
3. **Encoder** (Core ML `SwipeEncoder.mlmodelc`, CPU only): input `traj`
   Float32 [1, 64, 2] and `keys` Float32 [1, 26, 2] (the 26 letter centers in
   a–z order, in the same frame); output `log_probs` Float32 [1, 32, 27].
   Column 0 is the blank; column 1 + i is letter i of a–z.
4. **Lexicon** (`swipe/lexicon_bin.py`): the binary "LFLX" version 1 trie,
   read in place from a memory-mapped `Data`. Keys are words lowercased,
   apostrophes removed, and repeated letters collapsed.
5. **Decoder** (`swipe/decode.py`): CTC prefix beam search over the trie in
   Float64, with `logaddexp(a, b) = max + log1p(exp(−|a − b|))`. Each frame
   keeps the `beam` best prefixes (ties: the smaller key). Final score =
   ctc / len(key)^length_power + freq_weight × freq + length_bonus × len(key).
   Words are unique ignoring case, best first, and ties order by Unicode
   scalar values (not Swift's `String` comparison).

**Bundle.** `SWIPE_BUNDLE_DIR` (Makefile, like `PARAKEET_BUNDLE_DIR`) holds
`SwipeEncoder.mlmodelc/`, `lexicon.bin` and `bundle.json`. `bundle.json` has
`format` 1, the decode settings (`beam`, `top_k`, `length_power`,
`freq_weight`, `length_bonus`) and a SHA-256 for every file. The build checks
the hashes and copies the bundle into `LocalFlowKeyboard.appex/Swipe/`, with
`Resources/Swipe/` (licenses: the AOSP word list is Apache-2.0; the training
data is MIT). Without `SWIPE_BUNDLE_DIR`, the build has no swipe typing and
long drags are taps. The keyboard loads the bundle off the main thread when
it starts; any missing or invalid file disables swipe typing.

**Inserting a swiped word** (`KeyboardEditor`):

- The best candidate is inserted. If no candidate exists, nothing happens.
- A space goes before the word unless the text before the cursor is empty or
  ends with whitespace or one of `( [ { " ' “ ‘ / - @ #`. No space goes
  after it; the next swipe adds its own.
- **Space before a tapped word (2026-10-16, from device testing).** After a
  swiped word, the next tapped character that is a letter or digit gets a
  space inserted before it, in the same edit ("have" swiped, then "a"
  tapped, gives "have a"). Punctuation and symbols attach directly
  ("have."). This pending space survives Shift and layer keys (so Shift+"i"
  and digits from the 123 layer get it), and also a candidate replacement.
  It ends on any other key action (space, Return, delete, any character), a
  dictation insert, a field change, the trackpad, an outside text change,
  and when the text before the cursor no longer ends with the swiped word.
  The tapped letter's case is decided after the space, as if the space had
  been typed.
- Case: caps lock uppercases the word; a one-shot or automatic shift
  uppercases its first letter and is consumed, as a typed letter would. Case
  only ever rises: "I" and proper nouns keep their capitals.
- The word is refused in another identified field, as typed keys are.

**Candidate strip:** after a swipe, the middle of the dictation bar shows up
to three candidates, cased the same way, inserted word first. It replaces the
Undo and "Insert last" chips while it shows.

- Tapping another candidate replaces the inserted word, but only while the
  text before the cursor still ends with it and nothing else has edited the
  field. Otherwise the tap does nothing and the strip closes.
- The strip closes on any other key action, a dictation insert, a field
  change, the trackpad, or an outside text change.
- **Delete after a swipe:** while the strip shows, the first deletion (a tap
  or a held delete's touch-down deletion) removes the whole swiped word,
  leaving the space before it. Repeats continue as usual.

**Swipe trace (2026-10-16, from device testing):** while a touch is a swipe,
the key area draws a short trail behind the finger so the user can see the
swipe is recognized. It is not the full path.

- It covers only the last 0.15 s of samples (at least the last two), as a
  round-capped stroke that tapers from about 8 pt at the finger to nothing
  and fades from about 45% opacity to transparent. It uses the tint color.
- It appears when the touch becomes a swipe and follows every move. When the
  swipe ends or is cancelled, it fades out over about 0.15 s.
- It draws above the keys, takes no touches, and does not change key callouts
  (a swipe has none). It is drawn from the samples in memory only.
- With Reduce Motion on, the trail still shows but disappears at once
  instead of fading.

**Privacy:** swipe samples, candidates and decoder state stay in memory. They
are never logged, stored or sent, and nothing is learned from them.

**Torture-test contract:** characters act at release or rollover; space and
Return at release or rollover. Each edit is asserted right after the event
that typed it.

### Touchable backgrounds (fix, 2026-10-18)

**Why.** Fast typing dropped letters, mostly on the top row. The finding came
from a TestFlight typing test on the soft key edges branch, which has
TestFlight-only counters:
- LocalFlow dropped 7.0 characters per 100 against 1.3 for Apple's keyboard.
- In every attempt, the touch-downs the key area received equalled the
  characters typed, so the dropped taps never reached `touchesBegan`.

In a keyboard extension, iOS reportedly ignores a touch on a fully
transparent point, even inside a view that would take it (Apple Developer
Forums thread 702798; the workaround there is a background with a very low
alpha). The key area, the bar and the menu panel were `.clear`, so taps in the
12 pt row gaps, between keys, in the padding above the top row and in the
empty bar never arrived. Apple's own keyboard is not an extension.

**Fix.**
- The key area, the bar's hosting view and the menu panel's hosting view use
  `KeyAreaView.touchableBackground`: grey at 2% alpha. That is about 5 of 255
  in an 8-bit alpha channel, clear of rounding to 0.
- With the views touchable, a gap tap reaches the key area, whose nearest-key
  hit testing already covers every point ("no dead gaps"). A tap in the
  bar's empty space reaches the bar and does nothing, as intended.
- A tap outside the menu panel's card can close it again: its
  `Color.black.opacity(0.001)` tap area was likewise transparent.

**Verified on the device** (TestFlight build 30, soft key edges branch, with
this change added): the user reported the dropped taps essentially gone.
This cannot be unit-tested. The look is expected to be unchanged, since 2%
grey is not noticeable over the keyboard's backdrop. While the trackpad runs
the bar fades to 30%, so its tint can differ very slightly from the key
area's.

## Custom dictionary (contract, 2026-10-15)

The macOS custom dictionary (`Sources/Dictionary`, the fixed bonus with a
per-entry strength) now decodes iPhone dictations too. There is no correction
detection on iOS. Only our own keyboard could see later edits, and reading
the field for that would break invariant 5. So entries are added by hand, and
their strength comes from the arrows or from one test recording.

- **Storage.** The host app's own `UserDefaults.standard`, never the App
  Group: the keyboard never transcribes, so it never sees the words. The keys
  and payloads are the macOS ones (`custom_dictionary` and
  `custom_dictionary_ignore`, `DictionaryStorage` JSON version 1). The iOS UI
  shows no ignore list but keeps whatever is stored.
- **`DictionaryLibrary`** (HostCore, `@MainActor`, pure, tested) owns
  loading, edits and persistence over an injected `UserDefaults` and
  `BPEEncoder?`. It reuses `DictionaryEditor` and `DictionaryStorage`, and
  follows the macOS rules:
  - every edit is validated, persisted, then published, and raises `revision`;
  - without a vocabulary nothing can be edited;
  - saved data that fails validation makes the dictionary empty for decoding
    and refuses edits. The data is never overwritten; only an explicit reset
    removes it.
- **Strength arrows.** ▲ and ▼ step through `DictionaryValidation.presets`
  (×0.5 to ×8) and save at once. From a value between presets they move to
  the next preset in that direction; at either end the arrow is disabled.
- **Decoding.** Each transcription decodes with one immutable
  `DictionarySnapshot` (entries plus `revision`), taken when its decoding
  starts, after any wait for the model. An edit made after that applies from
  the next dictation. An empty dictionary takes the unbiased path unchanged;
  otherwise `LocalParakeetService.transcribe(samples:directory:dictionary:)`
  boosts and then restores casing, as on the Mac.
- **Transcription while recording.** When the model is ready as a request is
  admitted, `DictationSampleBuffer` feeds a streaming session
  (`LocalParakeetService.beginStreamingTranscription`) exactly the samples it
  collects, so each complete chunk is encoded and decoded during the recording
  and only the last partial chunk remains when it ends. The result equals the
  batch transcription of the same samples. Its snapshot is taken at admission;
  if the dictionary changed before the end, or the session fails, the drained
  samples are transcribed as above. Cancel, supersession, lock, session end
  and background-time expiry cancel the session; audio stays in memory. The
  session holds the audio the model queue has not processed yet plus one
  chunk window. Until its model work has drained after finish or cancel, the
  engine counts it as busy, so the runtime is neither released nor replaced.
- **Find strength** ("record a phrase and infer"). The recording runs in the
  foreground only; leaving it discards the recording. A check that has already
  started (after Done) uses no microphone and may finish in the background; its
  result, or its failure, shows when the user returns.
  - The app records one sentence of at most 15 s with its own
    `MicrophoneCapture` and `DictationSampleBuffer`, in memory only.
  - A running Flow session is ended first and started again when the sheet
    closes, if the app is still in front. It is not offered while a dictation
    is in progress.
  - `LocalParakeetService.probeStrength` transcribes the samples with the
    dictionary minus the word. It then re-decodes the same encoder output with
    the word at each of `VerifyDecision.strengths` (×1 to ×8), in order.
  - `StrengthProbe` (pure, `Sources/Dictionary`) decides:
    - **already recognized:** the unboosted transcript contains the word;
    - **recognized at the first strength whose decode is accepted:** the
      decode contains the word, and every difference from the unboosted
      transcript is a block whose new side is exactly the word and whose old
      side has at most two words more than the word. The limit keeps a decode
      that swallows neighbouring words from counting as a match;
    - **not recognized:** no strength produced the word that way.
  - Nothing changes until the user taps "Use ×n". Samples and texts are
    released when the sheet closes.
  - The probe goes through `TranscriptionEngine.withReadyRuntime`. It waits
    for readiness like a dictation and keeps the runtime from being released,
    but it is not reported as a dictation attempt.
- **Tests.** The iOS host tests also compile `Sources/Dictionary` and the
  Foundation-only `Sources/Parakeet/LocalParakeetCore.swift` it depends on.
  The root `make check` covers `StrengthProbe`.
- **Privacy.** Entries are user content:
  - they are never logged, never in a bug report and never in the App Group;
  - test recordings follow invariant 1;
  - the transcripts shown in the sheet are never stored.
