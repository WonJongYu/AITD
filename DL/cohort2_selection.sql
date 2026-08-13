/* ========================================================================
   File Name      : cohort2_selection.sql
   Description    : 최초 아미오다론 처방 환자 중 포함·제외 기준을 만족하는 연구 코호트 생성
   SQL Dialect    : PostgreSQL / OMOP CDM
   Output         : TEMP TABLE final_cohort

   실행 전 조건
     - 현재 search_path에서 OMOP CDM 테이블과 vocabulary 테이블
       (person, observation_period, drug_exposure, measurement,
        condition_occurrence, procedure_occurrence, concept,
        concept_ancestor)을 조회할 수 있어야 한다.
     - labeling2.sql과 같은 PostgreSQL 세션에서 실행해야 한다.

   전체 처리 순서
     1. 분석에 사용할 concept set 생성
     2. 전체 기록에서 환자별 최초 아미오다론 처방을 확정한 뒤,
        그 최초 처방이 2005-01-01~2026-06-30에 속할 때만 인덱스 후보로 선정
     3. 인덱스 전 365일 관찰기간과 인덱스 후 최소 1일 관찰 여부 확인
     4. TSH, 갑상선 약물·진단·수술, 임신, 만 18세 기준 적용
     5. 추적 종료일을 2년 후·관찰종료일·2026-06-30 중 가장 빠른 날로 설정
     6. 후속 labeling2.sql이 바로 사용할 final_cohort 생성
   ======================================================================== */

/* ------------------------------------------------------------------------
   [1] Concept set

   codeset_id
     0: 아미오다론
     1: 임신 관련 진단
     2: 갑상선 질환 기본 목록(원본과의 대응을 위해 유지, 배제에는 미사용)
     3: 갑상선 관련 약물
     4: TSH 검사
     5: 갑상선절제술
     6: 과거 갑상선 질환 배제용 세부 진단
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort2_codeset_seed;
CREATE TEMP TABLE cohort2_codeset_seed (
    codeset_id INT NOT NULL,
    concept_id BIGINT NOT NULL
);

INSERT INTO cohort2_codeset_seed (codeset_id, concept_id) VALUES
    /* 0. Amiodarone */
    (0, 19133832),
    (0, 41349044),
    (0, 1309944),
    (0, 40007699),

    /* 1. Pregnancy */
    (1, 4299535),

    /* 2. Thyroid disease: retained for source-definition traceability */
    (2, 4142479),
    (2, 141249),
    (2, 135772),
    (2, 140673),
    (2, 138387),
    (2, 133444),
    (2, 4131909),

    /* 3. Thyroid-related medication */
    (3, 1501700),
    (3, 1554072),
    (3, 19040606),
    (3, 1504620),

    /* 4. TSH */
    (4, 3009201),

    /* 5. Thyroidectomy */
    (5, 4030107),

    /* 6. Prior thyroid disease exclusion */
    (6, 4116228),
    (6, 4142479),
    (6, 138387),
    (6, 4129364),
    (6, 133444),
    (6, 137520),
    (6, 4281109),
    (6, 132579),
    (6, 133737),
    (6, 4199437),
    (6, 4130020),
    (6, 140673),
    (6, 133728),
    (6, 4130017),
    (6, 138384),
    (6, 140062),
    (6, 4183422),
    (6, 4130027),
    (6, 137820),
    (6, 37016342),
    (6, 4081998),
    (6, 4030049);

DROP TABLE IF EXISTS pg_temp.cohort2_codesets;
CREATE TEMP TABLE cohort2_codesets AS
/* seed concept 자체 */
SELECT DISTINCT
    s.codeset_id,
    s.concept_id
FROM cohort2_codeset_seed s
JOIN concept c
  ON c.concept_id = s.concept_id

UNION

/* seed concept의 유효한 descendant */
SELECT DISTINCT
    s.codeset_id,
    ca.descendant_concept_id AS concept_id
FROM cohort2_codeset_seed s
JOIN concept_ancestor ca
  ON ca.ancestor_concept_id = s.concept_id
JOIN concept c
  ON c.concept_id = ca.descendant_concept_id
 AND c.invalid_reason IS NULL;

