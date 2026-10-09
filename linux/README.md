# LocalFlow for Linux

Local dictation for Hyprland on NixOS: hold a key, speak, release, and the
text is typed into the focused window. Speech recognition runs on the CPU
with the ternary Parakeet model; nothing leaves the machine, and audio is
never written to disk. See `PLAN.md` for the design and measurements.

- `localflowd`: the daemon. It records, transcribes, post-processes (voice
  macros, "press enter", spoken delimiters) and types.
- `localflowctl`: sends one command to the daemon. Hyprland binds call it.

`localflowd` records from PipeWire (`lf-pipewire`, the default source or
`input_device`) and types through the Wayland virtual keyboard
(`lf-wayland`). `--fake-io` swaps both for fakes that record silence and
discard text.

## Build

From the repository root:

```bash
nix develop ./linux --command cargo build --release --manifest-path linux/Cargo.toml -p lf-daemon
# Binaries: linux/target/release/localflowd and localflowctl
```

The CPU needs AVX-512 (F, BW, VNNI, VBMI).

## Configure

`$XDG_CONFIG_HOME/localflow/config.json` (usually
`~/.config/localflow/config.json`). Every key is optional; unknown keys and
invalid values stop the daemon with an error. Defaults:

```json
{
  "version": 1,
  "export_path": "<XDG_DATA_HOME>/localflow/model",
  "precision": "i8x2",
  "cpus": "first 16 available CPUs",
  "press_enter": true,
  "spoken_delimiters": true,
  "voice_macros": [],
  "history": false,
  "min_recording_seconds": 0.3,
  "max_recording_seconds": 300,
  "log_level": "info",
  "input_device": null,
  "key_delay_ms": 1,
  "pause_media": true,
  "prompt_tag": "[dictated]",
  "double_tap_ms": 400
}
```

- `export_path`: the model export directory (`export.safetensors`,
  `manifest.json`, `tokenizer/`).
- `precision`: `f32`, `i8x1`, `i8x2` (default) or `i8x3`. i8x2 matched
  f32's WER over 32,560 dev/test utterances (six near-tie transcript
  changes) and is 25-28% faster than i8x3, which tracks f32 to rounding; see
  "Precision validation" in `PLAN.md`.
- `cpus`: an array (`[0, 1, 2]`) or a list string (`"0-15"`, `"0-7,16-23"`).
- `voice_macros`: `[{"command": "sign off", "payload": "Best regards,"}]`.
  Saying exactly the command (ignoring case and punctuation) types the payload.
- `history`: off by default (opt-in). With `true`, keeps the last 20 transcripts in
  `$XDG_DATA_HOME/localflow/history.json` (mode 0600). With `false` the file
  is neither read nor written; delete an old one by hand.
- Recordings shorter than `min_recording_seconds` are discarded; recording
  stops by itself at `max_recording_seconds` (at most 600).
- `input_device`: a PipeWire `node.name` to record from (see
  `wpctl inspect`); `null` follows the default source. A named device that
  is missing fails the recording instead of falling back to another input.
- `key_delay_ms`: pause after each typed key, 0-50 (raise it if an app drops
  characters).
- `pause_media`: pause media players that are playing while recording, and
  resume them when the recording ends (stop, cancel, maximum length, error
  or daemon shutdown). Uses MPRIS on the D-Bus session bus; only players
  LocalFlow paused and that are still paused are resumed, so a player you
  resumed, stopped or closed meanwhile is left alone. Useful with Bluetooth
  headsets, whose playback degrades while the microphone is in use. Without
  a session bus the daemon logs a warning and records anyway. Track
  metadata is never read; logs carry counts only.
