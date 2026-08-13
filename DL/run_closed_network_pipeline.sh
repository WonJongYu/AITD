#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

# 전달한 접속 인자는 psql에만 사용한다.
# 예: bash run_closed_network_pipeline.sh -h HOST -p 5432 -U USER -d DATABASE
bash run_all_v2.sh "$@"

cd SMART-main_DL
bash run_amiodarone.sh

echo "Closed-network SQL and SMART pipeline completed."