CREATE INDEX cohort2_codesets_lookup_idx
    ON cohort2_codesets (codeset_id, concept_id);

/* ------------------------------------------------------------------------
   [2] 전체 기록의 최초 아미오다론 처방 및 적격 인덱스 후보

   1. 날짜 필터를 적용하기 전에 전체 drug_exposure에서 환자별 최초
      아미오다론 처방 한 건을 확정한다.
   2. 그 최초 처방 시작일이 2005-01-01 이상, 2026-07-01 미만이어야 한다.
   3. 최초 처방일이 observation period 안에 있어야 한다.
   4. 최초 처방 전 365일과 처방 후 최소 1일이 관찰 가능해야 한다.

   중요:
     최초 처방이 위 조건을 만족하지 않아도 이후 재처방으로 대체하지 않는다.
     따라서 OMOP에 기록된 과거 아미오다론 사용자가 신규 사용자로 들어오는 것을
     구조적으로 차단한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort2_first_amiodarone_overall;
CREATE TEMP TABLE cohort2_first_amiodarone_overall AS
WITH ranked_amiodarone AS (
    SELECT
        de.drug_exposure_id AS event_id,
        de.person_id,
        de.drug_exposure_start_date::date AS start_date,
        COALESCE(
            de.drug_exposure_end_date::date,
            de.drug_exposure_start_date::date + 1
        ) AS exposure_end_date,
        de.visit_occurrence_id,
        ROW_NUMBER() OVER (
            PARTITION BY de.person_id
            ORDER BY
                de.drug_exposure_start_date,
                de.drug_exposure_id
        ) AS rn
    FROM drug_exposure de
    JOIN cohort2_codesets cs
      ON cs.codeset_id = 0
     AND cs.concept_id = de.drug_concept_id
    /* 날짜 범위를 걸기 전에 전체 기록에서 최초 처방을 찾는다. */
    WHERE de.drug_exposure_start_date IS NOT NULL
)
SELECT
    event_id,
    person_id,
    start_date,
    exposure_end_date,
    visit_occurrence_id
FROM ranked_amiodarone
WHERE rn = 1;

CREATE UNIQUE INDEX cohort2_first_amiodarone_person_idx
    ON cohort2_first_amiodarone_overall (person_id);

