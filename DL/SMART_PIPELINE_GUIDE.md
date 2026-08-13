# 길병원 폐쇄망 전체 실행 안내

## 전체 파이프라인

```text
DB 컴퓨터
코호트 생성 → TSH 라벨링 → 피처 추출 → CSV 8개 생성
                                      ↓ 승인 USB
Python 컴퓨터
라이브러리 설치 → 인터넷 차단 → 전처리 → 시험 학습 → 5개 seed 최종 학습
```

DB 컴퓨터와 Python 컴퓨터가 다르므로 `run_closed_network_pipeline.ps1`은 사용하지 않습니다.

## 1. DB 컴퓨터: SQL과 CSV 생성

PowerShell에서 `DL` 폴더로 이동합니다.

```powershell
Set-Location "DL 폴더 전체 경로"

.\run_all_v2.ps1 `
  -h POSTGRES_HOST `
  -p 5432 `
  -U USER_NAME `
  -d DATABASE_NAME
```

`run_all_v2.ps1`은 다음 SQL을 한 세션에서 순서대로 실행합니다.

1. `cohort2_selection.sql`: 전체 OMOP 기록의 최초 아미오다론 처방자를 선정하고 제외기준과 2년 추적기간을 적용
2. `labeling2.sql`: TSH로 Task 1 AITD 여부와 Task 2 저하증·중독증 라벨 생성
3. `demographics2_extraction.sql`: 인구학 정보와 아미오다론 사용기간 추출
4. `feature2_extraction.sql`: 고정 피처와 구간별 검사·질환·병용약물 추출
5. `export_smart_v2.sql`: 모델 입력용 CSV 6개와 코호트 흐름·outcome 집계 CSV 2개 저장

실행 결과에서 다음을 확인합니다.

- `n_qualified_with_prior_amiodarone_must_be_zero = 0`
- `n_final_cohort`, `n_final_flag`, `n_demographics`, `n_task1_rows`가 동일
- Task 1과 Task 2에 라벨 0과 1이 모두 존재

## 2. USB로 옮길 파일

아래 8개 CSV를 병원 승인 USB로 Python 컴퓨터에 옮깁니다.

```text
SMART-main_DL\data\amiodarone\raw\
├─ feature_model_task1.csv
├─ feature_model_task2.csv
├─ smart_task1_labels.csv
├─ smart_task2_labels.csv
├─ labeling_audit.csv
├─ export_manifest.csv
├─ cohort_attrition.csv
└─ cohort_outcome_counts.csv
```

Python 컴퓨터에도 `SMART-main_DL` 코드 폴더 전체가 있어야 합니다. CSV에는 환자 정보가 있으므로 폐쇄망 밖으로 반출하지 않습니다.

## 3. Python 컴퓨터: 라이브러리 설치

인터넷을 열고 `SMART-main_DL` 폴더에서 실행합니다.

```powershell
Set-Location "SMART-main_DL 폴더 전체 경로"

python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\requirements_amiodarone.txt

python -c "import numpy, pandas, sklearn, torch; print('packages OK'); print('CUDA:', torch.cuda.is_available())"
```

설치와 import 확인이 끝나면 인터넷을 닫습니다. GPU를 사용할 경우 설치된 PyTorch가 분석실 CUDA 환경과 호환되어야 합니다.

## 4. 인터넷 차단 후 전처리

```powershell
python .\data\amiodarone\preprocess.py --seed 3407
```

모델 CSV의 구조와 라벨을 검사하고, 환자 단위 train/validation/test 분할 및 Task 1 훈련군 기반 정규화를 수행합니다.

논문용 코호트 흐름도를 생성합니다.

```powershell
python .\make_cohort_flowchart.py
```

단계별 순차 제외 인원이 표시된 300 dpi PNG와 벡터 PDF가 `export\amiodarone\`에 생성됩니다.

## 5. 1 epoch 시험 실행

```powershell
.\run_amiodarone.ps1 `
  -Device auto `
  -BatchSize 16 `
  -PretrainEpochs 1 `
  -FinetuneEpochs 1
```

전처리 → SMART pre-training → Task 1 fine-tuning → Task 2 fine-tuning이 오류 없이 연결되는지만 확인합니다. 이 결과의 성능은 사용하지 않습니다.

## 6. 최종 5개 seed 반복 실험

시험 실행이 성공하면 실행합니다.

```powershell
.\run_repeated_seeds.ps1 `
  -Device auto `
  -BatchSize 64 `
  -PretrainEpochs 25 `
  -FinetuneEpochs 50 `
  -ThresholdMethod target-sensitivity `
  -TargetSensitivity 0.90
```

각 seed에서 분할·정규화·pre-training·Task 1/2 fine-tuning을 독립적으로 다시 수행합니다. 기본 seed는 `3407, 2024, 2025, 2026, 2027`입니다.

최종 결과는 다음 위치에서 확인합니다.

```text
export\amiodarone\repeated\aggregate_metrics.csv
export\amiodarone\repeated\aggregate_summary.json
```

- `aggregate_metrics.csv`: seed별 AUROC, Average Precision, 임계값, 민감도, 특이도, F1 및 test 사건 수
- `aggregate_summary.json`: Task별 5회 평균과 표준편차
- `test_predictions.csv`: 환자 ID가 있으므로 폐쇄망 외부 반출 금지
