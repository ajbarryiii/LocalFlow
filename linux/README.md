# LocalFlow for Linux

Local dictation for Hyprland on NixOS: hold a key, speak, release, and the
text is typed into the focused window. Speech recognition runs on the CPU
with a ternary or binary Parakeet model; nothing leaves the machine, and audio
is never written to disk. See `PLAN.md` for the design and measurements.

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

The CPU needs x86-64 with AVX2, FMA and F16C (Intel Haswell or AMD Zen 1 and
later). At startup the daemon picks the fastest set of kernels the CPU
supports and names it in its `model loaded` log line:

| Tier | CPU features | For example |
| --- | --- | --- |
| `avx512` | AVX-512 F, BW, VNNI and VBMI | Intel Ice Lake, Sapphire Rapids; AMD Zen 4 and later |
| `avx2+vnni` | AVX2 and AVX-VNNI | Intel Alder Lake and later client chips |
| `avx2` | AVX2 | Intel Haswell to Comet Lake, Skylake-SP to Cascade Lake Xeons; AMD Zen 1-3 |

`LOCALFLOW_CPU_TIER=avx512`, `avx2` or `avx2-novnni` forces a tier (`avx2`
still uses AVX-VNNI when the CPU has it; `avx2-novnni` does not). Forcing
one the CPU lacks stops the daemon with an error. Every tier computes the same
results bit for bit, so transcripts do not depend on the CPU.

On a Ryzen 9 9950X3D, which runs all three, 2-12 s clips took 1.4-1.7 times
as long end to end at `avx2+vnni` and 1.8-2.2 times at `avx2` as at `avx512`
(kea-t, i8x2: 27, 44 and 55 ms on average), and the encoder projections for
30 s of audio 2.0 and 2.6 times. That machine runs 256-bit instructions at
half its 512-bit rate, so these ratios say little about CPUs without AVX-512.

## Model

