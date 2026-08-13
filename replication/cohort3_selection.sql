/* ========================================================================
   File Name      : cohort3_selection.sql
   Description    : 아미오다론 신규 사용자 연구 코호트 생성
   SQL Dialect    : PostgreSQL
   Dependencies   : OMOP CDM v5.x tables available on search_path
   Main Output    : TEMP TABLE final_cohort

   실행 전제
     - run_all_replication_postgresql.sql에서 CDM/vocabulary schema를
       search_path에 설정하거나, 현재 세션의 search_path를 직접 설정한다.
     - 모든 결과는 현재 DB 세션의 TEMP TABLE로 생성한다.

   코호트 정의
     1. 환자별 전체 기록상 최초 아미오다론 처방일을 확정 (신규 사용자 설계)
     2. 그 최초 처방이 2005-01-01~2026-06-30 구간에 있어야 함
     3. 최초 처방 전 365일 및 처방 후 최소 1일 observation period 확보
     4. index date 포함 직전 365일 동안 갑상선 이상·임신 기준 배제
     5. index date에 만 18세 이상
     6. 종료일은 index+2년, observation period 종료일, 2026-06-30의 최솟값

   신규 사용자 정의에 대한 주의
     조건(2)(3)을 먼저 적용한 뒤 "남은 처방 중 최초"를 고르면, 최초 처방이
     관찰기간 요건에 걸려 탈락한 환자가 그 다음 처방으로 코호트에 들어와
     prevalent user가 신규 사용자로 오분류된다. 따라서 최초 처방일을 먼저
     확정하고, 그 처방 자체가 조건을 만족할 때만 코호트에 포함한다.
   ======================================================================== */

/* ------------------------------------------------------------------------
   [1] Concept sets
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.cohort_concept_seed;
CREATE TEMP TABLE cohort_concept_seed (
    codeset_id         integer NOT NULL,
    concept_id         bigint  NOT NULL,
    include_descendants boolean NOT NULL DEFAULT TRUE
);

INSERT INTO cohort_concept_seed (codeset_id, concept_id, include_descendants) VALUES
    /* 0: oral amiodarone */
    (0, 19133832, TRUE),
    (0, 41349044, TRUE),
    (0, 1309944,  TRUE),
    (0, 40007699, TRUE),

    /* 1: pregnancy-related diagnosis */
    (1, 4299535, TRUE),

    /* 2: 초기 정의의 legacy thyroid disease set은 codeset 6에 모두 흡수했다.
          미사용 codeset을 남겨두면 배제 기준에서 누락되어도 드러나지 않으므로
          별도 codeset으로 유지하지 않는다. */

    /* 3: thyroid medication */
    (3, 1501700,  TRUE),
    (3, 1554072,  TRUE),
    (3, 19040606, TRUE),
    (3, 1504620,  TRUE),

    /* 4: TSH */
    (4, 3009201, TRUE),

    /* 5: thyroidectomy */
    (5, 4030107, TRUE),

    /* 6: detailed pre-existing thyroid disease */
    (6, 4116228,  TRUE),
    (6, 4142479,  TRUE),
    (6, 138387,   TRUE),
    (6, 4129364,  TRUE),
    (6, 133444,   TRUE),
    (6, 137520,   TRUE),
    (6, 4281109,  TRUE),
    (6, 132579,   TRUE),
    (6, 133737,   TRUE),
    (6, 4199437,  TRUE),
    (6, 4130020,  TRUE),
    (6, 140673,   TRUE),
    (6, 133728,   TRUE),
    (6, 4130017,  TRUE),
    (6, 138384,   TRUE),
    (6, 140062,   TRUE),
    (6, 4183422,  TRUE),
    (6, 4130027,  TRUE),
    (6, 137820,   TRUE),
    (6, 37016342, TRUE),
    (6, 4081998,  TRUE),
    (6, 4030049,  TRUE),

    /* 갑상선종·갑상선 종양: 초기 코호트 정의(구 codeset 2)에 있었으나 상세
       세트로 옮기는 과정에서 누락되었던 항목이다. 원 논문의 ICD-9 240/241
       (goiter) 배제 기준에 해당하므로 배제 세트에 복원한다. */
    (6, 135772,   TRUE),   -- Goiter
    (6, 141249,   TRUE),   -- Benign neoplasm of thyroid gland
    (6, 4131909,  TRUE),   -- Neoplasm of thyroid gland
    (6, 36717452, TRUE);   -- Multiple endocrine neoplasia type 2A

DROP TABLE IF EXISTS pg_temp.cohort_codesets;
CREATE TEMP TABLE cohort_codesets AS
SELECT DISTINCT
    s.codeset_id,
    s.concept_id
FROM cohort_concept_seed s
JOIN concept c
  ON c.concept_id = s.concept_id
WHERE c.invalid_reason IS NULL

UNION

SELECT DISTINCT
    s.codeset_id,
    ca.descendant_concept_id AS concept_id
FROM cohort_concept_seed s
JOIN concept_ancestor ca
  ON ca.ancestor_concept_id = s.concept_id