DROP TABLE IF EXISTS pg_temp.cohort2_qualified_events;
CREATE TEMP TABLE cohort2_qualified_events AS
WITH eligible_first_amiodarone AS (
    SELECT
        fa.event_id,
        fa.person_id,
        fa.start_date,
        fa.exposure_end_date,
        op.observation_period_start_date::date AS op_start_date,
        op.observation_period_end_date::date AS op_end_date,
        fa.visit_occurrence_id,
        ROW_NUMBER() OVER (
            PARTITION BY fa.person_id
            ORDER BY
                op.observation_period_end_date DESC,
                op.observation_period_start_date ASC
        ) AS op_rn
    FROM cohort2_first_amiodarone_overall fa
    JOIN observation_period op
      ON op.person_id = fa.person_id
     AND fa.start_date BETWEEN
         op.observation_period_start_date::date AND op.observation_period_end_date::date
    WHERE fa.start_date >= DATE '2005-01-01'
      AND fa.start_date <  DATE '2026-07-01'
      AND op.observation_period_start_date::date + 365
          <= fa.start_date
      AND fa.start_date + 1
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
FROM eligible_first_amiodarone
/* 비정상적으로 겹치는 observation period가 있으면 가장 넓은 한 건만 선택한다. */
WHERE op_rn = 1;

CREATE INDEX cohort2_qualified_person_idx
    ON cohort2_qualified_events (person_id, start_date);

/* ------------------------------------------------------------------------
   [2-1] 생년정보 표준화

   OMOP PERSON의 birth_datetime은 선택 필드이므로 year_of_birth만 채워진
   데이터에서도 코호트와 age가 전부 사라지지 않도록 대체 생일을 만든다.

   우선순위
     1. birth_datetime
     2. 유효한 year/month/day
     3. year/month만 있으면 해당 월의 마지막 날(보수적 만 나이 판정)
     4. year만 있으면 12월 31일(보수적 만 나이 판정)

   불완전한 생년정보에서 가장 늦을 수 있는 생일을 사용하므로 만 18세 미만을
   잘못 포함하지 않는다. 대신 실제로 이미 만 18세인 일부 환자가 생일 전으로
   간주되어 제외되거나 age가 최대 1세 낮게 계산될 수 있다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort2_birth_info;
CREATE TEMP TABLE cohort2_birth_info AS
WITH birth_components AS (
    SELECT
        q.person_id,
        q.start_date AS index_date,
        p.birth_datetime,
        p.year_of_birth,
        p.month_of_birth,
        p.day_of_birth,
        CASE
            WHEN p.year_of_birth BETWEEN 1800
                 AND EXTRACT(YEAR FROM q.start_date)::int
            THEN make_date(p.year_of_birth, 1, 1)
        END AS birth_year_start,
        CASE
            WHEN p.year_of_birth BETWEEN 1800
                 AND EXTRACT(YEAR FROM q.start_date)::int
             AND p.month_of_birth BETWEEN 1 AND 12
            THEN make_date(p.year_of_birth, p.month_of_birth, 1)
        END AS birth_month_start
    FROM cohort2_qualified_events q
    LEFT JOIN person p
      ON p.person_id = q.person_id
)
SELECT
    person_id,
    CASE
        WHEN birth_datetime IS NOT NULL
            THEN birth_datetime::date
        WHEN birth_month_start IS NOT NULL
         AND day_of_birth BETWEEN 1 AND EXTRACT(
                DAY FROM birth_month_start + INTERVAL '1 month - 1 day'
             )::int
            THEN birth_month_start + (day_of_birth - 1)
        WHEN birth_month_start IS NOT NULL
            THEN (birth_month_start + INTERVAL '1 month - 1 day')::date
        WHEN birth_year_start IS NOT NULL
            THEN make_date(year_of_birth, 12, 31)
        ELSE NULL
    END AS birth_date_for_age,
    CASE
        WHEN birth_datetime IS NOT NULL
            THEN 'birth_datetime'
        WHEN birth_month_start IS NOT NULL
         AND day_of_birth BETWEEN 1 AND EXTRACT(
                DAY FROM birth_month_start + INTERVAL '1 month - 1 day'
             )::int
            THEN 'year_month_day'
        WHEN birth_month_start IS NOT NULL
            THEN 'year_month_conservative'
        WHEN birth_year_start IS NOT NULL
            THEN 'year_conservative'
        ELSE 'missing_or_invalid'
    END::text AS birth_date_source
FROM birth_components;

CREATE UNIQUE INDEX cohort2_birth_info_person_idx
    ON cohort2_birth_info (person_id);

/* ------------------------------------------------------------------------
   [3] 포함·제외 기준별 통과 여부

   갑상선 관련 배제(TSH, 약물, 질환, 절제술)와 임신 배제는 모두
   index_date - 365일부터 index_date 당일까지 검색한다.
   pass_* = 1이면 해당 기준을 통과한 것이다.

   TSH 단위 주의:
     현재 코호트 원 정의의 0.1~10 기준을 그대로 사용한다. TSH의 일반적인
     mIU/L와 uIU/mL는 수치가 같지만, 실제 데이터에 다른 단위가 존재한다면
     별도의 단위 품질 점검 후 이 부분도 표준화해야 한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort2_eligibility;
CREATE TEMP TABLE cohort2_eligibility AS
SELECT
    q.*,
    b.birth_date_for_age,
    b.birth_date_source,

    /* Rule 0: 과거 비정상 TSH가 없어야 함 */
    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM measurement m
        JOIN cohort2_codesets cs
          ON cs.codeset_id = 4
         AND cs.concept_id = m.measurement_concept_id
        WHERE m.person_id = q.person_id
          AND m.measurement_date BETWEEN q.start_date - 365 AND q.start_date
          AND m.value_as_number IS NOT NULL
          AND (m.value_as_number < 0.1 OR m.value_as_number > 10.0)
    ) THEN 1 ELSE 0 END AS pass_tsh,

    /* Rule 1: 과거 갑상선 관련 약물 처방이 없어야 함 */
    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM drug_exposure de
        JOIN cohort2_codesets cs
          ON cs.codeset_id = 3
         AND cs.concept_id = de.drug_concept_id
        WHERE de.person_id = q.person_id
          AND de.drug_exposure_start_date BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_thyroid_medication,

    /* Rule 2: 과거 갑상선 질환 진단이 없어야 함 */
    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM condition_occurrence co
        JOIN cohort2_codesets cs
          ON cs.codeset_id = 6
         AND cs.concept_id = co.condition_concept_id
        WHERE co.person_id = q.person_id
          AND co.condition_start_date BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_thyroid_disease,

    /* Rule 3: 과거 임신 관련 진단이 없어야 함 */
    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM condition_occurrence co
        JOIN cohort2_codesets cs
          ON cs.codeset_id = 1
         AND cs.concept_id = co.condition_concept_id
        WHERE co.person_id = q.person_id
          AND co.condition_start_date BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_pregnancy,

    /* Rule 4: 표준화된 생일 기준으로 index date에 만 18세 이상 */
    CASE
        WHEN b.birth_date_for_age IS NOT NULL
         AND (b.birth_date_for_age + INTERVAL '18 years')::date <= q.start_date
        THEN 1 ELSE 0
    END AS pass_age_18,

    /* Rule 5: 과거 갑상선절제술이 없어야 함 */
    CASE WHEN NOT EXISTS (
        SELECT 1
        FROM procedure_occurrence po
        JOIN cohort2_codesets cs
          ON cs.codeset_id = 5
         AND cs.concept_id = po.procedure_concept_id
        WHERE po.person_id = q.person_id
          AND po.procedure_date BETWEEN q.start_date - 365 AND q.start_date
    ) THEN 1 ELSE 0 END AS pass_thyroidectomy

