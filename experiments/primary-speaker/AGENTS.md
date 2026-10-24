# localflow-speaker

Experiments for primary-speaker detection in LocalFlow
(github.com/ajbarryiii/LocalFlow): drop words that someone other than the user
spoke during a dictation. This repository is experimental. Nothing here ships
until the owner approves integration; LocalFlow will then receive only an
exported, hash-pinned model and the reproduced algorithm, not this code.

Read `CONTRACT.md` first. `lfspk/api.py` is the interface; `lfspk/splits.py`
the speaker splits; the test split is sealed.

## Running

- `./python` runs the pinned CUDA PyTorch runtime plus a venv on the data disk
  (`/mnt/hd/localflow-speaker/venv`, torchaudio and scikit-learn added).
  `./python-nemo` adds NeMo 3.0 for Parakeet and TitaNet. Already installed:
  onnxruntime, jiwer, pyroomacoustics, speechbrain, matplotlib. Several agents
  share the venv, so ask the orchestrator to install anything else (never run
  pip yourself); record each package and why in your `DESIGN.md`. Never
  upgrade torch.
- Tests: `./python -m unittest discover -s tests -v`. Workstream tests live in
  `tests/` named `test_<workstream>_*.py`.
- Anything longer than about a minute runs as a supervised job (`job start` or
  the jobs-nixos MCP tools), never `nohup` or `&`.
- GPU: use `--needs gpu:shared --vram <honest budget>` and cap PyTorch with
  `torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))`.
  Exclusive `--needs gpu` only when a shared lease is genuinely impossible, and
  only after the orchestrator agrees. Keep CPU-only stages (feature extraction,
  decoding, mixing) out of GPU leases.
- Memory: set `--mem` honestly; several workstreams share a 60 GB host. Stream
  data rather than loading corpora into memory.
- Everything large lives under `/mnt/hd/localflow-speaker/`. Never commit data,
  audio, embeddings or model weights. One exception, managed by the
  orchestrator only: a read-only NVMe mirror of the LibriSpeech subsets at
  `~/.cache/localflow-speaker/LibriSpeech`, reached through the symlinks in
  `data/LibriSpeech` (`paths.LIBRISPEECH`), because the HDD is the bottleneck
  for on-the-fly mixing. Never write there.

## Data and privacy

- Public corpora only: LibriSpeech, MUSAN, AMI, ICSI, OpenSLR RIR sets, and
  pretrained public models. Record source, licence, URL, hash and retrieval
  date in `/mnt/hd/localflow-speaker/data/PROVENANCE.md`.
- No real user audio, no microphone recording, no LocalFlow user data, ever.
- Voice-synthesis or voice-conversion models (W4's inversion attacks) run only
  on public-corpus speakers. Synthesized audio stays on the data disk and is
  deleted after scoring.

## Review

Before any experiment runs (data generation at scale, training, evaluation),
the design and code go through the sol loop: Codex gpt-6.1-sol at reasoning
xhigh, service tier priority, reviews; address findings with reasoned
pushback and no scope creep; iterate until clean. Later rounds review only the
fix diffs. Unit tests and smoke runs of a few minutes on tiny data are allowed
while writing the code.

## Git

Commit only paths your workstream owns (`git commit -- <paths>`; retry if
`index.lock` is held by another agent). Never rewrite history, never push.
