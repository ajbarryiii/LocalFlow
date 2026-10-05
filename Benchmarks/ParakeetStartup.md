# Parakeet startup experiment

This branch benchmarks the completed 250,000-step ternary Parakeet checkpoint
already shipped by LocalFlow. It leaves the app's default all-function startup
unchanged. It adds no bundled model, MLX dependency, permission request, or
production logging. The Python/Swift benchmark programs are outside the app's
source and resource discovery paths.

## What is compared

| Arm | Initial preparation | Transcription |
| --- | --- | --- |
| `all` | Current 2/4/8/15-second Core ML functions, serially | Smallest suitable function |
| `fifteen-first` | Only the 15-second Core ML function | 15-second function until smaller functions are prepared |
| `mlx` | Repack the shipped C6s8 encoder in RAM for MLX | MLX GPU encoder; existing native frontend and FP32 decoder |
| `mlx-with-ane` | MLX initialization alongside 15-second ANE preparation | MLX transcripts while ANE prepares; then verify the ANE arm separately |

The final checkpoint export SHA-256 is
`a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503`.
These are all implementations of the same checkpoint, not additional models.
There is no dense FP16 export and no CPU/GPU Core ML fallback in this experiment.

MLX reads `Encoder.mlmodelc/model.mil` and its existing `weights/weight.bin`.
It reconstructs the sparse mask, signs and FP16-rounded row scales into MLX's
2-bit affine representation. Floating weights and folded position tables come
from the same blob. The existing bundle supplies frontend constants, FP32
decoder weights and vocabulary. No safetensors, second checkpoint, or converted
weight file is required by this path. Repacked weights exist only in memory.

This compiled-model reader uses an **unsupported, pinned MIL/blob layout**.
It verifies bundle hashes and rejects unexpected storage/layouts. It is a
feasibility tool, not a proposed supported production weight-loading API.
Synthetic tests cover blob bounds, dtype, padding, bit/nibble order, sparse row
scale selection, sign/zero packing, unsafe paths, and integrity failures.

## Startup behavior and length handling

`AppState.init` already calls `prepareLocalTranscriptionIfNeeded()` before
onboarding permissions are granted. Preparation does not wait for microphone
or Accessibility permission, or the first dictation. Its serial queue currently
prepares all four functions before queued transcription can run.

The 15-second function supports shorter inputs through padding. Longer audio
continues to use the existing independent 15-second chunks; the experiment
does not impose a 15-second recording limit or improve boundary context.

`prepareRemainingBuckets` allows benchmark clients to warm smaller functions
one at a time, yielding the service queue between functions. It is not called
by the app or the timing arms. An in-progress Core ML load/prediction cannot
be preempted: background warmups on that queue can still block dictation for
one whole warmup. Production scheduling needs separate investigation before
enabling incremental preparation.

## Reproduce

Run on Apple Silicon, macOS 26 or later, using the upstream
`wilderness-labs-stt/finetune/parakeet-ternary/ios` pinned Mac environment
(Python 3.12, MLX 0.32.3, NumPy) and its `macguard` launcher. No dependency
installation or upstream checkout modification is required.

```sh
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" make check
git diff --check
"$IOS/pyenv/.venv/bin/python" -m unittest discover \
  -s Tests -p 'test_parakeet_weight_index.py'
"$IOS/pyenv/.venv/bin/python" scripts/benchmark-parakeet-startup.py \
  --bundle "$MODEL_BUNDLE" \
  --output "$NEW_ARTIFACT_DIRECTORY" \
  --guard "$IOS/macguard"
```

`IOS`, `MODEL_BUNDLE`, and `NEW_ARTIFACT_DIRECTORY` refer to existing local
paths. Output must be a new directory outside this Git checkout. Use
`--arms all fifteen-first`, `--arms mlx mlx-with-ane`, or `--repeats 2` to
select arms or reverse their order on alternating repeats.

The runner builds a standalone optimized Swift executable, uses the installed
Samantha voice to generate an invented sentence, and pads it to 4/7/14 seconds.
The 18-second fixture has the same sentence in each of two chunks. It verifies
expected text internally and reports only match flags and timings. It never
launches LocalFlow, records a microphone, reads history/settings/context, or
contacts a transcription provider. Fixtures and scratch feature/encoder files
contain only this explicitly generated synthetic input and stay outside Git.

Each arm gets a copied inference-only bundle at a new path, followed by another
process using that same path. Copies are experiment inputs, not new shipping
assets. Existing metadata labeling normalizes the LocalFlow model ID while
leaving encoder/decoder weight bytes unchanged. Bundle copying, compilation of
the benchmark executable, and speech generation are excluded from startup
timers. Bundle integrity verification, native weight loading, MLX imports,
packing, and first inference are included. MLX uses file IPC to reuse the app's
frontend and decoder; that overhead is included in transcription time.