FROM cohort2_qualified_events q
LEFT JOIN cohort2_birth_info b
  ON b.person_id = q.person_id;

/* ------------------------------------------------------------------------
   [3-1] 논문 코호트 흐름도용 순차 제외 인원

   여러 제외기준에 동시에 해당하는 환자를 중복 계산하지 않도록 아래 순서를
   고정해 한 단계씩 적용한다.

   연구기간 → 관찰기간 → 만 18세 → 임신 → 갑상선 진단 → 갑상선절제술
   → 갑상선 약물 → 비정상 TSH

   각 n_excluded는 바로 전 단계까지 남아 있던 환자 중 해당 단계에서 새로
   제외된 인원이다. 따라서 모든 제외 인원과 최종 코호트 수의 합은 최초
   아미오다론 처방자 수와 일치한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort2_attrition;
CREATE TEMP TABLE cohort2_attrition AS
WITH
stage_0 AS (
    SELECT person_id
    FROM cohort2_first_amiodarone_overall
),
stage_1 AS (
    SELECT person_id
    FROM cohort2_first_amiodarone_overall
    WHERE start_date >= DATE '2005-01-01'
      AND start_date <  DATE '2026-07-01'
),
stage_2 AS (
    SELECT person_id
    FROM cohort2_qualified_events
),
stage_3 AS (
    SELECT person_id FROM cohort2_eligibility
    WHERE pass_age_18 = 1
),
stage_4 AS (
    SELECT person_id FROM cohort2_eligibility
    WHERE pass_age_18 = 1
      AND pass_pregnancy = 1
),
stage_5 AS (
    SELECT person_id FROM cohort2_eligibility
    WHERE pass_age_18 = 1
      AND pass_pregnancy = 1
      AND pass_thyroid_disease = 1
),
stage_6 AS (
    SELECT person_id FROM cohort2_eligibility
    WHERE pass_age_18 = 1
      AND pass_pregnancy = 1
      AND pass_thyroid_disease = 1
      AND pass_thyroidectomy = 1
),
stage_7 AS (
    SELECT person_id FROM cohort2_eligibility
    WHERE pass_age_18 = 1
      AND pass_pregnancy = 1
      AND pass_thyroid_disease = 1
      AND pass_thyroidectomy = 1
      AND pass_thyroid_medication = 1
),
stage_8 AS (
    SELECT person_id FROM cohort2_eligibility
    WHERE pass_age_18 = 1
      AND pass_pregnancy = 1
      AND pass_thyroid_disease = 1
      AND pass_thyroidectomy = 1
      AND pass_thyroid_medication = 1
      AND pass_tsh = 1
),
counts AS (
    SELECT
        (SELECT COUNT(*) FROM stage_0)::bigint AS n0,
        (SELECT COUNT(*) FROM stage_1)::bigint AS n1,
        (SELECT COUNT(*) FROM stage_2)::bigint AS n2,
        (SELECT COUNT(*) FROM stage_3)::bigint AS n3,
        (SELECT COUNT(*) FROM stage_4)::bigint AS n4,
        (SELECT COUNT(*) FROM stage_5)::bigint AS n5,
        (SELECT COUNT(*) FROM stage_6)::bigint AS n6,
        (SELECT COUNT(*) FROM stage_7)::bigint AS n7,
        (SELECT COUNT(*) FROM stage_8)::bigint AS n8
)
SELECT 0 AS step_order, 'initial'::text AS row_type,
       'first_amiodarone_overall'::text AS criterion_key,
       'Patients with a first recorded amiodarone prescription'::text AS criterion_label,
       n0 AS n_before, 0::bigint AS n_excluded, n0 AS n_remaining
FROM counts
UNION ALL
SELECT 1, 'exclusion', 'outside_study_period',
       'First prescription outside 2005-01-01 to 2026-06-30',
       n0, n0 - n1, n1 FROM counts
UNION ALL
SELECT 2, 'exclusion', 'insufficient_observation',
       'Required observation not met (365 days before and at least 1 day after index)',
       n1, n1 - n2, n2 FROM counts
UNION ALL
SELECT 3, 'exclusion', 'age_under_18_or_unknown',
       'Age under 18 years or missing/invalid birth information',
       n2, n2 - n3, n3 FROM counts
UNION ALL
SELECT 4, 'exclusion', 'prior_pregnancy',
       'Pregnancy-related diagnosis in the prior 365 days',
       n3, n3 - n4, n4 FROM counts
UNION ALL
SELECT 5, 'exclusion', 'prior_thyroid_disease',
       'Thyroid disease diagnosis in the prior 365 days',
       n4, n4 - n5, n5 FROM counts
UNION ALL
SELECT 6, 'exclusion', 'prior_thyroidectomy',
       'Thyroidectomy in the prior 365 days',
       n5, n5 - n6, n6 FROM counts
UNION ALL
SELECT 7, 'exclusion', 'prior_thyroid_medication',
       'Thyroid-related medication in the prior 365 days',
       n6, n6 - n7, n7 FROM counts
UNION ALL
SELECT 8, 'exclusion', 'prior_abnormal_tsh',
       'Abnormal TSH in the prior 365 days',
       n7, n7 - n8, n8 FROM counts
UNION ALL
SELECT 9, 'final', 'final_cohort',
       'Final eligible amiodarone cohort',
       n8, 0::bigint, n8 FROM counts;

/* ------------------------------------------------------------------------
   [4] 모든 기준을 통과한 환자
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.cohort2_included_events;
CREATE TEMP TABLE cohort2_included_events AS
SELECT
    event_id,
    person_id,
    start_date,
    exposure_end_date,
    op_start_date,
    op_end_date,
    visit_occurrence_id
FROM cohort2_eligibility
WHERE pass_tsh = 1
  AND pass_thyroid_medication = 1
  AND pass_thyroid_disease = 1
  AND pass_pregnancy = 1
  AND pass_age_18 = 1
  AND pass_thyroidectomy = 1;

/* ------------------------------------------------------------------------
   [5] 최종 코호트

   cohort_end_date는 다음 세 날짜 중 가장 빠른 날짜이다.
     1. index date + 2년
     2. observation period 종료일
     3. 데이터 종료일 2026-06-30

   환자당 index event가 한 건이므로 별도의 cohort era 병합은 필요하지 않다.
   final_cohort는 labeling2.sql이 같은 세션에서 바로 사용한다.
   ------------------------------------------------------------------------ */

