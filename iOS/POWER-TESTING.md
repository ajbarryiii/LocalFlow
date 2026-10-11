# Power testing (test builds only)

How much battery does an always-open microphone (an idle LocalFlow session) and
transcription cost? Two tools answer this together (ARCHITECTURE.md, "Power
log"):

- **The power log.** A test build records content-free proxies to a CSV while
  LocalFlow runs, over days of normal use. An agent analyzes the CSV.
- **Apple's Power Profiler.** It gives exact per-subsystem energy impact for
  short controlled runs.

The power log holds numbers and enums only: battery level and state, thermal
state, Low Power Mode, process CPU time, memory, host and app state, the build
number and the hardware model. It never holds audio, text, transcripts, or
field or app context. It stays on the phone until you export it.

## Build

`POWER_LOG=1` compiles the recorder into the host app only, never the
keyboard. The default is `0`, and production builds must stay `0`. A power
build writes everything to its own directory, `$(BUILD_DIR)-power`, so it
never shares objects, binaries or bundles with a normal build. For example,
`BUILD_DIR=build/device POWER_LOG=1` produces `iOS/build/device-power/LocalFlow.app`,
and `iOS/build/device/LocalFlow.app` stays the normal build. A `BUILD_DIR`
ending in `-power` is refused with `POWER_LOG=0`, after normalization, so
aliases such as `build/device-power/` or `build/device-power/.` are refused too.

```bash
make -C iOS all PLATFORM=device POWER_LOG=1 "${SIGN[@]}"     # SIGN as in README.md → Device
make -C iOS install-device PLATFORM=device POWER_LOG=1 "${SIGN[@]}" DEVICE=<name or id>
```

To publish to the OTA page, add `POWER_LOG=1` to the `make -C iOS all` line of
the publish script, and point its OTA step at `iOS/build/device-power/LocalFlow.app`.

Check a build before you publish it:

```bash
nm iOS/build/device-power/LocalFlow.app/LocalFlow | grep -c PowerRecorder   # > 0: a power build
nm iOS/build/device/LocalFlow.app/LocalFlow | grep -c PowerRecorder         # 0: a normal build
```

In a power build, Diagnostics has a **Power (test build)** section.

Only `POWER_LOG` selects the recorder. `SWIFT_FLAGS="-D LOCALFLOW_POWER_LOG"`
bypasses the gate (it would also reach the keyboard's compile) and must never
be used. `make binaries` only compiles and does not repackage an existing
`.app`, so use `all` for any build that gets installed or published.

## Collect

The phone records whenever LocalFlow runs, so daily use already produces data,
but daily use only gives **observed** rates. The in-app figures are
whole-device drain under whatever screen and use came with them. Sessions need
the screen on, while gaps include screen-off nights. The microphone's cost
comes only from **matched runs**: screen-on, a session against no session, with
everything else equal. Gaps are also uncontrolled: the log cannot prove the
phone stayed unplugged between two samples.

LocalFlow ends a session when the phone locks, and after at most 60 minutes
without dictation (except in the always-on test mode, below). So in a normal
session the microphone can only stay open with the screen on, and the baseline
must have the screen on too.

1. **Match the start.**
   - Begin each run at the same charge, for example 80–85 %, unplugged.
   - Begin at the same thermal state: let the phone cool to room temperature,
     and check `thermal_state` is `nominal` in the endpoint row.
   - Fix and write down:
     - brightness (Auto-Brightness off)
     - Settings → Display & Brightness → Auto-Lock: Never
     - Wi-Fi, Bluetooth and Low Power Mode
     - no media playing
     - the same static screen, for example one Notes page
2. **Warm the model first.** Open LocalFlow and dictate once before the first
   run, so preparation (a Neural Engine compile after install) is not inside a
   run. Then end the session.
3. **Take an endpoint at every run boundary.** A suspended LocalFlow records
   nothing, so open LocalFlow in front at each run's start and end. The
   `foreground` row is the endpoint reading. Then send it to the background
   (or Export), which flushes the log.
4. **Run A, microphone open, about 55 minutes, no dictation.**
   1. Open LocalFlow (the endpoint).
   2. Set Session length to 60 min and tap Start session.
   3. Switch to the static screen and leave the phone untouched.
   4. Before the session expires, open LocalFlow again. That is the end
      endpoint.
   5. To continue, tap End session and Start session to begin the next segment.

   Never dictate during Run A: a dictation is recording and transcription, not
   microphone-only time. Do two or more segments.
5. **Run B, baseline, the same length.**
   1. Open LocalFlow with no session (the endpoint).
   2. Send LocalFlow to the background and use the same static screen.
   3. Open LocalFlow again at the end (the end endpoint).

   Suspended time is logged as a gap.
6. Alternate A and B on the same day (A, B, A, B), and write down each
   boundary time. Also note anything that happened: calls, other apps, a warm
   room, a change of network.
7. Optional: a screen-off baseline overnight, which shows the phone's own idle
   drain.

### Overnight: always-on locked vs no session locked

The always-on microphone test mode (Diagnostics → Power → "Always-on
microphone (test)", power builds only) keeps the session through lock and
idle, so the microphone's screen-off cost can be measured. While it is on,
Home shows a banner with a Turn off button.

1. Run the two nights back to back, with the same start charge, room and
   settings. Note the bedtime and wake times. Don't touch the phone in between.
2. **Night A, always-on locked.**
   1. In the evening, open LocalFlow (the endpoint), turn the mode on, warm the
      model with one dictation, and start a session.
   2. Lock the phone and leave it unplugged overnight.
   3. In the morning, unlock and open LocalFlow (the end endpoint).
   4. Turn the mode off, then send LocalFlow to the background (which flushes).
3. **Night B, no session locked.** Same steps, with the mode off and no
   session. LocalFlow is suspended, so the night is a gap between the two
   endpoints.
4. Night A's rows show `always_on=true` and `protected_data=unavailable` while
   locked, and they keep coming every minute. A long silence followed by a
   `launch` row means iOS terminated the app, for example for memory.
5. The microphone's screen-off cost is rate(A) − rate(B), from the endpoints.
   The in-app "Mic open, locked (always-on)" figure is the same kind of
   observed rate as the others, never a projection.

The in-app rates need at least 1 h and a 3-point drop before they show. They
read "Observed whole-device drain; screen conditions differ. Microphone cost
requires matched runs." There is no projection. Compute the microphone's cost
from the matched endpoints, as described in Analyze.

## Retrieve

First open LocalFlow in front for an endpoint reading, then send it to the
background, which flushes the log. Or tap Diagnostics → Power → Export log,
which flushes and shares snapshot copies of both files (deleted again when
sharing ends).

Or copy over the pairing from the Mac, which works over SSH. Use the device
name from `xcrun devicectl list devices` and the app's `BUNDLE_ID`. Paths are
relative to the app's data container.

```bash
mkdir -p ~/localflow-power
for f in power-log.1.csv power-log.csv; do   # the rotated file may not exist
  xcrun devicectl device copy from --device "<device name or id>" \
    --domain-type appDataContainer --domain-identifier com.ajbarryiii.localflow.ios.dev \
    --source "Library/Application Support/PowerLog/$f" --destination ~/localflow-power/$f
done
```

The phone must be unlocked, or have been unlocked since it booted. The files
are never in the App Group. Copying does not wake a suspended LocalFlow, so
without the endpoint step above the last reading may be missing, or may come
from much later.

## Analyze

`power-log.csv` is the current file. `power-log.1.csv`, when present, is the
older file (the log rotates at 4 MB, about two weeks). Read the older file
first. Each file starts with the header row, then `# schema=2` (an older
`# schema=1` file has no `always_on` or `protected_data` columns: read the mode
as off and protected data as unknown). Skip lines
starting with `#`, and ignore a last line that has no final newline (a write
cut short). Fields with a comma are quoted (`"iPhone16,1"`). Decimals always
use `.`.

| Column | Meaning |
| --- | --- |
| `wall_time` | ISO 8601 UTC, milliseconds |
| `uptime_s` | monotonic seconds, counting sleep; comparable within one process run only |
| `trigger` | `periodic` (60 s), `state` (including the mode switched), `battery`, `thermal`, `powerMode`, `launch`, `foreground`, `background`, `terminate`, `protectedData` (lock or unlock) |
| `host_state` | `idle` (no audio session), `micOpen` (session, no dictation), `recording`, `transcribing`, `preparing` (model load or compile) |
| `app_state` | `foreground` or `background` |
| `battery_level` | `UIDevice.batteryLevel`, 0–1, `-1` when unknown |
| `battery_state` | `unplugged`, `charging`, `full`, `unknown` |
| `low_power_mode` | `true` or `false` |
| `thermal_state` | `nominal`, `fair`, `serious`, `critical` |
| `cpu_user_s`, `cpu_system_s` | the process's cumulative CPU time; restarts at 0 with each launch |
| `memory_mb`, `memory_peak_mb` | footprint as jetsam counts it; empty if unavailable |
| `compute_units` | `cpuAndNeuralEngine` or `cpuOnly` while a model runtime is loaded, else empty |
| `build`, `device` | `CFBundleVersion` and the hardware model |
| `always_on` | `true` or `false`: the always-on microphone test mode |
| `protected_data` | `available` or `unavailable` (locked, a proxy for screen off); empty if unknown |

A sample is taken at every transition, so each interval between two
consecutive rows belongs to the **first** row's state. The in-app summary
(`HostCore/PowerLogSummary.swift`) uses these rules:

- **Process runs.** A new run starts at a `launch` row, or where `uptime_s` or
  the CPU sum goes backwards. Within a run, use `uptime_s` differences; across
  runs only `wall_time` exists.
- **Inactive (gaps).** An interval starting at a `terminate` row, or at
  `background` + `idle`, is LocalFlow suspended or not running. Its charging
  history is unknown: the phone may have charged and come back below its
  starting level. Gap rates are uncontrolled observations, never a
  measurement; only gaps inside a run you watched (Run B) count.
- **Unknown.** Awake states with no row for more than 10 minutes (the 60 s
  timer did not fire), and runs that ended without a `terminate` row while
  active, are unknown: leave them out.
- **Drain.** Use only intervals with `unplugged` at both ends, known levels,
  and no level rise (a rise means it charged in between). Rate = points
  dropped ÷ hours.
- **CPU.** Use deltas of `cpu_user_s + cpu_system_s` within a run.
  Transcriptions are the entries into `transcribing`.

Report:

- For each run segment, the drain from the endpoint row at its start to the one
  at its end, in %/h. Find the endpoints by the boundary times from Collect;
  they are `foreground` rows.
- Check each Run A segment: `micOpen` throughout, with no `recording` or
  `transcribing`.
- The open-microphone cost is mean rate(A) − mean rate(B), with the spread
  across segments. Scale it to a day only for an explicitly stated
  screen-on duration, never × 24.
- Per-state time, CPU seconds, and CPU seconds per transcription.
- Memory peaks.
- Thermal or Low Power Mode changes that may explain outliers.
- Uncertainty. Levels are coarse (look at the distinct values). Battery
  percentage is not linear in energy, temperature shifts it, and 2 h runs give
  only a few points of drop.

Two caveats:

- **CPU time is not energy.** iOS charges the microphone and audio hardware to
  system daemons, not to LocalFlow.
- **Neural Engine work is not process CPU time.** The CPU columns understate
  transcription cost; only the battery drain and Power Profiler's system lane
  include it.

## Power Profiler (Apple, iOS 26 or later)

Steps from Apple's [Measuring your app's power use with Power
Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
and WWDC25 session 226, [Profile and optimize power usage in your
app](https://developer.apple.com/videos/play/wwdc2025/226/).

1. Turn on Developer Mode (Settings → Privacy & Security; the phone must have
   been connected to Xcode once).
2. Settings → Developer → Performance Trace: turn on Performance Trace, set the
   tracing mode to **Power Profiler**, and turn on the switch next to LocalFlow
   in the monitored apps.
   - Apple lists apps installed by Xcode, TestFlight or enterprise
     distribution; check that a `devicectl`/OTA development build appears.
   - With no app selected, only system power is recorded.
3. Open Control Center → + → Add a Control → **Performance Trace**.
4. Tap the control to start, do the run (Run A or B above, or a series of
   dictations), and tap it again to stop. A trace can last up to 10 hours.
5. Settings → Developer → Performance Trace → the Share button next to the
   trace: AirDrop it to the Mac. Double-click it in Finder to expand it, then
   open the result in Instruments.

Record away from Xcode. A phone paired with Xcode is kept awake, and sleep
periods then never appear.

What each lane tells you:

- **System Power Usage** (whole device, % of battery per hour): the only lane
  that includes the microphone and audio hardware and Neural Engine work.
  Select a region to see its average. Compare a micOpen region with a
  no-session region in the same screen state to get the microphone's cost.
  Compare dictation bursts with micOpen around them to get transcription's
  cost.
- **Track markers** (charger connected, thermal state, display brightness,
  periods when Apple silicon is asleep). An open session should prevent
  sleep; sleep periods returning after the session ends show what the open
  microphone takes away. Discard charging regions.
- **LocalFlow's CPU Power Impact:** the audio tap, the decoder and the Swift
  work around Core ML. It spikes during transcription and preparation, and
  should stay near zero while micOpen is idle.
- **LocalFlow's GPU Power Impact:** should be near zero; the model runs on the
  Neural Engine.
- **LocalFlow's Display Power Impact:** LocalFlow's own screens (onboarding,
  bounce) while in front.
- **LocalFlow's Networking Power Impact:** should be zero; LocalFlow has no
  network code.

There is no Neural Engine lane and no audio lane. Neural Engine transcription
and microphone cost appear only in System Power Usage. Per-app impact values
are scores comparable on one device model only.
