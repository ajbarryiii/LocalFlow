# LocalFlow for Linux: implementation plan

Status: draft, 2026-10-07. Branch `feat/linux-port`.

## Decisions

| Topic | Decision |
| --- | --- |
| Target | NixOS, Hyprland (Wayland), PipeWire, Ryzen 9 9950X3D, RTX 5090 |
| Language | Rust, as a Cargo workspace under `linux/`. The macOS Swift app is untouched. |
| Inference | Native, with no Python at runtime. CPU (AVX-512) first; CUDA later as an optional backend, with the CPU kept as fallback. |
| Model | Ternary Parakeet TDT 0.6B v2, M1 export, packed offline into a LocalFlow model image |
| Shortcuts | Hyprland `bind`/`bindr` run `localflowctl`. Key still to be chosen. |
| Text insertion | Type directly through the Wayland virtual keyboard (`zwp_virtual_keyboard_v1`). The clipboard is not touched. |
| Audio | Captured in memory only, never written to disk |
| Toolchain | `linux/flake.nix` dev shell; moved into the NixOS config once things work |
| Network | The daemon makes no network connections |

The model export lives in a directory outside the repository
(`export.safetensors`, `manifest.json`, `tokenizer/`). Model files never
enter Git.

Encoder configuration, from `manifest.json`:
- 24 FastConformer layers: d_model 1024, 8 heads, rel-pos attention with untied biases, FF expansion 4, conv kernel 9 with batch norm.
- `dw_striding` subsampling ×8 with 256 channels.
- 264 ternary projections, about 604M parameters, with a per-row FP32 scale.
- Frontend: 128 mels, n_fft 512, 25 ms window, 10 ms hop.
- Decoder: 2-layer LSTM with hidden size 640, a joint over 1024 tokens + blank + 5 durations, TDT greedy with at most 10 symbols per frame.

## Phase 0: CPU feasibility (go/no-go)

Question: can CPU inference be fast enough for dictation, at acceptable accuracy?

Target: transcription compute of at most about 100 ms for 10 s of audio and
at most about 300 ms for 30 s, using no more than the 8 cores in the large-L3
CCD.

Prior evidence: in an earlier private CPU-inference prototype, packed
AVX-512 kernels on this CPU ran a 762M-parameter Whisper-medium-shaped graph
(1,500 encoder frames plus 128 decode steps) in about 1.7 s. Parakeet sees
only 375 encoder frames for 30 s of audio, so a rough estimate is tens of ms
for typical utterances. It needs measuring.

Activations stay at full precision (or within FP32 rounding of it). Training
the model to tolerate low-bit activations is out of scope.

1. Done: workspace skeleton and flake dev shell.
2. Done: `lf-model` reads safetensors, verifies every SHA-256 in `manifest.json`, and decodes the 2-bit codes (`00`=0, `01`=+1, `10`=-1; code j sits at bits 2·(j%4)).
3. Done: `lf-gemm-bench` times all 240 ternary encoder GEMMs (24 layers × 10 projections, with `linear_pos` timed separately) on the real export weights.
   - Codes stay 2 bits per weight in memory, repacked into 64-row output blocks.
   - Per block, each thread expands one tile in L2 and reuses it across every frame. The work is compute-bound once T is past roughly 20.
   - Variants:
     - **f32:** FP32 activations, FMA against a {−1, 0, +1} f32 tile.
     - **i8xN:** N residual INT8 components per frame, `VPDPBUSD` against an s8 tile. Activations are offset to u8, and a per-row code sum, computed in advance, removes the offset.
   - BF16 and bit-serial popcount were not built: BF16 loses precision, and popcount needs low-bit activations.
   - Both kernels are checked against an f64 reference in `cargo test`.

### Results (2026-10-07, real M1 weights, synthetic activations)

Encoder ternary GEMMs only, median ms, on 8 threads pinned to the V-cache CCD (CPUs 0–7):

| Audio | f32 | i8x2 | i8x3 | i8x1 |
| ---: | ---: | ---: | ---: | ---: |
| 2 s | 15.1 | 8.2 | 10.9 | 4.9 |
| 5 s | 32.8 | 16.9 | 24.6 | 9.9 |
| 10 s | 61.8 | 31.9 | 47.1 | 17.0 |
| 15 s | 94.2 | 47.0 | 69.8 | 24.8 |
| 30 s | 183.5 | 92.6 | 138.5 | 47.7 |

Error against the f64 reference, relative RMS (layer 0, synthetic activations with outlier channels):

| f32 | i8x3 | i8x2 | i8x1 |
| ---: | ---: | ---: | ---: |
| 3e-7 | 5–7e-7 | 1.4–1.7e-4 | 3.4–4.3e-2 |

- **Kernel efficiency:** one core reaches about 605 GMAC/s for INT8 (about 110 of the 128 MAC/cycle peak with two 512-bit VNNI per cycle) and about 157 GMAC/s for FP32 FMA. Eight cores scale to about 94% of linear. Sixteen cores, across both CCDs, are faster again (i8x3 at 10 s: 30.6 ms).
- **`linear_pos`:** adds about 9% on top. It depends only on T, so it can be precomputed.
- **Accuracy and cost:** i8x3 matches FP32 rounding and is 1.3× faster than the f32 kernel. i8x2 is about 2× faster with roughly FP16-level error. i8x1 is too lossy.

**Gate: passed.** Both FP32-equivalent paths (f32 and i8x3) meet the target
with only GEMMs counted. Phase 1 starts with i8x3, keeping f32 as a
cross-check. i8x2 is adopted only if its transcripts match i8x3 on dev-clean
and dev-other. That comparison runs in the native pipeline, so the Python
accuracy study isn't needed.

### Decoder (2026-10-07, `lf-decoder-bench`, real weights)

On GPU and on the Mac's Swift decoder, the decoder costs as much as the
encoder because each token is a chain of small dependent matrix-vector
products. On this CPU it is cheap:

- 12 MB of FP16 weights are read per token step, split across 64-row superblocks per thread.
- Threads sync with a spin barrier between phases.
- The embedding is folded into the first layer's input weights.
- The encoder-side joint projection is computed once per utterance.

At 4 tokens/s on 8 threads: 0.7 ms for 10 s of audio, 4.3 ms for 60 s
(16 µs per token). 16 threads are no faster. Real-argmax decoding matches an
f64 reference emission for emission. FP32 storage is about 2× slower.

### 60 s under 100 ms at full precision: not reachable on this CPU

Measured register-only ceilings (`lf-gemm-bench --peak`, 16 cores, about 5.35 GHz):

| Unit | Ceiling | 60 s projections at 100% (434 G ternary MACs) |
| --- | ---: | ---: |
| VNNI, i8x3 (about FP32) | 10.9 T int8 MAC/s | 119 ms |
| FP32 FMA | 2.7 T MAC/s | 159 ms |
| Ternary FP32 lookup table (`vpermt2ps` over 27 sums of 3 inputs, + add) | 5.5 T MAC-equivalent/s | 79 ms |
| VNNI, i8x2 (about FP16 error, not FP32) | 10.9 T | 79 ms |

The lookup-table route was proposed by the Codex review and is exact FP32.
It is limited to about 1.33 lookups per cycle per core: copy, permute and
add are three vector-ALU operations on four pipes. Reloading the destroyed
operand from L1 instead of copying it drops this to about 1.0.

A 60 s total also includes:
- exact attention, about 41–55 G FP32 MACs (roughly 20–28 ms tuned);
- subsampling, depthwise convs, norms and the decoder (roughly 8–12 ms).

Realistic totals for 60 s at full precision on 16 cores:
- lookup-table projections: about 130–150 ms;
- current i8x3: about 210–230 ms.

For 10 s of audio: roughly 25–40 ms.

### Review findings to fix before Phase 1 (Codex, gpt-6.1-sol, xhigh)

- `ThreadPool::run` must be exclusive and panic-safe (a panic must not free a closure workers still use, or hang them).
- `QuantizedActs`, `PackedTernary` and `Scratch` need private fields, validated lengths and an exclusive scratch lease.
- Decoder schedules need validating before use.
- Activation quantization must handle non-finite and tiny-maximum frames.
- `project_encoder` needs a CPU-feature guard.
- `lf-decoder-bench --check` must fail on a mismatch.
- safetensors must use checked size arithmetic and reject overlapping ranges.
- Manifest paths must not escape the export directory through symlinks.
- Rust should enforce the zero blank-embedding invariant that Swift checks.

## Phase 1: native CPU pipeline

- **Packer** (`localflow-pack`):
  - Converts `export.safetensors` into a single image: a header holding the magic, version, source export SHA-256 and layout table, followed by 64-byte-aligned tensors.
  - Weights are stored in the kernel layout, with batch norm folded into the depthwise conv.
  - Precomputed: the embedding × LSTM input-weight table and the rel-pos table. The vocabulary is embedded.
  - Loading is an mmap.
