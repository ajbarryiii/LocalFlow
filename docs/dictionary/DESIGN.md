# Custom dictionary: design contract

This is the current contract for the custom dictionary on macOS, iOS and
Linux: word boosting, casing restoration, correction candidates,
verification, storage and the correction flow. Code comments cite it as
"DESIGN §x". The pinned interpretations it relies on are in
[DESIGN-pins.md](DESIGN-pins.md) and are cited as "pin Px". For the experiments
behind the shipped design, see [../word-boosting.md](../word-boosting.md).

How to read it:

- Every rule names the code, test or shared-vector section that pins it, as
  a symbol plus `file:line`. Paths are relative to the repository root,
  except that Swift files under `Sources/Dictionary/` and Rust files under
  `linux/crates/` are named from there after their first mention. Line
  numbers match the commit that last changed this file; if they drift,
  search for the named symbol.
- **Inferred** marks a statement read from the code's behavior when no
  comment, test or vector states it.
- Section numbers match the citations in the code. No code cites §2.1–§2.3
  or §3.3; they are numbered to keep the sequence.
- Swift means `Sources/Dictionary/` and its callers, which macOS and iOS
  share. Rust means the `linux/crates/` workspace.

## §1 Shared algorithms (all platforms)

Swift and Rust implement §1 independently. The shared vectors (§1.7) are
how both are held to it.

### §1.0 Text units

- Characters are Unicode scalars. Strings compare by exact scalar sequence,
  with no normalization: canonically equivalent spellings differ.
  (`DictionaryText`, `Sources/Dictionary/DictionaryText.swift:4-19`; the
  `lf_asr::dictionary` module doc, `linux/crates/lf-asr/src/dictionary.rs:5-7`)
- `fold(s)`: each scalar through its full lowercase mapping. Folding can
  lengthen text: `İ` folds to `i` + U+0307. (`DictionaryText.fold`,
  `DictionaryText.swift:21-36`; `fold`, `lf-asr/src/dictionary.rs:100-103`)
- `upper1(s)`: the first scalar through its full uppercase mapping, the rest
  unchanged. (`DictionaryText.upper1`, `DictionaryText.swift:38-42`;
  `upper1`, `lf-asr/src/dictionary.rs:105-113`)
- Whitespace is the Unicode `White_Space` property. A letter is general
  category L\*. A word character is L\*, M\*, Nd or Pc. A control character
  is Cc. Uppercase is the Unicode `Uppercase` property (pin P5).
  (`DictionaryText.isWhitespace`, `isLetter`, `isWordCharacter`,
  `isUppercase` and `isControl`, `DictionaryText.swift:44-63,122`;
  `is_whitespace`, `is_letter` and `is_word_char`,
  `lf-asr/src/dictionary.rs:115-134`)
- Edge punctuation is exactly `. , ; : ! ? " ' “ ” ‘ ’ ( ) [ ] { } … — – « »`.
  Other symbols, such as `# + & / @ - _`, are kept.
  (`DictionaryText.edgePunctuation`, `DictionaryText.swift:65`;
  `is_edge_punct`, `lf-asr/src/dictionary.rs:136-161`)
- `words(s)`: split on whitespace, with empty pieces dropped.
  (`DictionaryText.words`, `DictionaryText.swift:69-82`; `words`,
  `lf-asr/src/dictionary.rs:172-175`)
- `norm(w)`: `fold(w)` with leading and trailing edge punctuation removed.
  (`DictionaryText.norm`, `DictionaryText.swift:91-94`; `norm`,
  `linux/crates/lf-dictation/src/correction.rs:101-105`)

Tests: `testTextUnits` in `Tests/DictionaryTests.swift`, plus the
`lf-asr` unit tests.

### §1.1 Entries, validation and limits

An entry is a text and an f32 strength. Its **identity key** is
`fold(text)`. Two entries are the same entry when their keys are equal
scalar sequences. (`DictionaryEntry.key`,
`Sources/Dictionary/DictionaryEntry.swift:4-15`; `DictionaryEntry::key`
and `identity_key`, `lf-asr/src/dictionary.rs:48-52,246-250`)

Validation runs these steps in order, and the first failure wins. The
shared vector error names are in brackets.

1. If `words(text)` is empty: `empty`. If it has more than 8 words:
   `too-many-words`. The normalized text is the words joined by one U+0020.
2. If the normalized text has more than 100 scalars: `too-long`. If it has
   no letter: `no-letter`.
3. If the normalized text contains a control character: `unencodable`,
   whether or not a vocabulary is loaded (pin P6). If it encodes with
   `<unk>` under the model vocabulary (§1.3): `unencodable`.
4. If the strength is not finite or lies outside [0.25, 8]: `bad-strength`.

The stored text is the normalized text. (`DictionaryEntryError` and
`DictionaryValidation.validate`, `DictionaryEntry.swift:17-36,65-78`;
`normalize`, `encodable`, `check_strength` and `validate`,
`lf-asr/src/dictionary.rs:177-242`; vectors `validation`; `testValidation`)

Some callers have no vocabulary: loading on a Mac without the bundled
model, or `localflowctl dict list` without the model. These callers skip
the `<unk>` check in step 3 and nothing else.
(`DictionaryValidation.validate` with a nil encoder,
`DictionaryEntry.swift:63-64`; `parse` with no tokenizer,
`linux/crates/lf-daemon/src/dictionary.rs:332-334`) An edit is never
accepted without a vocabulary (§3.3).

