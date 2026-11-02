/* ========================================================================
   File Name      : demographics3_extraction.sql
   Description    : replication 데모그래픽 및 추적기간 내 아미오다론 사용량 추출
   SQL Dialect    : PostgreSQL
   Dependencies   : labeling3.sql (TEMP TABLE final_flag)
   ======================================================================== */

/* ------------------------------------------------------------------------
   성별, 나이
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.baseline_demog;
CREATE TEMP TABLE baseline_demog AS
SELECT
    f.person_id,
    f.aitd_flag,
    f.index_date,
    -- 성별
    CASE 
        WHEN p.gender_concept_id = 8507 THEN 1  -- Male
        WHEN p.gender_concept_id = 8532 THEN 0  -- Female
        ELSE NULL
    END AS male_flag,
    EXTRACT(YEAR FROM age(f.index_date, p.birth_datetime)) AS age_at_index
FROM final_flag f
JOIN person p
  ON p.person_id = f.person_id;

/* ------------------------------------------------------------------------
   아미오다론 사용 기간
   코호트와 동일한 아미오다론 concept set을 사용하며,
   인덱스일부터 실제 분석 종료일까지만 노출 일수를 합산한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.demog_amio_concept_seed;
CREATE TEMP TABLE demog_amio_concept_seed (
    concept_id INT
);

INSERT INTO demog_amio_concept_seed (concept_id) VALUES
    (19133832),
    (41349044),
    (1309944),
    (40007699);

DROP TABLE IF EXISTS pg_temp.demog_amio_concept_set;
CREATE TEMP TABLE demog_amio_concept_set AS
SELECT DISTINCT ca.descendant_concept_id AS concept_id
FROM demog_amio_concept_seed s
JOIN concept_ancestor ca
  ON ca.ancestor_concept_id = s.concept_id;

DROP TABLE IF EXISTS pg_temp.baseline_amio_use;
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
)

SELECT
    person_id,
    SUM(exposure_end_date - exposure_start_date + 1) AS amio_duration_days
FROM amio_exposure
WHERE exposure_end_date >= exposure_start_date
GROUP BY person_id;

/* ------------------------------------------------------------------------
   통합
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.baseline_all;
CREATE TEMP TABLE baseline_all AS
SELECT
    f.person_id,
    f.aitd_flag,
    f.index_date,
    f.followup_end_date,
    f.aitd_event_date,
    f.aitd_event_window,
    f.analysis_end_date,
    f.feature_cutoff_date,
    f.last_complete_observation_window,
    f.early_censor_flag,
    f.aitd_flag_complete_case,
    d.male_flag,
    d.age_at_index,
    a.amio_duration_days

FROM final_flag f
LEFT JOIN baseline_demog   d ON f.person_id = d.person_id
LEFT JOIN baseline_amio_use a ON f.person_id = a.person_id;

-- 민감도 분석 1: 조기 추적 종료 무사건 환자를 음성(0)으로 포함
DROP TABLE IF EXISTS pg_temp.baseline_all_censored_as_zero;
CREATE TEMP TABLE baseline_all_censored_as_zero AS
SELECT *
FROM baseline_all;

-- 민감도 분석 2: 조기 추적 종료 무사건 환자를 제외
DROP TABLE IF EXISTS pg_temp.baseline_all_complete_case;
CREATE TEMP TABLE baseline_all_complete_case AS
SELECT *
FROM baseline_all
WHERE aitd_flag_complete_case IS NOT NULL;

DROP TABLE IF EXISTS pg_temp.baseline_analysis;
CREATE TEMP TABLE baseline_analysis AS
SELECT 'censored_as_zero'::text AS analysis_scenario, b.*
FROM baseline_all_censored_as_zero b
UNION ALL
SELECT 'early_censored_excluded'::text AS analysis_scenario, b.*
FROM baseline_all_complete_case b;

/* ------------------------------------------------------------------------
   성별, n (%)
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    aitd_flag,
    SUM(male_flag)                       AS n_male,
    COUNT(*)                             AS n_total,
    ROUND(100.0 * SUM(male_flag) / COUNT(*), 1) AS pct_male
FROM baseline_analysis
GROUP BY analysis_scenario, aitd_flag
ORDER BY analysis_scenario, aitd_flag;

/* ------------------------------------------------------------------------
   나이, median(IQR)
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    aitd_flag,
    -- Age
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY age_at_index) AS median_age,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY age_at_index) AS p25_age,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY age_at_index) AS p75_age
FROM baseline_analysis
GROUP BY analysis_scenario, aitd_flag
ORDER BY analysis_scenario, aitd_flag;

/* ------------------------------------------------------------------------
   처방 기간, median(IQR)
   ------------------------------------------------------------------------ */

SELECT
    analysis_scenario,
    aitd_flag,
    -- Duration
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amio_duration_days) AS med_amio_days,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY amio_duration_days) AS p25_amio_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY amio_duration_days) AS p75_amio_days
FROM baseline_analysis
GROUP BY analysis_scenario, aitd_flag
ORDER BY analysis_scenario, aitd_flag;
