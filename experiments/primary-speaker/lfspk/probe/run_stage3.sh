#!/usr/bin/env bash
# W2 stage 3: the committed command chain (DESIGN 6). Back ends on the CPU,
# head training one job at a time on a shared GPU lease, frame report on the CPU.
# Chained after the stage-2 extraction jobs of run_stage2.sh. VRAM lease 11G:
# seed-1 runs peaked at 9.4 GiB device memory (nvidia-smi), above the 9G first used.
# Host --mem 22G: every run reached the 16G cgroup cap (page cache of the memmapped
# features and audio cache counts), and base seed 2 was OOM-killed there.
#   lfspk/probe/run_stage3.sh            # from the repository root
set -euo pipefail
cd "$(dirname "$0")/../.."
cpu=(--mem 14G --cpus 8 --stall 60m --timeout 4h)
gpu=(--needs gpu:shared --vram 11G --vram-enforce --mem 22G --cpus 10 --stall 20m --timeout 3h)
s3="./python -m lfspk.probe.stage3"

if [ "${1:-}" != "--train-only" ]; then
job start w2-s3-be-base "${cpu[@]}" --after w2-x-base-train -- env OMP_NUM_THREADS=8 $s3 fit-backends --feature base
job start w2-s3-be-logmel "${cpu[@]}" --after w2-x-base-train -- env OMP_NUM_THREADS=8 $s3 fit-backends --feature logmel
job start w2-s3-be-m1 "${cpu[@]}" --after w2-x-m1-train -- env OMP_NUM_THREADS=8 $s3 fit-backends --feature m1
fi
# packed int16 audio (bit-identical to the FLACs; audiocache.py) so training does
# not read ~400k random FLACs per run from the shared USB disk
cache=(--mem 6G --cpus 2 --stall 30m --timeout 3h)
job start w2-s3-cache-train "${cache[@]}" --after w2-x-base-train -- ./python -m lfspk.probe.audiocache --name train-halfB --split train
job start w2-s3-cache-dev "${cache[@]}" --after w2-s3-cache-train,w2-x-base-dev -- ./python -m lfspk.probe.audiocache --name dev --split dev

prev=w2-s3-be-base,w2-s3-be-logmel,w2-s3-be-m1,w2-x-base-dev,w2-x-m1-dev,w2-s3-cache-dev
for seed in 1 2 3; do
  for w in m1 base; do
    name="w2-s3-$w-s$seed"
    job start "$name" "${gpu[@]}" --after "$prev" -- ./python-nemo -m lfspk.probe.stage3 train --weights "$w" --seed "$seed"
    prev="$name"
  done
done
job start w2-s3-report "${cpu[@]}" --after "$prev" -- env OMP_NUM_THREADS=1 ./python -m lfspk.probe.framereport --workers 8