- Hold to Prompt: **double-tap and hold** the dictation key (tap it, then
  press again within `double_tap_ms` and hold) to dictate a prompt for an
  AI agent. The text is typed with `prompt_tag` in front, e.g.
  `[dictated] Rename the helper.`, so the agent knows it came from
  speech-to-text. "Press enter" still works; voice macros and empty
  dictations are never tagged. The first tap must be shorter than
  `min_recording_seconds` (so it records nothing); a first hold long enough
  to dictate is an ordinary dictation. Media players stay paused between
  the two taps.
  - `prompt_tag`: at most 64 characters, no control characters or
    newlines; surrounding spaces are trimmed; `""` types prompts untagged.
  - `double_tap_ms`: 150-1000, or 0 to turn double-tap off.

Check a configuration with `localflowd --check-config`.

## Run

```bash
linux/target/release/localflowd            # microphone and typing
linux/target/release/localflowd --fake-io  # silence in, text discarded, media left alone
```

The control socket is `$XDG_RUNTIME_DIR/localflow/ctl.sock` (directory 0700,
socket 0600). One daemon runs per user. Logs go to stderr (the journal under
systemd) and never contain transcripts or typed text. Logging never blocks
the daemon: if stderr stalls, lines are dropped and a "N log lines dropped"
note follows once it moves again.

```bash
localflowctl press     # start hold-to-talk
localflowctl release   # stop, transcribe, type
localflowctl toggle    # start or stop tap-to-toggle
localflowctl cancel    # discard the recording, or abandon transcription/typing
localflowctl again     # type the last dictation again
localflowctl status    # e.g. "state=idle model=ready"
localflowctl watch     # a line on every change, e.g. "state=idle model=ready mic=present"
localflowctl watch --waybar   # the same as Waybar JSON (see below)
```

Exit codes: 0 ok, 1 daemon error, 2 usage, 3 daemon not running (or, for
`watch`, the connection was lost), 4 timeout, 5 protocol error. `watch`
exits 0 when its reader goes away.

`watch` lines also carry microphone presence (`mic=present|absent|unknown`,
from the PipeWire node list) and, about 15 times a second while recording,
the input level (`level=0..100`). Only state names and that number are
sent; never audio or text. Up to 8 watchers can connect (more get
`error busy`); one that stops reading is disconnected so it cannot delay
key handling. `watch` exits as soon as whatever reads its output goes away.

### Waybar indicator

