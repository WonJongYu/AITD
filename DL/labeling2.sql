/* ========================================================================
   File Name      : labeling2.sql
   Description    : TSH 단독 기준의 V2 AITD·저하증·중독증 라벨링
   Dependencies   : cohort2_selection.sql
   SQL Dialect    : PostgreSQL
   Input          : TEMP TABLE final_cohort
   Main Output    : TEMP TABLE final_flag
   ======================================================================== */

/* ------------------------------------------------------------------------
   컨셉셋 구성
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS outcome_concept_seed;
CREATE TEMP TABLE outcome_concept_seed (
    set_name TEXT,
    concept_id INT,
    include_descendants BOOLEAN
);

INSERT INTO outcome_concept_seed (set_name, concept_id, include_descendants) VALUES
    -- 라벨 판정에는 TSH만 사용한다. FT4·진단·약물·수술은 사용하지 않는다.
    ('AITD_TSH', 3009201, TRUE);


DROP TABLE IF EXISTS outcome_concept_set;
CREATE TEMP TABLE outcome_concept_set AS
SELECT
    cs.set_name,
    ca.descendant_concept_id AS concept_id
FROM outcome_concept_seed cs
JOIN concept_ancestor ca
  ON cs.concept_id = ca.ancestor_concept_id
 AND cs.include_descendants = TRUE

UNION

SELECT
    cs.set_name,
    cs.concept_id
FROM outcome_concept_seed cs
/* concept_ancestor의 self-row 유무와 관계없이 seed 자체를 포함한다. */
;

/* ------------------------------------------------------------------------
   코호트 베이스
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS cohort_base;
CREATE TEMP TABLE cohort_base AS
SELECT
    subject_id        AS person_id,
    cohort_start_date AS index_date,
    cohort_end_date   AS followup_end_date
FROM final_cohort;

-- SELECT * FROM cohort_base LIMIT 100;

/* ------------------------------------------------------------------------
   TSH 검사 결과
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS tsh_measure;
CREATE TEMP TABLE tsh_measure AS
SELECT
    c.person_id,
    c.index_date,
    m.measurement_id,
    m.measurement_date,
    m.value_as_number AS tsh_value,
    CASE
        WHEN m.value_as_number >= 10.0 THEN 'hypothyroidism_tsh_ge_10'
        WHEN m.value_as_number >= 4.5  THEN 'hypothyroidism_tsh_4_5_to_lt_10'
        WHEN m.value_as_number <= 0.1  THEN 'thyrotoxicosis_tsh_le_0_1'
        WHEN m.value_as_number <= 0.35 THEN 'thyrotoxicosis_tsh_gt_0_1_to_0_35'
        ELSE 'normal_or_unclassified'
    END AS tsh_label_detail
FROM cohort_base c
JOIN measurement m
  ON m.person_id = c.person_id
JOIN outcome_concept_set cs
  ON cs.set_name = 'AITD_TSH'
 AND m.measurement_concept_id = cs.concept_id
/* 아미오다론 시작 당일 값은 baseline 피처로만 사용하고 outcome으로 판정하지 않는다. */
WHERE m.measurement_date > c.index_date
  AND m.measurement_date <= c.followup_end_date
  AND m.value_as_number IS NOT NULL;

