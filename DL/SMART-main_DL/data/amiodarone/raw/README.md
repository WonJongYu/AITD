# Amiodarone raw exports

`export_smart_v2.sql`이 PostgreSQL 임시테이블을 이 디렉터리에 CSV로 저장합니다.

생성 파일:

- `feature_model_task1.csv`: 전체 코호트의 AITD 이진예측용 wide 피처
- `feature_model_task2.csv`: 실제 AITD 양성군의 저하증·중독증 분류용 wide 피처
- `smart_task1_labels.csv`: Task 1 라벨(`0=AITD 없음`, `1=AITD 있음`)
- `smart_task2_labels.csv`: Task 2 라벨(`0=저하증`, `1=중독증`)
- `labeling_audit.csv`: 사건일·유형·cutoff·추적 소실 확인 자료
- `export_manifest.csv`: Task별 대상자 수와 라벨 분포
- `cohort_attrition.csv`: 논문 흐름도용 순차 제외기준별 시작·제외·잔여 인원
- `cohort_outcome_counts.csv`: 최종 코호트의 음성·저하증·중독증·mixed 집계

CSV의 빈 필드는 SQL `NULL`입니다. 실제 연구 데이터 CSV는 저장소에 커밋하지 않습니다.
