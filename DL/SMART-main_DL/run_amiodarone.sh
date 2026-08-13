#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

python_bin="${PYTHON_BIN:-python3}"
device="${DEVICE:-auto}"
seed="${SEED:-3407}"
batch_size="${BATCH_SIZE:-64}"
pretrain_epochs="${PRETRAIN_EPOCHS:-25}"
finetune_epochs="${FINETUNE_EPOCHS:-50}"
threshold_method="${THRESHOLD_METHOD:-target-sensitivity}"
target_sensitivity="${TARGET_SENSITIVITY:-0.90}"

"${python_bin}" data/amiodarone/preprocess.py --seed "${seed}"

"${python_bin}" pretrain_amiodarone.py \
  --device "${device}" \
  --seed "${seed}" \
  --batch-size "${batch_size}" \
  --epochs "${pretrain_epochs}"

"${python_bin}" train_amiodarone.py \
  --task task1 \
  --device "${device}" \
  --seed "${seed}" \
  --batch-size "${batch_size}" \
  --epochs "${finetune_epochs}" \
  --require-pretrained \
  --class-weights \
  --threshold-method "${threshold_method}" \
  --target-sensitivity "${target_sensitivity}"

"${python_bin}" train_amiodarone.py \
  --task task2 \
  --device "${device}" \
  --seed "${seed}" \
  --batch-size "${batch_size}" \
  --epochs "${finetune_epochs}" \
  --require-pretrained \
  --class-weights \
  --threshold-method "${threshold_method}" \
  --target-sensitivity "${target_sensitivity}"

echo "Amiodarone SMART pipeline completed. Results: export/amiodarone/"