/* ------------------------------------------------------------------------
   TSH 단독 수치 기반 사건 판별

   - 저하증: TSH 4.5 이상
       · 4.5 이상 10 미만
       · 10 이상
   - 중독증: TSH 0.35 이하
       · 0.1 초과 0.35 이하
       · 0.1 이하

   경계값 10과 0.1은 각각 더 심한 구간(10 이상, 0.1 이하)에 배정한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS lab_aitd_event;
CREATE TEMP TABLE lab_aitd_event AS
SELECT
    person_id,
    measurement_id,
    measurement_date AS event_date,
    tsh_value,
    tsh_label_detail,
    CASE WHEN tsh_value >= 4.5 THEN 1 ELSE 0 END AS hypothyroidism_flag,
    CASE WHEN tsh_value <= 0.35 THEN 1 ELSE 0 END AS thyrotoxicosis_flag
FROM tsh_measure
WHERE tsh_value >= 4.5
   OR tsh_value <= 0.35;

/* ------------------------------------------------------------------------
   환자별 최초 TSH 사건과 유형

   같은 최초 날짜에 저하증·중독증 값이 모두 기록된 경우 데이터 충돌을
   숨기지 않고 mixed로 남긴다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS first_aitd_event;
CREATE TEMP TABLE first_aitd_event AS
WITH first_event_date AS (
    SELECT
        person_id,
        MIN(event_date) AS aitd_event_date
    FROM lab_aitd_event
    GROUP BY person_id
)
SELECT
    d.person_id,
    d.aitd_event_date,
    MAX(e.hypothyroidism_flag) AS hypothyroidism_flag,
    MAX(e.thyrotoxicosis_flag) AS thyrotoxicosis_flag,
    CASE
        WHEN MAX(e.hypothyroidism_flag) = 1
         AND MAX(e.thyrotoxicosis_flag) = 1 THEN 'mixed'
        WHEN MAX(e.hypothyroidism_flag) = 1 THEN 'hypothyroidism'
        WHEN MAX(e.thyrotoxicosis_flag) = 1 THEN 'thyrotoxicosis'
    END AS aitd_type,
    STRING_AGG(
        DISTINCT e.tsh_label_detail,
        ',' ORDER BY e.tsh_label_detail
    ) AS tsh_label_detail
FROM first_event_date d
JOIN lab_aitd_event e
  ON e.person_id = d.person_id
 AND e.event_date = d.aitd_event_date
GROUP BY d.person_id, d.aitd_event_date;

/* ------------------------------------------------------------------------
   최종 라벨링

   aitd_type         : 최초 TSH 사건 유형(hypothyroidism/thyrotoxicosis/mixed)
   tsh_label_detail  : 최초 사건의 세부 TSH 범위
   aitd_event_window : 최초 AITD 사건이 속한 월 구간
   analysis_end_date : 양성은 최초 사건일, 무사건은 행정적 추적 종료일
   feature_cutoff_date:
       - 실제 종료점(AITD 사건일 또는 추적 종료일) 직전의 마지막 완전한
         observation window 경계일
       - 양성·조기 추적 종료 무사건 환자에게 같은 규칙을 적용한다.
       - 22~24개월은 outcome 관찰 구간이며 feature 수집시점은 21개월이 마지막이다.
     예: 16~18개월에 사건/추적 종료 시 index_date + 15개월까지만 특징에 사용
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS final_flag;
CREATE TEMP TABLE final_flag AS
SELECT
    c.person_id,
    c.index_date,
    c.followup_end_date,
    f.aitd_event_date,
    f.aitd_type,
    f.tsh_label_detail,
    CASE
        WHEN f.aitd_event_date IS NULL THEN NULL
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '1 month'  THEN 'm1'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '2 month'  THEN 'm2'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '3 month'  THEN 'm3'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '6 month'  THEN 'm4_6'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '9 month'  THEN 'm7_9'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '12 month' THEN 'm10_12'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '15 month' THEN 'm13_15'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '18 month' THEN 'm16_18'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '21 month' THEN 'm19_21'
        WHEN f.aitd_event_date <= c.index_date + INTERVAL '24 month' THEN 'm22_24'
        ELSE NULL
    END AS aitd_event_window,
    CASE
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '1 month'  THEN c.index_date
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '2 month'  THEN c.index_date + INTERVAL '1 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '3 month'  THEN c.index_date + INTERVAL '2 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '6 month'  THEN c.index_date + INTERVAL '3 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '9 month'  THEN c.index_date + INTERVAL '6 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '12 month' THEN c.index_date + INTERVAL '9 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '15 month' THEN c.index_date + INTERVAL '12 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '18 month' THEN c.index_date + INTERVAL '15 month'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '21 month' THEN c.index_date + INTERVAL '18 month'
        ELSE c.index_date + INTERVAL '21 month'
    END::date AS feature_cutoff_date,
    CASE
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '1 month'  THEN 'base'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '2 month'  THEN 'm1'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '3 month'  THEN 'm2'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '6 month'  THEN 'm3'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '9 month'  THEN 'm4_6'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '12 month' THEN 'm7_9'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '15 month' THEN 'm10_12'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '18 month' THEN 'm13_15'
        WHEN COALESCE(f.aitd_event_date, c.followup_end_date)
             <= c.index_date + INTERVAL '21 month' THEN 'm16_18'
        ELSE 'm19_21'
    END AS last_complete_observation_window,
    COALESCE(f.aitd_event_date, c.followup_end_date) AS analysis_end_date,
    CASE WHEN f.aitd_event_date IS NOT NULL THEN 1 ELSE 0 END AS aitd_flag,
    COALESCE(f.hypothyroidism_flag, 0) AS hypothyroidism_flag,
    COALESCE(f.thyrotoxicosis_flag, 0) AS thyrotoxicosis_flag,
    CASE
        WHEN f.aitd_event_date IS NULL THEN 0
        WHEN f.hypothyroidism_flag = 1 AND f.thyrotoxicosis_flag = 0 THEN 1
        WHEN f.hypothyroidism_flag = 0 AND f.thyrotoxicosis_flag = 1 THEN 2
        WHEN f.hypothyroidism_flag = 1 AND f.thyrotoxicosis_flag = 1 THEN 3
    END AS aitd_class,
    CASE
        WHEN f.aitd_event_date IS NULL
         AND c.followup_end_date < c.index_date + INTERVAL '2 year'
        THEN 1 ELSE 0
    END AS early_censor_flag
    -- 추적 소실 무사건 환자를 제외하는 complete-case 라벨은 현재 사용하지 않는다.
    -- , CASE
    --     WHEN f.aitd_event_date IS NOT NULL THEN 1
    --     WHEN c.followup_end_date >= c.index_date + INTERVAL '2 year' THEN 0
    --     ELSE NULL
    --   END AS aitd_flag_complete_case
FROM cohort_base c
LEFT JOIN first_aitd_event f
  ON c.person_id = f.person_id;

/* ------------------------------------------------------------------------
  민감도 분석용 데이터셋 1
  2년 전 추적이 종료된 무사건 환자도 음성(0)으로 분류
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS final_flag_censored_as_zero;
CREATE TEMP TABLE final_flag_censored_as_zero AS
SELECT
    person_id,
    index_date,
    followup_end_date,
    aitd_event_date,
    aitd_type,
    tsh_label_detail,
    aitd_event_window,
    feature_cutoff_date,
    last_complete_observation_window,
    analysis_end_date,
    early_censor_flag,
    aitd_flag,
    hypothyroidism_flag,
    thyrotoxicosis_flag,
    aitd_class
FROM final_flag;

/* 추적 소실 무사건 환자를 제외하는 complete-case 데이터셋: 현재 비활성화
-- DROP TABLE IF EXISTS final_flag_complete_case;
-- CREATE TEMP TABLE final_flag_complete_case AS
-- SELECT
--     person_id,
--     index_date,
--     followup_end_date,
--     aitd_event_date,
--     aitd_event_window,
--     feature_cutoff_date,
--     last_complete_observation_window,
--     analysis_end_date,
--     early_censor_flag,
--     aitd_flag_complete_case AS aitd_flag
-- FROM final_flag
-- WHERE aitd_flag_complete_case IS NOT NULL;
*/