| Limit | Value | Source |
|---|---|---|
| Words per entry | 8 | `DictionaryValidation.maxWords` (`DictionaryEntry.swift:45`), `MAX_WORDS` (`lf-asr/src/dictionary.rs:20`) |
| Scalars per entry (normalized) | 100 | `DictionaryValidation.maxScalars` (`DictionaryEntry.swift:46`), `MAX_SCALARS` (`lf-asr/src/dictionary.rs:22`) |
| Strength range | 0.25 to 8, inclusive | `DictionaryValidation.minStrength`/`maxStrength` (`DictionaryEntry.swift:47-48`), `MIN_STRENGTH`/`MAX_STRENGTH` (`lf-asr/src/dictionary.rs:23-24`) |
| Default strength | 1 | `DictionaryValidation.defaultStrength` (`DictionaryEntry.swift:49`), `DEFAULT_STRENGTH` (`lf-asr/src/dictionary.rs:25`) |
| Strength presets | 0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8 | `DictionaryValidation.presets` (`DictionaryEntry.swift:52`), `STRENGTH_PRESETS` (`lf-asr/src/dictionary.rs:27`) |
| Entry capacity | 1000 | `DictionaryValidation.capacity` (`DictionaryEntry.swift:50`), `MAX_ENTRIES` (`lf-asr/src/dictionary.rs:16`) |
| Ignore-list capacity | 1000 keys | `DictionaryValidation.ignoreCapacity` (`DictionaryEntry.swift:51`), `MAX_IGNORED` (`lf-asr/src/dictionary.rs:18`) |
| Stored key | ≤ 300 scalars, ≤ 8 fields split at U+0020, empty fields included (pin P6) | `DictionaryKey.isValid` (`DictionaryText.swift:106-118`), `valid_key` and `MAX_KEY_SCALARS` (`lf-asr/src/dictionary.rs:205-218`) |

Dictionary rules:

- Saving an entry replaces the entry with the same key in place. Otherwise
  the entry is appended, unless the dictionary already holds 1000 entries
  (`full`). If the key is invalid under pin P6, nothing changes.
  (`CustomDictionary.upsert`, `DictionaryEntry.swift:98-109`; `Store::add`,
  `lf-daemon/src/dictionary.rs:149-161`)
- The ignore list holds identity keys that are never suggested. Adding a
  key that is already present is a no-op. The list fills at 1000 keys, and
  a key invalid under pin P6 is refused. (`CustomDictionary.addIgnore`,
  `DictionaryEntry.swift:118-124`; `Store::ignore`,
  `lf-daemon/src/dictionary.rs:177-188`)
- Errors never quote the entry. (`DictionaryEditError.message`,
  `DictionaryEditor.swift:15-24`; `DictionaryEntryError.message`,
  `DictionaryEntry.swift:26-35`; the `EntryError` `Display` impl,
  `lf-asr/src/dictionary.rs:85-95`)

### §1.2 Bias graph and scoring

Surfaces and phrases:

- An entry is boosted as up to four **surfaces**, without repeats and in
  this order: the text, `fold(text)`, `upper1(text)`, and each U+0020-separated
  word through `upper1`. (`BiasGraph.surfaces`, `BiasGraph.swift:111-127`;
  `surfaces`, `lf-asr/src/dictionary.rs:252-263`)
- Each surface is encoded (§1.3). A sequence that is empty or contains
  `<unk>` is skipped. When two surfaces give the same token sequence, the
  largest strength is kept. (`BiasGraph.phrases`, `BiasGraph.swift:137-155`;
  `phrases`, `lf-asr/src/dictionary.rs:265-281`; vectors `phrases`)

The graph is an Aho-Corasick trie over token ids, with failure links.
(`BiasGraph`, `BiasGraph.swift:4-76`; the `lf_cpu::bias` module doc,
`linux/crates/lf-cpu/src/bias.rs:2-21`) Each phrase must be non-empty,
with every id below the non-blank vocabulary size (1024), and a finite
positive strength. Otherwise construction fails. (`BiasGraph.init`,
`BiasGraph.swift:24-32`; `BiasGraph::new`, `lf-cpu/src/bias.rs:48-65`)

Scores:

- `σ(n)` is the largest strength among the phrases whose path passes
  through or ends at state `n`. Entries that share a token prefix are
  therefore coupled through `σ`.
- `own(n) = σ(n) · (C + D · ln d(n))`, where `d(n) ≥ 1` is the depth of
  `n`. The root has `own(root) = 0`.
- `score(n) = max(own(n), score(fail(n)))`, computed breadth-first, so the
  result does not depend on phrase order.
- A non-blank token `t` taken from state `s` earns
  `α · score(goto(s, t))`, or 0 when `goto` returns to the root. The bonus
  is computed in f64 and stored as f32. A blank earns nothing and leaves
  the state unchanged.

(`BiasGraph.init` and `BiasGraph.step`, `BiasGraph.swift:45-84`; the
`lf_cpu::bias` module doc, `lf-cpu/src/bias.rs:8-22`; vectors `graph`)

