/* ========================================================================
   File Name      : demographics2_extraction.sql
   Description    : V2 데모그래픽 및 추적기간 내 아미오다론 사용량 추출
   Dependencies   : labeling2.sql
   SQL Dialect    : PostgreSQL
   Input          : TEMP TABLE final_flag
   Main Output    : TEMP TABLE baseline_all
   ======================================================================== */

/* ------------------------------------------------------------------------
   성별, 나이
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS baseline_demog;
CREATE TEMP TABLE baseline_demog AS
SELECT
    f.person_id,
    f.aitd_flag,
    f.hypothyroidism_flag,
    f.thyrotoxicosis_flag,
    f.aitd_class,
    f.index_date,
    -- 성별
    CASE 
        WHEN p.gender_concept_id = 8507 THEN 1  -- Male
        WHEN p.gender_concept_id = 8532 THEN 0  -- Female
        ELSE NULL
    END AS male_flag,
    /* cohort2_selection.sql의 만 18세 판정과 동일한 표준화 생일을 사용한다. */
    EXTRACT(YEAR FROM age(f.index_date, b.birth_date_for_age))::int AS age_at_index,
    b.birth_date_source
FROM final_flag f
JOIN person p
  ON p.person_id = f.person_id
LEFT JOIN cohort2_birth_info b
  ON b.person_id = f.person_id;

/* ------------------------------------------------------------------------
   아미오다론 사용 기간
   코호트와 동일한 아미오다론 concept set을 사용하며,
   인덱스일부터 실제 분석 종료일까지만 노출 일수를 합산한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS demog_amio_concept_seed;
CREATE TEMP TABLE demog_amio_concept_seed (
    concept_id INT
);

INSERT INTO demog_amio_concept_seed (concept_id) VALUES
    (19133832),
    (41349044),
    (1309944),
    (40007699);

DROP TABLE IF EXISTS demog_amio_concept_set;
CREATE TEMP TABLE demog_amio_concept_set AS
SELECT ca.descendant_concept_id AS concept_id
FROM demog_amio_concept_seed s
JOIN concept_ancestor ca
  ON ca.ancestor_concept_id = s.concept_id
UNION
/* concept_ancestor의 self-row 존재 여부와 무관하게 seed concept 자체도 포함 */
SELECT concept_id
FROM demog_amio_concept_seed;