LocalFlow needs a model export: a directory with `export.safetensors`,
`manifest.json` and `tokenizer/`. Two are published on Hugging Face, both
derived from NVIDIA's
[parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
and licensed CC-BY-4.0 (attribution in each export's `NOTICE`):

- [kea-b](https://huggingface.co/rajb3/kea-b) (recommended): 1-bit weights,
  105 MB.
- [kea-t](https://huggingface.co/rajb3/kea-t): ternary weights, 181 MB,
  slightly lower WER (1.33% vs 1.45% on 40 LibriSpeech test-clean clips),
  and slower (see `export_path` below).

The daemon checks every file against the SHA-256 hashes in `manifest.json`
when it loads. With Nix, the flake packages both exports, pinned to a
Hugging Face revision:

```bash
nix build ./linux#kea-b   # result/ is the export directory
```

In a Home Manager or NixOS configuration that has this flake as the input
`localflow`, set `export_path = "${localflow.packages.x86_64-linux.kea-b}"`.
Without Nix, download the repository into the default location:

```bash
git clone https://huggingface.co/rajb3/kea-b ~/.local/share/localflow/model
```

(`git lfs` must be installed; `hf download rajb3/kea-b --local-dir …` works
too).

## Configure

`$XDG_CONFIG_HOME/localflow/config.json` (usually
`~/.config/localflow/config.json`). Every key is optional; unknown keys and
invalid values stop the daemon with an error. Defaults:

```json
{
  "version": 1,
  "export_path": "<XDG_DATA_HOME>/localflow/model",
  "precision": "i8x2",
  "cpus": "one per physical core, at most 16",
  "press_enter": true,
  "spoken_delimiters": true,
  "spoken_numbers": true,
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
  `manifest.json`, `tokenizer/`), in either format: ternary
  (`parakeet-ternary-v1`, e.g. [kea-t](https://huggingface.co/rajb3/kea-t))
  or binary (`parakeet-binary-v1`, e.g.
  [kea-b](https://huggingface.co/rajb3/kea-b)). The format is read from
  `manifest.json`. Binary weights stay at 1 bit in memory (79 MB of encoder
  weights instead of 155 MB). On a Ryzen 9 9950X3D with i8x2, kea-b
  transcribed 2-12 s clips about 8% faster than kea-t end to end; its
  encoder projections were 9-21% faster at 3 s and 3-6% faster at 30 s.
- `precision`: `f32`, `i8x1`, `i8x2` (default) or `i8x3`. i8x2 matched
  f32's WER over 32,560 dev/test utterances (six near-tie transcript
  changes) and is 25-28% faster than i8x3, which tracks f32 to rounding; see
  "Precision validation" in `PLAN.md`.
- `cpus`: the CPUs the recognizer's threads are pinned to, an array
  (`[0, 1, 2]`) or a list string (`"0-15"`, `"0-7,16-23"`). By default, one
  CPU per physical core the daemon may run on (SMT siblings are skipped),
  whole L3 caches largest first, at most 16; on a 9950X3D that is CPUs 0-15,
  the V-cache CCD first. There, on 2-12 s clips, 8 cores of one L3 cache took
  23% longer and 16 threads left to the scheduler 47% longer.
- `voice_macros`: `[{"command": "sign off", "payload": "Best regards,"}]`.
  Saying exactly the command (ignoring case and punctuation) types the payload.
- `spoken_numbers`: write spoken numbers as digits ("twenty three percent"
  types "23%"). Zero to nine stay as words except in lists, labels, units
  and ranges ("step 3", "5 GB").
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
`watch`, the connection was lost), 4 timeout, 5 protocol error, 6 the
dictionary file cannot be read (`dict list`/`ignored`), 7 rofi failed
(`correct`, `dict review`), 8 the T3 token file is missing or unsafe
(`agents t3`). `watch` exits 0 when its reader goes away.

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

### Custom dictionary

Words and phrases in the dictionary are boosted while decoding, so names
and jargon the model tends to miss come out right, and entries with
capitals keep their exact spelling ("nixos" is typed as "NixOS").

```bash
localflowctl dict add Kubernetes             # strength 1 (the default)
localflowctl dict add New York --strength 2  # 0.25 to 8; higher boosts harder
localflowctl dict remove new york            # case does not matter
localflowctl dict list                       # one "text<TAB>strength" per line
localflowctl dict ignored                    # words never suggested
localflowctl dict unignore kubernetes
```

An entry has 1 to 8 words, at most 100 characters and at least one
letter, and the model must be able to spell it (otherwise `error
invalid-entry`). At most 1000 entries and 1000 ignored words. Adding a word
that differs only in case replaces the old entry. Strengths in the UI
presets are 0.5, 1, 1.41, 2, 2.83, 4, 5.66 and 8. Entries that share
their first tokens share a boost, at the larger strength.

The dictionary is `$XDG_DATA_HOME/localflow/dictionary.json` (directory
0700, file exactly 0600 and owned by you; anything else, including a
symlink or an invalid file, stops the daemon with an error that quotes no
content). The daemon owns it and replaces it atomically on every change;
a failed write changes nothing (`error storage`). Edit it with
`localflowctl dict` rather than by hand.

#### Teaching it from a correction

```bash
localflowctl correct
```

Bind it to a key (see `packaging/hyprland.conf`). Within two minutes of a
dictation being typed, it opens rofi with that dictation's text; edit it
to what you meant and press Return (Escape does nothing). **It never
changes the text already typed into the other app**: fix that there as
usual. If the edit replaces a few words with a word or phrase that, when
the same recording is decoded again with that word boosted, comes out
exactly where you corrected it, a second rofi asks whether to add it: "Add
…", "Not now" or "Don't suggest …" (which puts it on the ignored list). A
change of capitals only ("nixos" to "NixOS") is offered without
re-decoding, unless only the first letter changed (a sentence start). This
checks that the word fits the audio, not that it was said; treat it as a
suggestion. One suggestion per correction; the check takes at most about
three seconds and stops when you start a new dictation.

Privacy: the dictation's text and its decoded audio features stay in the
daemon's memory for those two minutes (dropped earlier by a new
dictation, a cancel or any dictionary change); macros and dictations that
press Return are never kept. rofi receives the text through an inherited
file descriptor, never its command line; it runs with your rofi
configuration and plugins replaced and with history disabled, and its
error output is discarded. Nothing goes to the notification daemon.

#### Protocol

Control replies used to carry no text at all. The correction and
dictionary commands below now carry text both ways, percent-encoded, over
the same private socket (0600, same-user peers only). `watch` lines and
logs still never carry any text, and `localflowctl` never prints it except
for `dict list`/`ignored` (your own dictionary).

```text
correct-begin                          ok <status> id=<n> text=<pct>   | error no-recent, too-long
correct-submit id=<n> text=<pct>       ok <status> job=<n>             | error stale, too-long, bad-request
correct-result job=<n>                 ok <status> result=pending|none
                                       ok <status> result=suggest word=<pct> strength=<dec> kind=replace|casing
                                                                       | error stale, unknown-job
dict-add word=<pct> [strength=<dec>]   ok <status>  | error invalid-entry, full, storage
dict-remove word=<pct>                 ok <status>  | error not-found, storage
dict-ignore word=<pct>                 ok <status>  | error full, storage
dict-unignore word=<pct>               ok <status>  | error not-found, storage
```

`<pct>` is UTF-8 with only `A-Z a-z 0-9 . _ ~ -` literal and every other
byte as `%XX` (uppercase hex), decoded once; control characters and
invalid UTF-8 are refused. `<dec>` is `[0-9]{1,2}(.[0-9]{1,3})?` between
0.25 and 8. Each field appears once; unknown, repeated or missing fields
are `error bad-request`. These lines may be up to 16 KiB and a decoded
value up to 4096 bytes; every other request stays within 256 bytes.
`correct-submit` answers at once; poll `correct-result` (localflowctl
does, every 200 ms for up to 5 s).

Hyprland binds and a systemd user unit are in `packaging/`. Neither is
installed automatically.

### Coding agents

Agents can help LocalFlow hear a project's terms, and the Waybar indicator
can show T3 Code threads that need you. The full contract is in
[`AGENT-LINK.md`](AGENT-LINK.md).

```bash
localflowctl words set myproject Hyprland PipeWire   # project words, boosted for 8 hours
localflowctl words clear myproject
localflowctl dict suggest Hyprland                   # an agent suggests a word…
localflowctl dict review                             # …and you approve it in rofi
localflowctl agents t3                               # T3 Code bridge (runs until killed)
```

- **Agent skill:** give agents `skills/localflow-dictation/SKILL.md`, e.g.
  link it into `~/.claude/skills/`, so they know what to do with
  `[dictated]` prompts.
- **Bridge:** it reads T3 Code 0.1.0's thread list, so it needs T3 Code
  0.1.0 or later, and a read-only T3 token in
  `~/.config/localflow/t3-token` with mode 0600:

  ```bash
  (umask 077; t3 auth session issue --scope orchestration:read --label localflow --ttl 30d --token-only > ~/.config/localflow/t3-token)
  ```

  A systemd user unit for it is in `packaging/localflow-t3-bridge.service`.
- **Waybar:**
  - Bind the module's `on-click` to `localflowctl dict review` to approve
    suggestions with a click.
  - Style the new classes:

    ```css
    #custom-localflow.agent-approval { color: #fab387; }
    #custom-localflow.agent-input { color: #a6e3a1; }
    #custom-localflow.suggestion { font-weight: bold; }
    ```

## Tests

```bash
nix develop ./linux --command cargo test --release --manifest-path linux/Cargo.toml
```

The kernel tests run at every tier the CPU supports, whatever
`LOCALFLOW_CPU_TIER` says, and check that the tiers agree bit for bit.

`lf-daemon/tests/private_dbus.rs` starts its own `dbus-daemon` (from the dev
shell) with fake MPRIS players; it never uses your session bus. Set
`LF_SKIP_DBUS_TESTS=1` to skip it where `dbus-daemon` is missing.

The dictation rules are pinned by `testdata/dictation-vectors.json` and
`testdata/number-vectors.json`, shared with the Swift app. Word boosting (BPE encoding, entry validation, the
bias graph and decision rule, casing restoration, correction candidates
and their audio check) is pinned by `testdata/dictionary-vectors.json`,
also shared with the Swift app. `lf-text` (the dictionary text rules and
the BPE tokenizer, with no model code) runs its encoding, validation, key
and phrase sections, `lf-asr` the bias graph and decision rule, and
`lf-dictation` (which depends on `lf-text`, not on `lf-asr`) the casing
and correction sections. The rofi tests use fake rofi scripts; one
also checks that the installed rofi reads the generated configuration back
(it is skipped when rofi is not on `PATH`). The real-model daemon test is ignored by default; it
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
19. Custom dictionary: `localflowctl dict add <a name the model misses>`,
    then dictate it: it comes out right; `dict add NixOS` and dictate
    "nixos": typed as `NixOS`. `ls -l ~/.local/share/localflow/dictionary.json`
    shows `-rw-------`.
20. `localflowctl correct` (or its bind) right after a dictation that got a
    word wrong: rofi opens with the dictation's text in the input box (not
    your rofi theme). Fix the word and press Return: within a few seconds a
    second rofi offers "Add “…” to your dictionary". Choose Add; `dict list`
    shows it. The text in the other app is unchanged. While rofi is open,
    `ps -o args -C rofi` shows no dictated text, and afterwards
    `~/.cache/rofi*` holds no entry history with it. Escape in either rofi
    does nothing. "Don't suggest" puts the word in `dict ignored`.
21. After more than two minutes, or after a new dictation, `correct` says
    `daemon error: no-recent`. The journal shows only counts
    ("correction submitted (1 candidates)", "correction checked: …"), never
    the words.
