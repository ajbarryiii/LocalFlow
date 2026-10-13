# Custom dictionary: word boosting experiments

These notes record what we tried before shipping the custom dictionary, and why the shipped design is what it is. The experiment code lives on the unmerged branch `archive/word-boosting-experiments`. Data and full result tables stayed on the development machine. No transcripts or user data were used: every experiment ran on public speech corpora.

## Shipped design

The dictionary biases greedy TDT decoding towards the user's words. It uses a fixed, depth-scaled bonus over an Aho-Corasick prefix tree of the entries' tokens:

- Each token that extends a match to depth `d` gets `α · strength · (1 + 3 · ln d)` added to its logit before the argmax, with α = 1.414.
- Every case variant of an entry is boosted (as typed, lowercase, first letter capitalized, each word capitalized).
- Unfinished matches are not cancelled.
- Each entry has its own strength (default ×1).

When the user corrects a misrecognized word, LocalFlow re-decodes the same audio with that word boosted at increasing strengths. It only suggests adding the word if the word then appears without disturbing the rest of the transcript. The strength that first worked becomes the entry's strength.

## Experiment 1: a fixed bonus

**Question:** does a fixed bonus help, and how strong should it be?

**Setup:**
- **Tuning data:** LibriSpeech test-clean, with the biasing lists of Le et al. 2021 (each utterance's rare words plus 100, 500 or 1000 distractors).
- **Held out:** test-other with the same lists, and Earnings-22 with per-call lists.
- **Search:** the bonus scale, depth scaling, cancelling unfinished matches, and case variants.

**Results** (held out, list size 100):

| Set | WER | Rare-word WER (B-WER) | Other words (U-WER) |
|---|---|---|---|
| LibriSpeech test-other | 4.41 → **3.41%** | 20.7 → **11.0%** | 2.56 → 2.55% |
| Earnings-22 | 15.39 → 15.47% (15.16% at half the scale) | 30.9 → 27.7% | 12.0 → 12.8% |

**What we learned:**
- **Case variants matter.** Without them test-other WER is 3.96% instead of 3.41%.
- **Cancelling unfinished matches hurts greedy decoding.**
- **Larger lists help a little less.**
- **No single strength fits all words.** For each missed word we decoded with only that word boosted. Almost every miss could be forced in, but the scale needed varied about 30×: the median was 1.4 on LibriSpeech and 5.7 on Earnings-22. That's why entries have their own strength, calibrated from the user's corrections.

## Experiment 2: a learned bonus with a prefix-tree GNN

**Question:** can a small learned module set the bonus per decision, from the decoder state and graph-neural-network encodings of the dictionary's prefix tree, and beat the fixed bonus? The approach follows TCPGen with GNN encodings (Sun, Zhang & Woodland, 2022).

**Models:**

| Model | What it adds | Parameters |
|---|---|---|
| L1 | hand-made features | 5k |
| L2 | decoder state and token identity | 3.5M |
| L3 | L2 plus subtree message passing | 5.6M |
| L3S | L3's size without the messages (a capacity control) | 5.6M |

**Data.** We used corpora the recognizer was not trained on. Training data: SPGISpeech, SlideSpeech and ICSI meetings. Held out: LibriSpeech test-other, Earnings-22, GigaSpeech, SlideSpeech test (rare-word lists and slide-keyword lists), ICSI eval and ACL 60/60. Dictionaries held each session's rare, session-specific words plus distractors. Models were selected on dev data only.

**Results.** Net errors are summed over every held-out set and list size; more negative is better.

| Model | Net errors |
|---|---|
| Fixed bonus, experiment 1 | −4,398 |
| Fixed bonus retuned on these domains | −3,490 |
| L1 | −4,202 |
| L2 | −5,095 |
| L3 (GNN) | −4,984 |
| L3S (no messages) | −5,259 |
| L3 trained on 25% of the data | **−5,914** |

**What we learned:**
- **The learned bonuses won mainly by being more cautious.** They made far fewer false insertions; the fixed bonus kept the best recall.
- **The GNN added nothing.**
- **More training made things worse.** The 25%-data run was best, which pointed at overtraining rather than missing capacity.

## Experiment 3: short training schedules, checked on a sealed set

**Question:** does a short training schedule make the learned bonus reliably better?

**Setup:**
- **Search:** L2 only, with three learning rates, checkpoints from 250 to 6000 steps, and a truncated version of experiment 2's schedule.
- **Selection** on dev; the winner was then retrained with two more seeds.
- **Confirmation set (pre-registered):** Earnings-21, 44 calls. None of these experiments had used it, and it showed no meaningful text overlap with the training calls.
- **Planned set dropped:** TED-LIUM was the first choice, but it had been withdrawn upstream, so it wasn't used.

**Results:**
- **Dev data:** stopping after 250 steps looked best (0.937 against 0.950 for experiment 2's L2). That was mostly selection noise: the winner won only 38% of bootstrap resamples, and fresh seeds scored 0.943 and 0.949.
- **The pre-registered Earnings-21 comparison was not supported.** Against experiment 2's L2, the new L2 was +0.017 WER points (95% CI −0.022 to +0.054).
- **On Earnings-21 the experiment 1 fixed bonus beat every learned model.** It removed 5,067 errors, against 1,850 to 3,154 for the learned models. The learned L2 was +0.27 WER points worse than it (95% CI +0.17 to +0.37).

## Conclusions

- **Ship the fixed bonus from experiment 1:** α 1.414, depth scaling 3, no cancelling, case variants on. It is simple, costs almost nothing per decision, needs no training data, and won on the only fresh test set.
- **Make strength per entry.** The strength a word needs varies a lot, and the user's corrections plus the audio check can calibrate it.
- **Drop learned biasing.** It needed a training pipeline and research-only training data (SPGISpeech and SlideSpeech are non-commercial), cost about 6× the joint network per decision, and didn't generalize.

**Ideas not pursued:**
- a text-only proposer for likely misrecognitions, checked against the audio;
- rewrite rules that map exact repeated mishearings to the right word;
- beam search.