- **Frontend:** pre-emphasis 0.97, centred STFT (n_fft 512, hop 160, Hann window of 400), Slaney mel, log(x + 2⁻²⁴), per-feature normalization.
- **Encoder:**
  - Subsampling convs, then 24 layers (half FF, rel-pos MHSA, conv module with GLU, depthwise k=9 and SiLU, half FF, LayerNorm).
  - A fixed thread pool pinned to the large-L3 CCD.
  - Variable length, with no buckets. Inputs over about 60 s are chunked.
- **Decoder:** TDT greedy. Port from `Sources/Parakeet/LocalParakeetCore.swift` and `NativeMath` in `ParakeetDecoder.swift`, which are already free of framework code.
- **Parity:**
  - The offline reference dumps per-stage outputs from the M1 export to a data disk outside the repository.
  - The native pipeline is compared stage by stage within tolerances, then by WER on dev-clean and dev-other against the published CUDA numbers.
- **Tests in Git:** synthetic weights only (a tiny random model configuration), with kernel results checked against a scalar reference.

### Status (2026-10-07): end-to-end pipeline built and verified

`lf-asr` implements the whole model natively. A separate packer and mmap
loading are not built yet: weights are converted at load, in about 3.6 s. Two
departures from the plan above:
- inputs are not chunked, so full-context attention runs up to `MAX_SECONDS`;
- parity was checked against the existing M1 GPU hypotheses rather than per-stage dumps.

Codex (gpt-6.1-sol, xhigh) reviewed the code twice before the test, and all
blocking findings were fixed.

**Test set:**
- All 39 test-set utterances of 30–60 s that have M1 GPU hypotheses: VoxPopuli 11, Earnings-22 10, LibriSpeech clean 9 and other 7, Common Voice 2.
- 20 joined LibriSpeech test-clean chapters of 37–59 s.
- 40 minutes of audio in total. Run with `lf-transcribe`.

| Precision, threads | 30–40 s p50 | 50–60 s p50 / p95 | Text identical to M1 (NeMo FP32, GPU) |
| --- | ---: | ---: | ---: |
| i8x2, 16 | 101 ms | 186 / 198 ms | 39/39 |
| i8x3, 16 | 135 ms | 242 / 257 ms | 39/39 |
| f32, 16 | 159 ms | 283 / 302 ms | 39/39 |
| i8x3, 8 (V-cache CCD) | 193 ms | 347 / 372 ms | 39/39 |

- **Agreement:** every precision produced character-for-character the same text as M1 on all 39 utterances, so WER is identical (7.93% with a simple shared normalizer).
- **Long context:** on the joined clips, full-context decoding scored 2.09% WER, against 2.16% for M1 on the separate segments.
- **Where the time goes:** at i8x3 on 16 threads, projections are about 128 ms of a mean of about 170 ms per utterance; attention about 20 ms; subsampling 7 ms; elementwise 10 ms; decoder 3.5 ms; frontend 2 ms.
- **i8x2:** it passed this accuracy gate, but 2,876 words is a small sample. Confirm on full dev sets before making it the default.

### Position cache

Each layer's `linear_pos` projection of the relative position embedding
depends only on the length. Before this change, every call recomputed the
embedding, ran 24 projections of `2T - 1` rows, and packed the results per
head for attention.

The projection is row-wise. Row `m` of the embedding for `T` frames is row
`m + Tmax - T` of the one for `Tmax`, so the rows for a shorter utterance are
the centre slice of a longer one.

`PositionCache` in `lf-asr` keeps the projections, already packed per head.
`rel_pos_attention_with` in `lf-cpu` reads them at a row offset.

**Policy:**
- The cache grows lazily to the longest utterance seen, in 64-frame (5.12 s) steps, and is capped by a limit.
- The default limit is 60 s, settable with `Transcriber::set_position_cache_seconds` (0 disables it).
- Longer utterances project per call, as before.
- Memory is 192 KiB per frame (144 MiB at 60 s), allocated only when long utterances actually occur.
- The rows are bit-identical either way, so the limit trades only memory against latency.

**Exactness:** tests compare cached and per-call results bit for bit at every precision (f32, i8x1-3).
- Projected rows were compared rather than assumed equal, across batch sizes, positions in the batch, thread counts and K blocks.
- Two full-width synthetic layers ran over a length sequence that grows, shrinks, passes the limit and changes precision.
- Attention was checked at every panel alignment.

**Latency and memory:** synthetic audio, `--warmup 1` at the same length, so the timed call hits a warm cache. Baseline and new runs were interleaved under the exclusive lock, and each figure is the median of 3. Stage times are in ms: projections / attention / elementwise. Working set is the transcriber's RSS after the 60 s run, from the harness.

| Precision, threads | Audio | Before | After | Saved | Stages before | Stages after | Working set before / after |
| --- | ---: | ---: | ---: | ---: | --- | --- | ---: |
| i8x3, 16 | 10 s | 41.9 | 40.0 | 1.9 | 33.2 / 3.4 / 2.8 | 32.2 / 2.5 / 2.8 | 250 / 268 MiB |
| i8x3, 16 | 30 s | 120.0 | 117.1 | 2.9 | 94.9 / 10.6 / 7.2 | 91.5 / 11.5 / 6.9 | 321 / 382 MiB |
| i8x3, 16 | 60 s | 255.8 | 244.4 | 11.4 | 186.5 / 38.1 / 15.9 | 180.8 / 34.4 / 14.4 | 428 / 550 MiB |
| i8x3, 8 | 10 s | 57.1 | 53.0 | 4.1 | 50.7 / 2.3 / 1.6 | 46.8 / 2.2 / 1.4 | 244 / 264 MiB |
| i8x3, 8 | 30 s | 172.4 | 160.2 | 12.2 | 148.0 / 13.4 / 4.2 | 136.7 / 12.9 / 3.9 | 313 / 375 MiB |
| i8x3, 8 | 60 s | 366.2 | 338.1 | 28.1 | 295.9 / 47.3 / 8.5 | 271.5 / 44.5 / 7.7 | 420 / 544 MiB |
| i8x2, 16 | 10 s | 34.4 | 30.9 | 3.5 | 25.5 / 3.6 / 2.8 | 23.2 / 2.4 / 2.8 | 249 / 268 MiB |
| i8x2, 16 | 30 s | 92.7 | 86.9 | 5.8 | 67.6 / 10.5 / 7.4 | 60.8 / 11.5 / 7.4 | 318 / 380 MiB |
| i8x2, 16 | 60 s | 203.2 | 181.5 | 21.7 | 135.7 / 36.8 / 15.4 | 117.2 / 34.0 / 15.6 | 422 / 546 MiB |
| i8x2, 8 | 10 s | 41.2 | 38.3 | 2.9 | 34.7 / 2.4 / 1.6 | 32.0 / 2.3 / 1.5 | 244 / 264 MiB |
| i8x2, 8 | 30 s | 123.3 | 114.9 | 8.4 | 99.1 / 13.2 / 4.2 | 91.5 / 12.8 / 3.9 | 311 / 373 MiB |
| i8x2, 8 | 60 s | 267.1 | 249.2 | 17.9 | 197.9 / 46.2 / 8.5 | 182.1 / 44.6 / 8.1 | 415 / 540 MiB |

- **Savings:** 2-28 ms (2-11%), growing with length. That broadly matches the 3-17 ms estimate for 16 threads. The largest saving is i8x3 on 8 threads, where the projections are slowest.
- **Memory:** RSS after model load is unchanged at 238 MiB, with a load peak of 410 MiB.
  - At 60 s, the working set grows by about 122 MiB: the 144 MiB cache, less the per-call scratch it replaces.
  - Peak RSS at 60 s rises from 424-431 to 544-554 MiB.
- **Run-to-run drift:** separate sessions differed by up to about 6 ms at 60 s, so the interleaved runs are the comparison to trust.
- **Growing the cache:** a call that grows it costs about the same as an uncached call, plus first-touch page faults on the fresh buffers. This was measured with `--warmup 0`, i8x3 on 16 threads, median of 3:
  - 10 s: 53.8 ms before, 56.6 ms after;
  - 60 s: 287.5 ms before, 299.0 ms after.
  - Buffers are allocated fresh at their exact size; reusing them would leave up to 2× capacity slack after gradual growth.
  - This happens at most once per 5.12 s step of new longest length, so at most 12 times up to the 60 s limit.

