# SMART for amiodarone-associated thyroid dysfunction

이 디렉터리는 길병원 폐쇄망에서 SQL로 추출한 아미오다론 코호트를 SMART 모델로 분석하기 위한 전용 코드입니다.

## 예측 과제

- **Task 1:** 갑상선 기능 저하증과 중독증을 하나의 AITD로 묶은 이진예측 (`0=AITD 없음`, `1=AITD 있음`)
- **Task 2:** 실제 AITD 양성군 안에서 아형 분류 (`0=갑상선 기능 저하증`, `1=갑상선 중독증`)

환자별로 SQL에서 정한 서로 다른 `feature_cutoff_date`까지의 정보만 입력에 사용합니다. 마지막 입력 구간 다음 구간의 발생 여부 또는 아형을 예측하므로 결과 구간의 정보는 입력에 포함하지 않습니다.

## 폐쇄망 실행 순서

1. PostgreSQL에서 `DL/run_all_v2.sql` 또는 `DL/run_all_v2.sh`를 실행합니다.
2. `DL/export_smart_v2.sql`로 6개 CSV를 `data/amiodarone/raw/`에 저장합니다.
3. 폐쇄망 Python 환경에 `requirements_amiodarone.txt`의 패키지를 준비합니다.
4. 이 디렉터리에서 다음 명령을 실행합니다.

```bash
bash run_amiodarone.sh
```

순수 Windows PowerShell 환경에서는 다음 명령을 사용합니다.

```powershell
.\run_amiodarone.ps1
```

실행 스크립트는 데이터 검증·전처리, SMART 사전학습, Task 1 미세조정, Task 2 미세조정을 차례로 수행합니다. 결과와 모델 가중치는 `export/amiodarone/`에 저장됩니다.

최종 연구 결과는 단일 분할보다 5개 seed 반복 층화 holdout을 기본으로 실행합니다.

```bash
bash run_repeated_seeds.sh
```

```powershell
.\run_repeated_seeds.ps1
```

각 반복은 환자 분할과 정규화를 다시 만들고 사전학습부터 Task 1·2까지 독립적으로
학습합니다. 반복별 결과와 평균·표준편차는 `export/amiodarone/repeated/`에 저장됩니다.

세부 데이터 구조, CSV 설명, 누수 방지 규칙과 실행 방법은 [`../SMART_PIPELINE_GUIDE.md`](../SMART_PIPELINE_GUIDE.md)를 확인하십시오.

## 남겨 둔 구성

- `data/amiodarone/`: 아미오다론 SQL 추출물 검증·전처리
- `data/amiodarone.py`: 전처리 결과 로더
- `models/smart.py`: SMART 인코더와 분류기
- `pretrain_amiodarone.py`: 연구 코호트 기반 사전학습
- `train_amiodarone.py`: Task 1·2 학습 및 평가
- `run_amiodarone.sh`: 전체 모델 파이프라인 실행
- `run_amiodarone.ps1`: Windows PowerShell용 전체 모델 파이프라인 실행
- `run_repeated_seeds.py`: 반복 층화 holdout 실행 및 결과 집계
- `run_repeated_seeds.sh`, `run_repeated_seeds.ps1`: Linux·Windows 반복 실행 파일
- `utils/`: 아미오다론 학습에 사용하는 공통 함수

## 원 모델 인용

이 연구용 구현은 SMART 공식 구현을 기반으로 합니다.

```text
@inproceedings{yu2024smart,
  title={SMART: Towards Pre-trained Missing-Aware Model for Patient Health Status Prediction},
  author={Yu, Zhihao and Chu, Xu and Jin, Yujie and Wang, Yasha and Zhao, Junfeng},
  booktitle={NeurIPS 2024},
  year={2024}
}
```
