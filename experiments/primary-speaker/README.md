# localflow-speaker (archived)

This is research code for primary-speaker detection in LocalFlow: removing
words spoken by anyone other than the enrolled user. The experiment ran from
2026-10-21 to 2026-10-24 and was closed without shipping anything. It is kept
for reference and is never to be merged.

- `ARCHIVE.md`: the outcome of each workstream, the conclusion and open items.
- `CONTRACT.md`: the scorer contract and benchmark rules shared by all
  workstreams.
- `lfspk/<area>/DESIGN.md` and `RESULTS.md`: each workstream's pre-registered
  design, its review trail and its results.

| area | workstream |
|---|---|
| `harness` | W0 benchmark harness |
| `embed` | W1 speaker embeddings |
| `probe` | W2 Parakeet encoder probe |
| `pvad` | W3 personal VAD |
| `protect` | W4 voiceprint protection |
| `extract` | W5 feature mask |
| `personal` | W6 per-user fine-tuning |

The code is not portable. The `python` and `python-nemo` wrappers and
`lfspk/paths.py` assume the original NixOS host, its data disk at `/mnt/hd`
and a pinned CUDA PyTorch runtime. The data, renders and checkpoints are not
in this repository. Every corpus is public (LibriSpeech, MUSAN, DEMAND, BUT ReverbDB
and the others listed in `lfspk/paths.py` and `lfspk/harness/corpora.py`). No user audio and no synthesised voices
were used.
