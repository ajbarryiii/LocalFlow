# Archive: primary-speaker detection experiment (2026-10-21 to 2026-10-24)

Status: **CLOSED by owner decision on 2026-10-24.** Nothing here is shipping.
This branch is kept for reference only and is never to be merged into
LocalFlow.

## Goal

Silently drop words spoken by anyone other than the enrolled user during a
LocalFlow dictation, Mac first. Target situations: office chatter, TV, call
audio from laptop speakers, and a second person dictating nearby, often at the
same time. Public corpora only (LibriSpeech, MUSAN, DEMAND, SLR28); no user
audio and no voice synthesis.

## Outcome by workstream

Each area's `RESULTS.md` is the authoritative record, including its review
trail.

| area | workstream | outcome |
|---|---|---|
| `lfspk/harness` | W0 benchmark harness, scenarios S0-S4 | Built and frozen: dev-v1, noise-dev-v1, sealed test-v1 and noise-test-v1. Parakeet drops 6-18 % of target words in the interference scenarios. Even an oracle word filter keeps 18.5 % of interferer words on dev at a 0.5 % target-word budget; the ceiling comes mostly from overlapped speech. The S0 0.1-point guardrail is infeasible under the pooled budget. |
| `lfspk/embed` | W1 speaker embeddings and adaptive profile | ReDimNet2-B2 (3.7 M params) matches TitaNet-L on clean verification. A gated profile update resists second-voice poisoning; an anchored one also resists long-horizon capture, but rejects about 60 % of genuine dictations after a setup change. Stage D stopped at 14 of 48 configs (half A only), with no selection. Best partial result: 42.5 % of interferer words kept, against the oracle's 18.5 %. |
| `lfspk/probe` | W2 Parakeet encoder speaker probe | Closed. Layers 6-8 carry speaker identity, but tap 7 has 2.3 times TitaNet's EER; gate (a) failed (+0.024 < 0.05). |
| `lfspk/pvad` | W3 personal VAD | 7 models trained; no dev evaluation or selection made. |
| `lfspk/protect` | W4 voiceprint protection | Final. Protection is encryption at rest (AES-GCM, ThisDeviceOnly Keychain key), and the dictation history should be encrypted with the same key. Cloning was skipped by owner decision. |
| `lfspk/extract` | W5 VoiceFilter-Lite-style mel mask conditioned on the voiceprint | Stage 0 oracle mask: 14 % of interferer words kept, against 30 % for the oracle word filter on held-out train speakers. The first R1-s0 checkpoint was superseded: it reached about 3-9 % of the oracle's suppression and barely used the voiceprint. The pre-registered fix screen (VA linear head, VB alpha = 3, VC 50 % impostor profiles) found **no variant passing**. Nothing is registered and dev was never scored. |
| `lfspk/personal` | W6 per-user fine-tuning pilot (22 held-out train speakers) | **Neither arm passes.** Matched-user minus wrong-user S4 gain: +0.014 (A-V0) and +0.040 (A-VB), both CIs including 0. A-VB's personal models over-suppress the user about twice as much as its base. The Mac CPU-budget gate was not measured. |

## Overall conclusion

The voiceprint-conditioned mask never learned to use identity: conditioned
and unconditioned twins scored almost the same throughout, and neither
per-user fine-tuning nor the screened loss and data changes fixed that. The
word-filter route (W1/W3) was the strongest remaining path, still far from
its oracle, when the experiment closed. The sealed test sets were never
scored.

## Artifacts

- Code and design records: this repository (local only, no remote).
- Data, renders, checkpoints and reports: `/mnt/hd/localflow-speaker/`
  (`runs/W0` to `runs/W6`, quarantined partials alongside).
- `CONTRACT.md` and `lfspk/api.py`: the scorer contract that all workstreams
  share.

## Open items at closure

- Mac cleanup: done 2026-10-24. W6's bundle (`~/localflow-speaker-w6/`,
  1.8 GB) and `/tmp/w6bench` were deleted; the tar and the Tailscale inbox
  were already empty.
- Product questions never decided: a clean-speech safeguard, the anchored
  versus re-enroll UX, and encrypting the dictation history.