/* 같은 이름의 영구 테이블은 건드리지 않고 현재 세션의 임시 결과만 교체한다. */
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
FROM cohort2_included_events;

CREATE UNIQUE INDEX final_cohort_subject_idx
    ON final_cohort (subject_id);

/* 순차 제외 합계와 실제 final_cohort가 일치해야 한다. */
DO $$
BEGIN
    IF (SELECT n_remaining FROM cohort2_attrition WHERE row_type = 'final')
       <> (SELECT COUNT(*) FROM final_cohort) THEN
        RAISE EXCEPTION 'Cohort attrition total does not match final_cohort';
    END IF;
END $$;

/* ------------------------------------------------------------------------
   [6] 실행 확인용 코호트 흐름 요약
   ------------------------------------------------------------------------ */

SELECT *
FROM cohort2_attrition
ORDER BY step_order;

/*
   최초 아미오다론 처방자 흐름.
   이후 재처방을 index로 대체하지 않았는지 단계별 인원으로 확인한다.
*/
SELECT
    COUNT(*) AS n_first_amiodarone_overall,
    COUNT(*) FILTER (
        WHERE fa.start_date >= DATE '2005-01-01'
          AND fa.start_date <  DATE '2026-07-01'
    ) AS n_first_amiodarone_in_study_period,
    COUNT(*) FILTER (
        WHERE fa.start_date >= DATE '2005-01-01'
          AND fa.start_date <  DATE '2026-07-01'
          AND EXISTS (
              SELECT 1
              FROM observation_period op
              WHERE op.person_id = fa.person_id
                AND fa.start_date BETWEEN
                    op.observation_period_start_date::date
                    AND op.observation_period_end_date::date
          )
    ) AS n_first_amiodarone_in_observation_period,
    COUNT(*) FILTER (
        WHERE fa.start_date >= DATE '2005-01-01'
          AND fa.start_date <  DATE '2026-07-01'
          AND EXISTS (
              SELECT 1
              FROM observation_period op
              WHERE op.person_id = fa.person_id
                AND fa.start_date BETWEEN
                    op.observation_period_start_date::date
                    AND op.observation_period_end_date::date
                AND op.observation_period_start_date::date + 365 <= fa.start_date
                AND fa.start_date + 1 <= op.observation_period_end_date::date
          )
    ) AS n_first_amiodarone_with_required_observation,
    (SELECT COUNT(*) FROM cohort2_qualified_events) AS n_qualified_index
