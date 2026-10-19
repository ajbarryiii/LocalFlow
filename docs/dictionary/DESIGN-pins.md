# Custom dictionary: pinned interpretations

Each pin settles a point that [DESIGN.md](DESIGN.md) could otherwise be read
two ways, so that Swift and Rust behave identically. Code cites them as
"pin Px" or "DESIGN Px". The source conventions match DESIGN.md: paths are
relative to the repository root, and **inferred** marks a statement read
from behavior rather than stated by a comment, test or vector.

| Pin | Subject | Section |
|---|---|---|
| P1 | Which edits form a block, and which casing changes qualify | §1.5.5, §1.5.6 |
| P2 | Alignment tie order | §1.5.3 |
| P3 | Window edits by words only in the re-decode | §1.6.4 |
| P4 | Runs of non-pieces encode as one `<unk>` | §1.3 |
| P5 | "Uppercase" is the Unicode `Uppercase` property | §1.0, §1.5.6 |
| P6 | Validity of stored identity and ignore keys | §1.1, §2.1, §3.2 |
| P7 | Empty text still gets the dummy prefix | §1.3 |
| P8 | Unattemptable candidates are dropped before the cap of three | §1.6.2, §1.6.6 |

## P1: blocks and casing candidates

- A block also includes a norm match whose edge-stripped surfaces differ,
  such as `nixos` against `NixOS`. Without this rule, a pure casing change
  would form no block.
- A casing candidate (equal norms on both sides) qualifies only if its
  surface has an uppercase scalar (P5) after its first scalar. A capitalized
  first letter alone, as at a sentence start, is never a candidate: `the
  plan` to `The plan` gives nothing, and so does `kubernetes` to
  `Kubernetes`.

Sources: `Sources/Dictionary/CorrectionCandidates.swift:70-71,111-115,157-162`,
`linux/crates/lf-dictation/src/correction.rs:227-230,256-259,307-314`.
Tests: `testCandidateHandCases` (`Tests/DictionaryTests.swift:431-437`) and
vectors `candidates`.

## P2: alignment tie order

The alignment is a word-level Levenshtein alignment with unit costs. When
backtracking from the end, prefer the diagonal (a match or substitution),
then a deletion (a word only in the first sequence), then an insertion (a
word only in the second). Unpaired words record where they sit in the other
sequence.

For example, `[a, b]` against `[c]` aligns as delete `a`, then substitute
`b`→`c`. `[c]` against `[a, b]` aligns as insert `a`, then substitute
`c`→`b`.

Sources: `Sources/Dictionary/CorrectionCandidates.swift:4-54`,
`linux/crates/lf-dictation/src/correction.rs:132-196`. Tests:
`testCandidateHandCases` (`Tests/DictionaryTests.swift:460-464`),
vectors `candidates` and `verify`.

## P3: window edits by words only in the re-decode

In §1.6.4(a), a substitution or insertion counts when its position in `E`
lies in `[lo, hi)`. A word that appears only in the re-decode `N` sits
before some `E[p]`, and it counts when `lo ≤ p ≤ hi`, inclusive at both
ends. An extra word just past the window's end therefore rejects the
decode.

Example: `E = a b chart c d e f`, so the window is `[0, 5)`. The extra word
`zz` before `E[5]` rejects the decode.

Sources: `Sources/Dictionary/VerifyDecision.swift:44-55`,
`linux/crates/lf-dictation/src/correction.rs:396-428`. Tests:
`testVerifyHandCases` (`Tests/DictionaryTests.swift:504-507`), vectors
`verify`.

## P4: one `<unk>` per run of non-pieces

After merging, each maximal run of consecutive symbols that are not
vocabulary pieces becomes a single `<unk>` (id 0). Runs separated by a
piece stay separate: `tzzh` encodes as `[▁t, <unk>, h]` and `tzhz` as
`[▁t, <unk>, h, <unk>]` in the test vocabulary.

Sources: `Sources/Dictionary/BPEEncoder.swift:61-73`,
`linux/crates/lf-asr/src/tokenizer.rs:130-137,196-206`. Tests:
`testEncoderHandCases` (`Tests/DictionaryTests.swift:108-110`), vectors
`encode`.

## P5: uppercase means the `Uppercase` property

"Uppercase" means the Unicode `Uppercase` derived property, not general
category Lu. Swift uses `Unicode.Scalar.Properties.isUppercase` and Rust
uses `char::is_uppercase`; both implement that property (inferred from
their documentation). P1's casing test is the only user of this rule.

Sources: `Sources/Dictionary/DictionaryText.swift:62-63`,
`linux/crates/lf-dictation/src/correction.rs:311`. Tests: the §1.5 cases
in `testCandidateHandCases` (`Tests/DictionaryTests.swift:401`).

## P6: stored identity and ignore keys

A stored identity key or ignore key is valid if and only if all of these
hold:

- it is non-empty;
- it has at most 300 scalars;
- it has at most 8 words separated by U+0020;
- it contains no control character (Cc);
- `fold(key) == key`.

The key limit is 300 scalars, not 100, because folding can expand text. A
valid 100-scalar entry such as `İ` followed by 99 × `a` has a 101-scalar
key, and it must save and load unchanged.

Three rules follow:

- A control character is never a vocabulary piece, so an entry containing
  one is `unencodable` even when no vocabulary is loaded (§1.1 step 3).
- Saving an entry or ignoring a key whose key fails P6 changes nothing.
- Loading saved data with an invalid ignore key fails the whole load.

Sources: `Sources/Dictionary/DictionaryText.swift:106-118`,
`Sources/Dictionary/DictionaryEntry.swift:38-42,72-74,181-186`,
`linux/crates/lf-asr/src/dictionary.rs:198-218`,
`linux/crates/lf-daemon/src/dictionary.rs:12-15,177-181`. Tests:
`testKeyValidity` (`Tests/DictionaryTests.swift:967-1008`),
`Tests/DictionaryVectorTests.swift:130`, the `lf-daemon` dictionary tests
(`dictionary.rs:563,785`), and vectors `keys` and `validation`.

## P7: empty text gets the dummy prefix

The U+2581 prefix is added to empty text too, as SentencePiece does, so `""`
encodes as `▁` alone. "Encodes without `<unk>`" also requires a non-empty
result.

Sources: `Sources/Dictionary/BPEEncoder.swift:44-45`,
`linux/crates/lf-asr/src/tokenizer.rs:137-140`. Tests:
`testEncoderHandCases` (`Tests/DictionaryTests.swift:111-112`), and the first
case of vectors `encode` (`""` encodes as id 63, `▁`).

## P8: verification order

Candidates are taken in text order:

- A replace candidate that cannot be attempted is dropped before the cap of
  three. "Cannot be attempted" means its block does not map onto `B`
  (§1.6.2). A dropped candidate costs no decode and no time.
- On macOS, a candidate already exhausted for this dictation is dropped the
  same way.
- Casing candidates are not mapped.
- Cancellation and the 3 s budget are checked before every decode, again
  after the decode before its result counts, and before a casing candidate
  is accepted.

On Linux the controller passes every candidate to the worker, and the
worker applies the filter and the cap.

Sources: `Sources/Dictionary/VerifyDecision.swift:121-162`,
`linux/crates/lf-daemon/src/worker.rs:321-386`,
`linux/crates/lf-daemon/src/controller.rs:518-527`. Tests:
`testVerificationOrder` (`Tests/DictionaryTests.swift:1010-1087`) and the
`lf-daemon` worker tests with a mocked clock. Vectors `verify` describe the
rule but leave ordering to these per-platform tests.
