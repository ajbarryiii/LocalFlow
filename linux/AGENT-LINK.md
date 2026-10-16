# Agent link (Linux)

Coding agents (Claude Code, Codex), usually running in T3 Code, can work
with LocalFlow in three ways:

1. **Suggest dictionary words.** An agent that works out what a misheard
   word should have been suggests it. Nothing is added until the user
   approves it in `localflowctl dict review`.
2. **Project words.** An agent loads a short list of distinctive terms for
   the project it works in. They are boosted like dictionary entries, live
   in memory only and expire.
3. **Agent status.** `localflowctl agents t3` reads T3 Code's per-thread
   status and reports counts to the daemon. The Waybar indicator shows when
   an agent needs approval or is waiting for input.

Everything stays on this machine. The daemon still opens no network
connections: only the bridge talks to T3 Code's local server, and it sends
the daemon counts, never thread titles or messages.

## Protocol additions

New text commands on the control socket (`localflow/1`, see
`lf_daemon::protocol`). Existing commands and replies are unchanged. As for
every text command, an unknown, repeated, missing or malformed field is
`error bad-request`.

```text
suggest-add word=<pct>                 ok <status> outcome=queued|present|ignored
                                       errors: invalid-entry, full, unavailable
suggest-next                           ok <status> id=<u64> word=<pct>
                                       errors: not-found, unavailable
suggest-resolve id=<u64> action=add|dismiss|ignore
                                       ok <status>
                                       errors: stale, invalid-entry, full, storage, unavailable
words-set set=<name> words=<pct> [ttl=<u64>]
                                       ok <status> loaded=<n> skipped=<n>
                                       errors: full, unavailable
words-clear set=<name>                 ok <status>; errors: not-found
agents-set [approval=<n>] [input=<n>] [working=<n>] [done=<n>] [ttl=<u64>]
                                       ok <status>
agents-clear                           ok <status>
```

`unavailable` means the daemon runs without a dictionary (as for the `dict-*`
commands).

### Suggestions

- `suggest-add` validates the word exactly like `dict-add` at strength 1
  (`invalid-entry` otherwise). If its identity key is already in the
  dictionary the outcome is `present`; if it is on the ignore list,
  `ignored`. Neither is queued. Otherwise it is queued (`queued`); a word
  whose key is already pending is not queued twice and keeps its place.
- At most 16 suggestions are pending (`full` beyond). Each expires 24 hours
  after it was queued. They are held in memory only, so a restart drops them.
- `suggest-next` returns the oldest pending suggestion. Before answering it
  drops pending words that have since been added to the dictionary or the
  ignore list. `not-found` when none is left.
- `suggest-resolve` finishes the suggestion with that `id`: `add` adds it to
  the dictionary at strength 1 (the errors of `dict-add`), `ignore` puts it
  on the ignore list (the errors of `dict-ignore`), `dismiss` just drops it.
  It leaves the queue on success; on an error it stays pending. An unknown
  or expired `id` is `stale`.
- `add` and `ignore` are dictionary changes like `dict-add`/`dict-ignore`:
  they end any correction session.

### Project words

- `<name>`: 1 to 64 characters of `A-Z a-z 0-9 . _ -` (`bad-request`
  otherwise). It names a set, e.g. the repository's directory name.
- `words`: entries separated by `,`, each trimmed. Each one is validated like
  a `dict-add` entry at strength 1. Invalid entries, empty pieces, repeats
  (by identity key) within the request, and entries beyond 64 in the set are
  skipped and counted in `skipped`. `loaded` counts the accepted ones.
- `words-set` replaces any set of the same name and restarts its expiry.
  `loaded=0` removes the set. At most 4 sets (`full` for a fifth name).
- `ttl`: seconds, 60 to 86400, default 28800 (8 hours); out of range is
  `bad-request`. A set is removed when its time is up, by the daemon's
  timer.
- Dictation boosts the dictionary's entries plus every live set's words at
  strength 1. A word that is also in the dictionary keeps the dictionary's
  strength. Casing is restored for project words as for dictionary entries.
- Project words never touch `dictionary.json`, never end a correction
  session, and are not part of correction suggestions (which see the
  dictionary only).

### Agent status

- Counts are 0 to 999 each (`bad-request` otherwise); a missing count is 0.
  `ttl`: seconds, 5 to 600, default 30; out of range is `bad-request`.
- The report replaces the previous one and lasts `ttl` seconds unless
  renewed, so the status clears by itself when the bridge stops.
  `agents-clear` removes it at once.

### Watch lines

Watch lines gain optional fields after `mic=` and `level=`, in this order,
each only when its value is above zero:

```text
suggestions=<n> words=<n> agent-approval=<n> agent-input=<n> agent-working=<n> agent-done=<n>
```

- `suggestions`: pending suggestions.
- `words`: project words loaded, over all live sets.
- `agent-*`: the live agent report.

A change to any of these sends a watch line. Status replies to other
commands do not carry these fields.

## Waybar

`watch --waybar` keeps its classes, glyphs and texts, with these additions:

