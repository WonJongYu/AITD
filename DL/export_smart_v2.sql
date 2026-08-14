/* ========================================================================
   File Name      : export_smart_v2.sql
   Description    : DBeaver에서 8개 CSV 결과를 조회하기 위한 SELECT 모음
   SQL Dialect    : PostgreSQL / OMOP CDM
   Dependencies   : feature2_extraction.sql까지 같은 DB 세션에서 실행 완료

   사용 방법
     1. 아래 SELECT를 한 개씩 실행한다.
     2. 각 결과 창에서 Export Data -> CSV를 선택한다.
     3. 각 구역에 적힌 CSV 파일명으로 저장한다.

   주의
     - 모든 입력은 TEMP TABLE이므로 앞의 4개 SQL과 같은 연결·세션에서 실행한다.
     - NULL은 CSV에서 빈 값으로 내보낸다.
   ======================================================================== */

/* [1/8] feature_model_task1.csv */
SELECT *
FROM feature_model_task1
ORDER BY person_id;


/* [2/8] feature_model_task2.csv */
SELECT *
FROM feature_model_task2
ORDER BY person_id;


/* [3/8] smart_task1_labels.csv */
SELECT person_id, label
FROM smart_task1_labels
ORDER BY person_id;


/* [4/8] smart_task2_labels.csv */
SELECT person_id, label
FROM smart_task2_labels
ORDER BY person_id;


/* [5/8] labeling_audit.csv */
SELECT
    person_id,
    index_date,
    followup_end_date,
    aitd_event_date,
    aitd_event_window,
    aitd_type,
    tsh_label_detail,
    feature_cutoff_date,
    last_complete_observation_window,
    analysis_end_date,
    aitd_flag,
    hypothyroidism_flag,
    thyrotoxicosis_flag,
    aitd_class,
    early_censor_flag
FROM final_flag
ORDER BY person_id;


/* [6/8] export_manifest.csv */
SELECT
    'task1_aitd'::text AS task,
    COUNT(*)::bigint AS n_total,
    COUNT(*) FILTER (WHERE label = 0)::bigint AS n_label_0,
    COUNT(*) FILTER (WHERE label = 1)::bigint AS n_label_1,
    0::bigint AS n_mixed_excluded
FROM smart_task1_labels

UNION ALL

SELECT
    'task2_subtype'::text AS task,
    COUNT(*)::bigint AS n_total,
    COUNT(*) FILTER (WHERE label = 0)::bigint AS n_label_0,
    COUNT(*) FILTER (WHERE label = 1)::bigint AS n_label_1,
    (SELECT COUNT(*) FROM final_flag WHERE aitd_class = 3)::bigint
        AS n_mixed_excluded
FROM smart_task2_labels
ORDER BY task;


/* [7/8] cohort_attrition.csv */
SELECT
    step_order,
    row_type,
    criterion_key,
    criterion_label,
    n_before,
    n_excluded,
    n_remaining
FROM cohort2_attrition
ORDER BY step_order;


/* [8/8] cohort_outcome_counts.csv */
SELECT
    'censored_as_zero'::text AS analysis_scenario,
    COUNT(*)::bigint AS n_final_cohort,
    COUNT(*) FILTER (WHERE aitd_flag = 0)::bigint AS n_negative,
    COUNT(*) FILTER (WHERE aitd_flag = 1)::bigint AS n_aitd_positive,
    COUNT(*) FILTER (WHERE aitd_class = 1)::bigint AS n_hypothyroidism,
    COUNT(*) FILTER (WHERE aitd_class = 2)::bigint AS n_thyrotoxicosis,
    COUNT(*) FILTER (WHERE aitd_class = 3)::bigint AS n_mixed,
    COUNT(*) FILTER (WHERE aitd_class IN (1, 2))::bigint AS n_task2_eligible,
    COUNT(*) FILTER (
        WHERE aitd_flag = 0
          AND early_censor_flag = 1
    )::bigint AS n_early_censored_negative
FROM final_flag;