| Constant | Value | Source |
|---|---|---|
| α (overall weight) | 1.414 | `BiasGraph.alpha` (`BiasGraph.swift:8`), `ALPHA` (`lf-cpu/src/bias.rs:26`), vectors `constants.alpha` |
| C (context score) | 1.0 | `BiasGraph.contextScore` (`BiasGraph.swift:9`), `CONTEXT_SCORE` (`lf-cpu/src/bias.rs:28`), vectors `constants.context_score` |
| D (depth scaling) | 3.0 | `BiasGraph.depthScaling` (`BiasGraph.swift:10`), `DEPTH_SCALING` (`lf-cpu/src/bias.rs:30`), vectors `constants.depth_scaling` |
| Blank row | 1024 | `blank` in `LocalParakeetCore.decode` (`BiasGraph.swift:165`), vectors `constants.blank` |

Worked example (vector G1): one phrase `[1, 2, 3]` at strength 1. The three
bonuses are `1.414 · (1 + 3 ln 1) = 1.414`, `1.414 · (1 + 3 ln 2) ≈ 4.3543`
and `1.414 · (1 + 3 ln 3) ≈ 6.0743`.

**Decision rule.** Take the argmax over rows 0…1024 (1024 is blank) of
`f64(logit) + f64(bonus)`, with blank's bonus 0. The first maximum wins.
(`BiasGraph.biasedArgmax`, `BiasGraph.swift:86-109`; `token_decision`,
`linux/crates/lf-cpu/src/decoder.rs:995-1009`; vectors `decision`)

A dictionary with no entries, or none whose surfaces encode, has no graph.
Decoding then takes the unbiased path. (`BiasGraph.build`,
`BiasGraph.swift:129-135`; `LocalParakeetRuntime.graph(for:)`,
`Sources/Parakeet/LocalParakeetService.swift:534-542`)

### §1.3 BPE encoding

The vocabulary has 1024 pieces. A piece's id is its merge rank, and lower
ids merge first. Id 0 is `<unk>`, which a merge never produces. Empty
pieces are ignored, and a repeated piece keeps its lowest id.
(`BPEEncoder.init(pieces:)`, `Sources/Dictionary/BPEEncoder.swift:5-24`;
`Tokenizer::from_pieces`, `linux/crates/lf-asr/src/tokenizer.rs:100-105`;
vectors `vocab`)

- macOS and iOS read `vocabulary.json`, shaped
  `{"0": piece, …, "1023": piece}`. It must be at most 1 MiB and have
  exactly 1024 keys. (`BPEEncoder.init(vocabularyFile:)`,
  `BPEEncoder.swift:26-41`)
- Linux reads `tokenizer.vocab`. After `<unk>`, scores must fall strictly
  with the id, so the id order is SentencePiece's merge order.
  (`Tokenizer::from_vocab_file`, `tokenizer.rs:63-81`)

To encode text:

1. Prefix the text with U+2581, and replace each U+0020 (only that
   character) with U+2581.
2. Make one symbol per scalar.
3. Repeatedly merge the adjacent pair whose concatenation is the piece with
   the lowest id; on ties, take the leftmost pair.
4. Map each symbol to its id. A maximal run of symbols that are not pieces
   becomes one `<unk>` (pin P4).

No other normalization is applied. Empty text encodes as U+2581 alone
(pin P7). (`BPEEncoder.encode`, `BPEEncoder.swift:43-74`;
`Tokenizer::encode`, `tokenizer.rs:130-206`; vectors `encode`;
`testEncoderHandCases`)

"Encodes without `<unk>`" means the result is non-empty and contains no id 0.
(`BPEEncoder.encodesWithoutUnknown`, `BPEEncoder.swift:76-79`; `encodable`,
`lf-asr/src/dictionary.rs:198-203`)

### §1.4 Casing restoration