FROM cohort2_first_amiodarone_overall fa;

/*
   생년정보 품질과 만 18세 통과 현황.
   첫 실행에서 cohort가 0명일 때 birth_datetime 결측 때문인지 즉시 확인한다.
*/
SELECT
    birth_date_source,
    COUNT(*) AS n_qualified_index,
    COUNT(*) FILTER (WHERE birth_date_for_age IS NOT NULL) AS n_birth_date_available,
    COUNT(*) FILTER (WHERE pass_age_18 = 1) AS n_pass_age_18,
    COUNT(*) FILTER (WHERE pass_age_18 = 0) AS n_fail_age_18
FROM cohort2_eligibility
GROUP BY birth_date_source
ORDER BY birth_date_source;

SELECT
    (SELECT COUNT(*) FROM cohort2_qualified_events) AS n_qualified_index,
    /* 아래 값은 최초 처방 로직이 정상이라면 반드시 0이어야 한다. */
    (
        SELECT COUNT(DISTINCT q.person_id)
        FROM cohort2_qualified_events q
        JOIN drug_exposure de
          ON de.person_id = q.person_id
         AND de.drug_exposure_start_date::date < q.start_date
        JOIN cohort2_codesets cs
          ON cs.codeset_id = 0
         AND cs.concept_id = de.drug_concept_id
    ) AS n_qualified_with_prior_amiodarone_must_be_zero,
    (SELECT COUNT(*) FROM cohort2_eligibility WHERE birth_date_for_age IS NULL)
        AS n_missing_or_invalid_birth_date,
    (SELECT COUNT(*) FROM cohort2_eligibility WHERE pass_age_18 = 1)
        AS n_pass_age_18,
    (SELECT COUNT(*) FROM final_cohort) AS n_final_cohort;