JOIN concept c
  ON c.concept_id = ca.descendant_concept_id
WHERE s.include_descendants
  AND c.invalid_reason IS NULL;

CREATE INDEX ON cohort_codesets (codeset_id, concept_id);

/* concept set이 비어 있는 상태로 분석을 진행하지 않는다. */
DO $validation$
DECLARE
    required_codeset integer;
BEGIN
    FOREACH required_codeset IN ARRAY ARRAY[0, 1, 3, 4, 5, 6]
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM cohort_codesets WHERE codeset_id = required_codeset
        ) THEN
            RAISE EXCEPTION 'Required cohort codeset % is empty', required_codeset;
        END IF;
    END LOOP;
END
$validation$;

/* ------------------------------------------------------------------------
   [2] First-ever amiodarone exposure

   신규 사용자 판정 기준일이므로 날짜 구간과 observation period 조건을
   적용하기 전, 전체 기록에서 환자별 최초 아미오다론 처방일을 확정한다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.cohort_first_amiodarone;
CREATE TEMP TABLE cohort_first_amiodarone AS
SELECT
    de.person_id,
    MIN(de.drug_exposure_start_date::date) AS first_amiodarone_date
FROM drug_exposure de
JOIN cohort_codesets cs
  ON cs.codeset_id = 0
 AND cs.concept_id = de.drug_concept_id
GROUP BY de.person_id;

CREATE UNIQUE INDEX ON cohort_first_amiodarone (person_id);

/* ------------------------------------------------------------------------
   [3] Index candidates

   최초 처방 자체가 날짜 구간과 observation period 조건을 모두 만족할 때만
   index date가 된다. 조건을 만족하지 못하는 환자는 다음 처방으로 대체되지
   않고 코호트에서 제외되며, 이로써 prevalent user 유입을 차단한다.
   같은 날짜에 처방이 여러 건이면 drug_exposure_id가 작은 행을 선택한다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.cohort_index_candidates;
CREATE TEMP TABLE cohort_index_candidates AS
WITH eligible_prescriptions AS (
    SELECT
        de.drug_exposure_id AS event_id,
        de.person_id,
        de.drug_exposure_start_date::date AS start_date,
        COALESCE(
            de.drug_exposure_end_date::date,
            de.drug_exposure_start_date::date + 1
        ) AS exposure_end_date,
        op.observation_period_start_date::date AS op_start_date,
        op.observation_period_end_date::date AS op_end_date,
        de.visit_occurrence_id,
        ROW_NUMBER() OVER (
            PARTITION BY de.person_id
            ORDER BY de.drug_exposure_start_date, de.drug_exposure_id,
                     op.observation_period_end_date DESC
        ) AS rn
    FROM drug_exposure de
    JOIN cohort_codesets cs
      ON cs.codeset_id = 0
     AND cs.concept_id = de.drug_concept_id
    /* 최초 처방 이외의 처방은 index 후보가 될 수 없다. */
    JOIN cohort_first_amiodarone fa
      ON fa.person_id = de.person_id
     AND fa.first_amiodarone_date = de.drug_exposure_start_date::date
    JOIN observation_period op
      ON op.person_id = de.person_id
     AND de.drug_exposure_start_date::date
         BETWEEN op.observation_period_start_date::date
             AND op.observation_period_end_date::date
    WHERE de.drug_exposure_start_date::date >= DATE '2005-01-01'
      AND de.drug_exposure_start_date::date <  DATE '2026-07-01'
      AND op.observation_period_start_date::date + 365
          <= de.drug_exposure_start_date::date
      AND de.drug_exposure_start_date::date + 1
          <= op.observation_period_end_date::date
)
SELECT
    event_id,
    person_id,
    start_date,
    exposure_end_date,
    op_start_date,
    op_end_date,
    visit_occurrence_id
FROM eligible_prescriptions
WHERE rn = 1;

CREATE INDEX ON cohort_index_candidates (person_id, start_date);