- **While idle, loading or without a microphone:**
  - A live report with `agent-approval` adds the class `agent-approval`;
    with `agent-input` (and no approval), `agent-input`.
  - Pending suggestions add `suggestion`.
  - With extra classes, `class` is an array: the state's class first, then
    `agent-approval` or `agent-input`, then `suggestion`.
  - The text becomes the glyph, a space and approval + input, when that sum
    is above zero.
- **While recording, transcribing or typing:** no extra classes, and the
  text is unchanged.
- **Tooltip, in any state but offline:** the state's tooltip is followed by
  these lines, each only when it applies:
  - `Agents: <a> need approval, <i> waiting for input, <w> working, <d> done`.
    Only the non-zero parts are listed, and the singular is used for 1.
  - `<n> dictionary suggestions from agents (localflowctl dict review)`, or
    `1 dictionary suggestion from an agent (…)`.
  - `<n> project words boosted`.

## CLI

```text
localflowctl dict suggest <word…>
localflowctl dict review
localflowctl words set <name> [--ttl SECONDS] [<word>…]     (words from stdin, one per line, when none are given)
localflowctl words clear <name>
localflowctl agents t3 [--token-file PATH] [--interval-ms N]
localflowctl agents clear
```

- **`dict suggest`** prints `queued for review`, `already in the dictionary`
  or `on the ignore list`.
- **`dict review`:**
  - Shows each pending suggestion in the existing rofi suggestion dialog.
  - "Add" sends `action=add`, "Don't suggest" sends `action=ignore`, and
    "Not now" sends `action=dismiss`.
  - Closing rofi stops the review and leaves the word pending.
  - It prints how many words were added, ignored and dismissed.
  - The word reaches rofi only through its stdin, as in `correct`.
- **`words set`:**
  - It rejects a word containing `,` (usage error) rather than splitting it.
  - It prints `loaded <n>, skipped <n>`.
- **`agents t3`** is the T3 Code bridge (below). It runs until killed.

New exit code: 8, the T3 token file is missing, unreadable or unsafe.

## T3 Code bridge (`localflowctl agents t3`)

- **Token:**
  - Read from `--token-file`, default `$XDG_CONFIG_HOME/localflow/t3-token`
    (`~/.config/localflow/t3-token`).
  - The file must be a regular file owned by the user, with no group or
    other permission bits, at most 4096 bytes. It holds one token of
    `0x21`–`0x7e` characters (surrounding whitespace is trimmed).
  - Create it with:

    ```bash
    (umask 077; t3 auth session issue --label localflow --ttl 30d --token-only > ~/.config/localflow/t3-token)
    ```
  - T3 cannot limit a session token's scope. The bridge only reads with it.
  - The token is never printed or logged.
- **Server:**
  - Each poll re-reads `server-runtime.json` from `$T3CODE_HOME/userdata/`
    (default `~/.t3/userdata/`), so a restarted T3 on a new port is found.
  - The file's `host` and `port` are used. An unspecified address
    (`0.0.0.0`, `::` or empty) and `localhost` become loopback
    (`127.0.0.1`, or `::1` for `::`).
  - Any other host that is not a loopback address counts as T3 being
    unreachable. The token is therefore only ever sent over loopback.
- **Poll:**
  - Every `--interval-ms` (default 2000, 500 to 60000), the bridge sends
    `GET /api/orchestration/shell` over HTTP/1.1 with
    `Authorization: Bearer <token>` and `Connection: close`.
  - Timeout: 5 s. Response limit: 32 MiB. Content-Length, chunked and
    close-delimited bodies are accepted.
- **Counting:** each object in the snapshot's `threads` is counted as
  follows. This mirrors T3's `projectThreadAwareness`.
  - Threads with a non-null `archivedAt` are skipped.
  - `approval`: `hasPendingApprovals`.
  - Else `input`: `hasPendingUserInput`.
  - Else failed, not counted: `session.status == "error"` or
    `latestTurn.state == "error"`.
  - Else `working`: `session.status` is `starting` or `running`, or
    `latestTurn.state == "running"`.
  - Else `done`, only if the thread is neither settled nor snoozed:
    - It counts as done when `latestTurn.state == "completed"`,
      `latestTurn.state == "interrupted"` with a non-null `completedAt`, or
      `session.status` is `ready` or `idle`.
    - Settled means `settledOverride == "settled"`, or a non-null
      `settledAt` when `settledOverride` is not `"active"`.
    - Snoozed means a `snoozedUntil` string later than now (ISO 8601 UTC,
      compared as text).
  - A snapshot without a `threads` array is a protocol error.
- **Reporting:**
  - After each successful poll, the bridge sends `agents-set` with the
    counts and `ttl` of three intervals (clamped to 5..600 s).
  - When T3 is unreachable or answers with an error, it sends
    `agents-clear` once and keeps polling.
  - When the daemon is unreachable, it keeps polling.
  - It writes a short line to stderr when the connection state changes
    (T3 reachable or not, token rejected with 401/403), never per poll.

## Agent instructions

`linux/skills/localflow-dictation/SKILL.md` is a skill for agents.
CLAUDE.md or AGENTS.md should point to it from the `[dictated]` rule. It
tells the agent:

- what `[dictated]` means;
- when to suggest a word (only words the user plainly meant, never guesses
  or ordinary words);
- when and how to load project words.