## Results: shared M1 Pro, macOS 27.0, 2026-10-05

The complete comparison is in [the timing record](parakeet-startup-results.json).
Times below run from CLI initialization to the first matched transcript.

| Arm | New-path first transcript | Same-path fresh-process first transcript | New-path peak group RSS |
| --- | ---: | ---: | ---: |
| All four ANE functions | 372.04 s | 2.28 s | 450 MiB |
| 15-second ANE function first | 94.27 s | 0.83 s | 489 MiB |
| Shared-weight MLX | 5.40 s | 5.41 s | 953 MiB |
| Shared-weight MLX alongside ANE preparation | 5.44 s | 6.05 s | 1,104 MiB |

Every fixture matched, including the 18-second two-chunk recording. The
15-second-only arm's prepared transcription times were 58–85 ms for single
chunks and 114 ms for two chunks in the new-path run. MLX's warmed 14-second
fixture median was about 108 ms. MLX's peak allocation was 451 MiB; total
process-group RSS was higher because of native workers and other allocations.

In the concurrent new-path run, ANE's first transcript was ready at 104.54 s.
MLX completed 87 additional probes during preparation: median 121 ms,
95th percentile 152 ms, maximum 220 ms. Their expected text also matched.
After preparation, MLX's median was 109 ms. The corresponding same-path ANE
process was ready in 1.01 s, before MLX; there were no overlapping probes.
One run per ANE configuration cannot establish whether the approximately
10-second ANE difference with concurrency was caused by MLX or normal noise.

An independent validation-only comparison against the hash-verified final
export confirmed bit-exact reconstruction of the ternary codes and
FP16-rounded row scales for all 240 runtime ternary matrices. That export was
not an input to any MLX transcription run. The folded floating tensors are
read directly from the existing compiled-model blob.

The 15-second-first approach is the smallest candidate change: roughly
94 seconds of preparation could fit within the described two-minute permission
setup, and short-chunk transcription remained fast. Preparing smaller functions
on the dictation queue immediately afterward could reintroduce long stalls.
Keeping the 15-second function for the session, or investigating a separate
preparation path, merits app-level testing before enabling this strategy.

Shared-weight MLX addresses the remaining gap when setup finishes sooner:
usable synthetic transcription in about five seconds, with responsive inference
during preparation. A cached ANE startup was faster than MLX initialization;
production should avoid requiring MLX readiness or retaining it unnecessarily
on that path. The runtime-size issue below prevents a negligible-growth claim.

## Interpretation and remaining work

New-path loads are
**not proven cold device-cache loads**: no cache deletion or Instruments cache
events are used. A fresh process does not imply a fresh ANE specialization
cache. This is a synthetic smoke comparison on a shared M1 Pro, not a WER
evaluation, a controlled device matrix, or sustained speech throughput.
The padded fixtures contain short speech, so decoder work is lighter than a
fully voiced recording of the same duration.

The benchmark demonstrates concurrent MLX/ANE feasibility, not app routing,
handoff, MLX unloading, cancellation, or robust fallback after preparation
failure. Those require a later production change and manual app testing.
MLX peak allocation excludes native workers and system Core ML/ANE services.
The guard reports peak process-group RSS and swap growth separately; its
polling can miss short peaks and also excludes system services.
The concurrent arm uses two native runtimes in separate benchmark processes;
its RSS is not a measured production app memory increase.
The concurrent arm probes a synthetic 14-second fixture at one-second intervals
throughout remaining preparation and reports median/p95/max latency. A cached
ANE load may finish before MLX initializes; zero overlapping samples then
provide no evidence about contention.

The installed Python MLX runtime is not a small packaging reference: its four
binary assets total 214,610,664 bytes (204.7 MiB), including a 190,319,536-byte
Metal library and a 21,108,048-byte MLX dynamic library. Python bindings and
the distributed-computing library account for the rest. These are installed
development binaries, **not a measured Swift app bundle increase**. Native
linking, kernel selection, distribution compression and licensing need to be
evaluated before claiming negligible bundle growth. Sharing weights alone
does not establish that result.

Required checks are `make check`, the pinned-environment packing tests,
standalone benchmark compilation, synthetic transcript checks, and
`git diff --check`. App-level microphone, shortcuts, Accessibility paste,
offline behavior, cancellation and handoff are not tested by this harness.
No app permissions should be changed for this experiment.
