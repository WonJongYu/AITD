# PostgreSQL 폐쇄망 실행 방법

## 전제

- PostgreSQL `psql` 클라이언트를 사용한다.
- OMOP CDM 임상 테이블과 vocabulary 테이블에 읽기 권한이 있어야 한다.
- `dataset.csv` 등 환자 수준 결과는 폐쇄망 밖으로 반출하지 않는다.
- 전체 SQL은 PostgreSQL TEMP TABLE을 공유하므로 반드시 한 연결에서 실행한다.

## 전체 권장 순서

1. DB 컴퓨터에서 PostgreSQL SQL runner를 실행하여 환자 수준 CSV를 생성한다.
2. DB 컴퓨터에서 QA를 확인하고 승인 USB에 결과를 복사한다.
3. Python 컴퓨터가 오프라인일 때 USB에서 requirements 파일만 먼저 복사하고 USB를
   분리한다.
4. USB가 분리된 상태에서 Python 컴퓨터의 인터넷을 개방한다.
5. Python 환경을 설치하고 `pip check`, import 및 버전 기록을 완료한다.
6. Python 컴퓨터의 인터넷 연결을 종료한다.
7. 인터넷 종료 후 USB를 다시 연결하여 `dataset.csv`와 노트북을 복사한다.
8. Python 컴퓨터에서 모델링 노트북을 실행한다.

DB 컴퓨터와 Python 컴퓨터는 서로 다른 장비이다. `dataset.csv`가 저장된 USB는
Python 컴퓨터의 네트워크가 꺼진 상태에서만 연결한다.

## DB 컴퓨터에서 PostgreSQL 실행

기존 결과를 덮어쓰지 않도록 폐쇄망 안에 실행별 새 결과 디렉터리를 만들고
그 디렉터리에서 실행한다. `\ir`은 SQL 파일을 runner 위치 기준으로 찾고,
`\copy` 결과는 현재 작업 디렉터리에 저장한다.

```bash
mkdir replication_run_YYYYMMDD
cd replication_run_YYYYMMDD

psql -X -v ON_ERROR_STOP=1 \
  -v cdm_schema=실제_CDM_SCHEMA \
  -v vocabulary_schema=실제_VOCABULARY_SCHEMA \
  -d 실제_DATABASE_NAME \
  -f /승인된_경로/replication/run_all_replication_postgresql.sql
```

접속에 host, port, user가 필요하면 다음 옵션을 추가한다.

```bash
-h HOST -p PORT -U USER
```

CDM과 vocabulary가 같은 schema에 있으면 두 변수에 같은 값을 넣는다.

## 실행 순서

1. `cohort3_selection.sql`
2. `labeling3.sql`
3. `demographics3_extraction.sql`
4. `feature3_extraction.sql`
5. `qa3_postgresql.sql`

오류가 하나라도 발생하면 `ON_ERROR_STOP`과 transaction 때문에 dataset export까지
진행하지 않는다. 오류 원인을 수정한 후 새 DB 연결에서 처음부터 다시 실행한다.

## 생성 파일

- `dataset.csv`: Python 모델링 입력용 환자 수준 자료
- `cohort_flow_summary.csv`: 단계별 코호트 환자 수
- `replication_qa_summary.csv`: 라벨 및 주요 검사 추출 QA

세 파일은 `psql`을 실행한 현재 디렉터리에 생성된다.

## 별도 Python 컴퓨터의 환경 준비

DB 컴퓨터에서 CSV 생성을 마친 다음 진행한다. Python 컴퓨터가 오프라인일 때 USB에서
`requirements-model.txt`만 먼저 복사하고 USB를 분리한다. USB가 분리되었고
`dataset.csv`가 Python 컴퓨터에 없는 것을 확인한 다음 인터넷을 열어 설치한다.

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install \
  -r /승인된_경로/replication/model/requirements-model.txt
```

설치 직후 인터넷이 열려 있을 때 의존성과 import를 검증하고 정확한 버전을 기록한다.

```bash
python -m pip check
python -c "import numpy, pandas, sklearn, xgboost, imblearn, matplotlib, seaborn, shap, lifelines, jupyterlab, ipykernel; print('Python packages: OK')"
python --version > python_environment.txt
python -m pip freeze >> python_environment.txt
python -m pip freeze > requirements-lock.txt
```

가능하면 `pip download --dest wheelhouse -r requirements-lock.txt`로 현재 환경용 설치
파일도 저장한다. 설치와 검증이 끝나면 Python 컴퓨터의 인터넷 연결을 종료한다.
인터넷 종료를 확인한 후에만 USB를 연결하여 `dataset.csv`와 노트북을 복사한다.

## 노트북 실행

Python 컴퓨터의 `replication_python_run_YYYYMMDD` 디렉터리에 USB의 `dataset.csv`와
노트북을 복사한다. 이렇게 하면 입력과 모든 모델 결과 CSV가 한 실행 폴더 안에 남는다.

```bash
cp /승인된_경로/replication/model/preprocessing\&model.ipynb .
```

가장 안전한 기본값은 CPU와 단일 병렬 작업이다.

```bash
export XGB_DEVICE=cpu
export MODEL_N_JOBS=1
jupyter lab
```

Jupyter에서 `preprocessing&model.ipynb`를 열고 **위에서 아래로 순차 실행**한다.
GPU가 승인·설치되어 있고 XGBoost CUDA 실행을 확인한 경우에만
`XGB_DEVICE=cuda`로 바꾼다. 단일 GPU에서는 `MODEL_N_JOBS=1`을 유지한다.

화면 조작 없이 전체 노트북을 실행하려면 다음 명령을 사용할 수 있다. RFECV와
튜닝 시간이 길 수 있으므로 timeout을 해제한다.

```bash
XGB_DEVICE=cpu MODEL_N_JOBS=1 \
  jupyter nbconvert --to notebook --execute --inplace \
  --ExecutePreprocessor.timeout=-1 'preprocessing&model.ipynb'