/* ------------------------------------------------------------------------
  현재 사용 분석의 대상, 양성, 음성 환자 수
   ------------------------------------------------------------------------ */

SELECT
    'censored_as_zero' AS analysis_scenario,
    COUNT(*) AS n_included,
    COALESCE(SUM(CASE WHEN aitd_flag = 1 THEN 1 ELSE 0 END), 0) AS n_positive,
    COALESCE(SUM(CASE WHEN aitd_flag = 0 THEN 1 ELSE 0 END), 0) AS n_negative,
    COALESCE(SUM(hypothyroidism_flag), 0) AS n_hypothyroidism,
    COALESCE(SUM(thyrotoxicosis_flag), 0) AS n_thyrotoxicosis,
    COALESCE(SUM(CASE WHEN aitd_class = 3 THEN 1 ELSE 0 END), 0) AS n_mixed
FROM final_flag_censored_as_zero;

/* 추적 소실 무사건 환자를 제외하는 시나리오 집계: 현재 비활성화
-- UNION ALL
-- SELECT
--     'early_censored_excluded' AS analysis_scenario,
--     COUNT(*) AS n_included,
--     COALESCE(SUM(CASE WHEN aitd_flag = 1 THEN 1 ELSE 0 END), 0) AS n_positive,
--     COALESCE(SUM(CASE WHEN aitd_flag = 0 THEN 1 ELSE 0 END), 0) AS n_negative,
--     (SELECT COUNT(*) FROM final_flag WHERE early_censor_flag = 1) AS n_excluded
-- FROM final_flag_complete_case
-- ORDER BY analysis_scenario;
*/