`localflowctl watch --waybar` prints one JSON object per change for a
Waybar custom module. Classes (also the `alt`): `idle`, `loading` (model
loading), `recording` (text is a scrolling level graph), `transcribing`,
`typing`, `nomic` (idle with no microphone), `offline` (daemon not
running). A prompt dictation (double-tap and hold; `tag=prompt` in
`watch` lines) adds the class `prompt` while it records, transcribes and
types (`"class": ["recording", "prompt"]`, tooltip "LocalFlow: recording
(prompt)"). It keeps retrying every 2 s while the daemon is down, so Waybar
never needs restarting. The default text uses Nerd Font glyphs; override
them with `format-icons` keyed by `alt` if you like.

```jsonc
"custom/localflow": {
    "exec": "localflowctl watch --waybar",
    "return-type": "json",
    "restart-interval": 5
}
```

```css
#custom-localflow.recording { color: #f38ba8; }
#custom-localflow.transcribing,
#custom-localflow.typing { color: #f9e2af; }
#custom-localflow.nomic { color: #e64553; }
#custom-localflow.offline,
#custom-localflow.loading { opacity: 0.5; }
/* A prompt dictation (double-tap and hold), after the rules above. */
#custom-localflow.prompt { color: #89b4fa; }
```

Hyprland binds and a systemd user unit are in `packaging/`. Neither is
installed automatically.

## Tests

```bash
nix develop ./linux --command cargo test --release --manifest-path linux/Cargo.toml
```

`lf-daemon/tests/private_dbus.rs` starts its own `dbus-daemon` (from the dev
shell) with fake MPRIS players; it never uses your session bus. Set
`LF_SKIP_DBUS_TESTS=1` to skip it where `dbus-daemon` is missing.

The dictation rules are pinned by `testdata/dictation-vectors.json`, shared
with the Swift app. The real-model daemon test is ignored by default; it
needs the model export and public LibriSpeech data:

```bash
LF_TEST_EXPORT=<export dir> LF_TEST_LIBRISPEECH=<LibriSpeech/test-clean> \
LF_TEST_M1_HYPS=<M1-test/librispeech_clean.json> \
nix develop ./linux --command cargo test --release --manifest-path linux/Cargo.toml \
  -p lf-daemon --test real_model -- --ignored --nocapture
```

## Manual test checklist

Run these by hand on the live session; the automated tests use fakes or
private headless instances and never touch the microphone or the desktop.
First run the backend smoke tests in the "Desktop I/O" section of
`linux/PLAN.md` (`lf-mic-smoke`, `lf-type-smoke`).

1. Start `localflowd` in a terminal; `localflowctl status` reports
   `model=loading`, then `model=ready` after a few seconds.
2. A second `localflowd` refuses to start ("already running").
3. Hold F13, say a sentence, release: the text appears in a terminal
   (foot/kitty), a browser text field, an Electron app and an XWayland app.
4. Say "… press enter" at the end: the text is typed and Return is pressed.
5. Say a configured voice macro: its payload is typed.
6. Say "quote hello end quote": `"hello"` is typed.
7. Held Super (needs the `device` block in `packaging/hyprland.conf`): hold
   F13, dictate a text containing a letter bound to a harmless Super
   shortcut, press and hold Super, release F13 and keep Super held until the
   text appears: the shortcut does not fire. (The app does see Super with
   the typed keys; Hyprland cannot prevent that.)
8. `localflowctl cancel` from a terminal while a long recording runs:
   nothing is typed.
9. Tap F13 briefly (under 0.3 s): nothing is typed (`note=too-short`).
10. Hold F13, press Shift, release F13, then release Shift: the recording
    stops (the release bind ignores modifiers). If it does not, the
    recording continues until `max_recording_seconds` or a cancel.
11. Tap F13 as briefly as possible, many times: no recording is left
    running (`localflowctl status` reports idle afterwards).
12. `localflowctl again` from a terminal types the last dictation again.
13. `journalctl --user -u localflowd` (or the terminal) shows no transcript
    text.
14. `~/.local/share/localflow/history.json` holds at most 20 entries, mode
    0600; with `"history": false` it is not written.
15. Stop the daemon with Ctrl+C or `systemctl --user stop localflowd` while
    recording: it exits cleanly and the socket is removed.
16. Media (`pause_media`): play music (e.g. Spotify, mpv or a browser tab),
    then dictate: playback pauses when recording starts and resumes after
    release. Repeat with `localflowctl cancel` and with a very short tap.
    Pause a second player by hand first: it stays paused. Resume the music
    by hand while recording: nothing changes at release. Stop the daemon
    while recording: the music resumes. With the AirPods Max, note whether
    the start of the resumed audio is lost while the headset switches back
    from HFP to A2DP. `playerctl -l` (if installed) lists the players the
    daemon sees.
17. Waybar indicator (`localflowctl watch --waybar` in a terminal, or the
    custom module): idle shows the microphone; holding F13 shows a moving
    level graph that follows your voice; release shows the hourglass, then
    idle. Disconnect the microphone (or turn the headset off): `nomic`
    within a second or two, and back to idle when reconnected. With
    `input_device` set, only that device counts. Stop the daemon: `offline`;
    start it again: idle within about 2 s, without restarting Waybar.
    `journalctl --user -u localflowd` shows `microphone: absent/present`
    but no device names.
18. Hold to Prompt: in a terminal or chat box, tap F13 once quickly, then
    press it again at once and hold while speaking: the text is typed as
    `[dictated] ...` (with "press enter" also pressing Return), the Waybar
    module shows the `prompt` class, and the journal says
    `recording (hold, prompt)`. A single hold types untagged text; a tap,
    a pause of a second, then a hold types untagged text too. With music
    playing, the double tap does not make it stutter; a single quick tap
    resumes it about `double_tap_ms` later. Find the gap that feels right
    and adjust `double_tap_ms` if 400 ms is too short or too long.
