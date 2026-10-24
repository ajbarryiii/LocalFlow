#!/usr/bin/env bash
# W2 stage 2: the committed command chain (DESIGN 5). Supervised jobs; GPU
# extraction on a shared lease, scoring and metrics on the CPU.
#   lfspk/probe/run_stage2.sh            # from the repository root
set -euo pipefail
cd "$(dirname "$0")/../.."
gpu=(--needs gpu:shared --vram 8G --vram-enforce --mem 12G --cpus 8 --stall 20m --timeout 3h)
cpu=(--mem 14G --cpus 8 --stall 60m --timeout 6h)

skip_base="${1:-}"  # --skip-base: relaunch after the base jobs have succeeded
if [ "$skip_base" != "--skip-base" ]; then
job start w2-x-base-train "${gpu[@]}" -- ./python-nemo -m lfspk.probe.extract --system base --split train
job start w2-x-base-dev "${gpu[@]}" --after w2-x-base-train -- ./python-nemo -m lfspk.probe.extract --system base --split dev
job start w2-x-base-dev-colour "${gpu[@]}" --after w2-x-base-dev -- ./python-nemo -m lfspk.probe.extract --system base --split dev --colour
fi
job start w2-x-m1-train "${gpu[@]}" --after w2-x-base-dev-colour -- ./python-nemo -m lfspk.probe.extract --system m1 --split train
job start w2-x-m1-dev "${gpu[@]}" --after w2-x-m1-train -- ./python-nemo -m lfspk.probe.extract --system m1 --split dev
job start w2-x-m1-dev-colour "${gpu[@]}" --after w2-x-m1-dev -- ./python-nemo -m lfspk.probe.extract --system m1 --split dev --colour
job start w2-x-tn-train "${gpu[@]}" --after w2-x-m1-dev-colour -- ./python-nemo -m lfspk.probe.extract --system titanet --split train
job start w2-x-tn-dev "${gpu[@]}" --after w2-x-tn-train -- ./python-nemo -m lfspk.probe.extract --system titanet --split dev
job start w2-x-tn-dev-colour "${gpu[@]}" --after w2-x-tn-dev -- ./python-nemo -m lfspk.probe.extract --system titanet --split dev --colour

# scoring (CPU): back ends fitted on train, dev trials scored
v="env OMP_NUM_THREADS=8 ./python -m lfspk.probe.verify"
[ "$skip_base" = "--skip-base" ] || job start w2-v-base "${cpu[@]}" --after w2-x-base-dev-colour -- bash -c "$v --feature base && $v --feature base --colour && $v --feature logmel && $v --feature logmel --colour"
job start w2-v-m1 "${cpu[@]}" --after w2-x-m1-dev-colour -- bash -c "$v --feature m1 && $v --feature m1 --colour"
job start w2-v-tn "${cpu[@]}" --after w2-x-tn-dev-colour -- bash -c "$v --feature titanet && $v --feature titanet --raw-cosine && $v --feature titanet --colour && $v --feature titanet --colour --raw-cosine"
job start w2-report "${cpu[@]}" --after w2-v-base,w2-v-m1,w2-v-tn -- env OMP_NUM_THREADS=1 ./python -m lfspk.probe.report --workers 8 --quiet
job start w2-closedset "${cpu[@]}" --after w2-x-tn-train -- env OMP_NUM_THREADS=1 ./python -m lfspk.probe.closedset --workers 8