Casing restoration runs on the raw transcript before post-processing
(macros, formatting, Return). It runs on every dictation on every platform.
(`CasingRestorer`, `CasingRestorer.swift:4-5`;
`LocalParakeetService.dictationResult`, `LocalParakeetService.swift:226-228`;
the worker's `run`, `linux/crates/lf-daemon/src/worker.rs:427-429`)

macOS and iOS also restore casing on every verification re-decode, with
the same entries the decode used (`LocalParakeetService.suggestCorrection`,
`LocalParakeetService.swift:249-280`). Linux compares the re-decode's raw
text (`AsrRecognizer::redecode`,
`linux/crates/lf-daemon/src/recognizer.rs:114-132`). Restoration keeps the
fold of the text unchanged and norms fold case, so this does not change
acceptance (§1.6.4) (inferred).

- Only entries containing a scalar that folding changes take part.
  Lowercase-only entries are inert.
- Candidate entries are ordered longest first by scalar count, then by entry
  text in scalar order.
- The scan runs left to right. A match can start only at a position that
  begins the transcript or follows a non-word character. The first entry
  matches if its fold equals the folds of a run of transcript scalars
  starting there; each transcript scalar's fold is consumed whole. The run
  must end the transcript or be followed by a non-word character. The run
  is replaced by the entry text, and the scan continues after it without
  rescanning the replacement.

(`CasingRestorer.apply`, `Sources/Dictionary/CasingRestorer.swift:12-62`;
`apply_casing`, `linux/crates/lf-dictation/src/correction.rs:33-81`;
vectors `casing`; `testCasingHandCases`)

### §1.5 Correction candidates and alignment

The inputs are the typed text (what LocalFlow inserted), the edited text
(the user's correction), the dictionary, the ignore list and the
vocabulary. The output is a list of candidates in text order.
(`CorrectionCandidates.find`,
`Sources/Dictionary/CorrectionCandidates.swift:91-130`;
`correction_candidates`, `linux/crates/lf-dictation/src/correction.rs:227-287`;
vectors `candidates`)

**§1.5.1 Bounds.** If either side has more than 4096 UTF-8 bytes or more
than 200 words, there are no candidates. (`CorrectionCandidates.maxBytes`,
`maxWords` and `withinBounds`, `CorrectionCandidates.swift:93-103`;
`MAX_CORRECTION_BYTES` and `MAX_CORRECTION_WORDS`,
`correction.rs:22-25,237-241`)

**§1.5.2 Words.** Each side is split with `words()`. Every word keeps its
split index. Words whose norm is empty are dropped, and the others keep
their original index. (`DictionaryWord.split`,
`CorrectionCandidates.swift:56-68`; `tokenize`, `correction.rs:107-127`)

**§1.5.3 Alignment.** A word-level Levenshtein alignment of the norms, with
unit costs and the pinned backtrack order (pin P2).
(`WordAlignment.align`, `CorrectionCandidates.swift:4-54`; `align`,
`correction.rs:132-196`)

**§1.5.4 Rewrite check.** Let `longest` be the word count of the longer side
(after §1.5.2) and `edits` the number of non-match alignment operations
(substitutions, deletions and insertions). If `longest ≥ 5` and
`2 · edits > longest`, there are no candidates. For example, `a b c d e` to
`b c x y e` has 3 edits against `longest` 5, so it is rejected. (in
`CorrectionCandidates.find`, `CorrectionCandidates.swift:107-109`;
`REWRITE_MIN_WORDS`, `correction.rs:26-27,242-254`)

**§1.5.5 Blocks.** A block is a maximal run of alignment operations that are
substitutions, deletions, insertions, or norm matches whose edge-stripped
surfaces differ (pin P1). (`inBlock` in `CorrectionCandidates.find`,
`CorrectionCandidates.swift:111-128`; `is_edit` in `correction_candidates`,
`correction.rs:256-287`)

**§1.5.6 Qualifying a block.** A block becomes a candidate only if all of
these hold:

- Each side has 1 to 3 words.
- The surface is the edited side's words joined by U+0020, with edge
  punctuation stripped from both ends. It passes §1.1 validation at
  strength 1.
- Its key is not already in the dictionary or the ignore list.

The candidate's kind is **casing** when the two sides have equal norms.
Such a block qualifies only if the surface has an uppercase scalar after
its first (pins P1 and P5). Every other qualifying block is a **replace**
candidate.

Each candidate records `before_range`, the half-open range of the typed
words' split indices, and `before_words`, the norms of those words.
(`CorrectionCandidates.candidate`, `CorrectionCandidates.swift:132-169`;
`qualify`, `correction.rs:289-326`; `testCandidateHandCases`)

### §1.6 Verify decision, strength ladder and budgets

A casing candidate needs no audio. It is accepted at strength 1 and never
decoded. A replace candidate is accepted only if re-decoding the retained
audio, with the dictionary snapshot plus the candidate, recovers the
candidate exactly where the user corrected it.
(`VerifyDecision`, `Sources/Dictionary/VerifyDecision.swift:4-76`;
`Expected` and `verify_decision`,
`linux/crates/lf-dictation/src/correction.rs:328-463`; vectors `verify`)

**§1.6.1 Base.** `B` is the norms of the dictation's transcript after
casing restoration and before post-processing.
(`VerifyDecision.accepts`, `VerifyDecision.swift:36-38`;
`LocalParakeetService.dictationResult`, `LocalParakeetService.swift:226-233`;
`Retained::raw`, `linux/crates/lf-daemon/src/worker.rs:33-43`)

**§1.6.2 Mapping.** Align the norms of the typed text to `B` (§1.5.3). Every
word of the block must align as an exact match, and the matched words must
form one contiguous run `B[i..<j]` equal to `before_words`. If they do not,
the candidate cannot be attempted (pin P8). (`VerifyDecision.mapBlock`,
`VerifyDecision.swift:11-33`; `Expected::new`, `correction.rs:351-393`)

**§1.6.3 Expected transcript.** `E = B[..<i] + x + B[j...]`, where `x` is the
norms of the candidate surface. (`VerifyDecision.accepts`,
`VerifyDecision.swift:39-40`; `Expected` and `Expected::new`,
`correction.rs:328-346,383-392`)

**§1.6.4 Acceptance.** For one re-decode `N` (casing-restored on macOS and
iOS, raw on Linux; see §1.4),
align `norms(N)` to `E` and set `lo = max(0, i − 2)` and
`hi = min(|E|, i + |x| + 2)`. `N` is accepted when both hold:

- (a) No substitution or insertion touches `E[lo..<hi]`, and no `N`-only
  word sits before `E[p]` for any `lo ≤ p ≤ hi` (pin P3).
- (b) Every other edit block has `before_words` as its `E` side and `x` as
  its `N` side; that is, the same correction recovered elsewhere.

(`VerifyDecision.accepts`, `VerifyDecision.swift:42-76`;
`VERIFY_CONTEXT_WORDS` and `Expected::accepts`,
`correction.rs:30-31,396-458`; `testVerifyHandCases`)

**§1.6.5 Strength ladder.** Strengths are tried in this order: 1.0, 1.41,
2.0, 2.83, 4.0, 5.66, 8.0. The first accepted strength becomes the
suggestion's strength. (`VerifyDecision.strengths`,
`VerifyDecision.swift:7`; `VERIFY_STRENGTHS`, `worker.rs:28-29`; vectors
`constants.verify_strengths`) iOS "Find strength" reuses the ladder with
its own acceptance rule (`StrengthProbe.accepts` and `StrengthProbe.find`,
`StrengthProbe.swift:25-77`; see the platform differences).

**§1.6.6 Budgets.**

- At most 3 candidates are attempted, in text order. Candidates that cannot
  be attempted are dropped first and do not count toward the cap (pin P8).
- Each candidate gets at most 7 decodes, one per strength.
- The whole check gets 3 s of elapsed time from its start.
- The check stops when cancelled.
- The budget and cancellation are checked before every decode, after every
  decode (before its result counts), and before a casing candidate is
  accepted.
- A decode error ends the check with no suggestion.

(`DictionarySuggestionFinder.maxCandidates`, `maxSeconds` and `find`,
`VerifyDecision.swift:113-162`; `MAX_VERIFY_CANDIDATES`, `VERIFY_BUDGET`
and `verify_with_clock`, `worker.rs:24-31,308-386`;
`testSuggestionBudgets`; `testVerificationOrder`)

The shared vectors test single decisions. Each platform tests ordering and
budgets with a mocked clock (vectors `verify` description). Two parts of
verification are macOS only (§3.4 and the platform differences):

- When the dictionary is full, nothing is verified.
  (`DictionarySuggestionFinder.find`, `VerifyDecision.swift:127-129`)
- Within one dictation, a candidate that failed at every strength is
  remembered and skipped. (`ExhaustedCandidates`,
  `VerifyDecision.swift:89-111,159`)

### §1.7 Shared vectors

`linux/testdata/dictionary-vectors.json` (version 1) has these sections:
`constants`, `vocab`, `encode`, `validation`, `phrases`, `graph`,
`decision`, `casing`, `candidates`, `verify` and `keys`. The file's
`description` array defines each section's exact semantics. All text in it
is invented.

- Consumers: `Tests/DictionaryVectorTests.swift`,
  `linux/crates/lf-asr/tests/dictionary_vectors.rs` and
  `linux/crates/lf-dictation/tests/dictionary_vectors.rs`.
- Validation error names are the raw values of `DictionaryEntryError`
  (`DictionaryEntry.swift:17-25`).
- Graph bonuses must match within 1 ULP of f32. Expected values are exact
  f64 math cast to f32 (vectors `graph` description).
- Because both suites read this one file, a change to any §1 rule needs the
  vectors and both implementations changed together (inferred).

## §2 Linux daemon

### §2.1 Storage

- The dictionary is stored in `$XDG_DATA_HOME/localflow/dictionary.json`,
  shaped `{"version":1,"entries":[{"text":…,"strength":…}],"ignore":[…]}`.
- The data directory is mode 0700.
- The file is opened with `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`. It must be
  a regular file owned by the effective uid, with mode exactly 0600, and
  at most 1 MiB. A missing file is an empty dictionary.
- Loading requires version 1 and at most 1000 entries. Each entry must be
  valid under §1.1 and stored already normalized, and no two entries may
  share a key. The ignore list may hold at most 1000 keys, each valid under
  pin P6, without repeats. Any other content is an error that quotes no
  content.
- A change is written to a 0600 temporary file, synced, renamed over the
  file, and the directory is synced. Only then is the change published.
  - A failed write changes nothing.
  - If only the directory sync fails, the rename is undone and the change
    is refused (`error storage`). Memory never changes.
  - If the rename cannot be undone, the file on disk may hold the refused
    change. The store is marked broken, the daemon replies `error storage`
    and stops, and its next start loads that file.

(The `lf_daemon::dictionary` module doc and `MAX_FILE_BYTES`,
`linux/crates/lf-daemon/src/dictionary.rs:2-23,38-40`; `Store::recover` and
`Store::is_broken`, `dictionary.rs:230-280`; test
`a_failed_directory_sync_is_undone_and_refused`, `dictionary.rs:736-780`)

### §2.2 Snapshots

Each published change is a new immutable `Snapshot`, identified by a
revision. A dictation decodes with the snapshot taken when it was
submitted. (`Snapshot`, `lf-daemon/src/dictionary.rs:61-68`;
`Controller::finish`, `lf-daemon/src/controller.rs:1237-1258`)

Agent-link project words are boosted together with the dictionary, and the
dictionary's strength wins on overlap. They are not dictionary changes.
(the `lf_daemon::controller` module doc and `Controller::finish`,
`controller.rs:81-85,1239-1242`)

### §2.3 Decoding

Casing is restored on the raw transcript before `lf_dictation::process`
(§1.4; the worker's `run`, `lf-daemon/src/worker.rs:427-429`). The biased
decision rule is §1.2's (`token_decision`, `lf-cpu/src/decoder.rs:995-1009`).

### §2.4 Correction session

- At most one session exists: the last typed dictation, held in memory
  only. It never reaches logs, `watch`, history or `Debug` output.
  (`CorrectionSession`, `controller.rs:131-138`; `Retained`,
  `worker.rs:33-43`)
- A dictation is kept only if all of these hold (`eligible` in the
  worker's `run`, `worker.rs:432-441`; `Controller::finish`,
  `controller.rs:1237-1258`):
  - it is not a macro;
  - it does not press Return;
  - its output is non-empty, at most 4096 bytes and free of control
    characters;
  - the dictionary revision has not changed since the dictation was
    submitted.
- The session lasts 120 s (`CORRECTION_WINDOW`). It is discarded earlier
  by a new recording, a cancel, or any published dictionary change.
  Discarding cancels its check, or marks the check stale.
  (`CORRECTION_WINDOW`, `discard_correction`, `expire_correction`,
  `apply_change`, `start_recording` and `cancel`,
  `controller.rs:127-129,419-443,595-605,1017-1025,1130-1131`)
- The retained audio is the dictation's encoder projection. Its size is
  bounded only by `max_recording_seconds` (default 300 s;
  `lf-daemon/src/config.rs:107,247`).
- `correct-submit` computes every candidate. The worker drops the ones it
  cannot attempt, then takes at most three (pin P8). A newer submit cancels
  a pending check. (`submit_correction`, `controller.rs:501-553`)

### §2.5 Dictionary and correction commands

The text commands are `correct-begin`, `correct-submit`, `correct-result`,
`dict-add`, `dict-remove`, `dict-ignore` and `dict-unignore`.
(the `lf_daemon::protocol` module doc, `linux/crates/lf-daemon/src/protocol.rs:43-72`)

- Text travels percent-encoded. Strengths are `<dec>` values within
  [0.25, 8], carried internally as milli-units (`format_dec`, `parse_dec`
  and `STRENGTH_RANGE`, `protocol.rs:830-862`).
- Error codes include `invalid-entry`, `full`, `not-found`, `storage`,
  `stale` and `too-long`.

`localflowctl correct` drives the user flow through rofi:

- It works within two minutes of a dictation.
- The user edits the dictation's text there; the text already typed into
  the other app is never changed.
- A second prompt offers "Add", "Not now" or "Don't suggest" for one
  verified suggestion.

(`linux/README.md:199-222`, "Teaching it from a correction")

## §3 macOS and iOS app

### §3.1 Decoder hook

Biased greedy TDT decoding uses the same loop and limits as the unbiased
decode, including at most 10 symbols per frame. The differences:

- The token is §1.2's biased argmax over the exposed logits.
- The bias state follows non-blank emissions, and a blank keeps it.

(`LocalParakeetCore.decode(length:bias:predict:joint:check:)`,
`Sources/Dictionary/BiasGraph.swift:158-188`; `testBiasedDecode`)

Each transcription decodes with one immutable `DictionarySnapshot`
(entries and revision). If the saved dictionary is unreadable, the
snapshot is empty. The graph is built on the model queue and cached by
revision. (`AppState.dictionarySnapshot`, `Sources/AppState.swift:327-330`;
`LocalParakeetRuntime.graph(for:)`,
`Sources/Parakeet/LocalParakeetService.swift:534-542`)

### §3.2 Storage

UserDefaults holds two keys (`DictionaryStorage`,
`Sources/Dictionary/DictionaryEntry.swift:139-199`;
`AppState.dictionaryStorageKey` and `dictionaryIgnoreStorageKey`,
`Sources/AppState.swift:295-332`):

| Key | Payload |
|---|---|
| `custom_dictionary` | `{"entries":[{"strength":…,"text":…}],"version":1}` |
| `custom_dictionary_ignore` | `{"ignore":[…],"version":1}` |

Both are JSON with sorted keys, and each payload is at most 1 MiB.

Loading validates everything:

- version 1, at most 1000 entries;
- every entry valid under §1.1 and stored already normalized, with no
  duplicate keys;
- every ignore key valid under pin P6 and stored exactly as saved, with no
  repeats.

A value of the wrong type is unreadable, never "missing". If anything
fails, the dictionary is empty in memory and the saved data is left
untouched. Edits are refused until an explicit reset removes both keys.
(`AppState.resetSavedDictionary` and `loadCustomDictionary`,
`AppState.swift:2299-2305,2326-2338`; `testStorage`)

`correction_suggestions_enabled` turns correction suggestions on or off.
It defaults to on. (`AppState.correctionSuggestionsStorageKey` and
`isCorrectionSuggestionsEnabled`, `AppState.swift:299,310-319,462`)

iOS uses the same keys and payloads, in the host app's standard
UserDefaults and never in the App Group. Its UI shows no ignore list but
keeps whatever is stored. (`DictionaryLibrary`,
`iOS/HostCore/DictionaryLibrary.swift:3-11`)

### §3.3 Editing

Every change goes through `DictionaryEditor`. A change is validated,
persisted, then published. Publishing raises the revision, stops all
correction work, and withdraws any visible suggestion.

- Without a vocabulary nothing can be edited.
- Errors are content-free.
- Settings shows inline validation once something is typed.

(`DictionaryEditor`, `Sources/Dictionary/DictionaryEditor.swift:2-78`;
`AppState.apply`, `applyDictionary` and `dictionaryDidChange`,
`AppState.swift:2268-2323`; `DictionaryEntryEditorView.validationError`,
`Sources/SettingsView.swift:777-785`; `testEditsNeedVocabulary`)

### §3.4 Retained correction sessions (macOS)

Audio is retained only while all of these hold: suggestions are on, the
dictionary is readable, and Accessibility is trusted.
(`AppState.retainsAudioForCorrection`, `AppState.swift:1584-1587`)

- **What is kept.** The per-chunk encoder projections (frames × 640 f32),
  the snapshot, and the base text (§1.6.1).
  (`LocalParakeetService.dictationResult` and
  `LocalParakeetRuntime.transcribeChunk`,
  `LocalParakeetService.swift:226-233,552-562`)
- **Size.** Retention is dropped once the projections exceed 16 MiB.
- **One session.** The store holds at most one session. A new one replaces
  it, and a stale id finds nothing.
- **Lifetime.** 90 s, enforced by deadline and by a scheduled expiry that
  never drops a newer session.

(`CorrectionSessionStore`, `defaultMaxBytes` and `defaultLifetime`,
`Sources/Dictionary/CorrectionSessionStore.swift:23-73`;
`LocalParakeetService.scheduleExpiry`, `LocalParakeetService.swift:316-321`;
`testRetainedSessions`)

A finished dictation is watched only if all of these hold
(`CorrectionEligibility.isEligible`, `CorrectionSessionStore.swift:6-21`;
`AppState.correctionPasteContext`, `AppState.swift:2181-2197`;
`testEligibilityWindow`):

- suggestions are on;
- the dictionary is readable;
- the audio was retained with the current revision;
- nothing was cancelled since recording stopped;
- it is not a macro and does not press Return;
- its output is non-empty and at most 4096 bytes.

Otherwise its audio is released.

The session is released when:

- a suggestion is claimed;
- the watch's last check finishes;
- no field is captured: nothing within the 0.3 s deadline, or suggestions
  were turned off meanwhile;
- a new dictation starts;
- the dictation is cancelled;
- suggestions are turned off;
- the dictionary changes;
- the app quits.

(`AppState.pasteAtCursorWhenShortcutReleased`, `stopCorrectionSuggestions`
and `dictionaryDidChange`, `AppState.swift:2142-2169,2199-2209,2318-2323`;
`LocalParakeetService.suggestCorrection`, `discardCorrectionSession` and
`releaseCorrectionSession`, `LocalParakeetService.swift:244-301`)

A field can be captured and the watch still fail to begin, for example
because the paste no longer ends at the caret. Nothing is released early
then: the audio stays until the 90 s expiry or one of the events above.
(`CorrectionWatcher.start`, `CorrectionWatcher.swift:449-457`)

### §3.5 Correction watcher and suggestion presentation (macOS)

The watcher is high risk: it reads another app's text field through
Accessibility. Text it reads stays in the session record and local
variables, is cleared when the watch finishes, and is never logged,
persisted or transmitted. (The `CorrectionWatcher.swift` header comment,
`Sources/Dictionary/CorrectionWatcher.swift:3-6`;
`AccessibilityTextFieldReader`, `Sources/AccessibilityTextFieldReader.swift:5-10`)

| Watcher constant | Value | Source |
|---|---|---|
| Capture deadline (the paste waits for the capture, at most this long) | 0.3 s | `CorrectionWatcher.captureDeadline` and `capture` (`CorrectionWatcher.swift:389,423-446`); `AppState.pasteAtCursorWhenShortcutReleased` (`AppState.swift:2142-2169`) |
| Settle delay after the paste | 0.15 s | `CorrectionWatcher.settleDelay` and `start` (`CorrectionWatcher.swift:390,449-464`) |
| Poll interval | 0.5 s | `CorrectionWatcher.pollInterval` (`CorrectionWatcher.swift:391`) |
| Longest watch | 60 s | `CorrectionWatchSession.maxDuration` (`CorrectionWatcher.swift:99`) |
| Quiet period before an edit is checked | 1.5 s | `CorrectionWatchSession.quietPeriod` (`CorrectionWatcher.swift:98`) |
| Checks per paste (the last ends the watch) | 3 | `CorrectionWatchSession.maxChecks` (`CorrectionWatcher.swift:100-101`) |
| Longest paste watched | 4097 UTF-16 units (4096 bytes plus the trailing space) | `CorrectionWatchSession.maxPastedUnits` (`CorrectionWatcher.swift:95`) |
| Context kept on each side | 40 units | `CorrectionWatchSession.contextUnits` (`CorrectionWatcher.swift:93`) |
| Span growth or shrinkage tolerated | 200 units | `CorrectionWatchSession.maxGrowth` (`CorrectionWatcher.swift:94`) |
| Read window at begin / per poll | 4200 / 4600 units | `CorrectionWatchSession.beginWindowLimit`/`pollWindowLimit` (`CorrectionWatcher.swift:96-97`) |
| Accessibility messaging timeout | 0.25 s | `AccessibilityTextFieldReader.messagingTimeout` (`AccessibilityTextFieldReader.swift:12`) |

**Watching**

- Only another app's focused, editable text area, text field or combo box
  is watched, never a secure one.
- Only these attributes are read: role, subrole, focus, character count,
  selection, and `AXStringForRange`. The full `AXValue` is never requested.
  (`AccessibilityTextFieldReader`, `AccessibilityTextFieldReader.swift:5-14`)
- At begin, the pasted text must end exactly at an empty selection.
- Each poll locates the span from its recorded context. The before-context
  must sit right before the span (or the span starts the document). The
  after-context must occur exactly once (or the span runs to the end).
  (`CorrectionWatchSession.begin` and `locate`,
  `CorrectionWatcher.swift:143-178,242-285`; `testSpanTracking`)
- Before every read, three things are checked: permission, the same process
  and element, and a non-secure field. Cancellation is checked before and
  after that safety check. Past the 60 s window, no text is read.
  (`CorrectionWatchSession.poll`, `guardedRead` and `safetyCheck`,
  `CorrectionWatcher.swift:184-213,287-324`; `testDeadlineStopsReads`)
- An edit unchanged for the quiet period is reported for checking, and the
  watch continues. (`CorrectionWatchSession.poll` and `report`,
  `CorrectionWatcher.swift:201-225`)

**Ending a watch**

- When a stop does not forbid captured text, an unchecked edit already read
  is finalized from memory.
- Cancel, lost permission and a secure field discard everything and abandon
  edits already reported. (`CorrectionDiscardReason.forbidsCapturedText`,
  `CorrectionWatchSession.end` and `expire`,
  `CorrectionWatcher.swift:39-49,227-240`; `testWatchEndsWithCapturedEdit`;
  `testForbiddenStopAbandonsReportedEdits`)

**Checks**

- Each reported edit starts a check that cancels any older one.
- Nothing is checked unless a suggestion may be presented, Accessibility is
  trusted, and the dictionary has room.
- A result is used only if its watch can be claimed atomically. Claiming
  ends the watch, so there is one suggestion per dictation.

(`AppState.handleCorrectionEdit`, `AppState.swift:2220-2249`;
`CorrectionWatcher.claim`, `CorrectionWatcher.swift:471-479`;
`testClaimingAWatch`; `testCorrectionChecksKeepTheirOrder`)

**Presentation**

- A suggestion may show only when suggestions are on, the dictionary is
  editable, and no dictation is under way. A dictation counts as under way
  while recording or transcribing, while a shortcut start is pending, and
  during a shortcut session. (`CorrectionSuggestionTiming.mayPresent`,
  `SuggestionPresentationGate.swift:59-67`)
- The overlay holds the only copy of a suggestion, bound to an id.
- A withdrawal is a recording press or start, a dictionary edit, or turning
  the setting off. A presentation requested before a withdrawal never
  shows.
- After 12 s a suggestion resolves as "Not now". However it leaves the
  screen, the word is cleared.
  (`SuggestionPresentationGate` and its `lifetime`,
  `Sources/Dictionary/SuggestionPresentationGate.swift:8-57`;
  `showDictionarySuggestion` and `withdrawDictionarySuggestion`,
  `Sources/RecordingOverlay.swift:275-300`; `testSuggestionGate`;
  `testSuggestionWithdrawal`)
- The actions are:
  - **Add:** saves the word at the verified strength, through §3.3.
  - **Don't suggest:** adds the key to the ignore list.
  - **Not now:** does nothing.

  (`AppState.handleDictionarySuggestionAction`, `AppState.swift:2251-2266`)

## Platform differences

| Aspect | macOS | iOS | Linux |
|---|---|---|---|
| Implementation | Swift, `Sources/Dictionary` | the same Swift sources (`iOS/ARCHITECTURE.md`, "Custom dictionary") | Rust: `lf-asr`, `lf-cpu`, `lf-dictation`, `lf-daemon` |
| Storage | two UserDefaults keys (§3.2) | the same keys in the host app's UserDefaults, never the App Group | one 0600 file with entries and ignore list (§2.1) |
| Vocabulary file | `vocabulary.json` | `vocabulary.json` | `tokenizer.vocab`, with scores checked (§1.3) |
| How corrections are found | Accessibility watcher on the pasted text (§3.5) | none: entries are added by hand | user-initiated `localflowctl correct` (§2.5) |
| Strength calibration | the strength verified from a correction | "Find strength": one recording, `StrengthProbe.accepts` accepts a decode whose every edit block has the word as its new side and replaces at most `maxExtraReplacedWords` (2) extra words (`StrengthProbe.swift:25-77`) | the strength verified from a correction |
| Retained audio | projections ≤ 16 MiB, 90 s (§3.4) | for "Find strength" only, released when the sheet closes | projection of the last typed dictation, 120 s (§2.4) |
| Candidates that failed at every strength | remembered per dictation (`ExhaustedCandidates`) | not applicable | not remembered (inferred: no such cache in `verify_with_clock`, `worker.rs`) |
| Full dictionary | nothing verified or offered (`DictionarySuggestionFinder.find`) | not applicable | still verified; `dict-add` then fails with `full` (inferred: no capacity check in `submit_correction` or `verify_with_clock`) |
| Phrase order before building the graph | first seen (`BiasGraph.phrases`) | first seen | sorted by token sequence (`phrases`); the graph does not depend on order (vectors `graph`, "G2 reversed") |
| Suggestion UI | overlay, 12 s, Add / Not now / Don't suggest | not applicable | rofi prompt, Add / Not now / Don't suggest |
| Project words | none | none | agent-link words are boosted and never end a session (§2.2) |