```

## 모델링 전체 과정

1. `dataset.csv`의 필수 열, 날짜, observation-window 이름을 검증한다.
2. 비현실적인 신장·체중을 결측으로 처리하고 BMI를 함께 재설정한다.
3. SQL이 정한 마지막 완전 관찰구간까지만 검사실 값을 선택한다. AITD 발생 구간의
   값과 loss-to-follow-up 이후 값은 feature에 사용하지 않는다.
4. 원시 시계열/라벨 날짜 열을 모델 입력에서 제외하고 `df_preprocessed.csv`와
   `survival_metadata.csv`를 만든다.
5. 환자를 stratified 80% development / 20% hold-out test로 한 번 분리한다.
6. MICE와 RobustScaler는 각 training fold 안에서만 적합한다.
7. development set에서 기본 네 모델의 5-fold OOF 성능을 확인한다. 이 단계에서는
   hold-out test를 조회하지 않는다.
8. 전처리 후 남은 전체 변수로 AdaBoost와 XGBoost 각각 5-fold recursive feature
   elimination을 수행한다. 각 단계에서 accuracy와 feature importance를 다시
   계산하고 중요도가 가장 낮은 변수 한 개를 제거한다. 모델별 최고 accuracy의
   변수 조합을 선택한 뒤 두 조합의 교집합을 최종 feature로 사용한다.
9. 교집합 feature로 KNN, Logistic Regression, XGBoost, AdaBoost와 네 sampling
   전략(none, Borderline-SMOTE, ENN, 두 방법 결합)을 조합한다. 각 조합은
   development set의 5-fold RandomizedSearchCV에서 macro-F1로 튜닝한다.
10. 모든 선택과 튜닝이 끝난 뒤 hold-out test를 한 번 평가한다.
11. XGBoost + Borderline-SMOTE 설명용 모델의 SHAP을 계산한다. threshold는
    development OOF 예측에서 정하고 고정한 뒤 test에 적용한다.
12. 실제 `analysis_end_date - index_date`를 이용해 test 환자의 Kaplan-Meier 분석을
    수행한다.

RFECV의 선택 기준은 요청한 대로 **accuracy**이고, 이후 하이퍼파라미터 튜닝 기준은
현재 원 모델링 코드의 **macro-F1**이다. 둘은 서로 다른 단계이므로 혼동하지 않는다.

## 모델링 생성 CSV

- `df_preprocessed.csv`: 모델 입력용 전처리 데이터
- `survival_metadata.csv`: 실제 추적기간과 사건일 정보
- `quick_development_cv_performance.csv`: 기본 모델 development OOF 성능
- `recursive_accuracy_history_adaboost.csv`
- `recursive_accuracy_history_xgboost.csv`
- `rfecv_feature_selection_adaboost.csv`
- `rfecv_feature_selection_xgboost.csv`
- `rfecv_feature_selection_all_models.csv`
- `recursive_selected_feature_intersection.csv`: 최종 공통 feature
- `tuning_results_log_adaboost_xgboost_intersection_*.csv`: 튜닝 재시작용 로그
- `development_5fold_cv_performance.csv`: 최적 파라미터의 5-fold 성능
- `final_holdout_performance.csv`: 최종 hold-out 성능
- `thresholds_selected_from_development_oof.csv`: development에서 고정한 threshold
- `final_threshold_performance.csv`: 고정 threshold의 hold-out 성능

환자 식별자와 환자 수준 자료가 포함된 `dataset.csv`, `df_preprocessed.csv`,
`survival_metadata.csv`는 폐쇄망 밖으로 반출하지 않는다. 외부 전달용 결과는 병원
규정에 따라 최소 셀 크기와 비식별 기준을 확인한 집계표만 별도로 준비한다.

## Table, Figure 및 보고서 생성

노트북 전체 실행이 완료되면 Python 실행 디렉터리에서 다음을 실행한다.

```bash
python /승인된_경로/replication/report/generate_report.py \
  --input-dir /승인된_경로/replication_python_run_YYYYMMDD
```

`report_outputs`에 Table 1-6 CSV, Figure 1-5 PNG/PDF, Markdown, HTML 및 최종 PDF
보고서가 생성된다. 이 단계는 모델을 다시 학습하지 않는다. 상세 데이터 계약과
파일 목록은 `replication/report/README.md`에 정리되어 있다.
