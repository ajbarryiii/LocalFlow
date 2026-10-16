---
name: localflow-dictation
description: Use when a user message starts with [dictated] (LocalFlow speech-to-text). Explains how to read dictated prompts, and how to help LocalFlow hear this project's terms by loading project words and suggesting dictionary words with localflowctl.
---

# LocalFlow dictation

A message that starts with `[dictated]` was spoken and transcribed by
LocalFlow, a local speech-to-text app. Read it as speech:

- Names, identifiers, file names and jargon may be misheard ("hyper land"
  for Hyprland, "app state" for `AppState`). Before you conclude that
  something does not exist, look for names that sound alike. When the
  intended name is unclear and the action is risky, ask.
- Punctuation and casing come from the recogniser, not the user.

LocalFlow on Linux can learn from you. Both commands below talk to the local
`localflowd` daemon through `localflowctl`. If `localflowctl` is missing or
reports that the daemon is not reachable (exit code 3), skip this and carry
on.

## Load project words (once per session)

The first time you see a `[dictated]` message in a session, load up to 40
distinctive terms the user is likely to say while working in this project.
They are boosted while LocalFlow transcribes, and expire after 8 hours.

```bash
localflowctl words set <set-name> <term> <term> …
```

- `<set-name>`: the repository's directory name, using only letters,
  digits, `.`, `_` and `-`. Loading the same name again replaces the set.
- Good terms are the project's own unusual names, the libraries and tools
  it uses, and unusual words in its domain, written exactly as they should
  appear: `Hyprland`, `PipeWire`, `Parakeet`, `serde`, `rofi`.
- Skip ordinary English words, which the recogniser already knows. Skip
  identifiers glued from ordinary words (`AppState`), which are spoken as
  separate words and will not match. Skip anything secret or personal.
- An entry may be a short phrase (up to 8 words) and must not contain `,`.
- The reply says how many were loaded and skipped. A skipped term is fine
  and is not an error to fix.

## Suggest a dictionary word (rarely)

When a dictated message clearly meant a specific word that was transcribed
wrongly, and the user is likely to say it again, suggest it for their
permanent dictionary:

```bash
localflowctl dict suggest <word>
```

- Nothing is added until the user approves it in `localflowctl dict review`,
  so suggest only words you are confident about, spelled exactly right.
- Never suggest ordinary words, guesses, people's names or anything secret.
- Suggest at most a few words per session. Do not repeat a word reported
  as `already in the dictionary` or `on the ignore list`.
- Mention the suggestion to the user in one short line.
