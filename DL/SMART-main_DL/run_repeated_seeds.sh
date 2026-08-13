#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

python_bin="${PYTHON_BIN:-python3}"
device="${DEVICE:-auto}"
batch_size="${BATCH_SIZE:-64}"
pretrain_epochs="${PRETRAIN_EPOCHS:-25}"
finetune_epochs="${FINETUNE_EPOCHS:-50}"
threshold_method="${THRESHOLD_METHOD:-target-sensitivity}"
target_sensitivity="${TARGET_SENSITIVITY:-0.90}"

"${python_bin}" run_repeated_seeds.py \
  --device "${device}" \
  --batch-size "${batch_size}" \
  --pretrain-epochs "${pretrain_epochs}" \
  --finetune-epochs "${finetune_epochs}" \
  --threshold-method "${threshold_method}" \
  --target-sensitivity "${target_sensitivity}" \
  "$@"

