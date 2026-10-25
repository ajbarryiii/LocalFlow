#!/bin/sh
# LocalFlow dictation mappings for river-classic (river 0.3.x, configured
# with riverctl; checked against 0.3.17). Not installed automatically; add
# these lines to your init script (~/.config/river/init), or run them once in
# a terminal to try them.
#
# river 0.4 and later have no riverctl: key bindings belong to the window
# manager you run on river. Its binding protocol (river-xkb-bindings-v1)
# reports key releases, so a window manager can offer hold to talk; if yours
# only runs commands on key press, bind its key to `localflowctl toggle`.
#
# Pick a key nothing else uses: F13-F24, a spare macro or thumb key, Pause,
# ... riverctl takes an XKB keysym name. To find it, run `wev`, press the key
# and read the "sym:" of the key event. The examples use XF86Tools, the sym
# the F13 key (key 191) produces with the default xkb rules.

# Hold to talk: press starts recording, release stops and types the text.
# Double-tap and hold dictates a prompt (Hold to Prompt). Mappings do not
# repeat unless made with -repeat.
riverctl map normal None XF86Tools spawn 'localflowctl press'
riverctl map -release normal None XF86Tools spawn 'localflowctl release'

# Teach the custom dictionary from a correction of the last dictation (within
# two minutes of typing it): a picker opens with its text; edit it and press
# Return. The text already typed in the other app is not changed. Needs rofi
# or wofi ("picker" in config.json; fuzzel and tofi cannot edit text).
riverctl map normal Super+Shift D spawn 'localflowctl correct'

# The release mapping only matches when the key comes up with exactly its
# modifiers (None): release Shift and the like first (other keys pressed
# meanwhile do not matter). Otherwise the recording keeps running: tap the
# dictation key again to stop it (or `localflowctl cancel`); it also stops by
# itself at `max_recording_seconds`.
#
# Modifiers and LocalFlow's typing: river matches mappings against the
# modifiers of the keyboard that sent the key. LocalFlow types through a
# virtual keyboard of its own, which river keeps out of the group of physical
# keyboards and which never holds a modifier, so text typed while you hold
# Super does not run your Super mappings. Apps should not see your held
# modifiers with it either; that part is from river's source
# (river/Keyboard.zig), not tested. The mapping behaviour above was checked in
# a private headless river-classic 0.3.17 with virtual keyboards (wtype)
# standing in for real ones.
#
# river has no per-device switch like Hyprland's `keybinds = false`. Do not
# map anything that types (such as `localflowctl again`) to a modifier
# combination.
