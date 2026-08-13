/* ========================================================================
   File Name      : export_smart_v2.sql
   Description    : SMART Task 1·2 입력과 코호트 흐름도 집계를 CSV로 저장
   Client         : PostgreSQL psql (\copy 메타 명령 사용)
   Dependencies   : feature2_extraction.sql

   실행 위치
     SQL/DL 디렉터리에서 실행해야 아래 상대경로로 저장된다.

   출력 위치
     SMART-main_DL/data/amiodarone/raw/

   주의
     - \copy는 PostgreSQL 서버가 아니라 psql을 실행한 로컬 컴퓨터에 저장한다.
     - 기존 CSV가 있으면 같은 파일명으로 덮어쓴다.
     - NULL은 빈 문자열로 저장하고 실제 숫자 0과 구분은 다음 전처리 단계에서
       CSV 결측값으로 읽어 처리한다.
   ======================================================================== */

\set ON_ERROR_STOP on

\echo '[SMART export 1/8] Task 1 feature table'
\copy (SELECT * FROM feature_model_task1 ORDER BY person_id) TO 'SMART-main_DL/data/amiodarone/raw/feature_model_task1.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 2/8] Task 2 feature table'
\copy (SELECT * FROM feature_model_task2 ORDER BY person_id) TO 'SMART-main_DL/data/amiodarone/raw/feature_model_task2.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 3/8] Task 1 labels'
\copy (SELECT person_id, label FROM smart_task1_labels ORDER BY person_id) TO 'SMART-main_DL/data/amiodarone/raw/smart_task1_labels.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 4/8] Task 2 labels'
\copy (SELECT person_id, label FROM smart_task2_labels ORDER BY person_id) TO 'SMART-main_DL/data/amiodarone/raw/smart_task2_labels.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 5/8] Label and censoring audit table'
\copy (SELECT person_id, index_date, followup_end_date, aitd_event_date, aitd_event_window, aitd_type, tsh_label_detail, feature_cutoff_date, last_complete_observation_window, analysis_end_date, aitd_flag, hypothyroidism_flag, thyrotoxicosis_flag, aitd_class, early_censor_flag FROM final_flag ORDER BY person_id) TO 'SMART-main_DL/data/amiodarone/raw/labeling_audit.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 6/8] Export manifest'
\copy (SELECT 'task1_aitd'::text AS task, COUNT(*)::bigint AS n_total, COUNT(*) FILTER (WHERE label = 0)::bigint AS n_label_0, COUNT(*) FILTER (WHERE label = 1)::bigint AS n_label_1, 0::bigint AS n_mixed_excluded FROM smart_task1_labels UNION ALL SELECT 'task2_subtype'::text AS task, COUNT(*)::bigint AS n_total, COUNT(*) FILTER (WHERE label = 0)::bigint AS n_label_0, COUNT(*) FILTER (WHERE label = 1)::bigint AS n_label_1, (SELECT COUNT(*) FROM final_flag WHERE aitd_class = 3)::bigint AS n_mixed_excluded FROM smart_task2_labels ORDER BY task) TO 'SMART-main_DL/data/amiodarone/raw/export_manifest.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 7/8] Sequential cohort attrition'
\copy (SELECT step_order, row_type, criterion_key, criterion_label, n_before, n_excluded, n_remaining FROM cohort2_attrition ORDER BY step_order) TO 'SMART-main_DL/data/amiodarone/raw/cohort_attrition.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export 8/8] Final cohort outcome counts'
\copy (SELECT 'censored_as_zero'::text AS analysis_scenario, COUNT(*)::bigint AS n_final_cohort, COUNT(*) FILTER (WHERE aitd_flag = 0)::bigint AS n_negative, COUNT(*) FILTER (WHERE aitd_flag = 1)::bigint AS n_aitd_positive, COUNT(*) FILTER (WHERE aitd_class = 1)::bigint AS n_hypothyroidism, COUNT(*) FILTER (WHERE aitd_class = 2)::bigint AS n_thyrotoxicosis, COUNT(*) FILTER (WHERE aitd_class = 3)::bigint AS n_mixed, COUNT(*) FILTER (WHERE aitd_class IN (1, 2))::bigint AS n_task2_eligible, COUNT(*) FILTER (WHERE aitd_flag = 0 AND early_censor_flag = 1)::bigint AS n_early_censored_negative FROM final_flag) TO 'SMART-main_DL/data/amiodarone/raw/cohort_outcome_counts.csv' WITH (FORMAT CSV, HEADER TRUE, NULL '')

\echo '[SMART export complete] SMART-main_DL/data/amiodarone/raw/'
