/* ========================================================================
   File Name      : labeling3.sql
   Description    : replication 코호트 AITD 판별 및 추적 소실 민감도 분석
   SQL Dialect    : PostgreSQL
   Dependencies   : cohort3_selection.sql (TEMP TABLE final_cohort)
   ======================================================================== */

/* ------------------------------------------------------------------------
   컨셉셋 구성
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.outcome_concept_seed;
CREATE TEMP TABLE outcome_concept_seed (
    set_name TEXT,
    concept_id INT,
    include_descendants BOOLEAN
);

INSERT INTO outcome_concept_seed (set_name, concept_id, include_descendants) VALUES
    -- 1) AITD 관련 진단 코드
    ('AITD_DX', 4130027, TRUE),   -- Subclinical iodine deficiency hypothyroidism
    ('AITD_DX', 4183422, TRUE),   -- Subclinical hypothyroidism
    ('AITD_DX', 140673,  TRUE),   -- Hypothyroidism
    ('AITD_DX', 4142479, TRUE),   -- Hyperthyroidism
    ('AITD_DX', 138387,  TRUE),   -- Thyrotoxicosis
    ('AITD_DX', 133444,  TRUE),   -- Thyroiditis

    -- 2) thyroidectomy
    ('AITD_PROC', 4030107, TRUE),

    -- 3) AITD 관련 약물
    ('AITD_MED', 1501700, TRUE),
    ('AITD_MED', 1554072, TRUE),
    ('AITD_MED', 19040606, TRUE),
    ('AITD_MED', 1504620, TRUE),

    -- 4) TSH / fT4
    ('AITD_TSH', 3009201, TRUE),
    ('AITD_FT4', 3008598, TRUE),
    ('AITD_FT4', 42529233, TRUE);


DROP TABLE IF EXISTS pg_temp.outcome_concept_set;
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
WHERE cs.include_descendants = FALSE;

/* ------------------------------------------------------------------------
   코호트 베이스
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort_base;
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

DROP TABLE IF EXISTS pg_temp.tsh_measure;
CREATE TEMP TABLE tsh_measure AS
SELECT
    c.person_id,
    c.index_date,
    m.measurement_date,
    m.value_as_number AS tsh_value
FROM cohort_base c
JOIN measurement m
  ON m.person_id = c.person_id
JOIN outcome_concept_set cs
  ON cs.set_name = 'AITD_TSH'
 AND m.measurement_concept_id = cs.concept_id
WHERE m.measurement_date BETWEEN c.index_date
                             AND c.followup_end_date
  AND m.value_as_number IS NOT NULL;

/* ------------------------------------------------------------------------
   FT4 검사 결과
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.ft4_measure;
CREATE TEMP TABLE ft4_measure AS
SELECT
    c.person_id,
    m.measurement_date,
    m.value_as_number AS ft4_value,
    m.range_low      AS ft4_range_low,
    m.range_high     AS ft4_range_high
FROM cohort_base c
JOIN measurement m
  ON m.person_id = c.person_id
JOIN outcome_concept_set cs
  ON cs.set_name = 'AITD_FT4'
 AND m.measurement_concept_id = cs.concept_id
WHERE m.measurement_date BETWEEN c.index_date
                             AND c.followup_end_date
  AND m.value_as_number IS NOT NULL;


/* ------------------------------------------------------------------------
   TSH, FT4 같은 날짜 매칭
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.tsh_ft4_pair;
CREATE TEMP TABLE tsh_ft4_pair AS
SELECT
    t.person_id,
    t.index_date,
    t.measurement_date,
    t.tsh_value,
    f.ft4_value
FROM tsh_measure t
LEFT JOIN ft4_measure f
  ON f.person_id = t.person_id
 AND f.measurement_date = t.measurement_date;

/* ------------------------------------------------------------------------
   수치 기반 양성 판별
   ft4_range_row = 0.89, ft4_range_high = 1.78
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.lab_aitd_event;
CREATE TEMP TABLE lab_aitd_event AS
SELECT
    person_id,
    measurement_date AS event_date
FROM tsh_ft4_pair
WHERE
      (
        tsh_value < 0.1
        AND ft4_value IS NOT NULL
        AND ft4_value > 1.78          -- upper normal 상수값
      )
   OR (tsh_value > 10)
   OR (
        tsh_value BETWEEN 4 AND 10
        AND measurement_date > index_date
        AND ft4_value IS NOT NULL
        AND ft4_value < 0.89          -- lower normal 상수값
      );

/* ------------------------------------------------------------------------
   진단 기반 양성 판별
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.dx_aitd_event;
CREATE TEMP TABLE dx_aitd_event AS
SELECT DISTINCT
    c.person_id,
    cond.condition_start_date AS event_date
FROM cohort_base c
JOIN condition_occurrence cond
  ON cond.person_id = c.person_id
JOIN outcome_concept_set cs
  ON cs.set_name = 'AITD_DX'
 AND cond.condition_concept_id = cs.concept_id
WHERE cond.condition_start_date BETWEEN c.index_date
                                    AND c.followup_end_date;

/* ------------------------------------------------------------------------
   약물 기반 양성 판별
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.drug_aitd_event;
CREATE TEMP TABLE drug_aitd_event AS
SELECT DISTINCT
    c.person_id,
    d.drug_exposure_start_date AS event_date
FROM cohort_base c
JOIN drug_exposure d
  ON d.person_id = c.person_id
JOIN outcome_concept_set cs
  ON cs.set_name = 'AITD_MED'
 AND d.drug_concept_id = cs.concept_id
WHERE d.drug_exposure_start_date BETWEEN c.index_date
                                     AND c.followup_end_date;

/* ------------------------------------------------------------------------
   수술 기반 양성 판별
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.proc_aitd_event;
CREATE TEMP TABLE proc_aitd_event AS
SELECT DISTINCT
    c.person_id,
    p.procedure_date AS event_date
FROM cohort_base c
JOIN procedure_occurrence p
  ON p.person_id = c.person_id
JOIN outcome_concept_set cs
  ON cs.set_name = 'AITD_PROC'
 AND p.procedure_concept_id = cs.concept_id
WHERE p.procedure_date BETWEEN c.index_date
                           AND c.followup_end_date;
SELECT COUNT(distinct person_id)  FROM proc_aitd_event;
     

/* ------------------------------------------------------------------------
   모든 양성 기준 통합
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.all_aitd_event;
CREATE TEMP TABLE all_aitd_event AS
SELECT person_id, event_date FROM lab_aitd_event
UNION ALL
SELECT person_id, event_date FROM dx_aitd_event
UNION ALL
SELECT person_id, event_date FROM drug_aitd_event
UNION ALL
SELECT person_id, event_date FROM proc_aitd_event;

DROP TABLE IF EXISTS pg_temp.first_aitd_event;
CREATE TEMP TABLE first_aitd_event AS
SELECT
    person_id,
    MIN(event_date) AS aitd_event_date
FROM all_aitd_event
GROUP BY person_id;

/* ------------------------------------------------------------------------
   최종 라벨링

   aitd_event_window : 최초 AITD 사건이 속한 월 구간
   analysis_end_date : 양성은 최초 사건일, 무사건은 행정적 추적 종료일
   feature_cutoff_date:
       - 실제 종료점(AITD 사건일 또는 추적 종료일) 직전의 마지막 완전한
         observation window 경계일
       - 양성·조기 추적 종료 무사건 환자에게 같은 규칙을 적용한다.
       - 22~24개월은 outcome 관찰 구간이며 feature 수집시점은 21개월이 마지막이다.
     예: 16~18개월에 사건/추적 종료 시 index_date + 15개월까지만 특징에 사용
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.final_flag;
CREATE TEMP TABLE final_flag AS
SELECT
    c.person_id,
    c.index_date,
    c.followup_end_date,
    f.aitd_event_date,
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
    CASE
        WHEN f.aitd_event_date IS NULL
         AND c.followup_end_date < c.index_date + INTERVAL '2 year'
        THEN 1 ELSE 0
    END AS early_censor_flag,
    CASE
        WHEN f.aitd_event_date IS NOT NULL THEN 1
        WHEN c.followup_end_date >= c.index_date + INTERVAL '2 year' THEN 0
        ELSE NULL
    END AS aitd_flag_complete_case
FROM cohort_base c
LEFT JOIN first_aitd_event f
  ON c.person_id = f.person_id;

/* ------------------------------------------------------------------------
  민감도 분석용 데이터셋 1
  2년 전 추적이 종료된 무사건 환자도 음성(0)으로 분류
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.final_flag_censored_as_zero;
CREATE TEMP TABLE final_flag_censored_as_zero AS
SELECT
    person_id,
    index_date,
    followup_end_date,
    aitd_event_date,
    aitd_event_window,
    feature_cutoff_date,
    last_complete_observation_window,
    analysis_end_date,
    early_censor_flag,
    aitd_flag
FROM final_flag;

/* ------------------------------------------------------------------------
  민감도 분석용 데이터셋 2
  2년 전 추적이 종료된 무사건 환자는 제외하고 완전한 라벨만 사용
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.final_flag_complete_case;
CREATE TEMP TABLE final_flag_complete_case AS
SELECT
    person_id,
    index_date,
    followup_end_date,
    aitd_event_date,
    aitd_event_window,
    feature_cutoff_date,
    last_complete_observation_window,
    analysis_end_date,
    early_censor_flag,
    aitd_flag_complete_case AS aitd_flag
FROM final_flag
WHERE aitd_flag_complete_case IS NOT NULL;

/* ------------------------------------------------------------------------
  두 시나리오별 분석 대상, 양성, 음성, 제외 환자 수
   ------------------------------------------------------------------------ */

SELECT
    'censored_as_zero' AS analysis_scenario,
    COUNT(*) AS n_included,
    COALESCE(SUM(CASE WHEN aitd_flag = 1 THEN 1 ELSE 0 END), 0) AS n_positive,
    COALESCE(SUM(CASE WHEN aitd_flag = 0 THEN 1 ELSE 0 END), 0) AS n_negative,
    0 AS n_excluded
FROM final_flag_censored_as_zero

UNION ALL

SELECT
    'early_censored_excluded' AS analysis_scenario,
    COUNT(*) AS n_included,
    COALESCE(SUM(CASE WHEN aitd_flag = 1 THEN 1 ELSE 0 END), 0) AS n_positive,
    COALESCE(SUM(CASE WHEN aitd_flag = 0 THEN 1 ELSE 0 END), 0) AS n_negative,
    (SELECT COUNT(*) FROM final_flag WHERE early_censor_flag = 1) AS n_excluded
FROM final_flag_complete_case
ORDER BY analysis_scenario;