/* ------------------------------------------------------------------------
   [4] Inclusion/exclusion criteria

   TSH, 갑상선 약물·질환·절제술과 임신을 모두 index-365일부터
   index 당일까지 검색한다. 날짜 단위 CDM에서 index 당일의 선후관계를
   구분할 수 없으므로 당일 기록은 prevalent 상태로 간주한다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.cohort_eligibility;
CREATE TEMP TABLE cohort_eligibility AS
SELECT
    q.*,

    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM measurement m
        JOIN cohort_codesets cs
          ON cs.codeset_id = 4
         AND cs.concept_id = m.measurement_concept_id
        WHERE m.person_id = q.person_id
          AND m.measurement_date::date
              BETWEEN q.start_date - 365 AND q.start_date
          AND m.value_as_number IS NOT NULL
          AND (m.value_as_number < 0.1 OR m.value_as_number > 10.0)
    ) THEN 1 ELSE 0 END AS pass_tsh,

    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM drug_exposure de
        JOIN cohort_codesets cs
          ON cs.codeset_id = 3
         AND cs.concept_id = de.drug_concept_id
        WHERE de.person_id = q.person_id
          AND de.drug_exposure_start_date::date
              BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_thyroid_medication,

    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM condition_occurrence co
        JOIN cohort_codesets cs
          ON cs.codeset_id = 6
         AND cs.concept_id = co.condition_concept_id
        WHERE co.person_id = q.person_id
          AND co.condition_start_date::date
              BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_thyroid_disease,

    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM condition_occurrence co
        JOIN cohort_codesets cs
          ON cs.codeset_id = 1
         AND cs.concept_id = co.condition_concept_id
        WHERE co.person_id = q.person_id
          AND co.condition_start_date::date
              BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_pregnancy,

    CASE WHEN EXISTS (
        SELECT 1
        FROM person p
        WHERE p.person_id = q.person_id
          AND p.birth_datetime IS NOT NULL
          AND (p.birth_datetime::date + INTERVAL '18 years')::date
              <= q.start_date
    ) THEN 1 ELSE 0 END AS pass_age_18,

    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM procedure_occurrence po
        JOIN cohort_codesets cs
          ON cs.codeset_id = 5
         AND cs.concept_id = po.procedure_concept_id
        WHERE po.person_id = q.person_id
          AND po.procedure_date::date
              BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_thyroidectomy
FROM cohort_index_candidates q;

/* ------------------------------------------------------------------------
   [5] Final cohort
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.final_cohort;
CREATE TEMP TABLE final_cohort AS
SELECT
    person_id AS subject_id,
    start_date AS cohort_start_date,
    LEAST(
        (start_date + INTERVAL '2 years')::date,
        op_end_date,
        DATE '2026-06-30'
    ) AS cohort_end_date
FROM cohort_eligibility
WHERE pass_tsh = 1
  AND pass_thyroid_medication = 1
  AND pass_thyroid_disease = 1
  AND pass_pregnancy = 1
  AND pass_age_18 = 1
  AND pass_thyroidectomy = 1;

CREATE UNIQUE INDEX ON final_cohort (subject_id);

/* ------------------------------------------------------------------------
   [6] Cohort-flow audit
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.cohort_flow_summary;
CREATE TEMP TABLE cohort_flow_summary AS
SELECT 1 AS stage_order,
       'patients with any amiodarone record'::text AS stage,
       COUNT(*)::bigint AS n
FROM cohort_first_amiodarone

UNION ALL

SELECT 2, 'first amiodarone in study period with 365d prior observation',
       COUNT(*)::bigint
FROM cohort_eligibility

UNION ALL

SELECT 3, 'after abnormal TSH exclusion', COUNT(*)::bigint
FROM cohort_eligibility
WHERE pass_tsh = 1

UNION ALL

SELECT 4, 'after thyroid medication exclusion', COUNT(*)::bigint
FROM cohort_eligibility
WHERE pass_tsh = 1
  AND pass_thyroid_medication = 1

UNION ALL

SELECT 5, 'after thyroid disease exclusion', COUNT(*)::bigint
FROM cohort_eligibility
WHERE pass_tsh = 1
  AND pass_thyroid_medication = 1
  AND pass_thyroid_disease = 1

UNION ALL

SELECT 6, 'after pregnancy exclusion', COUNT(*)::bigint
FROM cohort_eligibility
WHERE pass_tsh = 1
  AND pass_thyroid_medication = 1
  AND pass_thyroid_disease = 1
  AND pass_pregnancy = 1

UNION ALL

SELECT 7, 'after age criterion', COUNT(*)::bigint
FROM cohort_eligibility
WHERE pass_tsh = 1
  AND pass_thyroid_medication = 1
  AND pass_thyroid_disease = 1
  AND pass_pregnancy = 1
  AND pass_age_18 = 1

UNION ALL

SELECT 8, 'after thyroidectomy exclusion / final cohort', COUNT(*)::bigint
FROM final_cohort;

DO $validation$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM final_cohort) THEN
        RAISE EXCEPTION 'Final cohort is empty; verify schema, concepts, dates, and exclusions';
    END IF;

    IF EXISTS (
        SELECT subject_id FROM final_cohort
        GROUP BY subject_id HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'final_cohort contains duplicate subject_id values';
    END IF;

    IF EXISTS (
        SELECT 1 FROM final_cohort
        WHERE cohort_end_date < cohort_start_date
    ) THEN
        RAISE EXCEPTION 'final_cohort contains an end date before index date';
    END IF;

    /* 신규 사용자 설계 검증: index date 이전의 아미오다론 노출이 남아 있으면
       prevalent user가 포함된 것이므로 즉시 중단한다. */
    IF EXISTS (
        SELECT 1
        FROM final_cohort fc
        JOIN drug_exposure de
          ON de.person_id = fc.subject_id
        JOIN cohort_codesets cs
          ON cs.codeset_id = 0
         AND cs.concept_id = de.drug_concept_id
        WHERE de.drug_exposure_start_date::date < fc.cohort_start_date
    ) THEN
        RAISE EXCEPTION 'Prevalent amiodarone user detected: exposure before index date';
    END IF;
END
$validation$;

SELECT stage_order, stage, n
FROM cohort_flow_summary
ORDER BY stage_order;
