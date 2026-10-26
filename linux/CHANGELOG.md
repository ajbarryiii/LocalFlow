# Changelog

All notable changes to LocalFlow for Linux are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Linux
releases are tagged `linux-vX.Y.Z`, separately from the macOS app's tags.

## [0.1.0] - 2026-10-26

The first Linux release.

### Added

- Local push-to-talk dictation: hold a key, speak, release, and the text is
  typed into the focused window. Speech recognition runs on the CPU, nothing
  leaves the machine, and audio is never written to disk.
- `localflowd`, the daemon that records, transcribes, post-processes and
  types, and `localflowctl`, which controls it: `press`, `release`, `toggle`,
  `cancel`, `again` (type the last dictation again), `status` and `watch`.
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
