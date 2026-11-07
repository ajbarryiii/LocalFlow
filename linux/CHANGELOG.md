# Changelog

All notable changes to LocalFlow for Linux are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Linux
releases are tagged `linux-vX.Y.Z`, separately from the macOS app's tags.

## [Unreleased]

### Added

- A settings window and correction dialogs, `localflow-gui` (prototype,
  built with Rune; the flake's `localflow-gui` package). Its changes go to a
  new `settings.json` beside `config.json`, whose keys replace
  `config.json`'s, so a read-only `config.json` from Home Manager can still
  be adjusted. `"picker": "gui"` uses its dialogs for `localflowctl correct`
  and `dict review`; `auto` uses them only for the suggestion dialog, and only
  when no menu tool (rofi, fuzzel, wofi, tofi) is installed. Escape closes
  the settings window, and launching it again brings the open one forward.
  The windows have the iPhone app's dark look. Settings not applied yet
  show a dot, and an invalid value is explained under its field. If the
  daemon does not restart after **Apply**, the window says the settings
  were saved and keeps saying so, with **Retry**, until a restart works; a
  daemon started outside its systemd user unit is not silently skipped,
  the window asks you to restart it (also when it is busy or does not
  answer within half a second). **Speed** names `precision` from
  Fastest to Slowest. Adding a voice macro puts the cursor in its Say
  field. The dialogs' smallest size fits every choice.

### Changed

- The Waybar indicator (`localflowctl watch --waybar`) looks like the
  iPhone keyboard's dictation island, and every state is six cells wide, so
  the module and the clock beside it no longer move. While recording it
  shows a row of small white dots instead of bars, ending in a larger
  aurora dot, so it reads as listening from the first moment, even in
  silence. Your voice crosses the row in about half a second: a syllable
  rises at once beside the aurora dot and fades within a few dots, so
  syllables read as separate pulses, and the row rises out of the line at
  its left end; in silence the dots rest small and dim. While transcribing,
  the row rests without the aurora dot and a glacier-white spot sweeps
  across it every 1.1 s, drawn by `localflowctl` itself ten times a second
  and only in that state. The dots are standard characters with Pango
  markup, at half the bar font's size and set in the `monospace` font, so
  the clock holds still while you speak even when the bar's font is
  proportional, and need no Nerd Font (keep the module's `escape` off); the
  aurora dot's colour is in the markup, so it shows without the README's
  CSS. Each other state has its own glyph: a clock while the model loads, a
  keyboard while typing, the microphone with a slash without a microphone,
  power-off when LocalFlow isn’t running, and a raised hand while an agent
  needs your approval (unless there is no microphone). A prompt dictation
  shows `›` before the dots. Tooltips use plain words ("LocalFlow: ready",
  "2 dictionary suggestions waiting"). The README's CSS uses the iPhone
  keyboard's colours, gives the module a fixed `min-width`, and adds
  `min-length` and `align` to the module.
- The recommended model is now
  [Kea-B 0.1](https://huggingface.co/wildernesslabs/kea-b-0.1): `kea-b` in
  `localflowctl fetch-model` and the flake installs it instead of Kea-B 0.0.
  It is more accurate at the same size and speed. An existing kea-b export
  is kept until you run `localflowctl fetch-model --force`.
- 1-bit models now run with one INT8 activation part (`i8x1`) unless
  `precision` is set, instead of two. Kea-B 0.1 was trained for it, and
  transcription takes about a third less time. Ternary models still default
  to `i8x2`.

- Dictations are transcribed while you speak: audio goes to the recognizer
  as it is captured, and every 15 s window (windows overlap by 2 s) is
  transcribed as soon as it is complete, so after the key is released only
  the last window is left. Long dictations no longer wait for the whole
  recording to be encoded, which matters most on CPUs with few cores.
- When you stop speaking but still hold the key, the last window is
  transcribed during the pause, so releasing the key after a pause leaves
  almost nothing to do. The text is the same either way: the result is used
  only if the recording ends exactly there.
- Pauses are shortened before the model hears them, as in the macOS app:
  silence before and after speech keeps 0.3 s, and a pause longer than
  0.8 s is cut to 0.8 s. This saves encoder time on every dictation, and
  can change transcripts slightly.
- Window transcripts are joined at a word both windows heard, the same way
  the macOS app joins them (shared test vectors pin the pause shortening,
  the windows and the joins on both platforms).
- A dictation uses the dictionary as it was when the recording started (it
  used the dictionary as it was when the recording stopped).
- The encoder never sees more than 15 s at once, so its working memory no
  longer grows with the longest dictation, and the warm-up after loading the
  model is 15 s of silence instead of 30 s.
- A dictation keeps at most 16 MiB of encoder output for checking a later
  correction, as on the Mac; a longer one can still be dictated but not
  corrected.

## [0.1.0] - 2026-10-26

The first Linux release.

### Added

- Local push-to-talk dictation: hold a key, speak, release, and the text is
  typed into the focused window. Speech recognition runs on the CPU, nothing
  leaves the machine, and audio is never written to disk.
- `localflowd`, the daemon that records, transcribes, post-processes and
  types, and `localflowctl`, which controls it: `press`, `release`, `toggle`,
  `cancel`, `again` (type the last dictation again), `status` and `watch`.
  Both print their version with `--version`.
- Speech recognition with the 1-bit [kea-b](https://huggingface.co/rajb3/kea-b)
  (recommended) or ternary [kea-t](https://huggingface.co/rajb3/kea-t) model
  exports of NVIDIA's Parakeet TDT 0.6B v2. Every model file is checked
  against its SHA-256 hash at load.
- CPU kernels for AVX-512, AVX2 with AVX-VNNI, and AVX2, picked at startup.
  Every tier produces the same transcripts. Recognizer threads are pinned to
  one CPU per physical core by default (`cpus` overrides this).
- Microphone capture from PipeWire, from the default source or a chosen
  `input_device`.
- Text output through the Wayland virtual keyboard (Hyprland, sway, river
  and other wlroots compositors), the RemoteDesktop portal (GNOME 45 and
  later, KDE Plasma 6) or uinput (any desktop, X11 included), chosen
  automatically or with `output`. The clipboard is never used.
- Dictation keys: key bind snippets for Hyprland, sway, river and niri, a
  tap-to-toggle mode for desktops whose binds only run on key press, and
  global shortcuts through the desktop portal (`"trigger": "portal"`) for
  hold to talk on GNOME and KDE Plasma.
- Hold to Prompt: double-tap and hold the dictation key to type the text
  with a `[dictated]` tag (configurable with `prompt_tag`) for AI agents.
- Text post-processing: voice macros, "press enter", spoken delimiters
  ("quote hello end quote"), spoken numbers written as digits, and a space
  after a finished sentence so consecutive dictations do not run together.
- A custom dictionary (`localflowctl dict`) that boosts names and jargon
  while decoding and keeps their capitals, and `localflowctl correct`, which
  suggests a dictionary word after you correct a recent dictation in rofi
  or wofi. Suggestions can also be reviewed in fuzzel or tofi.
- Coding agent support: project words (`localflowctl words`), dictionary
  suggestions that you approve with `localflowctl dict review`, an agent
  skill for `[dictated]` prompts, and a T3 Code bridge
  (`localflowctl agents t3`) that shows threads needing you.
- Status indicators: a Waybar module (`localflowctl watch --waybar`) with a
  live input level, and a tray icon (`localflowctl tray`).
- Pausing playing media players (MPRIS) while recording, and resuming them
  afterwards (`pause_media`, on by default).
- Opt-in history of the last 20 transcripts (`history`, off by default). Logs
  never contain transcripts or typed text.
- `localflowctl fetch-model`, which downloads kea-b (or kea-t) from a pinned
  Hugging Face revision, checks every file's SHA-256 hash, and installs it
  where the daemon looks for its model.
- A Nix flake with the daemon package, both model exports pinned to a
  Hugging Face revision, and a development shell. The package runs the test
  suite while it builds, and installs a systemd user unit, a desktop file for
  the portal trigger, and the key bind examples.
- A systemd user unit, a desktop file and key bind examples in `packaging/`
  for installing by hand.

[0.1.0]: https://github.com/ajbarryiii/LocalFlow/releases/tag/linux-v0.1.0
