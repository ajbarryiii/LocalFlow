# LocalFlow for Linux

Local dictation for Wayland desktops (developed on Hyprland and NixOS): hold
a key, speak, release, and the text is typed into the focused window.
Speech recognition runs on the CPU with a ternary or binary Parakeet model;
nothing leaves the machine, and audio is never written to disk. See `PLAN.md`
for the design and measurements.

- `localflowd`: the daemon. It records, transcribes, post-processes (voice
  macros, "press enter", spoken delimiters) and types.
- `localflowctl`: sends one command to the daemon. Your desktop's key binds
  call it, or the daemon binds keys itself through the desktop portal; see
  "Dictation key" below.

`localflowd` records from PipeWire (`lf-pipewire`, the default source or
`input_device`) and types through the Wayland virtual keyboard
(`lf-wayland`) on wlroots compositors (Hyprland, sway, river), the
RemoteDesktop portal (GNOME, KDE) or uinput (anything, X11 included); see
[Text output and desktops](#text-output-and-desktops). `--fake-io` swaps
the microphone and the output for fakes that record silence and discard
text.

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
  "double_tap_ms": 400,
  "output": "auto",
  "keyboard_layout": null,
  "trigger": "commands"
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
  It needs hold to talk, so desktops limited to toggle do not have it (see
  "Dictation key").
  - `prompt_tag`: at most 64 characters, no control characters or
    newlines; surrounding spaces are trimmed; `""` types prompts untagged.
  - `double_tap_ms`: 150-1000, or 0 to turn double-tap off.
- `output`: how text is typed: `auto` (default), `wayland`, `portal` or
  `uinput`. See [Text output and desktops](#text-output-and-desktops).
- `keyboard_layout`: the XKB layout your desktop uses, for the `uinput`
  output (and the portal if the desktop sends no keymap), e.g.
  `{"layout": "us", "variant": "dvorak"}`. Fields: `rules`, `model`,
  `layout`, `variant`, `options`; missing ones (or `null`) take
  libxkbcommon's defaults (`XKB_DEFAULT_LAYOUT` and friends, else US).
- `trigger`: how the dictation key reaches the daemon. `"commands"`: key
  binds run `localflowctl` (see "Dictation key"). `"portal"`: the daemon
  also binds shortcuts through the desktop portal (GNOME, KDE Plasma);
  `localflowctl` keeps working either way.

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

Bind it to a key (see the snippets in `packaging/`). Within two minutes of a
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

Key binds (see "Dictation key"), a desktop file and a systemd user unit are
in `packaging/`. None is installed automatically.

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

## Text output and desktops

`output` picks how text is typed. With `auto` (the default) the daemon
uses the first of these that works at startup and logs which one it chose
(`text output: ...`), never the text:

1. **Wayland virtual keyboard** (`wayland`), when the compositor offers
   `zwp_virtual_keyboard_manager_v1`: Hyprland, sway, river and other
   wlroots compositors. It uploads its own keymap, so your layout does not
   matter and any Unicode character can be typed. A Wayland compositor
   that does not answer yet at startup also selects it (it may still be
   starting); typing retries the connection.
2. **RemoteDesktop portal** (`portal`), when xdg-desktop-portal offers
   RemoteDesktop version 2 with keyboards: GNOME 45 and later, KDE Plasma 6.
3. **uinput** (`uinput`), when `/dev/uinput` is writable: any compositor,
   and X11.

If none works, the daemon warns and keeps the virtual keyboard, which
reports its error on each dictation. The clipboard is never used.

The portal and uinput send key codes that the desktop interprets with its
own keyboard layout. LocalFlow types each character with a key and at most
Shift, AltGr and level 5 on that layout; dead keys and Compose are not used.
Text containing a character the layout cannot produce (é on a US layout,
say) is refused as a whole and nothing is typed (`typing refused: cannot
type the character at position N`); it is never typed differently.

### Hyprland

Use `packaging/hyprland.conf`. Hyprland matches its binds against the
modifiers held on every keyboard, so text typed while Super is held would
trigger Hyprland binds (Super+Q closes the window, Super+M exits Hyprland).
The `device` block in that file stops LocalFlow's virtual keyboard from
triggering any Hyprland bind:

```ini
device {
    name = hl-virtual-keyboard-localflowd
    keybinds = false
}
```

The name is `hl-virtual-keyboard-` plus the daemon's process name. Hyprland
reads it when the virtual keyboard is created, so restart `localflowd` after
adding it. Apps still see modifiers held on the physical keyboard (Hyprland
always shares them; `input:virtualkeyboard:share_states` does not change
that), so text typed while Ctrl is held reaches the focused app as Ctrl
shortcuts: release modifiers before releasing the dictation key, and do not
bind anything that types (such as `localflowctl again`) to a modifier
combination.

### sway, river and other wlroots compositors

The virtual keyboard works as on Hyprland. Bind `localflowctl press` to the
key's press and `localflowctl release` to its release (see "Dictation key"
and `packaging/sway.conf`, `packaging/river-init.sh`). Modifiers held on the
physical keyboard combine with the typed keys here too.

### GNOME and KDE Plasma (portal)

Needs xdg-desktop-portal with the desktop's backend
(`xdg-desktop-portal-gnome` 45 or later, `xdg-desktop-portal-kde` from
Plasma 6), which GNOME and Plasma sessions normally run.

- At the first start the desktop asks whether to allow remote control of
  the keyboard (LocalFlow asks for the keyboard only, never the pointer or
  the screen). Allow it once; the grant is remembered with a restore token
  in `$XDG_STATE_HOME/localflow/portal-restore-token` (usually
  `~/.local/state/localflow`, directory 0700, file 0600). The token is a
  credential for that grant: it is never logged; treat it like a password.
  Delete the file, or revoke the grant in the desktop's settings, to be
  asked again.
- Until the grant arrives, dictations fail with `waiting for the desktop to
  allow LocalFlow to type`; dictate again after allowing it. An unanswered
  dialog is withdrawn after 5 minutes, and the next dictation asks again.
- Characters go through the keymap the desktop sends, with its current
  layout group and Caps Lock state. If that changes while a dictation is
  being typed (you switch layouts or press Caps Lock), the rest of it is
  not typed and the journal says so.
- GNOME and Plasma custom shortcuts run a command on key press only. For
  hold to talk, set `"trigger": "portal"` (see "Dictation key"); otherwise
  bind `localflowctl toggle` to a key (tap to start, tap again to stop and
  type).

### X11 and everything else (uinput)

The daemon creates a keyboard device, "LocalFlow virtual keyboard", through
`/dev/uinput`, which your user must be able to write. With that permission
any program you run can inject keystrokes, so grant it deliberately.

- NixOS:

  ```nix
  hardware.uinput.enable = true;               # uinput module, udev rule, `uinput` group
  users.users.<you>.extraGroups = [ "uinput" ];
  ```

  then log out and in again.
- Other distributions: load the module at boot
  (`echo uinput | sudo tee /etc/modules-load.d/uinput.conf`), add a udev
  rule such as
  `KERNEL=="uinput", GROUP="uinput", MODE="0660", OPTIONS+="static_node=uinput"`
  in `/etc/udev/rules.d/60-uinput.rules`, create the group, add yourself to
  it and log in again.

The desktop applies its own layout to the device, which the daemon cannot
read: set `keyboard_layout` to match it (for example
`{"layout": "de"}` or `{"layout": "us", "variant": "dvorak"}`). Only the
first layout of a list is used, so switch to it before dictating; Caps
Lock on the physical keyboard changes what letters type. Under X11, use
your window manager or `xbindkeys` to call `localflowctl`.

### The systemd unit

Every output keeps to Unix sockets and device nodes: the Wayland socket,
the D-Bus session bus and the EIS socket the portal hands over, or
`/dev/uinput`. `packaging/localflowd.service` needs no change
(`RestrictAddressFamilies=AF_UNIX` holds). If you add `PrivateDevices=yes`
or `DevicePolicy=closed`, the uinput output also needs
`DeviceAllow=/dev/uinput w`.

## Dictation key

Pick a key nothing else uses: F13-F24, a spare macro or thumb key, Pause,
and so on. To find its name and code, run `wev` (`xev` prints the same
codes), press the key, and read the key event:

```text
[14:     wl_keyboard] key: serial: 7; time: 449; key: 191; state: 1 (pressed)
                      sym: XF86Tools    (269025153), utf8: ''
```

`key:` is the code (Hyprland's `code:191`, sway's `bindcode 191`); `sym:` is
the XKB name (river, niri, sway's `bindsym`). The packaged snippets use the
F13 key as their example: with the default xkb rules it is code 191 and
produces the XF86Tools sym rather than F13. Replace it with your key.

The daemon understands three key gestures:

- **Hold to talk** (`localflowctl press` on key down, `release` on key up):
  recording runs while the key is held; letting go types the text.
- **Hold to Prompt**: double-tap and hold (see "Configure"). It is built on
  hold to talk, so it needs a desktop that reports the key coming up.
- **Toggle** (`localflowctl toggle`): tap to start, tap again to stop and
  type. For desktops whose binds only run on key press.

| Desktop | How to bind | Hold to talk |
| --- | --- | --- |
| Hyprland | `packaging/hyprland.conf` (`exec` binds; recommended) | yes |
| sway | `packaging/sway.conf` | yes |
| river-classic (0.3) | `packaging/river-init.sh` | yes |
| river 0.4 and later | your window manager's binds (see `packaging/river-init.sh`) | if it runs commands on release |
| niri | `packaging/niri.kdl` (toggle) | no: niri 26.04 binds run on press only |
| GNOME, KDE Plasma | `"trigger": "portal"` (below); text goes through the RemoteDesktop portal | yes, if the desktop reports releases |
| anything else | a key bind that runs `localflowctl toggle` | no |

Each snippet notes how that desktop's binds treat held modifiers and
LocalFlow's virtual keyboard. In short: do not hold other keys while the
dictation key goes up, and never bind anything that types (such as
`localflowctl again`) to a modifier combination.

### Desktop portal (GNOME, KDE Plasma)

With `"trigger": "portal"`, the daemon binds its own global shortcuts
through xdg-desktop-portal's GlobalShortcuts interface, so desktops whose
custom shortcuts only run a command on key press still get hold to talk.

Mutter does not implement the Wayland virtual keyboard protocol and KWin
does not offer it to ordinary clients, so on GNOME and KDE Plasma the text
is typed through the RemoteDesktop portal instead (see "GNOME and KDE
Plasma (portal)" under "Text output and desktops"). The portal trigger
also works on compositors that have the protocol (Hyprland, below).

1. Copy `packaging/com.ajbarryiii.localflow.desktop` to
   `~/.local/share/applications/`. The daemon registers the app ID
   `com.ajbarryiii.localflow` (xdg-desktop-portal 1.19 or later), and the
   desktop names it from this file.
2. Set `"trigger": "portal"` and restart `localflowd`. On first start the
   desktop asks you to accept two shortcuts and choose their keys:
   - "Hold to dictate" (`hold-to-talk`): hold to talk and Hold to Prompt;
   - "Start or stop dictation" (`toggle`).
   LocalFlow asks for no particular key. Change them later in the
   desktop's shortcut settings (GNOME Settings > Keyboard > Keyboard
   Shortcuts; KDE System Settings > Keyboard > Shortcuts).
3. `localflowctl correct` needs rofi, which needs layer-shell (KDE has it,
   GNOME does not); bind it as an ordinary custom shortcut.

Behaviour:

- Key down and up arrive as `press` and `release` requests, stamped on
  arrival, so hold, toggle, Hold to Prompt and `min_recording_seconds`
  work exactly as with `localflowctl`. A key up is passed on only after
  the same session's key down, so it never ends a hold started by a bind.
- If the portal is missing, the daemon logs a warning, keeps serving
  `localflowctl`, and tries again in the background (1 s, doubling to
  60 s). If you cancel the dialog, or the portal refuses, it does not ask
  again until the daemon restarts.
- If the session ends while the key is held (the portal closes it, exits or
  restarts, or the bus connection drops), the daemon treats that as the key
  coming up: what you said so far is transcribed and typed, and the
  microphone closes. It never keeps recording on a lost session. A toggle
  recording keeps running until the next toggle. Then it binds a new
  session, with backoff.
- A desktop that never reports the key coming up leaves a hold running
  until `max_recording_seconds`: use the toggle shortcut there.
- Logs carry shortcut IDs, counts and D-Bus error names, never key names.
  `--fake-io` leaves the portal alone, as it does the desktop.

On Hyprland, xdg-desktop-portal-hyprland implements the interface too, and
Hyprland binds the shortcuts with its `global` dispatcher (example in
`packaging/hyprland.conf`; `hyprctl globalshortcuts` lists them). The plain
`exec` binds remain the recommended way there. Use one or the other: with
both on one key, every key event arrives twice and Hold to Prompt stops
working.

## Tests

```bash
nix develop ./linux --command cargo test --release --manifest-path linux/Cargo.toml
```

The kernel tests run at every tier the CPU supports, whatever
`LOCALFLOW_CPU_TIER` says, and check that the tiers agree bit for bit.

`lf-daemon/tests/private_dbus.rs` starts its own `dbus-daemon` (from the dev
shell) with fake MPRIS players; it never uses your session bus. Likewise
`lf-portal/tests/mock_portal.rs` serves a mock RemoteDesktop portal on a
private bus and a fake EIS server, so it never opens your desktop's portal
or types anywhere. Set `LF_SKIP_DBUS_TESTS=1` to skip both where
`dbus-daemon` is missing. `lf-keyboard` maps characters through a synthetic
keymap and through the `us`, `de` and `dvorak` layouts of the XKB data
libxkbcommon was built with, and checks uinput event encoding without
opening `/dev/uinput`.

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
Items 1-21 use the Hyprland binds in `packaging/hyprland.conf`; "the key" is
your dictation key.

1. Start `localflowd` in a terminal; `localflowctl status` reports
   `model=loading`, then `model=ready` after a few seconds.
2. A second `localflowd` refuses to start ("already running").
3. Hold the key, say a sentence, release: the text appears in a terminal
   (foot/kitty), a browser text field, an Electron app and an XWayland app.
4. Say "… press enter" at the end: the text is typed and Return is pressed.
5. Say a configured voice macro: its payload is typed.
6. Say "quote hello end quote": `"hello"` is typed.
7. Held Super (needs the `device` block in `packaging/hyprland.conf`): hold
   the key, dictate a text containing a letter bound to a harmless Super
   shortcut, press and hold Super, release the key and keep Super held until
   the text appears: the shortcut does not fire. (The app does see Super
   with the typed keys; Hyprland cannot prevent that.)
8. `localflowctl cancel` from a terminal while a long recording runs:
   nothing is typed.
9. Tap the key briefly (under 0.3 s): nothing is typed (`note=too-short`).
10. Hold the key, press Shift, release the key, then release Shift: the
    recording stops (the release bind ignores modifiers). If it does not, the
    recording continues until `max_recording_seconds` or a cancel.
11. Tap the key as briefly as possible, many times: no recording is left
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
    custom module): idle shows the microphone; holding the key shows a moving
    level graph that follows your voice; release shows the hourglass, then
    idle. Disconnect the microphone (or turn the headset off): `nomic`
    within a second or two, and back to idle when reconnected. With
    `input_device` set, only that device counts. Stop the daemon: `offline`;
    start it again: idle within about 2 s, without restarting Waybar.
    `journalctl --user -u localflowd` shows `microphone: absent/present`
    but no device names.
18. Hold to Prompt: in a terminal or chat box, tap the key once quickly, then
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
22. Text output selection: on Hyprland the journal says `text output:
    Wayland virtual keyboard (auto: the compositor offers the virtual
    keyboard protocol)` and typing behaves as before (items 3-7). No
    portal dialog appears.
23. GNOME 45+ and KDE Plasma 6 (`output` unset or `"portal"`): at the
    first start the desktop asks once to allow keyboard control; allow it.
    `ls -l ~/.local/state/localflow/portal-restore-token` shows
    `-rw-------`, and the journal never shows its contents. Dictate into a
    GTK or Qt app, a browser and an XWayland app: the text appears,
    including Shift and AltGr characters of your layout. A character the
    layout cannot type is refused (`typing refused: …`) and nothing is
    typed. Restart the daemon: it does not ask again. Turn Caps Lock on and
    dictate: the case is still right. Deny the dialog (delete the token
    first): dictation fails with an error and the next one asks again.
24. uinput (`"output": "uinput"`, after the setup in [Text output and
    desktops](#text-output-and-desktops), with `keyboard_layout` set to the
    desktop's layout): under X11 and under a Wayland compositor, dictation
    types correctly, including Shift and AltGr characters;
    `libinput list-devices` (or `xinput list`) shows "LocalFlow virtual
    keyboard" while the daemon runs and not after it stops. Without
    permission on `/dev/uinput` the journal warns at startup and dictation
    fails cleanly.
25. sway (`packaging/sway.conf`, with your key): items 3, 9 and 18 work;
    holding the key and tapping another key loses the release (the
    recording keeps running), and tapping the dictation key again stops it.
    With Super held on the real keyboard while text is typed, no Super
    bind fires and the app receives the text without Super.
26. river-classic (`packaging/river-init.sh`): as item 25, except that
    another key tapped during the hold does not matter and Shift held at
    release loses the release.
27. niri (`packaging/niri.kdl`): tap the key to start, tap again to stop:
    the text is typed. Note whether text typed while Super is held runs a
    Super bind, or reaches the app with Super.
28. GNOME and KDE Plasma (`"trigger": "portal"`, desktop file installed): on
    first start the desktop asks to accept "Hold to dictate" and "Start or
    stop dictation", named LocalFlow; assign keys. The journal says
    `global shortcuts bound: 2 of 2`. Holding the hold shortcut shows
    `state=recording mode=hold` in `localflowctl watch`, and releasing it
    ends the recording and types the text through the RemoteDesktop portal
    (item 23); a double tap and hold shows `tag=prompt`; the toggle
    shortcut toggles. Cancel the shortcut dialog instead: one warning, no
    second dialog, and `localflowctl` still works.
29. Portal session loss: hold the key and restart the portal
    (`systemctl --user restart xdg-desktop-portal`): the recording stops
    and what was said is typed; the journal shows "released the held
    dictation key", then the shortcuts are bound again without a dialog
    and work.
30. Hyprland with `"trigger": "portal"` and the `global` binds from
    `packaging/hyprland.conf` (instead of the `exec` binds):
    `hyprctl globalshortcuts` lists `com.ajbarryiii.localflow:hold-to-talk`
    and `:toggle`; items 3 and 18 work.