**59-utterance set** (i8x3, 16 threads, once, in the harness's order, so cache rebuilds as longer utterances arrive fall inside timed calls):

| | p50 | p95 | max | Identical to M1 | Joined WER | Working set at end |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Before | 145.8 ms | 260.1 ms | 265.9 ms | 39/39 | 2.09% | 461 MiB |
| After | 138.2 ms | 247.7 ms | 272.4 ms | 39/39 | 2.09% | 596 MiB |

Per-utterance WER and substitution, deletion and insertion counts are identical on all 59 utterances.

### Precision validation (2026-10-07): is i8x2 transcript-equivalent?

Question: can `Precision::Int8(2)` (i8x2) be the default instead of i8x3
without changing what the user gets?

**Method**
- **Data:** every utterance of 5 dev sets (22,418 utterances, 28.5 h) and 4 test sets (10,142 utterances, 21.1 h): 32,560 utterances and 481,140 scored reference words.
- **Runs:** `lf-transcribe --save-hyps` at f32, i8x3 and i8x2, 16 threads, one utterance at a time. `lf-hypcompare` compares the saved hypotheses with each other and with the M1 GPU hypotheses of the same export (NeMo, strict FP32, batched greedy TDT).
- **WER:** the harness's simple normalizer (lowercase, keep letters, digits and apostrophes) is applied to ours and M1's alike. It is computed over the utterances the official scoring keeps: M1's `scored` flag, which drops references that are empty after Whisper normalization (891 AMI and 4 earnings22 records). M1's official Whisper-normalized WER, taken from the eval file, is shown for context only.
- **Divergences:** `lf-transcribe --analyze f32,i8x3,i8x2` reruns an utterance through the encoder at each precision and through the scalar f64 reference decoder. It reports the first greedy decision where two runs differ and the top-1 minus top-2 logit margin there. The margin is a log-probability gap in nats; 0 is an exact tie.
- **Determinism:** on dev-other, i8x2 and f32 each gave identical hypotheses (text and tokens) at 8 and at 16 threads, and in a repeated 16-thread run.
- No transcripts are kept in the repository; hypotheses stay in `/tmp/lf-agents/`.

**Accuracy per set** (WER columns use the simple normalizer; "same text" means character-for-character)

| Set | Utts | Words | M1 official WER | WER M1 | WER f32 | WER i8x3 | WER i8x2 | Same text as M1, f32 / i8x3 / i8x2 | Word edits vs M1, f32 / i8x3 / i8x2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| librispeech_dev_clean | 2,703 | 54,402 | 1.987% | 2.129% | 2.129% | 2.129% | 2.129% | 2703 / 2703 / 2703 | 0 / 0 / 0 |
| librispeech_dev_other | 2,864 | 50,948 | 4.198% | 4.375% | 4.375% | 4.375% | 4.375% | 2864 / 2864 / 2863 | 0 / 0 / 1 |
| voxpopuli_dev | 1,753 | 44,194 | 6.018% | 6.718% | 6.718% | 6.718% | 6.716% | 1753 / 1753 / 1752 | 0 / 0 / 1 |
| yodas_dev | 2,000 | 37,963 | 6.512% | 6.693% | 6.693% | 6.693% | 6.693% | 1972 / 1972 / 1971 | 0 / 0 / 1 |
| ami_dev | 13,098 | 94,093 | 11.713% | 13.063% | 13.063% | 13.063% | 13.064% | 13098 / 13098 / 13097 | 0 / 0 / 1 |
| librispeech_clean (test) | 2,620 | 52,576 | 2.054% | 2.229% | 2.229% | 2.229% | 2.229% | 2620 / 2620 / 2620 | 0 / 0 / 0 |
| librispeech_other (test) | 2,939 | 52,343 | 4.198% | 4.413% | 4.413% | 4.413% | 4.413% | 2939 / 2939 / 2939 | 0 / 0 / 0 |
| voxpopuli (test) | 1,842 | 44,380 | 6.193% | 6.769% | 6.769% | 6.769% | 6.769% | 1841 / 1841 / 1841 | 0 / 0 / 0 |
| earnings22 (test) | 2,741 | 50,241 | 11.716% | 16.522% | 16.522% | 16.522% | 16.520% | 2729 / 2729 / 2727 | 0 / 0 / 1 |
| All dev | 22,418 | 281,600 | | 7.524% | 7.524% | 7.524% | 7.524% | 22390 / 22390 / 22386 | 0 / 0 / 4 |
| All test | 10,142 | 199,540 | | 7.411% | 7.411% | 7.411% | 7.410% | 10129 / 10129 / 10127 | 0 / 0 / 1 |

- **f32 and i8x3 against M1:** 0 word edits on all 32,560 utterances. The 41 texts that differ are not word differences:
  - 40 (yodas_dev 28, earnings22 12) are equal once spaces are removed. They differ only in the spacing around a standalone `▁` piece before `?` pieces, which `lf_asr::Tokenizer::decode` renders differently from NeMo. This was the same for every precision: a detokenizer difference, not a precision one. Fixed after the integration merge (`3ca9c62`): `lf-asr` now strips one space before vocabulary punctuation as NeMo does, and YODAS dev plus Earnings-22 match M1 on 4740/4741 utterances.
  - 1 (voxpopuli test) has an extra comma. There, f32's margin is 3.9e-6 nats. The f64 reference decoder agrees with M1 and the F16-weight fast decoder does not, so CPU versus GPU arithmetic already flips near ties this close.
- **The simple normalizer** scores higher than the official one, most on earnings22 (numbers and currency). It is applied to M1 and to us identically.

**Pairwise agreement** (different text / different tokens / word edits)

| Pair | Dev, 22,418 utts | Test, 10,142 utts |
| --- | --- | --- |
| f32 vs i8x3 | 0 / 0 / 0 | 0 / 0 / 0 |
| f32 vs i8x2 | 4 / 4 / 4 | 2 / 3 / 1 |
| i8x3 vs i8x2 | 4 / 4 / 4 | 2 / 3 / 1 |

**Every i8x2 divergence** (7 utterances with different tokens; all are first-decision token flips to f32's runner-up)

| Set | Effect on text | f32 margin at the flip (nats) | i8x2 margin for its choice | Largest token-logit change, through the flip | Effect on errors vs reference |
| --- | --- | ---: | ---: | ---: | --- |
| librispeech_dev_other | 1 word | 2.0e-4 | 2.1e-4 | 2.1e-3 | none (same count) |
| voxpopuli_dev | 1 word | 1.3e-4 | 1.4e-3 | 3.0e-3 | 1 fewer |
| yodas_dev | 1 word | 8.2e-5 | 2.9e-4 | 5.5e-3 | none |
| ami_dev | 1 word | 2.3e-4 | 5.7e-4 | 2.4e-3 | 1 more |
| earnings22 | 1 word | 4.6e-5 | 3.4e-5 | 8.1e-4 | 1 fewer |
| earnings22 | punctuation only | 3.1e-4 | 3.0e-4 | 1.4e-3 | none |
| librispeech_clean | none (tokens only) | 5.7e-5 | 5.7e-5 | 3.6e-3 | none |

Net effect on WER: one error fewer in 481,140 words.

**How often ties occur** (`--analyze` on a deterministic, dispersed subset: 200 utterances from each dev set and 600 from AMI, spread over 18 meetings; 1,400 utterances and 47,504 greedy decisions. It was picked with `shuf`, using a fixed file as the random source, so it is reproducible but not a uniform random draw.)
- f32 token margins: below 0.001 nats in 1 decision (0.002%), below 0.01 in 14 (0.029%), below 0.1 in 155 (0.33%), below 1 in 1,373 (2.9%).
- Largest token-logit change per decision against f32, per set:
  - i8x3: median 8.3e-6 to 1.0e-5, p99 2.8e-5 to 3.6e-5, max 1.7e-4;
  - i8x2: median 1.3e-3 to 1.6e-3, p99 4.7e-3 to 5.3e-3, max 2.1e-2.
- Encoder output, relative RMS against f32: i8x3 about 5e-7, i8x2 about 8e-5.
- **Decisions at risk** (f32 margin below twice the change): i8x3 0; i8x2 3 token and 7 duration decisions, about 1 in 4,800.
- **Decisions that flipped:** 2 for i8x2, about 1 in 24,000. One is the voxpopuli_dev word change above; the other is a duration choice that left the text unchanged.
- **Earlier sample:** an analysis of the first 150 utterances of each set and the first 450 of AMI (33,551 decisions) found similar rates: 0.033% of margins below 0.01, and 2 flips. It covered only 2 speakers per LibriSpeech set and 2 AMI meetings.
- These rates are descriptive of this sample and this export.
- **Fast decoder:** emission agreement with the f64 reference was checked, but not its margins. It matched the reference in every sampled run. On the near-tie voxpopuli test utterance above, it differed from the reference for f32 and i8x3.

**Latency and memory** (synthetic signal, exclusive lock, median of 3 processes; each process warms up on 60 s, then times 10, 30 and 60 s; 8 threads = CPUs 0–7, the V-cache CCD)

| Audio | i8x3, 16 thr | i8x2, 16 thr | i8x3, 8 thr | i8x2, 8 thr |
| --- | ---: | ---: | ---: | ---: |
| 10 s | 44.3 ms | 33.2 ms | 58.6 ms | 42.2 ms |
| 30 s | 124.9 ms | 90.1 ms | 174.6 ms | 124.9 ms |
| 60 s | 269.4 ms | 196.8 ms | 370.7 ms | 269.3 ms |

- **Speedup:** on synthetic 10–60 s inputs, i8x2 is 1.33–1.40× faster than i8x3 (25–28% less latency) at both thread counts. i8x2 on 8 threads matches i8x3 on 16. On short speech the gain is smaller (next table).

Short utterances, same protocol (5 warm-up utterances, whole transcribe call, mean / p50 / p95 per utterance):

| Set | i8x3, 16 thr | i8x2, 16 thr | i8x3, 8 thr | i8x2, 8 thr |
| --- | --- | --- | --- | --- |
| librispeech_dev_clean, first 500 (mean 7.1 s) | 32.9 / 26.9 / 71.4 ms | 24.8 / 20.3 / 52.8 ms | 43.2 / 35.2 / 96.6 ms | 31.4 / 25.7 / 69.5 ms |
| ami_dev, first 1000 (mean 2.6 s) | 14.7 / 10.8 / 35.1 ms | 11.7 / 9.1 / 26.5 ms | 17.6 / 12.1 / 45.8 ms | 13.3 / 9.3 / 33.2 ms |

Memory (MiB, `/proc/self/status`):
- After model load: RSS 238, peak 410 (the peak includes load-time temporaries).
- After 60 s, transcriber working set (RSS minus the 10 MiB of synthetic audio): i8x2 422 at 16 threads and 415 at 8; i8x3 427 and 420.
- Process peak: 424–437. Precision changes memory by about 5 MiB.

**Recommendation: i8x2 is transcript-equivalent enough to be the default.**
- **Evidence:**
  - Over 32,560 utterances it changed 6 texts against f32 (5 single-word edits, 1 punctuation) and 1 more token sequence.
  - WER moves by at most about 0.0023 percentage points on any set (one error). The changes go both ways: net, one error fewer.
  - In the f64 diagnostic, every change starts at a near-tied greedy decision: f32's top two tokens are within 3.1e-4 nats, and i8x2 takes f32's runner-up.
  - This shows the decoder's local choice was nearly tied. It does not show that the two transcripts are equally likely or mean the same; the recommendation rests on the observed agreement and WER.
  - The same kind of near-tie flip (3.9e-6 nats) already separates our f32 CPU path from M1 on the GPU.
- **Speed:** 25–28% less latency than i8x3 on synthetic 10–60 s inputs. Mean per utterance is 25–27% less on LibriSpeech dev-clean and 20–24% less on AMI.
- **Risks:**
  - i8x2 is not bit-identical to FP32. It perturbs logits by about 1e-3, about 160 times more than i8x3. In the dispersed sample, about 1 decision in 4,800 was close enough to flip, and about 1 in 24,000 did.
  - This was measured on read speech, parliament, meetings, YouTube and earnings calls in English only, for this export only. A new export, or a model with sharper outlier activations, should be re-checked with `lf-transcribe --save-hyps` and `lf-hypcompare`. That takes about 45 minutes for the dev sets at three precisions on the shared CPU.
  - No dictation recordings from the target microphone were tested.
- **Fallback:** keep i8x3 selectable as the higher-precision option. It matched the f32 baseline on all 32,560 utterances, but it is not bit-exact either: its logit changes are about 1e-5, so a tie closer than that could still flip. Keep f32 as the cross-check.

### Lookup-table kernel (2026-10-07): exact, but not worth integrating

`lf-cpu/src/gemm_lut.rs` is an exact-FP32 ternary GEMM built on lookup tables.
It stays in the tree as an experimental kernel with tests. It is not wired
into `lf-asr`, because it missed the bar: at least 1.2× faster than i8x3 at
16 threads on 30–60 s, or close to i8x2.

**Design:**
- Inputs are grouped in threes. The 27 signed sums of a group come in ± pairs, so each frame and group gets a 16-float table with one sum per pair (14 entries, indexed by the non-negative balanced-ternary patterns).
- A weight row's three codes give `v = a + 3b + 9c` in −13..13. The kernel does one non-destructive `vpermps` on `|v|` and one FMA by ±1.0 (the sign comes from bit 31 of the stored index through one `vpternlogd`).
  - This avoids the register copy that the 27-entry `vpermt2ps` design needs.
  - Probe (`--peak`, "LUT sym"): 5.0 T MAC-equivalents/s on 16 cores, against 5.5 T for `vpermt2ps` + add.
- Index tiles: 4 bytes per group and output, expanded per 128 groups from the shared 2-bit `PackedTernary` layout with `vpermb`. A separate sign vector doubled the tile and was 4–19% slower at 16 threads, depending on the tile depth.
- Threads form frame groups (`threads / 2`, at most 4), and each group builds tables for its own frames. A group's tables stay in one buffer when they fit 9 MiB; otherwise they are double-buffered in chunks, with one barrier per chunk.
- Microkernel: 128 outputs × 3 frames. K = 1024 is padded to 344 groups.
- Error is at the f32 kernel's level: about 2.1e-7 relative RMS against the f64 reference, versus 3.4e-7 for f32 and 5.4e-7 for i8x3 (layer 0, 63 frames, synthetic activations). The sums are reassociated, so results are not bit-identical to the f32 kernel.
- NaN or infinite inputs poison only their own frame, as in `gemm_f32`. Finite inputs within 3× of `f32::MAX` can overflow in the pre-sums.

**GEMM-only results.** Real M1 weights, synthetic activations, all 240
projections. Median ms of 3 process runs, each the median of 3 repetitions,
under the exclusive lock. LUT is shown at its final defaults.

| Threads | Audio | f32 | i8x3 | i8x2 | LUT | LUT vs i8x3 | LUT vs i8x2 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10 s | 473.6 | 354.2 | 239.7 | 290.7 | 1.22× | 0.82× |
| 1 | 60 s | 2740 | 2083 | 1399 | 1715 | 1.21× | 0.82× |
| 8 | 2 s | 15.5 | 11.1 | 8.2 | 15.0 | 0.74× | 0.55× |
| 8 | 5 s | 32.4 | 24.6 | 16.9 | 26.9 | 0.91× | 0.63× |
| 8 | 10 s | 61.2 | 47.1 | 31.8 | 45.2 | 1.04× | 0.70× |
| 8 | 15 s | 92.3 | 69.8 | 47.0 | 63.8 | 1.09× | 0.74× |
| 8 | 30 s | 183.3 | 138.7 | 92.6 | 122.3 | 1.13× | 0.76× |
| 8 | 60 s | 359.4 | 275.4 | 184.9 | 251.7 | 1.09× | 0.73× |
| 16 | 2 s | 9.5 | 9.2 | 6.1 | 13.8 | 0.67× | 0.44× |
| 16 | 5 s | 19.4 | 16.3 | 11.5 | 24.4 | 0.67× | 0.47× |
| 16 | 10 s | 36.3 | 30.4 | 21.1 | 35.6 | 0.85× | 0.59× |
| 16 | 15 s | 54.3 | 44.7 | 30.7 | 47.8 | 0.94× | 0.64× |
| 16 | 30 s | 108.4 | 88.8 | 59.8 | 82.2 | 1.08× | 0.73× |
| 16 | 60 s | 212.6 | 174.2 | 119.3 | 162.0 | 1.08× | 0.74× |

At 1 thread, LUT is also 1.19× and 1.27× faster than i8x3 for 2 s and 5 s.
The 1-thread rows and all non-LUT columns come from the full grid run
(`--variants f32,i8x3,i8x2,lut`). The LUT columns at 8 and 16 threads come
from a rerun after the final budget change, which moved times by under 3%.

**Memory:**
- Weights are the same for every variant: 0.256 bytes per weight (2-bit codes plus a per-row scale and sum), 154.5 MB.
- Workspace beyond `x` and `y`, at most over 1–16 threads and 2–60 s:
  - f32: 2.1 MB;
  - i8x2: 15.0 MB;
  - i8x3: 20.3 MB;
  - LUT: 38.6 MB, of which about 37.5 MB is tables for four frame groups.

**Why it falls short:**
- **Per core, LUT wins:** about 250 GMAC/s against 207 for i8x3. That is about 70% of the 1-thread "LUT sym" probe (355 GMAC/s).
- **Across cores, it loses efficiency:** at 16 threads it reaches 2.7 T/s, about 54% of the probe. i8x3 keeps about 2.5 T/s, about 69% of its 3.6 T/s effective ceiling.
- **Frame groups re-read the weights:** every frame group streams all 154 MB of codes and re-expands every tile. With one group, the tables for all frames (about 87 KB per frame at K = 4096) overflow L2 and are re-read from L3 by every thread. Four groups were the measured optimum between those two costs.
- **Short inputs:** table building, barriers and per-chunk tile expansion are paid per call, so short inputs are slower than i8x3: up to 15 s on 16 threads, and up to 5 s on 8 threads.
- **Microkernel only, other stages skipped:** about 73–78 ms at 30 s on 16 threads, already above the 59.8 ms of i8x2.
- **Bottom line:** this design's register ceiling for the 60 s projections (434 G MACs at 5.0 T/s) is about 87 ms. That is worse than i8x2's 79 ms, and the 79 ms in the ceiling table above belongs to the 27-entry `vpermt2ps` design. That design was not built, because its probe drops to 3.4–3.8 T/s once the destroyed operand is reloaded from L1. i8x2 stays the faster near-exact option. LUT's only advantage is exactness: about 1.08× over i8x3 at 30–60 s on 16 threads, and 1.04–1.13× on 8 threads from 10 s up.

## Phase 2: daemon and control interface

- `localflowd` runs a state machine: idle → recording → transcribing.
- `localflowctl press|release|toggle|cancel|status` talks to it over `$XDG_RUNTIME_DIR/localflow/ctl.sock` (directory 0700, socket 0600).
- Hold versus tap-to-toggle matches `DictationShortcutSessionController`.
- **Audio:** a PipeWire capture stream at 16 kHz mono f32 into an in-memory buffer.
- **Post-processing:** port `LocalDictationCore` (the press-enter command, voice macros, spoken delimiters). Shared JSON test vectors keep the Swift and Rust versions consistent; the Swift side is verified in macOS CI.
- **Insertion:** a virtual keyboard through `wayland-client`, uploading its own keymap so the Dvorak layout doesn't matter. "Press enter" sends Return.
- **Config:** `~/.config/localflow/config.json`.
- **History:** transcripts only, last 20 entries, in `~/.local/share/localflow/history.json` (mode 0600), opt-in (off by default, per AGENTS.md: persisting user content needs an explicit opt-in).
- **Logging:** no transcripts or other user content in logs, since journald persists them.

## Daemon core

Status (2026-10-07): built against the `lf-io-api` traits, with fakes in
tests. Since the integration merge, `localflowd` uses the PipeWire and
virtual-keyboard backends (config keys `input_device` and `key_delay_ms`);
`--fake-io` remains for testing. See `README.md` for use and the manual test
checklist.

**`lf-dictation`** ports `Sources/LocalDictationCore.swift`: trailing
"press enter", whole-phrase voice macros and `SpokenDelimiterFormatter`.
- Swift `String` semantics are emulated explicitly: `Character` is a grapheme
  cluster, `isWhitespace`/`isPunctuation` look at the first scalar,
  `lowercased()`/`uppercased()` map per scalar (no final-sigma rule),
  `==` is canonical equivalence, and `trimmingCharacters` trims `White_Space`.
- The ICU regex is hand-matched: leftmost match, full case folding for the
  literals ("preß enter" matches), `\s` = `White_Space`, `\p{P}`.
- `linux/testdata/dictation-vectors.json` holds 164 vectors: every Swift
  test case (11 `process` cases and all 86 delimiter cases, `origin: swift`)
  and 67 additional edge cases (`origin: rust-edge`: case, punctuation,
  whitespace, empty, NBSP, combining marks, final sigma, ß, İ, emoji, CJK).
  The `rust-edge` values follow documented Swift/ICU behaviour but have not
  run on macOS. **Follow-up:** have `Tests/LocalDictationTests.swift` consume
  the file (needs macOS CI).

**`lf-daemon`** (`localflowd`, `localflowctl`):
- **Commands → shortcut events** (port of `DictationShortcutSessionController`,
  with its Swift tests): `press`/`release` = hold key down/up; `toggle` = a full
  tap of the toggle key (activate + deactivate); `again` = Paste Again (retype
  the last dictation, held in memory only); `cancel` = Escape; `status`.
- **States:** idle → recording → transcribing → typing → idle. A dedicated
  worker thread owns the recognizer and the `TextOutput`; the control loop
  never waits for it.

| Situation | Behaviour |
| --- | --- |
| press/toggle while transcribing or typing | ignored (`note=ignored`), as in Swift |
| release with no hold session; press in toggle mode | ignored |
| toggle while holding | switches to toggle mode; the release is then ignored |
| cancel while recording | audio discarded, idle |
| cancel while transcribing | idle at once; the result is dropped |
| cancel while typing | waits for the 64-byte piece being typed, then nothing more: no further text and no Return after the reply; typed text stays |
| cancel while idle | ignored |
| capture fails to start or stop | capture cancelled, `error capture`, idle, session reset |
| press and release arrive out of order (each bind is its own process) | `localflowctl` stamps requests with `CLOCK_MONOTONIC` at start; a press stamped before an unmatched release is ignored, and a release stamped before the current hold's press is ignored; stamps from the future are treated as absent |
| empty recording / under `min_recording_seconds` (0.3 s) | discarded before recognition (`note=empty` / `note=too-short`) |
| `max_recording_seconds` (300 s) reached | stops and transcribes |
| recording while the model loads | allowed; transcribed when ready |
| new dictation while an abandoned job finishes | allowed; its job runs next |
| model load fails or the worker panics | daemon exits non-zero |
| press within `double_tap_ms` (400) of a hold release that was too short or empty | prompt recording: output gets `prompt_tag` (`[dictated] ...`), `tag=prompt` in replies |

- **Hold to Prompt (double-tap and hold):** port of the Swift app's prompt
  tag (`LocalDictationCore.process(promptTag:)`, branch
  `feat/custom-dictionary`) into `lf-dictation`; the Mac's separate shortcut
  becomes a double tap of the hold key, detected in the controller because
  Hyprland has no double-tap binds. Designed for requests from
  `localflowctl` (always stamped, never replayed) delivered by Hyprland,
  possibly out of order; other same-user input must not wedge the daemon
  or tag an ordinary hold, and any doubt means no tag. Rules:
  1. Timing must agree on both clocks: the press must *arrive* within
     `double_tap_ms` of the tap's release arriving, by the daemon's
     `CLOCK_BOOTTIME` (suspend expires a pending tap; the release's
     arrival is read before the capture stops, so a stall there can only
     expire a tap), *and* be *stamped* within `double_tap_ms` after the
     release's stamp (late, bunched delivery is not a double tap).
  2. A tap arms only when, from idle, a press with a fresh stamp (present,
     at most 50 ms ahead of and 2 s behind the daemon's clock) newer than
     the last release that stopped a recording started a hold recording,
     its own fresh, non-stale release stopped it, and it was discarded as
     too short or empty. A prompt starts only from such a press. Anything
     else (any other request but `status`, unstamped or out-of-order
     requests, busy states) arms nothing and clears a pending tap.
  3. Client stamps otherwise serve only the existing out-of-order checks;
     a stamp from the future is treated as absent and never stored, so no
     request can make later valid ones be ignored. The newest orphan
     release's stamp is kept (an older stamp never lowers it) until a
     press stamped after it arrives; the maximum-length timer clears the
     ended hold's press stamp.

  A too-short prompt recording is a tap again. After a tap the media
  resume waits for the window (controller deadline) so a double tap does
  not stutter the music; every recording start re-sends the (idempotent)
  pause. A tap whose release overtook its press is not a tap (no tag).

  **Known limitation (pre-existing, not specific to Hold to Prompt):** a
  *second* press that overtakes the *first* hold's release (e.g. stamps
  press 1000, press 1200, release 1080, received in that order) is
  ignored like any press during a hold; the late first release then
  stops the recording, and the speech of the second hold is lost (nothing
  is typed, nothing is tagged). It needs the key pressed again within
  process start-up jitter of releasing it. Fixing it means queueing a
  press that arrives during a hold until the matching release is known,
  which has not been done.

- **Socket:** `$XDG_RUNTIME_DIR/localflow/ctl.sock`. Refuses to start unless
  the runtime directory is a 0700 directory owned by the user; the
  `localflow` directory must be 0700 (created so, never repaired), the socket
  is 0600, a `flock` on `localflowd.lock` allows one instance, and every
  connection's `SO_PEERCRED` uid must match. One request line per
  connection: `localflow/1 <command>`, printable ASCII, under 256 bytes, sent
  within 250 ms. Connections are served one at a time in accept order. That
  does not guarantee a press is handled before its release, because
  Hyprland starts a separate `localflowctl` process for each; the `at=`
  stamp restores the order (see the table), except when the later process
  reads the clock first, which needs a tap shorter than process start-up.
  A stalled same-user client delays other commands by up to 250 ms each
  (same-user processes are inside the trust boundary anyway).
- **Watch (status subscription):** `localflow/1 watch` hands the connection
  from the socket thread to the control loop, which keeps up to 8 watchers.
  The socket thread reserves the place first (connected plus queued
  watchers, shared counter); over the cap, one connection may go to the
  control loop, which reclaims watchers that closed or shut down reading
  (poll for hang-up plus a zero-length send) before admitting or refusing
  it, and any other is answered `error busy` at once by the socket thread.
  Refusals are logged only as a count, at most once a minute; the control
  loop logs nothing per watcher. It sends a
  status line at once, after any event or timer that changes state, mode,
  model readiness or microphone presence, and every 66 ms while recording
  with the input level (`level=0..100`, the only audio-derived value).
  Sends use `MSG_DONTWAIT` with a 64 KiB send buffer; a full buffer, short
  write or error drops the watcher, so a stuck client never delays keys. The
  level timer runs only while recording with watchers connected.
  `localflowctl watch --waybar` renders Waybar JSON (a scrolling level graph
  while recording) and reconnects every 2 s while the daemon is down. Both
  watch modes poll stdout alongside the socket and exit 0 as soon as their
  reader goes away, even when nothing changes.
- **Microphone presence:** `AudioCapture::input_available`. `lf-pipewire`
  runs a registry monitor on its own thread (own main loop, stopped with a
  bounded wait) that counts `Audio/Source`, `Audio/Source/Virtual` and
  `Audio/Duplex` nodes, or matches `input_device` by `node.name` or
  `object.serial`, never LocalFlow's own stream. Unreachable PipeWire is
  `unknown`, not absent, and is retried every 2 s. Changes reach the control
  loop as an event. Node names are compared only, never logged or sent.
- **Config:** `$XDG_CONFIG_HOME/localflow/config.json`, all keys optional,
  unknown keys and bad values rejected; errors name fields, never macro text.
- **History:** last 20 `{time, raw, text}` entries in
  `$XDG_DATA_HOME/localflow/history.json`, 0600 in a 0700 directory, written
  to a temporary file, fsynced and renamed. Off by default; `"history": false`
  (the default) stops all reads and writes.
- **Privacy:** the daemon's audio buffers are overwritten when dropped (also
  on panics and for queued jobs); logs carry states, durations and error
  kinds only, and go through a bounded queue to a logger thread so a stalled
  stderr drops lines (counted, then reported) instead of blocking key
  handling (`localflowd` flushes for up to 1 s at exit); its panic hook
  logs through the same queue with thread name and location only (a
  formatted panic message could quote recognized text); config errors never
  echo values or unknown macro keys; stale
  temporary history files are removed at start, even with history off.
  Since the integration, `lf-pipewire` wipes its capture buffers on every
  path (stop hands them to the daemon's wiping wrapper) and `lf-asr` zeroes
  its raw waveform copies right after the spectrum is computed.
  **Limitation:** derived data (spectrum, features, encoder activations)
  stays in `lf-asr`'s reusable workspace, in memory only, until the next
  dictation overwrites it; buffers inside PipeWire itself are out of reach.
- **Warm-up:** after loading, the recognizer transcribes 30 s of silence
  (about 170 ms at startup) so the working buffers exist before the first
  dictation. On an idle CPU this barely matters (first dictation 66 ms cold
  versus 60 ms warm, below); a first run under CPU contention took 805 ms
  cold, but that run was not controlled.

**End-to-end test** (`tests/real_model.rs`, ignored by default): the daemon
with the real export at i8x3 on CPUs 0-15, a fake capture returning public
LibriSpeech test-clean audio and a fake output. The typed text equalled the
M1 GPU hypothesis after post-processing for every utterance. Latency is from
the client's `release` to `status` reporting idle (polled every 5 ms, so it
includes up to about 5 ms of polling); exclusive CPU lock, median of 3 runs:

| Step | With warm-up | Without warm-up |
| --- | ---: | ---: |
| Model ready after start | 3.67 s | 3.51 s |
| 1089-134686-0000 (10.4 s), first dictation | 60 ms | 66 ms |
| 1089-134686-0001 (3.3 s) | 20 ms | 20 ms |
| 1089-134686-0000 (10.4 s), repeated | 53 ms | 51 ms |

Codex (gpt-6.1-sol, xhigh) reviewed the work twice. Fixed: Return could
follow a cancel; modifier-held releases (`bindri`); out-of-order
press/release (`at=` stamps); worker not joined at stop; Swift parity of
match ranges inside a grapheme, U+200B trimming and the case-change span;
chunk sizes; audio wiping on all paths; config errors echoing content;
FIFO history hang; capture cleanup on errors; stale temporary history
files; startup rollback; unbounded CPU-list expansion. Open: `lf-asr`
workspace retention (above) and the Swift side of the shared vectors.

## Phase 3: desktop integration

- A Hyprland binds snippet, once the key is chosen.
- A systemd user unit.
- A Waybar status module (done: `localflowctl watch --waybar`; see the
  daemon core section and `README.md`).
- Start and stop sound cues.
- A manual test checklist: microphone, shortcut hold and toggle, typing into a terminal, a browser, an Electron app and an XWayland app, press enter, cancel.

## Phase 4: CUDA backend

- Hand-written `.cu` kernels, compiled by nvcc to an `sm_120` fatbin, embedded in the binary and loaded through the CUDA driver API.
- Weights loaded once into a single resident VRAM allocation.
- One CUDA graph per length bucket, covering frontend → encoder → decoder.
- TDT greedy decode as a persistent kernel.
- The Triton runtime in the private training repository acts as the offline correctness oracle.
- Falls back to the CPU backend when CUDA initialization or allocation fails, or when latency exceeds its budget.

## Phase 5: NixOS packaging

- A package derivation and a NixOS or home-manager module.
- Dependencies move from the flake into the system config.

## Integration (2026-10-07)

Five branches (position cache, precision validation, lookup-table kernel,
daemon core, desktop I/O) were developed in parallel, each reviewed twice by
Codex, then merged. After the merge:
- `localflowd` was wired to the real PipeWire and Wayland backends.
- NeMo's space-before-punctuation rule was ported to `lf-asr`.
- Four further Codex rounds on the integrated code found and fixed:
  - capture-buffer wiping on every path;
  - history made opt-in;
  - `WAYLAND_DEBUG` cleared at startup;
  - a slow device start no longer eats the recording window;
  - client deadline above the capture start timeout;
  - whole-text validation before the first key;
  - typing pieces sized in characters;
  - a 2 s budget per output call and per capture shutdown;
  - per-recording level meters;
  - analysis-tool fixes.

Residual risks:
- A capture thread that hangs inside PipeWire is detached after 2 s. It keeps its (in-memory) audio until it ends, when its buffers are wiped.
- Spectrum, features and encoder activations stay in `lf-asr`'s reusable workspace until the next dictation (the raw waveform copies are zeroed).
- Worst-case cancel waits are about 2 s per phase when the compositor or PipeWire hangs. A backlog of requests has no global bound.
- Not yet run live: microphone capture, typing and modifier behaviour on the Hyprland session, and journald output. See `README.md` and the "Desktop I/O" section.

## Open items

- Shortcut key: F13 on a remapped Kinesis thumb key (binds in `packaging/hyprland.conf` use keycode 191; confirm with `wev`).
- Default precision: i8x2, chosen by the user (2026-10-07) on the validation above (25–28% faster than i8x3, six near-tie transcript changes in 32,560 utterances, same WER). i8x3 remains available for bit-level FP32 fidelity.

## Risks

- Reduced activation precision may cost WER (Phase 0, step 4).
- Training jobs compete for CPU and GPU.
- Virtual keyboard compatibility with some apps, such as XWayland and Electron. To be covered by the manual test checklist.

## Desktop I/O

Status (2026-10-07): `lf-pipewire` implements `AudioCapture` and
`lf-wayland` implements `TextOutput`. Both pass end-to-end tests against
private headless instances. They have not yet run on the live Hyprland
session (see the manual tests below).

### Audio capture (`lf-pipewire`)

- Each recording runs a PipeWire main loop on its own thread with one capture stream (`node.name = localflow-capture`, `media.role = Communication`). The stream offers only F32LE, 16 kHz, mono, so PipeWire's adapter resamples and downmixes.
- If the server ever negotiates another rate or channel count, `convert.rs` takes over: a channel average plus a Kaiser-windowed sinc polyphase resampler (16 zero crossings, about 85 dB stopband, unit DC gain). It is unit-tested against ideal sines, aliasing, DC and chunked streaming.
- Input: the default source, or a node name via `target.object`. A named target also sets `node.dont-fallback` and `node.dont-move`, so a missing device fails instead of silently recording another one, and stored routing metadata cannot move the stream.
- Buffers follow the SPA chunk contract: the offset is taken modulo the block size, regions may wrap, the stride is honoured, and partial frames are dropped. A format the converter rejects stops the capture with an error.
- `start` blocks until the stream is Streaming (default timeout 3 s), so "no microphone" is an error, not an empty recording.
- The buffer is in memory only and bounded by `max_duration` (default 600 s, matching `lf-asr`'s `MAX_SECONDS`). Beyond it, the default `Overflow::Truncate` keeps the start and sets `Recording::truncated`; `Overflow::Error` fails `stop`. Capacity never grows past the limit.
- `level()` is the RMS of the latest buffer, reset to 0 when idle. Samples are sanitized (non-finite becomes 0) and clamped to [-1, 1].
- Stop and cancel signal an eventfd watched by the loop; queued buffers are drained before the loop exits. `cancel` is idempotent, and `Drop` cancels.
- `PIPEWIRE_REMOTE`, when set, overrides `CaptureConfig::remote`, as everywhere in PipeWire.
- Errors carry fixed descriptions and errno values, never the server's free-form messages.

### Text output (`lf-wayland`)

- `zwp_virtual_keyboard_v1` on the first seat, through the pure-Rust `wayland-client` backend (no libwayland).
- The keymap has one key per needed character, each with its Unicode keysym (`Uxxxx`). Return, Tab and Space sit on their usual keys (evdev 28, 15 and 57). Typing therefore ignores the user's layout (Dvorak).
- Characters go only on an allowlist of 50 ordinary printable keys: the US number, top, home and bottom rows, plus the ISO/JIS `IntlBackslash`, `IntlRo` and `IntlYen`. Chromium/Electron drop keys whose evdev code has no DOM `code`. Compositors, IMEs and media handlers act on special keys (Esc, modifiers, F-keys including dictation hotkeys, navigation, keypad, IME, media, power) by keycode. The first review found that the earlier 128-code denylist put `^` on evdev 170, which Chromium drops.
- Text with more distinct characters is typed in batches, re-uploading the keymap between batches. Keymaps go through sealed, close-on-exec memfds.
- `\n`, `\r\n` and a lone `\r` become Return, and `\t` becomes Tab. Any other control character rejects the whole text before a key is sent. The error gives only its position.
- Default delay of 1 ms per key, configurable. A round trip runs every 32 keys. Every wait on the compositor is bounded (5 s), including a non-blocking socket connect that survives a full listen backlog.
- The typer connects lazily, checks liveness with a round trip before each call, and reconnects after any error. A compositor without the protocol gives a clear error.
- No text appears in logs or errors, and errors never echo compositor messages. `wayland-backend` uses its `log` feature, so it prints nothing to stderr. If the daemon installs a logger, it must filter out the `wayland_backend` target at every level: at error level it logs the compositor's protocol error messages, and at debug level every request, including keycodes.

### Tests

| Test | What it proves |
| --- | --- |
| `lf-wayland` unit tests (15) | tokenizing, the keycode allowlist, batching (maximal, ordered, covering), keymap text, memfd seals, connect timeout against a listener that never accepts, handshake timeout against a silent peer |
| `lf-wayland/tests/xkb_compile.rs` | Generated keymaps compile in real libxkbcommon. Every key yields exactly its character (ASCII, Latin-1, BMP, non-BMP, U+10FFFF, combining, ZWJ), also after the compositor-style `get_as_string` round trip. |
| `lf-wayland/tests/headless_sway.rs` | Private headless sway (own `XDG_RUNTIME_DIR`, no input devices, no XWayland, no D-Bus). The test refuses to run unless `WAYLAND_DISPLAY` resolves to that socket. A client decodes `wl_keyboard` through xkbcommon, and every case must round-trip exactly: ASCII, non-ASCII, emoji/ZWJ/combining, newlines/tabs, `press_enter`, 1,500 chars with 704 distinct (30 keymaps), control-character rejection, reconnect, no-delay typing. It also checks that only allowlisted keycodes appear on the wire, with no stuck keys, zero modifiers and monotonic timestamps. |
| `lf-pipewire` unit tests (20) | downmix, resampler accuracy for 48k/44.1k/8k, aliasing rejection, DC gain, chunked equals one-shot, output length, rate/allocation limits, SPA chunk decoding (modulo offset, wrap, stride, partial frames, NaN), rejected and accepted format changes, truncation and overflow policies |
| `lf-pipewire/tests/private_pipewire.rs` | Private `pipewire` daemon (no ALSA/udev/session manager/D-Bus, socket `lf-test-pipewire`). Its clients use a private client configuration. The test refuses to run unless `PIPEWIRE_REMOTE` is unset and every remote is an absolute path inside its private directory (relative names fall back to `/run/pipewire`). A 48 kHz stereo 440 Hz tone is linked in with a bounded `pw-link` loop. Checks: sample count, RMS, 100% of power at 440 Hz, level meter, 3 cycles, double start, cancel, truncation, overflow error, missing remote, unlinked start timeout, drop while recording. |

### Measurements

Exclusive CPU lock, 3 runs, medians:

| Measurement | Result |
| --- | ---: |
| Typing 900 chars, no key delay (headless sway): `type_text` returns / receiver decodes the last key | 2.7 / 2.7 ms |
| Typing 900 chars, default 1 ms delay: `type_text` returns / receiver decodes the last key | 902.7 / 901.7 ms |
| Capture: `start` call to the first buffer with audio (private graph, 9 starts) | 3.6 ms (2.3–4.2) |

The receiver times are stamped by the test client when it decodes the key, on a headless compositor, so a real app's text-widget insertion is not included. The capture latency covers thread start, connection, stream creation, and linking by a `pw-link` loop polling every 5 ms. A real microphone adds device wake-up from suspend, so measure that with `lf-mic-smoke`.

### Manual tests (live session; not run yet)

From the repository root:

```
nix develop ./linux --command cargo build --release --manifest-path linux/Cargo.toml -p lf-pipewire -p lf-wayland
./linux/target/release/lf-mic-smoke --seconds 5 --cycles 3     # speak; prints duration, RMS, peak, latency only
./linux/target/release/lf-mic-smoke --seconds 3 --target <node.name from `wpctl inspect`>
./linux/target/release/lf-type-smoke --wait 3 'Grüße — “quotes” 👍🏽 日本語'   # focus a text field within 3 s
./linux/target/release/lf-type-smoke --wait 3 --enter 'echo typed'               # in a terminal: runs the command
```

Checklist:
- Microphone: duration about N s per cycle, RMS rises when speaking, and all 3 cycles work. Note the first-buffer latency. Unplug or disable the microphone, and `start` must fail within 3 s.
- Typing, exact text with the Dvorak layout active, in a terminal (foot/kitty), Firefox, a Chromium/Electron app, a GTK app and an XWayland app.
- More than 50 distinct characters (e.g. a long paragraph with digits and punctuation, or CJK text) in each app, which exercises keymap re-uploads.
- Physical keyboard behaviour right after typing: the user's Dvorak layout must still apply. Hold Shift or Super while typing to see how Hyprland merges modifiers.
- Whether an input method (fcitx5/ibus), if enabled, intercepts virtual-keyboard keys.

### Risks

- Hyprland combines modifiers held on the physical keyboard with virtual-keyboard keys (confirmed live 2026-10-08, Hyprland 0.55.4). Text typed while Ctrl was held reached the app as Ctrl shortcuts. Text typed again with Super+F13 still held triggered Hyprland's own binds: Super+L locked the screen and Super+Return opened a terminal, and Super+Q or Super+M (exit) were equally reachable. The daemon cannot see physical modifier state. `device { name = hl-virtual-keyboard-localflowd; keybinds = false }` (`packaging/hyprland.conf`) stops LocalFlow's keyboard from triggering any Hyprland bind; Hyprland reads it when the virtual keyboard is created, so the daemon must (re)connect after it is set. `input:virtualkeyboard:share_states = 0` does not help: it only stops a virtual keyboard's own state from being shared, while a physical keyboard's modifiers are always merged into what apps receive (Hyprland `InputManager::shareModsFromAllKBs`; verified live: Super held while the smoke test typed `z` reached Neovim as `<D-z>`). So apps still see modifiers held when F13 is released. The packaged binds are now F13 hold-to-talk only (the user does not use toggle, cancel or again from the keyboard), so no bind types while its own modifier is held. A remaining option is typing through `zwp_input_method_v2` `commit_string`, which modifiers cannot affect, for apps that support text-input-v3.
- Keymap switching: some clients (XWayland, older Electron) may apply a new keymap late. Batching makes this visible only for texts with more than 50 distinct characters, which long English paragraphs can reach. Two-level keys (the second level reached with Shift) would double the capacity, but they add modifier events; that is not done.
- `start` blocking until Streaming makes the device wake-up time part of the shortcut's response time. To be measured on the real microphone.

## Pause media while recording

Status (2026-10-07): built and tested against fakes and a private
`dbus-daemon`; not yet run on the live session. Requested because recording
switches the user's Bluetooth headset (AirPods Max) to HFP, which degrades
playback. The macOS app's `dictation_audio_interruption_enabled` mutes the
output instead; on Linux, pausing the players is more precise and leaves
system sounds alone.

- **Config:** `pause_media` (default `true`). `--fake-io` disables it.
- **Mechanism:** MPRIS on the D-Bus session bus (`lf-media`, pure-Rust
  `zbus` 5).
  - A recording start lists the `org.mpris.MediaPlayer2.*` names, resolves each to its unique connection name, and calls `Pause` on those whose `PlaybackStatus` is `Playing`.
  - At the end of the recording, `Play` goes only to the players it paused that still report `Paused`. A player the user resumed, stopped or closed meanwhile is left alone. A player restarted under the same name is a new connection, so it is never resumed.
  - `playerctld` is skipped: it forwards calls to the last active player.
  - Only `PlaybackStatus` is read, with `Properties.Get`. No proxy, so no `GetAll` (which would fetch track metadata) and no signal subscriptions.
- **Why not zbus's blocking API alone:** its `method_timeout` only times the
  wait for the reply; the send can block on a bus that stops reading. Each
  call is therefore zbus's async call raced against a timer on the media
  thread (`async_io::block_on`; `async-io` and `futures-lite` are zbus's own
  runtime crates, so no new crates). A call or connection attempt that loses
  is dropped, which cancels it. After a timeout or connection error the
  connection is discarded, because a cancelled send may have left half a
  message. The next call reconnects. A new bus GUID makes every remembered
  player unknown, so stale unique names are never called.
- **API:** `MediaPlayers` (list, status, pause, play), `PlayerId` and
  `MediaError` (`Unavailable`, `Gone`, `TimedOut`, `Rejected`) live in
  `lf-io-api`, next to `AudioCapture` and `TextOutput`. The trait sits there,
  not in `lf-daemon`, so `lf-media` needs no dependency on the daemon. The
  policy (`lf_media::Pauser`) works on any backend, and
  `lf_media::fake::FakePlayers` is the fake.
- **Ownership rules (`Pauser`):**
  - A `Pause` that timed out or lost its connection may have landed, so the player is remembered. A refused or "gone" `Pause` is not remembered, and it also drops any older claim on that player.
  - After a pause pass, it waits up to 300 ms for the paused players to report `Paused` (the deadline is checked before each read). A resume that still reads `Playing` for a player whose pause was never confirmed watches it for up to 700 ms more and plays it if the pause lands.
  - Transient failures (timeouts, lost connection, D-Bus `NoReply`/`Timeout`/`TimedOut`) during a resume are retried once, at the end of the pass. A player that still fails stays paused and remembered. The media thread retries it up to 3 times, 1 s apart, while no recording runs, and again at shutdown.
  - A new pause pass re-pauses remembered players the user had started again. It also pauses players resumed in the last 2 s that still read `Paused`, since their `Play` may not have landed yet.
- **Daemon:**
  - The controller only calls `pause`/`resume` on a `MediaSink`; each sets the wanted state (an atomic flag) and wakes a dedicated `lf-media` thread (`media.rs`). Recording never waits for D-Bus.
  - `pause` comes just before the microphone starts, and `resume` after the capture stopped, on every path out of recording: stop, cancel, maximum length, too-short/empty, capture start or stop failure, and shutdown.
  - The thread works towards the latest wanted state. Queued wake-ups collapse, so a quick tap does not stop and restart the music.
  - Both passes check the wanted state before every call and stop when it changes. A resume overtaken by the next recording leaves the rest paused, and that recording's pass re-pauses any player already resumed. At most the one call in flight can land after the change.
  - When the controller is dropped (shutdown or a control-loop panic), the channel closes and the thread resumes what it still holds. `Handle::join` waits up to 3 s for that.
  - `localflowd` routes termination signals to the shutdown path before the socket serves its first request (`daemon::start_with`), so a signal cannot skip the resume.
- **Bounds:** 250 ms per D-Bus call (sending included), 1 s to connect, at
  most 16 MPRIS names per pass.
- **Failures:** no session bus is a warning (once per outage), and every
  later recording retries. Errors are fixed kinds, never D-Bus messages
  from players. Logs carry counts only, never bus names or metadata.

Tests:

| Test | What it proves |
| --- | --- |
| `lf-media` unit tests (22) | Only playing players are paused. Resume covers only what was paused and still is: user-resumed, user-stopped, vanished and restarted players are left alone. A refused pause is not remembered and a refused re-pause drops the old claim; a timed-out pause is remembered and resumed only if paused. Late pauses are caught by the confirm wait and by settling. A `Play` that has not landed is paused by the next recording. Transient resume failures are retried and, if still failing, kept. Stopped passes keep or skip the right players. A new pass re-pauses restarted players. The confirm and settle waits are bounded even with slow reads. Remote errors are classified without their text. A missing bus fails fast; a silent bus is bounded by the connect timeout, repeatedly, without leaking attempts. |
| `lf-daemon` controller tests (2) | `pause` before the microphone starts and `resume` after it stopped, on every end path. Nothing is sent while transcribing, typing or idle. |
| `lf-daemon` media thread tests (8) | Pause and resume run in order. Closing the channel resumes. Queued requests collapse (the music is never stopped). A resume overtaken by the next recording gives way: only the player already played is played, and it is paused again. A pause overtaken by the end of the recording gives way. These ordering tests are driven by a call hook in the fake, not by timing. Transient resume failures are retried while idle. No bus is retried. `join` is bounded when players hang. |
| `lf-daemon/tests/daemon.rs` (3) | The whole daemon with `FakePlayers` pauses and resumes, also on cancel. Shutdown while recording resumes before `join` returns. Slow players or no bus do not delay recording. |
| `lf-daemon/tests/private_dbus.rs` (6) | Private `dbus-daemon` (own config and socket, `--nosyslog`, cleared environment). The test refuses to run unless `DBUS_SESSION_BUS_ADDRESS` equals the printed private address and the server GUID matches; bootstrap, guard and cleanup are bounded. Fake MPRIS players are served by `zbus` and the daemon uses its real backend. Checks: pause/resume on hold, toggle and cancel; paused and stopped players untouched; one player with two names paused once; `playerctld` ignored; user-changed players left alone; a restarted player not resumed; a player that hangs on `PlaybackStatus` (sorted first) costs one 250 ms timeout, then the healthy player is paused, with immediate replies to the client; shutdown while recording resumes; an unreachable bus does not stop dictation; `Metadata` is never read. |

Codex (gpt-6.1-sol, xhigh) reviewed the work. Round 1 fixed:
- sends not covered by the call timeout;
- a stale resume playing media during the next recording;
- lost ownership on late pauses and transient failures;
- confirm-window overshoot;
- remembered players skipped on re-pause;
- refused pauses treated as ambiguous;
- leaked connection attempts;
- a startup signal window;
- weak hung-player and harness-bound tests.

Round 2 (on the fixes) found no blocking issue. Fixed:
- `Play`s that land late escaping the next pause;
- ownership lost after a second transient failure;
- stale claims kept after a refused re-pause;
- `org.freedesktop.DBus.Error.TimedOut` classified as a refusal;
- settle-window overshoot and an expiry/stop race;
- unbounded harness reads and fake-player joins;
- scheduling-dependent ordering tests (now hook-driven, with wall-clock bounds loosened);
- `Report.failed` documented as players, not calls.

Limitations and manual tests:
- A player the user pauses by hand during the recording (or within the settle window, the idle retries or the 2 s "recent" window around it) is resumed at the end; it cannot be told apart from one LocalFlow paused without watching signals.
- A shutdown over many players that each answer slowly can exceed the 3 s budget; the players not reached stay paused. Likewise if the daemon is killed (SIGKILL) while recording.
- If PipeWire hangs on stop, `lf-pipewire` detaches its capture thread after 2 s and the daemon resumes media anyway (rejected Codex suggestion: keeping music paused until a hung PipeWire recovers is worse; the detached thread's audio is never used).
- Resuming happens when the recording stops, while the headset may still be switching back from HFP to A2DP, so the first moment of audio might be lost. Check this live with the AirPods Max; a short resume delay would be the fix.
- Not yet run live: Spotify, mpv, Firefox/Chromium tabs. See item 16 of the README checklist.
