#!/usr/bin/env bash
set -euo pipefail

# \copy의 상대경로가 항상 DL/SMART-main_DL 아래를 가리키도록
# 이 스크립트가 위치한 DL 디렉터리로 이동한 뒤 psql을 실행한다.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

# 접속 옵션은 그대로 psql에 전달한다.
# 예: bash run_all_v2.sh -h HOST -p 5432 -U USER -d DATABASE
psql "$@" -v ON_ERROR_STOP=1 -f run_all_v2.sql