DROP TABLE IF EXISTS baseline_amio_use;
CREATE TEMP TABLE baseline_amio_use AS
WITH amio_exposure AS (
    SELECT
        f.person_id,
        d.drug_exposure_start_date,
        d.drug_exposure_end_date,
        d.quantity,
        d.days_supply,
        d.drug_concept_id,
        GREATEST(d.drug_exposure_start_date, f.index_date)::date AS exposure_start_date,
        LEAST(
            COALESCE(
                d.drug_exposure_end_date,
                d.drug_exposure_start_date
                  + (GREATEST(COALESCE(d.days_supply, 1), 1) - 1) * INTERVAL '1 day'
            ),
            f.analysis_end_date
        )::date AS exposure_end_date
    FROM final_flag f
    JOIN drug_exposure d
      ON d.person_id = f.person_id
    JOIN demog_amio_concept_set cs
      ON d.drug_concept_id = cs.concept_id
    WHERE d.drug_exposure_start_date <= f.analysis_end_date
      AND COALESCE(
            d.drug_exposure_end_date,
            d.drug_exposure_start_date
              + (GREATEST(COALESCE(d.days_supply, 1), 1) - 1) * INTERVAL '1 day'
          ) >= f.index_date
),
/*
   동일 환자의 처방 구간을 시작일 순으로 정렬한다.
   이전까지의 가장 늦은 종료일을 구해 현재 처방이 기존 구간과
   겹치거나 바로 이어지는지 판단한다.
*/
ordered_exposure AS (
    SELECT
        person_id,
        exposure_start_date,
        exposure_end_date,
        MAX(exposure_end_date) OVER (
            PARTITION BY person_id
            ORDER BY exposure_start_date, exposure_end_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS previous_max_end
    FROM amio_exposure
    WHERE exposure_end_date >= exposure_start_date
),
island_start AS (
    SELECT
        *,
        CASE
            WHEN previous_max_end IS NULL
              OR exposure_start_date > previous_max_end + 1
            THEN 1 ELSE 0
        END AS new_island
    FROM ordered_exposure
),
island_id AS (
    SELECT
        *,
        SUM(new_island) OVER (
            PARTITION BY person_id
            ORDER BY exposure_start_date, exposure_end_date
            ROWS UNBOUNDED PRECEDING
        ) AS exposure_island
    FROM island_start
),
merged_exposure AS (
    SELECT
        person_id,
        exposure_island,
        MIN(exposure_start_date) AS merged_start_date,
        MAX(exposure_end_date) AS merged_end_date
    FROM island_id
    GROUP BY person_id, exposure_island
),
duration_summary AS (
    SELECT
        person_id,
        /* 첫 투약일부터 마지막 투약일까지의 전체 기간: 중간 투약 공백 포함 */
        (MAX(exposure_end_date) - MIN(exposure_start_date) + 1)::int
            AS amio_duration_span_days
    FROM ordered_exposure
    GROUP BY person_id
),
therapeutic_days_summary AS (
    SELECT
        person_id,
        /* 겹친 처방일을 한 번만 계산한 실제 아미오다론 투약일수 */
        SUM(merged_end_date - merged_start_date + 1)::int AS amio_sum_days
    FROM merged_exposure
    GROUP BY person_id
)
SELECT
    d.person_id,
    d.amio_duration_span_days,
    t.amio_sum_days
FROM duration_summary d
JOIN therapeutic_days_summary t
  ON t.person_id = d.person_id;

/* ------------------------------------------------------------------------
   통합
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS baseline_all;
CREATE TEMP TABLE baseline_all AS
SELECT
    f.person_id,
    f.aitd_flag,
    f.hypothyroidism_flag,
    f.thyrotoxicosis_flag,
    f.aitd_class,
    f.aitd_type,
    f.tsh_label_detail,
    f.index_date,
    f.followup_end_date,
    f.aitd_event_date,
    f.aitd_event_window,
    f.analysis_end_date,
    /* 추적기간은 시간 차이이므로 index_date를 1일로 더하지 않는다. */
    (f.analysis_end_date::date - f.index_date::date)::int AS followup_days,
    f.feature_cutoff_date,
    f.early_censor_flag,
    -- 추적 소실 무사건 환자 제외용 컬럼은 현재 사용하지 않는다.
    -- f.aitd_flag_complete_case,
    d.male_flag,
    d.age_at_index,
    /* 모델 피처는 아니며 생년정보 대체 수준 확인을 위한 품질 컬럼이다. */
    d.birth_date_source,
    a.amio_duration_span_days,
    a.amio_sum_days

FROM final_flag f
LEFT JOIN baseline_demog   d ON f.person_id = d.person_id
LEFT JOIN baseline_amio_use a ON f.person_id = a.person_id;

-- 민감도 분석 1: 조기 추적 종료 무사건 환자를 음성(0)으로 포함
DROP TABLE IF EXISTS baseline_all_censored_as_zero;
CREATE TEMP TABLE baseline_all_censored_as_zero AS
SELECT *
FROM baseline_all;

/* 조기 추적 종료 무사건 환자를 제외하는 데이터셋: 현재 비활성화
-- DROP TABLE IF EXISTS baseline_all_complete_case;
-- CREATE TEMP TABLE baseline_all_complete_case AS
-- SELECT *
-- FROM baseline_all
-- WHERE aitd_flag_complete_case IS NOT NULL;
*/

DROP TABLE IF EXISTS baseline_analysis;
CREATE TEMP TABLE baseline_analysis AS
SELECT 'censored_as_zero'::text AS analysis_scenario, b.*
FROM baseline_all_censored_as_zero b;

/* 조기 추적 종료 무사건 환자 제외 시나리오 결합: 현재 비활성화
-- UNION ALL
-- SELECT 'early_censored_excluded'::text AS analysis_scenario, b.*
-- FROM baseline_all_complete_case b;
*/

/*
   현재 분석에서 AITD 음성군·양성군 통계와 전체군 통계를
   같은 형식으로 출력하기 위한 보고용 테이블이다.
   overall 행은 기술통계 출력용으로만 추가되며 원 코호트 수를 바꾸지 않는다.
*/
DROP TABLE IF EXISTS baseline_analysis_reporting;
CREATE TEMP TABLE baseline_analysis_reporting AS
SELECT
    b.*,
    CASE
        WHEN b.aitd_flag = 0 THEN 'AITD_negative'
        WHEN b.aitd_flag = 1 THEN 'AITD_positive'
    END::text AS outcome_group
FROM baseline_analysis b
UNION ALL
SELECT
    b.*,
    'overall'::text AS outcome_group
FROM baseline_analysis b;

/* ------------------------------------------------------------------------
   분석 시나리오별 대상자 수 및 조기 추적 소실
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    COUNT(*) AS n_total,
    COUNT(*) FILTER (WHERE aitd_flag = 0) AS n_negative,
    COUNT(*) FILTER (WHERE aitd_flag = 1) AS n_positive,
    COUNT(*) FILTER (WHERE early_censor_flag = 1) AS n_early_censored,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE early_censor_flag = 1)
        / NULLIF(COUNT(*), 0),
        1
    ) AS pct_early_censored
FROM baseline_analysis
GROUP BY analysis_scenario
ORDER BY analysis_scenario;

/* ------------------------------------------------------------------------
   성별, n (%)
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    outcome_group,
    COUNT(*) AS n_total,
    COUNT(male_flag) AS n_sex_known,
    COUNT(*) FILTER (WHERE male_flag = 1) AS n_male,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE male_flag = 1)
        / NULLIF(COUNT(male_flag), 0),
        1
    ) AS pct_male_among_known,
    COUNT(*) FILTER (WHERE male_flag = 0) AS n_female,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE male_flag = 0)
        / NULLIF(COUNT(male_flag), 0),
        1
    ) AS pct_female_among_known,
    COUNT(*) FILTER (WHERE male_flag IS NULL) AS n_sex_unknown,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE male_flag IS NULL)
        / NULLIF(COUNT(*), 0),
        1
    ) AS pct_sex_unknown
FROM baseline_analysis_reporting
GROUP BY analysis_scenario, outcome_group
ORDER BY analysis_scenario, outcome_group;

/* ------------------------------------------------------------------------
   나이, median(IQR)
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    outcome_group,
    COUNT(*) AS n_total,
    COUNT(age_at_index) AS n_age_available,
    COUNT(*) FILTER (WHERE age_at_index IS NULL) AS n_age_missing,
    -- Age
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY age_at_index) AS median_age,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY age_at_index) AS p25_age,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY age_at_index) AS p75_age
FROM baseline_analysis_reporting
GROUP BY analysis_scenario, outcome_group
ORDER BY analysis_scenario, outcome_group;

/* 생년정보 원천별 대상자 수: age가 대체 계산된 비율을 확인한다. */
SELECT
    analysis_scenario,
    birth_date_source,
    COUNT(*) AS n_patients,
    COUNT(*) FILTER (WHERE age_at_index IS NULL) AS n_age_missing
FROM baseline_analysis
GROUP BY analysis_scenario, birth_date_source
ORDER BY analysis_scenario, birth_date_source;

/* ------------------------------------------------------------------------
   실제 추적기간, median(IQR)
   - 양성: AITD 발생일 - index_date
   - 음성: 실제 추적 종료일 - index_date
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    outcome_group,
    COUNT(*) AS n_total,
    COUNT(followup_days) AS n_followup_available,
    COUNT(*) FILTER (WHERE followup_days IS NULL) AS n_followup_missing,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY followup_days) AS median_followup_days,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY followup_days) AS p25_followup_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY followup_days) AS p75_followup_days
FROM baseline_analysis_reporting
GROUP BY analysis_scenario, outcome_group
ORDER BY analysis_scenario, outcome_group;

/* ------------------------------------------------------------------------
   아미오다론 전체 노출 기간과 실제 투약일수, median(IQR)
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    outcome_group,
    COUNT(*) AS n_total,
    COUNT(amio_duration_span_days) AS n_amio_duration_available,
    COUNT(*) FILTER (WHERE amio_duration_span_days IS NULL) AS n_amio_duration_missing,
    -- Duration span: 첫 투약일부터 마지막 투약일까지, 중간 공백 포함
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amio_duration_span_days) AS median_amio_duration_span_days,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amio_duration_span_days) AS p25_amio_duration_span_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amio_duration_span_days) AS p75_amio_duration_span_days,
    COUNT(amio_sum_days) AS n_amio_sum_days_available,
    COUNT(*) FILTER (WHERE amio_sum_days IS NULL) AS n_amio_sum_days_missing,
    -- Sum days: 처방 중복일을 제거한 실제 투약일수
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amio_sum_days) AS median_amio_sum_days,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amio_sum_days) AS p25_amio_sum_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amio_sum_days) AS p75_amio_sum_days
FROM baseline_analysis_reporting
GROUP BY analysis_scenario, outcome_group
ORDER BY analysis_scenario, outcome_group;
