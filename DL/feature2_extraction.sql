/* ========================================================================
   File Name      : feature2_extraction.sql
   Description    : V2 월 구간별 특징 추출
   Dependencies   : labeling2.sql
   SQL Dialect    : PostgreSQL
   Input          : TEMP TABLE final_flag
   Main Output    : TEMP TABLE feature_model_wide
   ======================================================================== */

/* ==========================================
   Part 1

   Index-date baseline features
   - age와 sex는 index_date 시점의 인구학적 정보로 정의한다.
   - height, weight, BMI, alcohol, smoking은 index_date 당일 기록을 우선한다.
   - 당일 기록이 없으면 index_date 이전 1년 안에서 가장 가까운 기록을 사용한다.
   - index_date 이후 기록은 사용하지 않는다.
   ========================================== */

/* Age */

DROP TABLE IF EXISTS feature_age;
CREATE TEMP TABLE feature_age AS
SELECT
    f.person_id,
    /* cohort의 만 18세 판정과 같은 표준화 생일을 사용한다. */
    EXTRACT(YEAR FROM AGE(f.index_date, b.birth_date_for_age))::int AS age_at_index
FROM final_flag f
LEFT JOIN cohort2_birth_info b
  ON b.person_id = f.person_id;

/* Sex */

DROP TABLE IF EXISTS feature_sex;
CREATE TEMP TABLE feature_sex AS
SELECT
    f.person_id,
    CASE 
        WHEN p.gender_concept_id = 8507 THEN 1 -- Male
        WHEN p.gender_concept_id = 8532 THEN 0 -- Female
        ELSE NULL 
    END AS male_flag
FROM final_flag f
JOIN person p ON f.person_id = p.person_id;

/* Height */

DROP TABLE IF EXISTS feature_height;
CREATE TEMP TABLE feature_height AS
WITH height_raw AS (
    SELECT
        f.person_id,
        m.value_as_number AS height_cm,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY m.measurement_date DESC, m.measurement_id DESC
        ) AS rn
    FROM final_flag f
    JOIN measurement m ON m.person_id = f.person_id
    WHERE m.measurement_concept_id IN (3036277) -- Height (cm)
      AND m.value_as_number IS NOT NULL
      -- baseline 신체계측은 인덱스 이후 값을 사용하지 않는다.
      AND m.measurement_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
)
SELECT person_id, height_cm
FROM height_raw
WHERE rn = 1;

/* Weight */

DROP TABLE IF EXISTS feature_weight;
CREATE TEMP TABLE feature_weight AS
WITH weight_raw AS (
    SELECT
        f.person_id,
        m.value_as_number AS weight_kg,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY m.measurement_date DESC, m.measurement_id DESC
        ) AS rn
    FROM final_flag f
    JOIN measurement m ON m.person_id = f.person_id
    WHERE m.measurement_concept_id IN (3025315) -- Weight (kg)
      AND m.value_as_number IS NOT NULL
      AND m.measurement_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
)
SELECT person_id, weight_kg
FROM weight_raw
WHERE rn = 1;

/* BMI */

DROP TABLE IF EXISTS feature_bmi;
CREATE TEMP TABLE feature_bmi AS
WITH bmi_measured_raw AS (
    SELECT
        f.person_id,
        m.value_as_number AS bmi_measured,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY m.measurement_date DESC, m.measurement_id DESC
        ) AS rn
    FROM final_flag f
    JOIN measurement m ON m.person_id = f.person_id
    WHERE m.measurement_concept_id IN (3038553) -- BMI concept_id
      AND m.value_as_number IS NOT NULL
      AND m.measurement_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
),
bmi_measured_uniq AS (
    SELECT person_id, bmi_measured FROM bmi_measured_raw WHERE rn = 1
)
SELECT
    f.person_id,
    CASE
        WHEN h.height_cm > 0 AND w.weight_kg IS NOT NULL 
        THEN w.weight_kg / POWER(h.height_cm / 100.0, 2)
        ELSE b.bmi_measured
    END AS bmi
FROM final_flag f
LEFT JOIN feature_height h ON f.person_id = h.person_id
LEFT JOIN feature_weight w ON f.person_id = w.person_id
LEFT JOIN bmi_measured_uniq b ON f.person_id = b.person_id;

/* ------------------------------------------------------------------------
   Glasheen et al. (2019) CDMF CCI 구현

   Reference:
   Glasheen WP, et al. Charlson Comorbidity Index: ICD-9 Update and
   ICD-10 Translation. Am Health Drug Benefits. 2019;12:188-197.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC6684052/

   논문 부록의 ICD-9-CM/ICD-10-CM 코드 및 6개 계층 규칙을 적용하여
   feature_cci_flags와 feature_cci_score를 생성한다.

   한국 데이터의 KCD7은 ICD-10 계열 코드로 처리한다. source vocabulary가 없는
   레코드는 코드가 영문자로 시작하면 ICD-10/KCD, 숫자로 시작하면 ICD-9로
   보조 판정한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS feature_cci_code_rule;
CREATE TEMP TABLE feature_cci_code_rule (
    set_name   TEXT,
    code_system TEXT,
    code_regex TEXT
);

INSERT INTO feature_cci_code_rule (set_name, code_system, code_regex) VALUES
    /* 1. Myocardial infarction */
    ('cci_mi', 'ICD9CM',  '^(410|412)'),
    ('cci_mi', 'ICD10CM', '^(I21|I22)|^I252$'),

    /* 2. Congestive heart failure */
    ('cci_chf', 'ICD9CM',  '^428|^(39891|40201|40211|40291|40401|40403|40411|40413|40491|40493|425[4-9])$'),
    ('cci_chf', 'ICD10CM', '^(I43|I50)|^(I110|I130|I132|I255|I420|I425|I426|I427|I428|I429|P290)$'),

    /* 3. Peripheral vascular disease */
    ('cci_pvd', 'ICD9CM',  '^(440|441|4432|4438)|^(0930|4373|4431|4439|4471|5571|5579|V434)$'),
    ('cci_pvd', 'ICD10CM', '^(I70|I71)|^(I731|I738|I739|I771|I790|I791|I798|K551|K558|K559|Z958|Z959)$'),

    /* 4. Cerebrovascular disease */
    ('cci_cvd', 'ICD9CM',  '^(430|431|432|433|434|435|436|437|438)|^36234$'),
    ('cci_cvd', 'ICD10CM', '^(G45|G46|H340|H341|H342|I6[0-8])'),

    /* 5. Dementia */
    ('cci_dementia', 'ICD9CM',  '^(2901|2902|2904|2941|2942|3311)|^(2900|2903|2940|2948|3310|3312|3317|797)$'),
    ('cci_dementia', 'ICD10CM', '^(F01|F02|F03|G30|G310)|^(F04|F05|F061|F068|G132|G138|G311|G312|G914|G94|R4181|R54)$'),

    /* 6. Chronic pulmonary disease */
    ('cci_copd', 'ICD9CM',  '^(490|491|492|493|494|495|496|500|501|502|503|504|505)|^(5064|5081|5088)$'),
    ('cci_copd', 'ICD10CM', '^(J4[0-7]|J6[0-7])|^(J684|J701|J703)$'),

    /* 7. Rheumatic disease */
    ('cci_rheum', 'ICD9CM',  '^7148|^725|^(4465|7100|7101|7102|7103|7104|7140|7141|7142)$'),
    ('cci_rheum', 'ICD10CM', '^(M05|M06|M32|M33|M34)|^(M315|M351|M353|M360)$'),

    /* 8. Peptic ulcer disease */
    ('cci_pud', 'ICD9CM',  '^(531|532|533|534)'),
    ('cci_pud', 'ICD10CM', '^(K25|K26|K27|K28)'),

    /* 9. Mild liver disease */
    ('cci_liver_mild', 'ICD9CM',  '^(570|571)|^(07022|07023|07032|07033|07044|07054|0706|0709|5733|5734|5738|5739|V427)$'),
    ('cci_liver_mild', 'ICD10CM', '^(B18|K73|K74)|^(K700|K701|K702|K703|K709|K713|K714|K715|K717|K760|K762|K763|K764|K768|K769|Z944)$'),

    /* 10. Diabetes without chronic complications */
    ('cci_dm', 'ICD9CM',  '^(2508|2509|2490|2491|2492|2493|2499)'),
    ('cci_dm', 'ICD10CM', '^E(08|09|10|11|13)[01689]'),

    /* 11. Mild-to-moderate renal disease */
    ('cci_renal_mild_mod', 'ICD9CM',  '^(582|583)|^(40300|40310|40390|40400|40401|40410|40411|40490|40491|5851|5852|5853|5854|5859|V420)$'),
    ('cci_renal_mild_mod', 'ICD10CM', '^(N03|N05)|^(I129|I130|I1310|N181|N182|N183|N184|N189|Z940)$'),

    /* 12. Diabetes with chronic complications */
    ('cci_dm_comp', 'ICD9CM',  '^(2504|2505|2506|2507)'),
    ('cci_dm_comp', 'ICD10CM', '^E(08|09|10|11|13)[2345]'),

    /* 13. Hemiplegia or paraplegia */
    ('cci_hemi_para', 'ICD9CM',  '^(342|343|344)|^3341$'),
    ('cci_hemi_para', 'ICD10CM', '^(G81|G82|G83)|^(G041|G114|G800|G801|G802)$'),

    /* 14. Any malignancy, excluding nonmelanoma skin cancer */
    ('cci_malignancy', 'ICD9CM',  '^(14[0-9]|15[0-9]|16[0-9]|170|171|172|174|175|176|179|18[0-9]|190|191|192|193|194|195|200|201|202|203|204|205|206|207|208)|^(1991|2386)$'),
    ('cci_malignancy', 'ICD10CM', '^(C0[0-9]|C1[0-9]|C2[0-9]|C3[0-4]|C37|C38|C39|C40|C41|C43|C45|C46|C47|C48|C49|C50|C5[1-8]|C6[0-3]|C76|C81|C82|C83|C84|C85|C88|C9[0-9])|^C801$'),

    /* 15. Moderate-to-severe liver disease */
    ('cci_liver_mod_sev', 'ICD9CM',  '^4562|^(4560|4561|5722|5723|5724|5728)$'),
    ('cci_liver_mod_sev', 'ICD10CM', '^(I850|K704|K711|K721|K729)|^(I864|K765|K766|K767)$'),

    /* 16. Severe renal disease */
    ('cci_renal_severe', 'ICD9CM',  '^586|^(40301|40311|40391|40402|40403|40412|40413|40492|40493|5855|5856|5880|V4511|V4512|V560|V561|V562|V5631|V5632|V568)$'),
    ('cci_renal_severe', 'ICD10CM', '^N19|^Z49|^(I120|I1311|I132|N185|N186|N250|Z992)$'),

    /* 17. HIV infection without AIDS */
    ('cci_hiv', 'ICD9CM',  '^042'),
    ('cci_hiv', 'ICD10CM', '^B20'),

    /* 18. Metastatic solid tumor */
    ('cci_metastatic', 'ICD9CM',  '^(196|197|198)|^1990$'),
    ('cci_metastatic', 'ICD10CM', '^(C77|C78|C79)|^(C800|C802)$'),

    /* 19. AIDS 판정을 위한 opportunistic infection */
    ('cci_aids_oi', 'ICD9CM',  '^(112|180|114|054|115|176|20[0-9]|031|01[0-8]|130)|^(1175|0074|0785|0072|1363|V1261|0463|0031|7994)$|^3483'),
    ('cci_aids_oi', 'ICD10CM', '^(B37|C53|B38|B45|B25|B00|B39|C46|C8[1-9]|C9[0-6]|A31|A1[5-9]|B58)|^(A072|G934|A073|B59|Z8701|A812|A021|R64)$');

/* CCI lookback 기간 내 진단코드를 정규화하고 ICD 버전을 판정한다. */
DROP TABLE IF EXISTS feature_cci_diagnosis_normalized;
CREATE TEMP TABLE feature_cci_diagnosis_normalized AS
SELECT
    f.person_id,
    co.condition_occurrence_id,
    co.condition_start_date,
    REGEXP_REPLACE(
        UPPER(COALESCE(NULLIF(co.condition_source_value, ''), src.concept_code)),
        '[^A-Z0-9]', '', 'g'
    ) AS normalized_code,
    CASE
        WHEN src.vocabulary_id = 'ICD9CM' THEN 'ICD9CM'
        WHEN src.vocabulary_id IN ('ICD10CM', 'ICD10', 'KCD7') THEN 'ICD10CM'
        /* 다른 것으로 명시된 vocabulary를 코드 모양만으로 ICD/KCD로 오인하지 않는다. */
        WHEN src.vocabulary_id IS NOT NULL THEN NULL
        /* source vocabulary가 없을 때 코드 형태를 보조 기준으로 사용 */
        WHEN UPPER(COALESCE(NULLIF(co.condition_source_value, ''), src.concept_code))
             ~ '^[[:space:]]*[A-Z]' THEN 'ICD10CM'
        WHEN UPPER(COALESCE(NULLIF(co.condition_source_value, ''), src.concept_code))
             ~ '^[[:space:]]*[0-9]' THEN 'ICD9CM'
        ELSE NULL
    END AS code_system
FROM final_flag f
JOIN condition_occurrence co
  ON co.person_id = f.person_id
 AND co.condition_start_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
LEFT JOIN concept src
  ON src.concept_id = co.condition_source_concept_id;

/* 환자별로 논문 코드표에 해당하는 CCI 질환군을 매칭한다. */
DROP TABLE IF EXISTS feature_cci_code_match;
CREATE TEMP TABLE feature_cci_code_match AS
SELECT DISTINCT
    d.person_id,
    d.condition_occurrence_id,
    r.set_name
FROM feature_cci_diagnosis_normalized d
JOIN feature_cci_code_rule r
  ON r.code_system = d.code_system
 AND d.normalized_code ~ r.code_regex
WHERE d.normalized_code IS NOT NULL
  AND d.normalized_code <> '';

/* 19개 질환군 중 HIV와 opportunistic infection은 AIDS 판정에 함께 사용한다. */
DROP TABLE IF EXISTS feature_cci_flags;
CREATE TEMP TABLE feature_cci_flags AS
SELECT
    f.person_id,
    MAX(CASE WHEN m.set_name = 'cci_mi' THEN 1 ELSE 0 END) AS mi,
    MAX(CASE WHEN m.set_name = 'cci_chf' THEN 1 ELSE 0 END) AS chf,
    MAX(CASE WHEN m.set_name = 'cci_pvd' THEN 1 ELSE 0 END) AS pvd,
    MAX(CASE WHEN m.set_name = 'cci_cvd' THEN 1 ELSE 0 END) AS cvd,
    MAX(CASE WHEN m.set_name = 'cci_dementia' THEN 1 ELSE 0 END) AS dementia,
    MAX(CASE WHEN m.set_name = 'cci_copd' THEN 1 ELSE 0 END) AS copd,
    MAX(CASE WHEN m.set_name = 'cci_rheum' THEN 1 ELSE 0 END) AS rheum,
    MAX(CASE WHEN m.set_name = 'cci_pud' THEN 1 ELSE 0 END) AS pud,
    MAX(CASE WHEN m.set_name = 'cci_liver_mild' THEN 1 ELSE 0 END) AS liver_mild,
    MAX(CASE WHEN m.set_name = 'cci_dm' THEN 1 ELSE 0 END) AS dm,
    MAX(CASE WHEN m.set_name = 'cci_renal_mild_mod' THEN 1 ELSE 0 END) AS renal_mild_mod,
    MAX(CASE WHEN m.set_name = 'cci_dm_comp' THEN 1 ELSE 0 END) AS dm_comp,
    MAX(CASE WHEN m.set_name = 'cci_hemi_para' THEN 1 ELSE 0 END) AS hemi_para,
    MAX(CASE WHEN m.set_name = 'cci_malignancy' THEN 1 ELSE 0 END) AS malignancy,
    MAX(CASE WHEN m.set_name = 'cci_liver_mod_sev' THEN 1 ELSE 0 END) AS liver_mod_sev,
    MAX(CASE WHEN m.set_name = 'cci_renal_severe' THEN 1 ELSE 0 END) AS renal_severe,
    MAX(CASE WHEN m.set_name = 'cci_hiv' THEN 1 ELSE 0 END) AS hiv,
    MAX(CASE WHEN m.set_name = 'cci_metastatic' THEN 1 ELSE 0 END) AS metastatic,
    MAX(CASE WHEN m.set_name = 'cci_aids_oi' THEN 1 ELSE 0 END) AS aids_oi
FROM final_flag f
LEFT JOIN feature_cci_code_match m ON m.person_id = f.person_id
GROUP BY f.person_id;

/*
   Glasheen 2019의 6개 hierarchy 적용:
   1) hemiplegia/paraplegia > cerebrovascular disease
   2) moderate/severe liver > mild liver
   3) diabetes with complications > diabetes without complications
   4) severe renal > mild/moderate renal
   5) metastatic tumor > nonmetastatic malignancy
   6) AIDS > HIV without AIDS

   AIDS는 HIV 진단과 opportunistic infection 진단이 모두 있을 때만 6점이다.
   나이는 별도의 age feature이므로 CCI 총점에 가산하지 않는다.
*/
DROP TABLE IF EXISTS feature_cci_score;
CREATE TEMP TABLE feature_cci_score AS
SELECT
    person_id,
    (
        mi + chf + pvd + dementia + copd + rheum + pud
        + GREATEST(cvd, 2 * hemi_para)
        + GREATEST(liver_mild, 3 * liver_mod_sev)
        + GREATEST(dm, 2 * dm_comp)
        + GREATEST(renal_mild_mod, 3 * renal_severe)
        + GREATEST(2 * malignancy, 6 * metastatic)
        + GREATEST(
            3 * hiv,
            CASE WHEN hiv = 1 AND aids_oi = 1 THEN 6 ELSE 0 END
          )
    )::int AS charlson_index
FROM feature_cci_flags;

/* source vocabulary 및 코드 정규화 상태 확인용 품질 테이블 */
DROP TABLE IF EXISTS feature_cci_source_quality;
CREATE TEMP TABLE feature_cci_source_quality AS
SELECT
    code_system,
    COUNT(*) AS n_diagnosis,
    COUNT(*) FILTER (WHERE normalized_code IS NULL OR normalized_code = '') AS n_code_missing
FROM feature_cci_diagnosis_normalized
GROUP BY code_system;

/* Alcohol */

DROP TABLE IF EXISTS feature_alcohol;
CREATE TEMP TABLE feature_alcohol AS
WITH alc_raw AS (
    SELECT
        f.person_id,
        o.observation_concept_id,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY o.observation_date DESC, o.observation_id DESC
        ) AS rn  
    FROM final_flag f
    JOIN observation o ON o.person_id = f.person_id
    WHERE o.observation_concept_id IN (
            4022664,  -- Non-drinker
            4074035,  -- Current drinker
            4220362   -- Ex-drinker
        )
      AND o.observation_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
)
SELECT
    person_id,
    CASE 
        WHEN observation_concept_id = 4074035 THEN 1
        ELSE 0
    END AS current_drinker_flag
FROM alc_raw
WHERE rn = 1;

/* Smoking */

DROP TABLE IF EXISTS feature_smoking;
CREATE TEMP TABLE feature_smoking AS
WITH smoke_raw AS (
    SELECT
        f.person_id,
        o.observation_concept_id,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY o.observation_date DESC, o.observation_id DESC
        ) AS rn   
    FROM final_flag f
    JOIN observation o ON o.person_id = f.person_id
    WHERE o.observation_concept_id IN (
            4222303,  -- Non-smoker
            40766945, -- Current smoker
            4310250   -- Ex-smoker
        )
      AND o.observation_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date           
)
SELECT
    person_id,
    CASE 
        WHEN observation_concept_id = 40766945 THEN 1
        ELSE 0
    END AS current_smoker_flag
FROM smoke_raw
WHERE rn = 1;

/* ==========================================
   Part 2
   ========================================== */


DROP TABLE IF EXISTS concept_seed;
CREATE TEMP TABLE concept_seed (
    set_name TEXT,
    concept_id INT,
    include_descendants BOOLEAN
);

INSERT INTO concept_seed (set_name, concept_id, include_descendants) VALUES
    ('AMIODARONE', 19133832, TRUE),
    ('AMIODARONE', 41349044, TRUE),
    ('AMIODARONE', 1309944,  TRUE),
    ('AMIODARONE', 40007699, TRUE);

DROP TABLE IF EXISTS concept_set;
CREATE TEMP TABLE concept_set AS
SELECT
    cs.set_name,
    ca.descendant_concept_id AS concept_id
FROM concept_seed cs
JOIN concept_ancestor ca
  ON cs.concept_id = ca.ancestor_concept_id
 AND cs.include_descendants = TRUE
UNION
SELECT
    cs.set_name,
    cs.concept_id
FROM concept_seed cs;



DROP TABLE IF EXISTS tmp_amio_strength;
CREATE TEMP TABLE tmp_amio_strength AS
SELECT
  ds.drug_concept_id,
  MAX(
    CASE
      /* 1) amount_value 기반 (정제/캡슐에서 보통 이게 채워짐) */
      WHEN ds.amount_value IS NOT NULL THEN
        CASE
          WHEN LOWER(au.concept_name) LIKE '%microgram%' OR LOWER(au.concept_code) IN ('mcg','ug') THEN ds.amount_value / 1000.0
          WHEN LOWER(au.concept_name) LIKE '%milligram%' OR LOWER(au.concept_code) IN ('mg')      THEN ds.amount_value
          WHEN LOWER(au.concept_name) LIKE '%gram%'      OR LOWER(au.concept_code) IN ('g')       THEN ds.amount_value * 1000.0
          ELSE NULL
        END

      /* 2) numerator/denominator 기반 (일부 데이터는 이 형태) */
      WHEN ds.numerator_value IS NOT NULL
       AND COALESCE(ds.denominator_value, 1) > 0
       AND (
            LOWER(du.concept_name) LIKE '%tablet%'
         OR LOWER(du.concept_name) LIKE '%capsule%'
         OR LOWER(du.concept_name) LIKE '%each%'
         OR LOWER(du.concept_name) LIKE '%pill%'
       )
      THEN
        (
          CASE
            WHEN LOWER(nu.concept_name) LIKE '%microgram%' OR LOWER(nu.concept_code) IN ('mcg','ug') THEN ds.numerator_value / 1000.0
            WHEN LOWER(nu.concept_name) LIKE '%milligram%' OR LOWER(nu.concept_code) IN ('mg')      THEN ds.numerator_value
            WHEN LOWER(nu.concept_name) LIKE '%gram%'      OR LOWER(nu.concept_code) IN ('g')       THEN ds.numerator_value * 1000.0
            ELSE NULL
          END
        ) / COALESCE(ds.denominator_value, 1)

      ELSE NULL
    END
  ) AS strength_mg_per_unit
FROM drug_strength ds
LEFT JOIN concept au ON au.concept_id = ds.amount_unit_concept_id
LEFT JOIN concept nu ON nu.concept_id = ds.numerator_unit_concept_id
LEFT JOIN concept du ON du.concept_id = ds.denominator_unit_concept_id
WHERE ds.ingredient_concept_id = 1309944
GROUP BY ds.drug_concept_id;


DROP TABLE IF EXISTS feature_amio_rx_unit;
CREATE TEMP TABLE feature_amio_rx_unit AS
WITH base AS (
  SELECT
      f.person_id,
      d.drug_exposure_id,
      d.drug_concept_id,

      f.index_date::date AS index_date,
      -- 모든 종단 특징은 AITD 발생 구간 직전 또는 실제 관찰 종료까지만 사용한다.
      f.feature_cutoff_date::date AS censor_date,

      d.drug_exposure_start_date::date AS rx_start_date,
      COALESCE(
        d.drug_exposure_end_date::date,
        (d.drug_exposure_start_date::date
          + (GREATEST(COALESCE(d.days_supply, 1), 1) - 1) * INTERVAL '1 day')::date
      ) AS rx_end_date,

      d.quantity::numeric AS quantity_total,
      s.strength_mg_per_unit
  FROM final_flag f
  JOIN drug_exposure d
    ON d.person_id = f.person_id
  JOIN concept_set cs
    ON cs.set_name='AMIODARONE'
   AND cs.concept_id = d.drug_concept_id
  LEFT JOIN tmp_amio_strength s
    ON s.drug_concept_id = d.drug_concept_id
  WHERE d.drug_exposure_start_date::date >= f.index_date::date
    AND d.drug_exposure_start_date::date <= f.feature_cutoff_date::date
),
calc AS (
  SELECT
      b.*,
      GREATEST(b.rx_start_date, b.index_date) AS win_start_date,
      LEAST(b.rx_end_date, b.censor_date)     AS win_end_date,
      (b.rx_end_date - b.rx_start_date + 1)   AS orig_days
  FROM base b
)
SELECT
    person_id,
    drug_exposure_id,
    drug_concept_id,

    rx_start_date,
    rx_end_date,

    CASE WHEN win_end_date >= win_start_date
      THEN (win_end_date - win_start_date + 1)
      ELSE 0
    END AS duration_days,

    strength_mg_per_unit,
    quantity_total,

    /* quantity_in_window는 최종 컬럼에서 제외하고, dose 계산에만 내부적으로 사용 */
    CASE
      WHEN strength_mg_per_unit IS NOT NULL AND quantity_total IS NOT NULL THEN
        (
          CASE
            WHEN orig_days > 0 AND win_end_date >= win_start_date
              THEN quantity_total * ((win_end_date - win_start_date + 1)::numeric / orig_days::numeric)
            ELSE 0
          END
        ) * strength_mg_per_unit
      ELSE NULL
    END AS dose_mg_in_window,

    CASE
      WHEN strength_mg_per_unit IS NOT NULL AND quantity_total IS NOT NULL THEN
        (
          (
            CASE
              WHEN orig_days > 0 AND win_end_date >= win_start_date
                THEN quantity_total * ((win_end_date - win_start_date + 1)::numeric / orig_days::numeric)
              ELSE 0
            END
          ) * strength_mg_per_unit
        ) / 1000.0
      ELSE NULL
    END AS dose_g_in_window
FROM calc
WHERE win_end_date >= win_start_date;
 
 

/* Cumulative_dose_g */

DROP TABLE IF EXISTS feature_amio_cumulative_dose;
CREATE TEMP TABLE feature_amio_cumulative_dose AS
SELECT
  person_id,
  /*
     quantity와 strength가 모두 있어 용량 계산이 가능한 처방만 합산한다.
     모든 처방의 용량이 계산 불가능하면 SUM 결과는 NULL이다.
     누락 정도는 feature_amio_data_quality에서 별도로 확인한다.
  */
  SUM(dose_g_in_window) AS cumulative_dose_g
FROM feature_amio_rx_unit
GROUP BY person_id;

/* 아미오다론 용량 계산 가능성 확인용 품질 변수 */
DROP TABLE IF EXISTS feature_amio_data_quality;
CREATE TEMP TABLE feature_amio_data_quality AS
SELECT
  person_id,
  COUNT(*) AS amio_rx_count,
  SUM(CASE WHEN quantity_total IS NULL THEN 1 ELSE 0 END) AS amio_quantity_missing_count,
  SUM(CASE WHEN strength_mg_per_unit IS NULL THEN 1 ELSE 0 END) AS amio_strength_missing_count,
  SUM(CASE WHEN dose_g_in_window IS NOT NULL THEN 1 ELSE 0 END) AS amio_dose_calculable_count,
  CASE
    WHEN COUNT(*) > 0
    THEN SUM(CASE WHEN dose_g_in_window IS NOT NULL THEN 1 ELSE 0 END)::numeric / COUNT(*)::numeric
    ELSE NULL
  END AS amio_dose_calculable_ratio
FROM feature_amio_rx_unit
GROUP BY person_id;

/* Aver_dose_kg */

DROP TABLE IF EXISTS feature_amio_aver_dose_kg;
CREATE TEMP TABLE feature_amio_aver_dose_kg AS
SELECT
  f.person_id,
  CASE
    WHEN w.weight_kg > 0 THEN c.cumulative_dose_g / w.weight_kg
    ELSE NULL
  END AS aver_dose_g_per_kg
FROM final_flag f
LEFT JOIN feature_amio_cumulative_dose c ON c.person_id = f.person_id
LEFT JOIN feature_weight w              ON w.person_id = f.person_id;

/* Duration */

DROP TABLE IF EXISTS feature_amio_duration_span;
CREATE TEMP TABLE feature_amio_duration_span AS
WITH win AS (
  SELECT
    r.person_id,
    GREATEST(r.rx_start_date, f.index_date::date) AS win_start,
    LEAST(r.rx_end_date, f.feature_cutoff_date::date) AS win_end
  FROM feature_amio_rx_unit r
  JOIN final_flag f
    ON f.person_id = r.person_id
  WHERE LEAST(r.rx_end_date, f.feature_cutoff_date::date)
        >=
        GREATEST(r.rx_start_date, f.index_date::date)
)
SELECT
  person_id,
  (MAX(win_end) - MIN(win_start) + 1)::int AS duration_span_days
FROM win
GROUP BY person_id;

/* Sum days */

DROP TABLE IF EXISTS feature_amio_sum_days;
CREATE TEMP TABLE feature_amio_sum_days AS
WITH ordered_rx AS (
  SELECT
    r.person_id,
    GREATEST(r.rx_start_date, f.index_date::date) AS rx_start_date,
    LEAST(r.rx_end_date, f.feature_cutoff_date::date) AS rx_end_date,
    MAX(LEAST(r.rx_end_date, f.feature_cutoff_date::date)) OVER (
      PARTITION BY r.person_id
      ORDER BY GREATEST(r.rx_start_date, f.index_date::date),
               LEAST(r.rx_end_date, f.feature_cutoff_date::date)
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS previous_max_end
  FROM feature_amio_rx_unit r
  JOIN final_flag f ON f.person_id = r.person_id
), island_start AS (
  SELECT
    *,
    CASE
      WHEN previous_max_end IS NULL
        OR rx_start_date > previous_max_end + 1
      THEN 1 ELSE 0
    END AS new_island
  FROM ordered_rx
), island_id AS (
  SELECT
    *,
    SUM(new_island) OVER (
      PARTITION BY person_id
      ORDER BY rx_start_date, rx_end_date
      ROWS UNBOUNDED PRECEDING
    ) AS exposure_island
  FROM island_start
), merged_rx AS (
  SELECT
    person_id,
    exposure_island,
    MIN(rx_start_date) AS merged_start,
    MAX(rx_end_date) AS merged_end
  FROM island_id
  GROUP BY person_id, exposure_island
)
SELECT
  person_id,
  SUM(merged_end - merged_start + 1)::int AS sum_days
FROM merged_rx
GROUP BY person_id;

/*
   PDD 분모용 치료일수
   누적용량의 분자와 범위를 맞추기 위해 용량 계산이 가능한 처방만 병합한다.
   최종 feature인 sum_days는 위에서 계산한 전체 치료일수를 그대로 사용한다.
*/
DROP TABLE IF EXISTS feature_amio_calculable_sum_days;
CREATE TEMP TABLE feature_amio_calculable_sum_days AS
WITH ordered_rx AS (
  SELECT
    r.person_id,
    GREATEST(r.rx_start_date, f.index_date::date) AS rx_start_date,
    LEAST(r.rx_end_date, f.feature_cutoff_date::date) AS rx_end_date,
    MAX(LEAST(r.rx_end_date, f.feature_cutoff_date::date)) OVER (
      PARTITION BY r.person_id
      ORDER BY GREATEST(r.rx_start_date, f.index_date::date),
               LEAST(r.rx_end_date, f.feature_cutoff_date::date)
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS previous_max_end
  FROM feature_amio_rx_unit r
  JOIN final_flag f ON f.person_id = r.person_id
  WHERE r.dose_g_in_window IS NOT NULL
), island_start AS (
  SELECT
    *,
    CASE
      WHEN previous_max_end IS NULL
        OR rx_start_date > previous_max_end + 1
      THEN 1 ELSE 0
    END AS new_island
  FROM ordered_rx
), island_id AS (
  SELECT
    *,
    SUM(new_island) OVER (
      PARTITION BY person_id
      ORDER BY rx_start_date, rx_end_date
      ROWS UNBOUNDED PRECEDING
    ) AS exposure_island
  FROM island_start
), merged_rx AS (
  SELECT
    person_id,
    exposure_island,
    MIN(rx_start_date) AS merged_start,
    MAX(rx_end_date) AS merged_end
  FROM island_id
  GROUP BY person_id, exposure_island
)
SELECT
  person_id,
  SUM(merged_end - merged_start + 1)::int AS calculable_sum_days
FROM merged_rx
GROUP BY person_id;

/* PDD */

DROP TABLE IF EXISTS feature_amio_pdd;
CREATE TEMP TABLE feature_amio_pdd AS
SELECT
  f.person_id,
  CASE
    WHEN s.calculable_sum_days > 0
    THEN c.cumulative_dose_g / s.calculable_sum_days
    ELSE NULL
  END AS pdd_g_per_day
FROM final_flag f
LEFT JOIN feature_amio_cumulative_dose c ON c.person_id = f.person_id
LEFT JOIN feature_amio_calculable_sum_days s ON s.person_id = f.person_id;

/* ==========================================
   Part 3
   ========================================== */

/*
   병용약물과 동반질환을 검사실 값과 동일한 시간구간으로 수집하기 위한 공통 구간표.

   - base: index_date 이전 1년부터 index_date까지
   - 추적구간: 앞 경계 초과, 뒤 경계 이하
   - feature_cutoff_date가 구간 중간이면 관찰된 부분까지만 사용
   - cutoff 이후 시작하는 구간은 available_flag=0이며 최종 feature는 NULL
*/
DROP TABLE IF EXISTS feature_dynamic_windows;
CREATE TEMP TABLE feature_dynamic_windows AS
SELECT
    f.person_id,
    w.time_point,
    w.window_order,
    (f.index_date - INTERVAL '1 year')::date AS baseline_start_date,
    w.window_start_date,
    w.window_end_date,
    LEAST(w.window_end_date, f.feature_cutoff_date::date) AS observed_window_end_date,
    w.include_start,
    CASE
        WHEN w.time_point = 'base' THEN 1
        WHEN f.feature_cutoff_date::date > w.window_start_date THEN 1
        ELSE 0
    END AS available_flag
FROM final_flag f
CROSS JOIN LATERAL (
  VALUES
    ('base', 0, (f.index_date - INTERVAL '1 year')::date, f.index_date::date, TRUE),
    ('m1', 1, f.index_date::date, (f.index_date + INTERVAL '1 month')::date, FALSE),
    ('m2', 2, (f.index_date + INTERVAL '1 month')::date, (f.index_date + INTERVAL '2 month')::date, FALSE),
    ('m3', 3, (f.index_date + INTERVAL '2 month')::date, (f.index_date + INTERVAL '3 month')::date, FALSE),
    ('m4_6', 4, (f.index_date + INTERVAL '3 month')::date, (f.index_date + INTERVAL '6 month')::date, FALSE),
    ('m7_9', 5, (f.index_date + INTERVAL '6 month')::date, (f.index_date + INTERVAL '9 month')::date, FALSE),
    ('m10_12', 6, (f.index_date + INTERVAL '9 month')::date, (f.index_date + INTERVAL '12 month')::date, FALSE),
    ('m13_15', 7, (f.index_date + INTERVAL '12 month')::date, (f.index_date + INTERVAL '15 month')::date, FALSE),
    ('m16_18', 8, (f.index_date + INTERVAL '15 month')::date, (f.index_date + INTERVAL '18 month')::date, FALSE),
    ('m19_21', 9, (f.index_date + INTERVAL '18 month')::date, (f.index_date + INTERVAL '21 month')::date, FALSE),
    ('m22_24', 10, (f.index_date + INTERVAL '21 month')::date, (f.index_date + INTERVAL '24 month')::date, FALSE)
) AS w(time_point, window_order, window_start_date, window_end_date, include_start);


DROP TABLE IF EXISTS rx_feature_concept_seed;
CREATE TEMP TABLE rx_feature_concept_seed (
    set_name   text,
    concept_id bigint
) ON COMMIT PRESERVE ROWS;

DELETE FROM rx_feature_concept_seed
WHERE set_name IN (
'rx_TKIs','rx_allopurinol','rx_antipsychotic','rx_NSAID','rx_antiDMs','rx_metformin','rx_propafenone'
);

WITH seeds AS (
  SELECT * FROM (VALUES
    -- TKIs: ATC가 미기재라서 보통 TKI들이 속한 ATC 그룹(L01E: Protein kinase inhibitors)로 시딩
    ('rx_TKIs',              'L01E',    NULL),

    ('rx_allopurinol',       'M04AA01', NULL),
    ('rx_antipsychotic',     'N05A',    NULL),

    -- NSAID: M01A 전체에서 glucosamine(M01AX05) 제외
    ('rx_NSAID',             'M01A',    'M01AX05'),

    -- Anti-diabetics: 요청하신 ATC 코드들
    ('rx_antiDMs',           'A10BB',   NULL),
    ('rx_antiDMs',           'A10BD',   NULL),
    ('rx_antiDMs',           'A10BF',   NULL),
    ('rx_antiDMs',           'A10BG',   NULL),
    ('rx_antiDMs',           'A10BH',   NULL),
    ('rx_antiDMs',           'A10BJ',   NULL),
    ('rx_antiDMs',           'A10BK',   NULL),
    ('rx_antiDMs',           'A10BX',   NULL),

    -- 메트포르민(사용자 표): A10BD07 (조합제 코드일 수 있어 ingredient 필터링을 별도로 함)
    ('rx_metformin',         'A10BD07', NULL),

    -- Propafenone
    ('rx_propafenone',       'C01BC03', NULL)
  ) AS v(set_name, atc_code, exclude_atc_code)
),

/* seed ATC code -> seed concept_id */
atc_seed AS (
  SELECT s.set_name, s.atc_code, s.exclude_atc_code, c.concept_id AS atc_concept_id
  FROM seeds s
  JOIN concept c
    ON c.vocabulary_id = 'ATC'
   AND c.concept_code  = s.atc_code
),

/* seed ATC concept_id -> all descendant ATC 5th-level concepts */
atc_5th AS (
  SELECT a.set_name,
         d.concept_id   AS atc5_id,
         d.concept_code AS atc5_code
  FROM atc_seed a
  JOIN concept_ancestor ca
    ON ca.ancestor_concept_id = a.atc_concept_id
  JOIN concept d
    ON d.concept_id = ca.descendant_concept_id
  WHERE d.vocabulary_id = 'ATC'
    AND d.concept_class_id = 'ATC 5th'
),

/* NSAID에서 glucosamine(M01AX05) 제외 */
filtered_atc AS (
  SELECT *
  FROM atc_5th
  WHERE NOT (
    set_name = 'rx_NSAID'
    AND atc5_code LIKE 'M01AX05%'
  )
),

/* ATC 5th -> RxNorm/RxNorm Extension Ingredient(±Precise Ingredient) */
rx_ing AS (
  SELECT f.set_name, rx.concept_id, rx.concept_name, rx.concept_class_id, rx.vocabulary_id
  FROM filtered_atc f
  JOIN concept_relationship cr
    ON cr.concept_id_1 = f.atc5_id
   AND cr.relationship_id IN ('ATC - RxNorm pr lat', 'ATC - RxNorm')
   AND cr.invalid_reason IS NULL
  JOIN concept rx
    ON rx.concept_id = cr.concept_id_2
   AND rx.standard_concept = 'S'
   AND rx.domain_id = 'Drug'
   AND rx.vocabulary_id IN ('RxNorm', 'RxNorm Extension')
   AND rx.concept_class_id IN ('Ingredient', 'Precise Ingredient')
   AND rx.invalid_reason IS NULL
),

/* metformin은 set_name 단위로 "metformin"만 남기도록 보정(조합제 ATC에서 딸려오는 타 성분 제거) */
final_seed AS (
  SELECT DISTINCT set_name, concept_id
  FROM rx_ing
  WHERE set_name <> 'rx_metformin'

  UNION ALL

  SELECT 'rx_metformin' AS set_name, c.concept_id
  FROM concept c
  WHERE c.standard_concept = 'S'
    AND c.domain_id = 'Drug'
    AND c.vocabulary_id IN ('RxNorm', 'RxNorm Extension')
    AND c.concept_class_id = 'Ingredient'
    AND lower(c.concept_name) = 'metformin'
)

INSERT INTO rx_feature_concept_seed (set_name, concept_id)
SELECT set_name, concept_id
FROM final_seed
-- 테이블에 (set_name, concept_id) 유니크 제약이 있으면 아래 ON CONFLICT 사용 가능
ON CONFLICT DO NOTHING;

DROP TABLE IF EXISTS rx_feature_concept_set;
CREATE TEMP TABLE rx_feature_concept_set AS
SELECT DISTINCT
    cs.set_name,
    ca.descendant_concept_id AS concept_id
FROM rx_feature_concept_seed cs
JOIN concept_ancestor ca
  ON ca.ancestor_concept_id = cs.concept_id
JOIN concept c
  ON c.concept_id = ca.descendant_concept_id
WHERE cs.concept_id IS NOT NULL
  AND c.invalid_reason IS NULL;

/* 인덱스 이전 1년 병용약물 현황 확인용 baseline audit */
DROP TABLE IF EXISTS feature_rx_baseline_audit;
CREATE TEMP TABLE feature_rx_baseline_audit AS
SELECT
    f.person_id,
    MAX(CASE WHEN cs.set_name = 'rx_TKIs' THEN 1 ELSE 0 END) AS rx_tkis_flag,
    MAX(CASE WHEN cs.set_name = 'rx_allopurinol' THEN 1 ELSE 0 END) AS rx_allopurinol_flag,
    MAX(CASE WHEN cs.set_name = 'rx_antipsychotic' THEN 1 ELSE 0 END) AS rx_antipsychotic_flag,
    MAX(CASE WHEN cs.set_name = 'rx_NSAID' THEN 1 ELSE 0 END) AS rx_nsaid_flag,
    MAX(CASE WHEN cs.set_name = 'rx_antiDMs' THEN 1 ELSE 0 END) AS rx_antidms_flag,
    MAX(CASE WHEN cs.set_name = 'rx_metformin' THEN 1 ELSE 0 END) AS rx_metformin_flag,
    MAX(CASE WHEN cs.set_name = 'rx_propafenone' THEN 1 ELSE 0 END) AS rx_propafenone_flag
FROM final_flag f
LEFT JOIN drug_exposure de ON f.person_id = de.person_id
    -- 인덱스일 전 1년 이내 기록 필터링
    AND de.drug_exposure_start_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
LEFT JOIN rx_feature_concept_set cs ON de.drug_concept_id = cs.concept_id
GROUP BY f.person_id;


SELECT 'rx_TKIs'              AS set_name, SUM(rx_tkis_flag)         AS n_persons FROM feature_rx_baseline_audit
UNION ALL
SELECT 'rx_allopurinol',                     SUM(rx_allopurinol_flag)            FROM feature_rx_baseline_audit
UNION ALL
SELECT 'rx_antipsychotic',                   SUM(rx_antipsychotic_flag)          FROM feature_rx_baseline_audit
UNION ALL
SELECT 'rx_NSAID',                           SUM(rx_nsaid_flag)                  FROM feature_rx_baseline_audit
UNION ALL
SELECT 'rx_antiDMs',                         SUM(rx_antidms_flag)                FROM feature_rx_baseline_audit
UNION ALL
SELECT 'rx_metformin',                       SUM(rx_metformin_flag)              FROM feature_rx_baseline_audit
UNION ALL
SELECT 'rx_propafenone',                     SUM(rx_propafenone_flag)            FROM feature_rx_baseline_audit
ORDER BY set_name;


/* ------------------------------------------------------------------------
   병용약물의 구간별 동적 feature

   해당 약물의 처방 노출기간이 각 구간과 하루라도 겹치면 1, 없으면 0이다.
   따라서 앞 구간에서 시작해 다음 구간까지 이어지는 장기 처방도 반영한다.
   환자가 해당 구간에 전혀 도달하지 못한 경우에는 NULL로 둔다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS feature_rx_dynamic_long;
CREATE TEMP TABLE feature_rx_dynamic_long AS
WITH rx_names(set_name) AS (
  VALUES
      ('rx_TKIs'),
      ('rx_allopurinol'),
      ('rx_antipsychotic'),
      ('rx_NSAID'),
      ('rx_antiDMs'),
      ('rx_metformin'),
      ('rx_propafenone')
)
SELECT
    w.person_id,
    w.time_point,
    w.window_order,
    n.set_name,
    CASE
        WHEN w.available_flag = 0 THEN NULL
        ELSE MAX(CASE WHEN cs.concept_id IS NOT NULL THEN 1 ELSE 0 END)
    END AS feature_flag
FROM feature_dynamic_windows w
CROSS JOIN rx_names n
LEFT JOIN drug_exposure de
  ON de.person_id = w.person_id
 AND w.available_flag = 1
 AND (
        (
            w.include_start = TRUE
        AND COALESCE(
                de.drug_exposure_end_date,
                de.drug_exposure_start_date
                  + (GREATEST(COALESCE(de.days_supply, 1), 1) - 1) * INTERVAL '1 day'
            ) >= w.window_start_date
        )
     OR (
            w.include_start = FALSE
        AND COALESCE(
                de.drug_exposure_end_date,
                de.drug_exposure_start_date
                  + (GREATEST(COALESCE(de.days_supply, 1), 1) - 1) * INTERVAL '1 day'
            ) > w.window_start_date
        )
 )
 AND de.drug_exposure_start_date <= w.observed_window_end_date
LEFT JOIN rx_feature_concept_set cs
  ON cs.concept_id = de.drug_concept_id
 AND cs.set_name = n.set_name
GROUP BY
    w.person_id,
    w.time_point,
    w.window_order,
    w.available_flag,
    n.set_name;

DROP TABLE IF EXISTS feature_rx_dynamic_wide;
CREATE TEMP TABLE feature_rx_dynamic_wide AS
SELECT
    person_id,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'base' THEN feature_flag END) AS rx_tkis_base,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm1' THEN feature_flag END) AS rx_tkis_m1,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm2' THEN feature_flag END) AS rx_tkis_m2,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm3' THEN feature_flag END) AS rx_tkis_m3,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm4_6' THEN feature_flag END) AS rx_tkis_m4_6,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm7_9' THEN feature_flag END) AS rx_tkis_m7_9,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm10_12' THEN feature_flag END) AS rx_tkis_m10_12,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm13_15' THEN feature_flag END) AS rx_tkis_m13_15,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm16_18' THEN feature_flag END) AS rx_tkis_m16_18,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm19_21' THEN feature_flag END) AS rx_tkis_m19_21,
    MAX(CASE WHEN set_name = 'rx_TKIs' AND time_point = 'm22_24' THEN feature_flag END) AS rx_tkis_m22_24,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'base' THEN feature_flag END) AS rx_allopurinol_base,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm1' THEN feature_flag END) AS rx_allopurinol_m1,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm2' THEN feature_flag END) AS rx_allopurinol_m2,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm3' THEN feature_flag END) AS rx_allopurinol_m3,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm4_6' THEN feature_flag END) AS rx_allopurinol_m4_6,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm7_9' THEN feature_flag END) AS rx_allopurinol_m7_9,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm10_12' THEN feature_flag END) AS rx_allopurinol_m10_12,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm13_15' THEN feature_flag END) AS rx_allopurinol_m13_15,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm16_18' THEN feature_flag END) AS rx_allopurinol_m16_18,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm19_21' THEN feature_flag END) AS rx_allopurinol_m19_21,
    MAX(CASE WHEN set_name = 'rx_allopurinol' AND time_point = 'm22_24' THEN feature_flag END) AS rx_allopurinol_m22_24,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'base' THEN feature_flag END) AS rx_antipsychotic_base,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm1' THEN feature_flag END) AS rx_antipsychotic_m1,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm2' THEN feature_flag END) AS rx_antipsychotic_m2,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm3' THEN feature_flag END) AS rx_antipsychotic_m3,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm4_6' THEN feature_flag END) AS rx_antipsychotic_m4_6,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm7_9' THEN feature_flag END) AS rx_antipsychotic_m7_9,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm10_12' THEN feature_flag END) AS rx_antipsychotic_m10_12,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm13_15' THEN feature_flag END) AS rx_antipsychotic_m13_15,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm16_18' THEN feature_flag END) AS rx_antipsychotic_m16_18,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm19_21' THEN feature_flag END) AS rx_antipsychotic_m19_21,
    MAX(CASE WHEN set_name = 'rx_antipsychotic' AND time_point = 'm22_24' THEN feature_flag END) AS rx_antipsychotic_m22_24,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'base' THEN feature_flag END) AS rx_nsaid_base,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm1' THEN feature_flag END) AS rx_nsaid_m1,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm2' THEN feature_flag END) AS rx_nsaid_m2,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm3' THEN feature_flag END) AS rx_nsaid_m3,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm4_6' THEN feature_flag END) AS rx_nsaid_m4_6,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm7_9' THEN feature_flag END) AS rx_nsaid_m7_9,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm10_12' THEN feature_flag END) AS rx_nsaid_m10_12,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm13_15' THEN feature_flag END) AS rx_nsaid_m13_15,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm16_18' THEN feature_flag END) AS rx_nsaid_m16_18,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm19_21' THEN feature_flag END) AS rx_nsaid_m19_21,
    MAX(CASE WHEN set_name = 'rx_NSAID' AND time_point = 'm22_24' THEN feature_flag END) AS rx_nsaid_m22_24,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'base' THEN feature_flag END) AS rx_antidms_base,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm1' THEN feature_flag END) AS rx_antidms_m1,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm2' THEN feature_flag END) AS rx_antidms_m2,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm3' THEN feature_flag END) AS rx_antidms_m3,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm4_6' THEN feature_flag END) AS rx_antidms_m4_6,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm7_9' THEN feature_flag END) AS rx_antidms_m7_9,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm10_12' THEN feature_flag END) AS rx_antidms_m10_12,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm13_15' THEN feature_flag END) AS rx_antidms_m13_15,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm16_18' THEN feature_flag END) AS rx_antidms_m16_18,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm19_21' THEN feature_flag END) AS rx_antidms_m19_21,
    MAX(CASE WHEN set_name = 'rx_antiDMs' AND time_point = 'm22_24' THEN feature_flag END) AS rx_antidms_m22_24,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'base' THEN feature_flag END) AS rx_metformin_base,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm1' THEN feature_flag END) AS rx_metformin_m1,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm2' THEN feature_flag END) AS rx_metformin_m2,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm3' THEN feature_flag END) AS rx_metformin_m3,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm4_6' THEN feature_flag END) AS rx_metformin_m4_6,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm7_9' THEN feature_flag END) AS rx_metformin_m7_9,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm10_12' THEN feature_flag END) AS rx_metformin_m10_12,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm13_15' THEN feature_flag END) AS rx_metformin_m13_15,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm16_18' THEN feature_flag END) AS rx_metformin_m16_18,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm19_21' THEN feature_flag END) AS rx_metformin_m19_21,
    MAX(CASE WHEN set_name = 'rx_metformin' AND time_point = 'm22_24' THEN feature_flag END) AS rx_metformin_m22_24,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'base' THEN feature_flag END) AS rx_propafenone_base,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm1' THEN feature_flag END) AS rx_propafenone_m1,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm2' THEN feature_flag END) AS rx_propafenone_m2,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm3' THEN feature_flag END) AS rx_propafenone_m3,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm4_6' THEN feature_flag END) AS rx_propafenone_m4_6,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm7_9' THEN feature_flag END) AS rx_propafenone_m7_9,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm10_12' THEN feature_flag END) AS rx_propafenone_m10_12,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm13_15' THEN feature_flag END) AS rx_propafenone_m13_15,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm16_18' THEN feature_flag END) AS rx_propafenone_m16_18,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm19_21' THEN feature_flag END) AS rx_propafenone_m19_21,
    MAX(CASE WHEN set_name = 'rx_propafenone' AND time_point = 'm22_24' THEN feature_flag END) AS rx_propafenone_m22_24
FROM feature_rx_dynamic_long
GROUP BY person_id;

/* 구간별 병용약물 양성 환자 수 확인용 */
SELECT
    set_name,
    time_point,
    SUM(feature_flag) AS n_persons,
    COUNT(feature_flag) AS n_observed
FROM feature_rx_dynamic_long
GROUP BY set_name, time_point
ORDER BY set_name, MIN(window_order);



/* ==========================================
   Part 4
   ========================================== */

DROP TABLE IF EXISTS dx_code_seed;
CREATE TEMP TABLE dx_code_seed (
  set_name       TEXT,
  vocabulary_id  TEXT,
  code_prefix    TEXT
);

INSERT INTO dx_code_seed VALUES
-- bradycardia
('dx_bradycardia','ICD9CM','427.81'),
('dx_bradycardia','ICD10CM','I49.5'),
('dx_bradycardia','ICD10CM','R00.1'),
('dx_bradycardia','KCD7','I49.5'),
('dx_bradycardia','KCD7','R00.1'),

-- goiter
('dx_goiter','ICD9CM','240'),
('dx_goiter','ICD9CM','241'),
('dx_goiter','ICD10CM','E01'),
('dx_goiter','ICD10CM','E04'),
('dx_goiter','KCD7','E01'),
('dx_goiter','KCD7','E04'),

-- anemia (prefix로 잡으면 D50~D64 전부 포함)
('dx_anemia','ICD9CM','280'),
('dx_anemia','ICD9CM','281'),
('dx_anemia','ICD9CM','282'),
('dx_anemia','ICD9CM','283'),
('dx_anemia','ICD9CM','284'),
('dx_anemia','ICD9CM','285'),
('dx_anemia','ICD10CM','D50'),
('dx_anemia','ICD10CM','D51'),
('dx_anemia','ICD10CM','D52'),
('dx_anemia','ICD10CM','D53'),
('dx_anemia','ICD10CM','D55'),
('dx_anemia','ICD10CM','D57'),
('dx_anemia','ICD10CM','D58'),
('dx_anemia','ICD10CM','D59'),
('dx_anemia','ICD10CM','D60'),
('dx_anemia','ICD10CM','D61'),
('dx_anemia','ICD10CM','D63'),
('dx_anemia','ICD10CM','D64'),
('dx_anemia','KCD7','D50'),
('dx_anemia','KCD7','D51'),
('dx_anemia','KCD7','D52'),
('dx_anemia','KCD7','D53'),
('dx_anemia','KCD7','D55'),
('dx_anemia','KCD7','D57'),
('dx_anemia','KCD7','D58'),
('dx_anemia','KCD7','D59'),
('dx_anemia','KCD7','D60'),
('dx_anemia','KCD7','D61'),
('dx_anemia','KCD7','D63'),
('dx_anemia','KCD7','D64'),

-- hypertension
('dx_hypertension','ICD9CM','401'),
('dx_hypertension','ICD9CM','402'),
('dx_hypertension','ICD9CM','403'),
('dx_hypertension','ICD9CM','404'),
('dx_hypertension','ICD9CM','405'),
('dx_hypertension','ICD10CM','I10'),
('dx_hypertension','ICD10CM','I11'),
('dx_hypertension','ICD10CM','I12'),
('dx_hypertension','ICD10CM','I13'),
('dx_hypertension','ICD10CM','I15'),
('dx_hypertension','KCD7','I10'),
('dx_hypertension','KCD7','I11'),
('dx_hypertension','KCD7','I12'),
('dx_hypertension','KCD7','I13'),
('dx_hypertension','KCD7','I15'),

-- diabetes
('dx_diabetes','ICD9CM','250'),
('dx_diabetes','ICD10CM','E08'),
('dx_diabetes','ICD10CM','E09'),
('dx_diabetes','ICD10CM','E10'),
('dx_diabetes','ICD10CM','E11'),
('dx_diabetes','ICD10CM','E13'),
('dx_diabetes','ICD10CM','E14'),
('dx_diabetes','KCD7','E08'),
('dx_diabetes','KCD7','E09'),
('dx_diabetes','KCD7','E10'),
('dx_diabetes','KCD7','E11'),
('dx_diabetes','KCD7','E13'),
('dx_diabetes','KCD7','E14'),

-- diabetic nephropathy
('dx_dm_nephropathy','ICD9CM','250.4'),
('dx_dm_nephropathy','ICD10CM','E10.2'),
('dx_dm_nephropathy','ICD10CM','E11.2'),
('dx_dm_nephropathy','ICD10CM','E13.2'),
('dx_dm_nephropathy','KCD7','E10.2'),
('dx_dm_nephropathy','KCD7','E11.2'),
('dx_dm_nephropathy','KCD7','E13.2'),

-- gout
('dx_gouts','ICD9CM','274'),
('dx_gouts','ICD10CM','M10'),
('dx_gouts','KCD7','M10'),

-- rheumatoid arthritis
('dx_rheumatoid_arthritis','ICD9CM','714.0'),
('dx_rheumatoid_arthritis','ICD9CM','714.1'),
('dx_rheumatoid_arthritis','ICD9CM','714.2'),
('dx_rheumatoid_arthritis','ICD9CM','714.3'),
('dx_rheumatoid_arthritis','ICD10CM','M05'),
('dx_rheumatoid_arthritis','ICD10CM','M06'),
('dx_rheumatoid_arthritis','KCD7','M05'),
('dx_rheumatoid_arthritis','KCD7','M06'),

-- chronic renal failure
('dx_chronic_rf','ICD9CM','585'),
('dx_chronic_rf','ICD9CM','403'),
('dx_chronic_rf','ICD9CM','404'),
('dx_chronic_rf','ICD9CM','V45.1'),
('dx_chronic_rf','ICD9CM','996.7'),

('dx_chronic_rf','ICD10CM','N18'),
('dx_chronic_rf','ICD10CM','T82.4'),
('dx_chronic_rf','ICD10CM','Z49.2'),
('dx_chronic_rf','ICD10CM','Z99.2'),

('dx_chronic_rf','KCD7','N18'),
('dx_chronic_rf','KCD7','T82.4'),
('dx_chronic_rf','KCD7','Z49.2'),
('dx_chronic_rf','KCD7','Z99.2'),


-- renal dysfunction (broad)
('dx_renal_dysfunction','ICD9CM','580'),
('dx_renal_dysfunction','ICD9CM','581'),
('dx_renal_dysfunction','ICD9CM','582'),
('dx_renal_dysfunction','ICD9CM','583'),
('dx_renal_dysfunction','ICD9CM','585'),
('dx_renal_dysfunction','ICD9CM','586'),
('dx_renal_dysfunction','ICD9CM','587'),
('dx_renal_dysfunction','ICD9CM','588'),
('dx_renal_dysfunction','ICD9CM','589'),
('dx_renal_dysfunction','ICD9CM','590'),
('dx_renal_dysfunction','ICD9CM','593'),
('dx_renal_dysfunction','ICD9CM','753'),
('dx_renal_dysfunction','ICD9CM','996'),
('dx_renal_dysfunction','ICD9CM','403'),
('dx_renal_dysfunction','ICD9CM','404'),
('dx_renal_dysfunction','ICD9CM','405'),
('dx_renal_dysfunction','ICD9CM','250.3'),
('dx_renal_dysfunction','ICD9CM','250.4'),
('dx_renal_dysfunction','ICD10CM','N00'),
('dx_renal_dysfunction','ICD10CM','N01'),
('dx_renal_dysfunction','ICD10CM','N02'),
('dx_renal_dysfunction','ICD10CM','N03'),
('dx_renal_dysfunction','ICD10CM','N04'),
('dx_renal_dysfunction','ICD10CM','N05'),
('dx_renal_dysfunction','ICD10CM','N06'),
('dx_renal_dysfunction','ICD10CM','N07'),
('dx_renal_dysfunction','ICD10CM','N08'),
('dx_renal_dysfunction','ICD10CM','N11'),
('dx_renal_dysfunction','ICD10CM','N12'),
('dx_renal_dysfunction','ICD10CM','N14'),
('dx_renal_dysfunction','ICD10CM','N15'),
('dx_renal_dysfunction','ICD10CM','N16'),
('dx_renal_dysfunction','ICD10CM','N17'),
('dx_renal_dysfunction','ICD10CM','N18'),
('dx_renal_dysfunction','ICD10CM','N19'),
('dx_renal_dysfunction','ICD10CM','N25'),
('dx_renal_dysfunction','ICD10CM','N26'),
('dx_renal_dysfunction','ICD10CM','N27'),
('dx_renal_dysfunction','ICD10CM','N28'),
('dx_renal_dysfunction','ICD10CM','I12'),
('dx_renal_dysfunction','ICD10CM','I13'),
('dx_renal_dysfunction','ICD10CM','Q60'),
('dx_renal_dysfunction','ICD10CM','Q61'),
('dx_renal_dysfunction','ICD10CM','Q62'),
('dx_renal_dysfunction','ICD10CM','Q63'),
('dx_renal_dysfunction','ICD10CM','E10.2'),
('dx_renal_dysfunction','ICD10CM','E14.2'),
('dx_renal_dysfunction','ICD10CM','T82.4'),
('dx_renal_dysfunction','ICD10CM','T86.1'),
('dx_renal_dysfunction','ICD10CM','Z49'),
('dx_renal_dysfunction','ICD10CM','Z94.0'),
('dx_renal_dysfunction','ICD10CM','Z99.2'),
('dx_renal_dysfunction','KCD7','N00'),
('dx_renal_dysfunction','KCD7','N01'),
('dx_renal_dysfunction','KCD7','N02'),
('dx_renal_dysfunction','KCD7','N03'),
('dx_renal_dysfunction','KCD7','N04'),
('dx_renal_dysfunction','KCD7','N05'),
('dx_renal_dysfunction','KCD7','N06'),
('dx_renal_dysfunction','KCD7','N07'),
('dx_renal_dysfunction','KCD7','N08'),
('dx_renal_dysfunction','KCD7','N11'),
('dx_renal_dysfunction','KCD7','N12'),
('dx_renal_dysfunction','KCD7','N14'),
('dx_renal_dysfunction','KCD7','N15'),
('dx_renal_dysfunction','KCD7','N16'),
('dx_renal_dysfunction','KCD7','N17'),
('dx_renal_dysfunction','KCD7','N18'),
('dx_renal_dysfunction','KCD7','N19'),
('dx_renal_dysfunction','KCD7','N25'),
('dx_renal_dysfunction','KCD7','N26'),
('dx_renal_dysfunction','KCD7','N27'),
('dx_renal_dysfunction','KCD7','N28'),
('dx_renal_dysfunction','KCD7','I12'),
('dx_renal_dysfunction','KCD7','I13'),
('dx_renal_dysfunction','KCD7','Q60'),
('dx_renal_dysfunction','KCD7','Q61'),
('dx_renal_dysfunction','KCD7','Q62'),
('dx_renal_dysfunction','KCD7','Q63'),
('dx_renal_dysfunction','KCD7','E10.2'),
('dx_renal_dysfunction','KCD7','E14.2'),
('dx_renal_dysfunction','KCD7','T82.4'),
('dx_renal_dysfunction','KCD7','T86.1'),
('dx_renal_dysfunction','KCD7','Z49'),
('dx_renal_dysfunction','KCD7','Z94.0'),
('dx_renal_dysfunction','KCD7','Z99.2'),

-- diabetes with complications
('dx_dm_complications','ICD9CM','250.4'),
('dx_dm_complications','ICD9CM','250.5'),
('dx_dm_complications','ICD9CM','250.6'),
('dx_dm_complications','ICD9CM','250.7'),

('dx_dm_complications','ICD10CM','E08.2'),
('dx_dm_complications','ICD10CM','E08.3'),
('dx_dm_complications','ICD10CM','E08.4'),
('dx_dm_complications','ICD10CM','E08.5'),

('dx_dm_complications','ICD10CM','E09.2'),
('dx_dm_complications','ICD10CM','E09.3'),
('dx_dm_complications','ICD10CM','E09.4'),
('dx_dm_complications','ICD10CM','E09.5'),

('dx_dm_complications','ICD10CM','E10.2'),
('dx_dm_complications','ICD10CM','E10.3'),
('dx_dm_complications','ICD10CM','E10.4'),
('dx_dm_complications','ICD10CM','E10.5'),
('dx_dm_complications','ICD10CM','E10.7'),

('dx_dm_complications','ICD10CM','E11.2'),
('dx_dm_complications','ICD10CM','E11.3'),
('dx_dm_complications','ICD10CM','E11.4'),
('dx_dm_complications','ICD10CM','E11.5'),

('dx_dm_complications','ICD10CM','E13.2'),
('dx_dm_complications','ICD10CM','E13.3'),
('dx_dm_complications','ICD10CM','E13.4'),
('dx_dm_complications','ICD10CM','E13.5'),

('dx_dm_complications','KCD7','E08.2'),
('dx_dm_complications','KCD7','E08.3'),
('dx_dm_complications','KCD7','E08.4'),
('dx_dm_complications','KCD7','E08.5'),
('dx_dm_complications','KCD7','E09.2'),
('dx_dm_complications','KCD7','E09.3'),
('dx_dm_complications','KCD7','E09.4'),
('dx_dm_complications','KCD7','E09.5'),
('dx_dm_complications','KCD7','E10.2'),
('dx_dm_complications','KCD7','E10.3'),
('dx_dm_complications','KCD7','E10.4'),
('dx_dm_complications','KCD7','E10.5'),
('dx_dm_complications','KCD7','E10.7'),
('dx_dm_complications','KCD7','E11.2'),
('dx_dm_complications','KCD7','E11.3'),
('dx_dm_complications','KCD7','E11.4'),
('dx_dm_complications','KCD7','E11.5'),
('dx_dm_complications','KCD7','E13.2'),
('dx_dm_complications','KCD7','E13.3'),
('dx_dm_complications','KCD7','E13.4'),
('dx_dm_complications','KCD7','E13.5')
;

DROP TABLE IF EXISTS dx_feature_concept_seed;
CREATE TEMP TABLE dx_feature_concept_seed AS
SELECT DISTINCT
  s.set_name,
  std.concept_id
FROM dx_code_seed s
JOIN concept src
  ON src.vocabulary_id = s.vocabulary_id
 AND src.concept_code LIKE s.code_prefix || '%'
 AND src.invalid_reason IS NULL
JOIN concept_relationship cr
  ON cr.concept_id_1 = src.concept_id
 AND cr.relationship_id = 'Maps to'
 AND cr.invalid_reason IS NULL
JOIN concept std
  ON std.concept_id = cr.concept_id_2
 AND std.standard_concept = 'S'
 AND std.domain_id = 'Condition'
 AND std.invalid_reason IS NULL;



DROP TABLE IF EXISTS dx_feature_concept_set;
CREATE TEMP TABLE dx_feature_concept_set AS
SELECT DISTINCT
  cs.set_name,
  ca.descendant_concept_id AS concept_id
FROM dx_feature_concept_seed cs
JOIN concept_ancestor ca
  ON ca.ancestor_concept_id = cs.concept_id
JOIN concept c
  ON c.concept_id = ca.descendant_concept_id
WHERE c.invalid_reason IS NULL;


/* 인덱스 이전 1년 동반질환 현황 확인용 baseline audit */
DROP TABLE IF EXISTS feature_dx_baseline_audit;
CREATE TEMP TABLE feature_dx_baseline_audit AS
SELECT
    f.person_id,
    MAX(CASE WHEN cs.set_name = 'dx_bradycardia' THEN 1 ELSE 0 END) AS dx_bradycardia_flag,
    MAX(CASE WHEN cs.set_name = 'dx_goiter' THEN 1 ELSE 0 END) AS dx_goiter_flag,
    MAX(CASE WHEN cs.set_name = 'dx_anemia' THEN 1 ELSE 0 END) AS dx_anemia_flag,
    MAX(CASE WHEN cs.set_name = 'dx_hypertension' THEN 1 ELSE 0 END) AS dx_hypertension_flag,
    MAX(CASE WHEN cs.set_name = 'dx_diabetes' THEN 1 ELSE 0 END) AS dx_diabetes_flag,
    MAX(CASE WHEN cs.set_name = 'dx_dm_nephropathy' THEN 1 ELSE 0 END) AS dx_dm_nephropathy_flag,
    MAX(CASE WHEN cs.set_name = 'dx_dm_complications' THEN 1 ELSE 0 END) AS dx_dm_complications_flag,
    MAX(CASE WHEN cs.set_name = 'dx_gouts' THEN 1 ELSE 0 END) AS dx_gouts_flag,
    MAX(CASE WHEN cs.set_name = 'dx_chronic_rf' THEN 1 ELSE 0 END) AS dx_chronic_rf_flag,
    MAX(CASE WHEN cs.set_name = 'dx_renal_dysfunction' THEN 1 ELSE 0 END) AS dx_renal_dysfunction_flag,
    MAX(CASE WHEN cs.set_name = 'dx_rheumatoid_arthritis' THEN 1 ELSE 0 END) AS dx_ra_flag
FROM final_flag f
LEFT JOIN condition_occurrence co ON f.person_id = co.person_id
    -- 인덱스일 기준 과거 1년 기록 필터링
    AND co.condition_start_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
LEFT JOIN dx_feature_concept_set cs ON co.condition_concept_id = cs.concept_id
GROUP BY f.person_id;


SELECT 'dx_bradycardia' AS dx, COUNT(*) AS cnt
FROM feature_dx_baseline_audit WHERE dx_bradycardia_flag = 1
UNION ALL
SELECT 'dx_goiter', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_goiter_flag = 1
UNION ALL
SELECT 'dx_anemia', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_anemia_flag = 1
UNION ALL
SELECT 'dx_hypertension', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_hypertension_flag = 1
UNION ALL
SELECT 'dx_diabetes', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_diabetes_flag = 1
UNION ALL
SELECT 'dx_dm_nephropathy', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_dm_nephropathy_flag = 1
UNION ALL
SELECT 'dx_dm_complications', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_dm_complications_flag = 1
UNION ALL
SELECT 'dx_gouts', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_gouts_flag = 1
UNION ALL
SELECT 'dx_chronic_rf', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_chronic_rf_flag = 1
UNION ALL
SELECT 'dx_renal_dysfunction', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_renal_dysfunction_flag = 1
UNION ALL
SELECT 'dx_rheumatoid_arthritis', COUNT(*) FROM feature_dx_baseline_audit WHERE dx_ra_flag = 1;


/* ------------------------------------------------------------------------
   동반질환의 구간별 누적(cumulative) feature

   baseline 시작일(index_date - 1년)부터 각 구간의 관찰 종료일까지
   해당 진단 기록이 한 번이라도 있으면 1, 없으면 0이다.
   한 번 1이 된 동반질환은 이후 관찰 구간에서도 계속 1로 유지된다.
   환자가 해당 구간에 전혀 도달하지 못한 경우에는 NULL로 둔다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS feature_dx_dynamic_long;
CREATE TEMP TABLE feature_dx_dynamic_long AS
WITH dx_names(set_name) AS (
  VALUES
      ('dx_bradycardia'),
      ('dx_goiter'),
      ('dx_anemia'),
      ('dx_hypertension'),
      ('dx_diabetes'),
      ('dx_dm_nephropathy'),
      ('dx_dm_complications'),
      ('dx_gouts'),
      ('dx_chronic_rf'),
      ('dx_renal_dysfunction'),
      ('dx_rheumatoid_arthritis')
)
SELECT
    w.person_id,
    w.time_point,
    w.window_order,
    n.set_name,
    CASE
        WHEN w.available_flag = 0 THEN NULL
        ELSE MAX(CASE WHEN cs.concept_id IS NOT NULL THEN 1 ELSE 0 END)
    END AS feature_flag
FROM feature_dynamic_windows w
CROSS JOIN dx_names n
LEFT JOIN condition_occurrence co
  ON co.person_id = w.person_id
 AND w.available_flag = 1
 AND co.condition_start_date >= w.baseline_start_date
 AND co.condition_start_date <= w.observed_window_end_date
LEFT JOIN dx_feature_concept_set cs
  ON cs.concept_id = co.condition_concept_id
 AND cs.set_name = n.set_name
GROUP BY
    w.person_id,
    w.time_point,
    w.window_order,
    w.available_flag,
    n.set_name;

DROP TABLE IF EXISTS feature_dx_dynamic_wide;
CREATE TEMP TABLE feature_dx_dynamic_wide AS
SELECT
    person_id,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'base' THEN feature_flag END) AS dx_bradycardia_base,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm1' THEN feature_flag END) AS dx_bradycardia_m1,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm2' THEN feature_flag END) AS dx_bradycardia_m2,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm3' THEN feature_flag END) AS dx_bradycardia_m3,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm4_6' THEN feature_flag END) AS dx_bradycardia_m4_6,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm7_9' THEN feature_flag END) AS dx_bradycardia_m7_9,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm10_12' THEN feature_flag END) AS dx_bradycardia_m10_12,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm13_15' THEN feature_flag END) AS dx_bradycardia_m13_15,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm16_18' THEN feature_flag END) AS dx_bradycardia_m16_18,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm19_21' THEN feature_flag END) AS dx_bradycardia_m19_21,
    MAX(CASE WHEN set_name = 'dx_bradycardia' AND time_point = 'm22_24' THEN feature_flag END) AS dx_bradycardia_m22_24,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'base' THEN feature_flag END) AS dx_goiter_base,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm1' THEN feature_flag END) AS dx_goiter_m1,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm2' THEN feature_flag END) AS dx_goiter_m2,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm3' THEN feature_flag END) AS dx_goiter_m3,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm4_6' THEN feature_flag END) AS dx_goiter_m4_6,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm7_9' THEN feature_flag END) AS dx_goiter_m7_9,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm10_12' THEN feature_flag END) AS dx_goiter_m10_12,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm13_15' THEN feature_flag END) AS dx_goiter_m13_15,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm16_18' THEN feature_flag END) AS dx_goiter_m16_18,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm19_21' THEN feature_flag END) AS dx_goiter_m19_21,
    MAX(CASE WHEN set_name = 'dx_goiter' AND time_point = 'm22_24' THEN feature_flag END) AS dx_goiter_m22_24,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'base' THEN feature_flag END) AS dx_anemia_base,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm1' THEN feature_flag END) AS dx_anemia_m1,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm2' THEN feature_flag END) AS dx_anemia_m2,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm3' THEN feature_flag END) AS dx_anemia_m3,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm4_6' THEN feature_flag END) AS dx_anemia_m4_6,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm7_9' THEN feature_flag END) AS dx_anemia_m7_9,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm10_12' THEN feature_flag END) AS dx_anemia_m10_12,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm13_15' THEN feature_flag END) AS dx_anemia_m13_15,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm16_18' THEN feature_flag END) AS dx_anemia_m16_18,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm19_21' THEN feature_flag END) AS dx_anemia_m19_21,
    MAX(CASE WHEN set_name = 'dx_anemia' AND time_point = 'm22_24' THEN feature_flag END) AS dx_anemia_m22_24,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'base' THEN feature_flag END) AS dx_hypertension_base,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm1' THEN feature_flag END) AS dx_hypertension_m1,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm2' THEN feature_flag END) AS dx_hypertension_m2,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm3' THEN feature_flag END) AS dx_hypertension_m3,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm4_6' THEN feature_flag END) AS dx_hypertension_m4_6,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm7_9' THEN feature_flag END) AS dx_hypertension_m7_9,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm10_12' THEN feature_flag END) AS dx_hypertension_m10_12,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm13_15' THEN feature_flag END) AS dx_hypertension_m13_15,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm16_18' THEN feature_flag END) AS dx_hypertension_m16_18,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm19_21' THEN feature_flag END) AS dx_hypertension_m19_21,
    MAX(CASE WHEN set_name = 'dx_hypertension' AND time_point = 'm22_24' THEN feature_flag END) AS dx_hypertension_m22_24,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'base' THEN feature_flag END) AS dx_diabetes_base,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm1' THEN feature_flag END) AS dx_diabetes_m1,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm2' THEN feature_flag END) AS dx_diabetes_m2,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm3' THEN feature_flag END) AS dx_diabetes_m3,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm4_6' THEN feature_flag END) AS dx_diabetes_m4_6,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm7_9' THEN feature_flag END) AS dx_diabetes_m7_9,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm10_12' THEN feature_flag END) AS dx_diabetes_m10_12,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm13_15' THEN feature_flag END) AS dx_diabetes_m13_15,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm16_18' THEN feature_flag END) AS dx_diabetes_m16_18,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm19_21' THEN feature_flag END) AS dx_diabetes_m19_21,
    MAX(CASE WHEN set_name = 'dx_diabetes' AND time_point = 'm22_24' THEN feature_flag END) AS dx_diabetes_m22_24,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'base' THEN feature_flag END) AS dx_dmnephropathys_base,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm1' THEN feature_flag END) AS dx_dmnephropathys_m1,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm2' THEN feature_flag END) AS dx_dmnephropathys_m2,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm3' THEN feature_flag END) AS dx_dmnephropathys_m3,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm4_6' THEN feature_flag END) AS dx_dmnephropathys_m4_6,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm7_9' THEN feature_flag END) AS dx_dmnephropathys_m7_9,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm10_12' THEN feature_flag END) AS dx_dmnephropathys_m10_12,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm13_15' THEN feature_flag END) AS dx_dmnephropathys_m13_15,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm16_18' THEN feature_flag END) AS dx_dmnephropathys_m16_18,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm19_21' THEN feature_flag END) AS dx_dmnephropathys_m19_21,
    MAX(CASE WHEN set_name = 'dx_dm_nephropathy' AND time_point = 'm22_24' THEN feature_flag END) AS dx_dmnephropathys_m22_24,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'base' THEN feature_flag END) AS dx_dm_coms_base,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm1' THEN feature_flag END) AS dx_dm_coms_m1,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm2' THEN feature_flag END) AS dx_dm_coms_m2,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm3' THEN feature_flag END) AS dx_dm_coms_m3,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm4_6' THEN feature_flag END) AS dx_dm_coms_m4_6,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm7_9' THEN feature_flag END) AS dx_dm_coms_m7_9,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm10_12' THEN feature_flag END) AS dx_dm_coms_m10_12,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm13_15' THEN feature_flag END) AS dx_dm_coms_m13_15,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm16_18' THEN feature_flag END) AS dx_dm_coms_m16_18,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm19_21' THEN feature_flag END) AS dx_dm_coms_m19_21,
    MAX(CASE WHEN set_name = 'dx_dm_complications' AND time_point = 'm22_24' THEN feature_flag END) AS dx_dm_coms_m22_24,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'base' THEN feature_flag END) AS dx_gouts_base,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm1' THEN feature_flag END) AS dx_gouts_m1,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm2' THEN feature_flag END) AS dx_gouts_m2,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm3' THEN feature_flag END) AS dx_gouts_m3,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm4_6' THEN feature_flag END) AS dx_gouts_m4_6,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm7_9' THEN feature_flag END) AS dx_gouts_m7_9,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm10_12' THEN feature_flag END) AS dx_gouts_m10_12,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm13_15' THEN feature_flag END) AS dx_gouts_m13_15,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm16_18' THEN feature_flag END) AS dx_gouts_m16_18,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm19_21' THEN feature_flag END) AS dx_gouts_m19_21,
    MAX(CASE WHEN set_name = 'dx_gouts' AND time_point = 'm22_24' THEN feature_flag END) AS dx_gouts_m22_24,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'base' THEN feature_flag END) AS dx_chronic_rfs_base,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm1' THEN feature_flag END) AS dx_chronic_rfs_m1,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm2' THEN feature_flag END) AS dx_chronic_rfs_m2,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm3' THEN feature_flag END) AS dx_chronic_rfs_m3,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm4_6' THEN feature_flag END) AS dx_chronic_rfs_m4_6,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm7_9' THEN feature_flag END) AS dx_chronic_rfs_m7_9,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm10_12' THEN feature_flag END) AS dx_chronic_rfs_m10_12,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm13_15' THEN feature_flag END) AS dx_chronic_rfs_m13_15,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm16_18' THEN feature_flag END) AS dx_chronic_rfs_m16_18,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm19_21' THEN feature_flag END) AS dx_chronic_rfs_m19_21,
    MAX(CASE WHEN set_name = 'dx_chronic_rf' AND time_point = 'm22_24' THEN feature_flag END) AS dx_chronic_rfs_m22_24,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'base' THEN feature_flag END) AS dx_renal_dyss_base,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm1' THEN feature_flag END) AS dx_renal_dyss_m1,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm2' THEN feature_flag END) AS dx_renal_dyss_m2,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm3' THEN feature_flag END) AS dx_renal_dyss_m3,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm4_6' THEN feature_flag END) AS dx_renal_dyss_m4_6,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm7_9' THEN feature_flag END) AS dx_renal_dyss_m7_9,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm10_12' THEN feature_flag END) AS dx_renal_dyss_m10_12,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm13_15' THEN feature_flag END) AS dx_renal_dyss_m13_15,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm16_18' THEN feature_flag END) AS dx_renal_dyss_m16_18,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm19_21' THEN feature_flag END) AS dx_renal_dyss_m19_21,
    MAX(CASE WHEN set_name = 'dx_renal_dysfunction' AND time_point = 'm22_24' THEN feature_flag END) AS dx_renal_dyss_m22_24,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'base' THEN feature_flag END) AS dx_ras_base,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm1' THEN feature_flag END) AS dx_ras_m1,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm2' THEN feature_flag END) AS dx_ras_m2,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm3' THEN feature_flag END) AS dx_ras_m3,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm4_6' THEN feature_flag END) AS dx_ras_m4_6,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm7_9' THEN feature_flag END) AS dx_ras_m7_9,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm10_12' THEN feature_flag END) AS dx_ras_m10_12,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm13_15' THEN feature_flag END) AS dx_ras_m13_15,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm16_18' THEN feature_flag END) AS dx_ras_m16_18,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm19_21' THEN feature_flag END) AS dx_ras_m19_21,
    MAX(CASE WHEN set_name = 'dx_rheumatoid_arthritis' AND time_point = 'm22_24' THEN feature_flag END) AS dx_ras_m22_24
FROM feature_dx_dynamic_long
GROUP BY person_id;

/* 구간별 동반질환 양성 환자 수 확인용 */
SELECT
    set_name,
    time_point,
    SUM(feature_flag) AS n_persons,
    COUNT(feature_flag) AS n_observed
FROM feature_dx_dynamic_long
GROUP BY set_name, time_point
ORDER BY set_name, MIN(window_order);

/*
   누적 동반질환 품질검사:
   관찰된 구간에서 한 번 1이 된 뒤 다시 0으로 내려가는 행은 없어야 한다.
   n_cumulative_reversal = 0이면 누적 로직이 정상이다.
*/
SELECT COUNT(*) AS n_cumulative_reversal
FROM (
    SELECT
        person_id,
        set_name,
        time_point,
        feature_flag,
        MAX(CASE WHEN feature_flag = 1 THEN 1 ELSE 0 END) OVER (
            PARTITION BY person_id, set_name
            ORDER BY window_order
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_positive_flag
    FROM feature_dx_dynamic_long
) q
WHERE prior_positive_flag = 1
  AND feature_flag = 0;




/* ==========================================
   Part 5
   ========================================== */

/* Lab Concept Seed */
DROP TABLE IF EXISTS lab_concept_seed;
CREATE TEMP TABLE lab_concept_seed (
    set_name TEXT,
    concept_id INT
);

INSERT INTO lab_concept_seed (set_name, concept_id) VALUES
    ('lab_TSH', 3009201), 
    ('lab_FT4', 3008598), 
    ('lab_FT4', 42529233),
    -- Free triiodothyronine (FT3)
    ('lab_FT3', 42529256),
    -- Total triiodothyronine (Total T3)
    ('lab_TotalT3', 42529253),
    -- Total thyroxine (Total T4)
    ('lab_TotalT4', 3016991),
    ('lab_rbc', 3026361), 
    ('lab_hgb', 3000963),
    ('lab_hct', 3009542),
    ('lab_mcv', 37065843),
    ('lab_mch', 37045413),
    ('lab_mchc', 40654759),
    ('lab_tg', 3022192), 
    ('lab_AST', 3013721), 
    ('lab_ALT', 3006923), 
    ('lab_HDL', 3007070),
    ('lab_LDL', 3028437), 
   ('lab_SCr', 3016723), 
  ('lab_ALK_P', 3035995), 
 ('lab_Cholesterol', 3027114);

/* ------------------------------------------------------------------------
   환자별 검사실 특징 관찰 가능 구간

   - 양성: AITD 발생 구간 직전 경계까지만 feature_cutoff_date로 설정됨
   - 완전 추적 음성: 24개월까지 모두 1
   - 조기 추적 종료: 종료일 이전의 일부 구간 값은 사용할 수 있지만,
     해당 구간의 complete_flag는 0이므로 부분 관찰임을 구분할 수 있음
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS feature_window_observation;
CREATE TEMP TABLE feature_window_observation AS
SELECT
    person_id,
    (feature_cutoff_date::date - index_date::date) AS observed_followup_days,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '1 month'  THEN 1 ELSE 0 END AS m1_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '2 month'  THEN 1 ELSE 0 END AS m2_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '3 month'  THEN 1 ELSE 0 END AS m3_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '6 month'  THEN 1 ELSE 0 END AS m4_6_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '9 month'  THEN 1 ELSE 0 END AS m7_9_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '12 month' THEN 1 ELSE 0 END AS m10_12_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '15 month' THEN 1 ELSE 0 END AS m13_15_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '18 month' THEN 1 ELSE 0 END AS m16_18_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '21 month' THEN 1 ELSE 0 END AS m19_21_complete_flag,
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '24 month' THEN 1 ELSE 0 END AS m22_24_complete_flag
FROM final_flag;


  
/* [Part 5] Longitudinal Lab Values - Baseline + 10 Follow-up Windows */

DROP TABLE IF EXISTS feature_lab_values_wide;
CREATE TEMP TABLE feature_lab_values_wide AS
WITH lab_segments AS (
    SELECT 
        f.person_id,
        cs.set_name,
        m.measurement_id,
        m.value_as_number,
        -- 1. 시점 구간(Time Window) 정의
        CASE 
            WHEN m.measurement_date <= f.index_date THEN 'base'
            WHEN m.measurement_date > f.index_date AND m.measurement_date <= (f.index_date + INTERVAL '1 month') THEN 'm1'
            WHEN m.measurement_date > (f.index_date + INTERVAL '1 month') AND m.measurement_date <= (f.index_date + INTERVAL '2 month') THEN 'm2'
            WHEN m.measurement_date > (f.index_date + INTERVAL '2 month') AND m.measurement_date <= (f.index_date + INTERVAL '3 month') THEN 'm3'
            WHEN m.measurement_date > (f.index_date + INTERVAL '3 month') AND m.measurement_date <= (f.index_date + INTERVAL '6 month') THEN 'm4_6'
            WHEN m.measurement_date > (f.index_date + INTERVAL '6 month') AND m.measurement_date <= (f.index_date + INTERVAL '9 month') THEN 'm7_9'
            WHEN m.measurement_date > (f.index_date + INTERVAL '9 month') AND m.measurement_date <= (f.index_date + INTERVAL '12 month') THEN 'm10_12'
            WHEN m.measurement_date > (f.index_date + INTERVAL '12 month') AND m.measurement_date <= (f.index_date + INTERVAL '15 month') THEN 'm13_15'
            WHEN m.measurement_date > (f.index_date + INTERVAL '15 month') AND m.measurement_date <= (f.index_date + INTERVAL '18 month') THEN 'm16_18'
            WHEN m.measurement_date > (f.index_date + INTERVAL '18 month') AND m.measurement_date <= (f.index_date + INTERVAL '21 month') THEN 'm19_21'
            WHEN m.measurement_date > (f.index_date + INTERVAL '21 month') AND m.measurement_date <= (f.index_date + INTERVAL '24 month') THEN 'm22_24'
        END AS time_point,
        -- 2. 각 구간의 목표 날짜 (가장 가까운 값을 찾기 위한 기준점)
        CASE 
            WHEN m.measurement_date <= f.index_date THEN f.index_date
            WHEN m.measurement_date <= (f.index_date + INTERVAL '1 month') THEN f.index_date + INTERVAL '1 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '2 month') THEN f.index_date + INTERVAL '2 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '3 month') THEN f.index_date + INTERVAL '3 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '6 month') THEN f.index_date + INTERVAL '6 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '9 month') THEN f.index_date + INTERVAL '9 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '12 month') THEN f.index_date + INTERVAL '12 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '15 month') THEN f.index_date + INTERVAL '15 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '18 month') THEN f.index_date + INTERVAL '18 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '21 month') THEN f.index_date + INTERVAL '21 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '24 month') THEN f.index_date + INTERVAL '24 month'
        END AS target_date,
        m.measurement_date
    FROM final_flag f
    JOIN measurement m ON f.person_id = m.person_id
    JOIN lab_concept_seed cs ON m.measurement_concept_id = cs.concept_id
    WHERE m.measurement_date >= f.index_date - INTERVAL '1 year'
      AND m.measurement_date <= f.feature_cutoff_date
      AND m.value_as_number IS NOT NULL
),
ranked_labs AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY person_id, set_name, time_point 
            ORDER BY ABS(EXTRACT(EPOCH FROM (measurement_date - target_date))) ASC,
                     measurement_id DESC
        ) AS rn
    FROM lab_segments
    WHERE time_point IS NOT NULL
)
SELECT 
    person_id,
    /* 1. TSH (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'base' THEN value_as_number END) AS tsh_base,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm1' THEN value_as_number END) AS tsh_m1,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm2' THEN value_as_number END) AS tsh_m2,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm3' THEN value_as_number END) AS tsh_m3,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm4_6' THEN value_as_number END) AS tsh_m4_6,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm7_9' THEN value_as_number END) AS tsh_m7_9,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm10_12' THEN value_as_number END) AS tsh_m10_12,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm13_15' THEN value_as_number END) AS tsh_m13_15,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm16_18' THEN value_as_number END) AS tsh_m16_18,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm19_21' THEN value_as_number END) AS tsh_m19_21,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm22_24' THEN value_as_number END) AS tsh_m22_24,

    /* 2. FT4 (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'base' THEN value_as_number END) AS ft4_base,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm1' THEN value_as_number END) AS ft4_m1,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm2' THEN value_as_number END) AS ft4_m2,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm3' THEN value_as_number END) AS ft4_m3,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm4_6' THEN value_as_number END) AS ft4_m4_6,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm7_9' THEN value_as_number END) AS ft4_m7_9,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm10_12' THEN value_as_number END) AS ft4_m10_12,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm13_15' THEN value_as_number END) AS ft4_m13_15,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm16_18' THEN value_as_number END) AS ft4_m16_18,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm19_21' THEN value_as_number END) AS ft4_m19_21,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm22_24' THEN value_as_number END) AS ft4_m22_24,

    /* 3. FT3 (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'base' THEN value_as_number END) AS ft3_base,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm1' THEN value_as_number END) AS ft3_m1,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm2' THEN value_as_number END) AS ft3_m2,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm3' THEN value_as_number END) AS ft3_m3,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm4_6' THEN value_as_number END) AS ft3_m4_6,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm7_9' THEN value_as_number END) AS ft3_m7_9,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm10_12' THEN value_as_number END) AS ft3_m10_12,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm13_15' THEN value_as_number END) AS ft3_m13_15,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm16_18' THEN value_as_number END) AS ft3_m16_18,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm19_21' THEN value_as_number END) AS ft3_m19_21,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm22_24' THEN value_as_number END) AS ft3_m22_24,

    /* 4. Total T3 (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'base' THEN value_as_number END) AS total_t3_base,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm1' THEN value_as_number END) AS total_t3_m1,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm2' THEN value_as_number END) AS total_t3_m2,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm3' THEN value_as_number END) AS total_t3_m3,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm4_6' THEN value_as_number END) AS total_t3_m4_6,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm7_9' THEN value_as_number END) AS total_t3_m7_9,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm10_12' THEN value_as_number END) AS total_t3_m10_12,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm13_15' THEN value_as_number END) AS total_t3_m13_15,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm16_18' THEN value_as_number END) AS total_t3_m16_18,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm19_21' THEN value_as_number END) AS total_t3_m19_21,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm22_24' THEN value_as_number END) AS total_t3_m22_24,

    /* 5. Total T4 (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'base' THEN value_as_number END) AS total_t4_base,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm1' THEN value_as_number END) AS total_t4_m1,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm2' THEN value_as_number END) AS total_t4_m2,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm3' THEN value_as_number END) AS total_t4_m3,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm4_6' THEN value_as_number END) AS total_t4_m4_6,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm7_9' THEN value_as_number END) AS total_t4_m7_9,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm10_12' THEN value_as_number END) AS total_t4_m10_12,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm13_15' THEN value_as_number END) AS total_t4_m13_15,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm16_18' THEN value_as_number END) AS total_t4_m16_18,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm19_21' THEN value_as_number END) AS total_t4_m19_21,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm22_24' THEN value_as_number END) AS total_t4_m22_24,

    /* 6. RBC (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'base' THEN value_as_number END) AS rbc_base,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm1' THEN value_as_number END) AS rbc_m1,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm2' THEN value_as_number END) AS rbc_m2,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm3' THEN value_as_number END) AS rbc_m3,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm4_6' THEN value_as_number END) AS rbc_m4_6,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm7_9' THEN value_as_number END) AS rbc_m7_9,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm10_12' THEN value_as_number END) AS rbc_m10_12,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm13_15' THEN value_as_number END) AS rbc_m13_15,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm16_18' THEN value_as_number END) AS rbc_m16_18,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm19_21' THEN value_as_number END) AS rbc_m19_21,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm22_24' THEN value_as_number END) AS rbc_m22_24,

    /* 4. HGB (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'base' THEN value_as_number END) AS hgb_base,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm1' THEN value_as_number END) AS hgb_m1,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm2' THEN value_as_number END) AS hgb_m2,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm3' THEN value_as_number END) AS hgb_m3,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm4_6' THEN value_as_number END) AS hgb_m4_6,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm7_9' THEN value_as_number END) AS hgb_m7_9,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm10_12' THEN value_as_number END) AS hgb_m10_12,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm13_15' THEN value_as_number END) AS hgb_m13_15,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm16_18' THEN value_as_number END) AS hgb_m16_18,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm19_21' THEN value_as_number END) AS hgb_m19_21,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm22_24' THEN value_as_number END) AS hgb_m22_24,

    /* 5. HCT (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'base' THEN value_as_number END) AS hct_base,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm1' THEN value_as_number END) AS hct_m1,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm2' THEN value_as_number END) AS hct_m2,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm3' THEN value_as_number END) AS hct_m3,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm4_6' THEN value_as_number END) AS hct_m4_6,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm7_9' THEN value_as_number END) AS hct_m7_9,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm10_12' THEN value_as_number END) AS hct_m10_12,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm13_15' THEN value_as_number END) AS hct_m13_15,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm16_18' THEN value_as_number END) AS hct_m16_18,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm19_21' THEN value_as_number END) AS hct_m19_21,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm22_24' THEN value_as_number END) AS hct_m22_24,

    /* 6. MCV (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'base' THEN value_as_number END) AS mcv_base,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm1' THEN value_as_number END) AS mcv_m1,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm2' THEN value_as_number END) AS mcv_m2,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm3' THEN value_as_number END) AS mcv_m3,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm4_6' THEN value_as_number END) AS mcv_m4_6,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm7_9' THEN value_as_number END) AS mcv_m7_9,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm10_12' THEN value_as_number END) AS mcv_m10_12,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm13_15' THEN value_as_number END) AS mcv_m13_15,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm16_18' THEN value_as_number END) AS mcv_m16_18,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm19_21' THEN value_as_number END) AS mcv_m19_21,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm22_24' THEN value_as_number END) AS mcv_m22_24,

    /* 7. MCH (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'base' THEN value_as_number END) AS mch_base,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm1' THEN value_as_number END) AS mch_m1,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm2' THEN value_as_number END) AS mch_m2,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm3' THEN value_as_number END) AS mch_m3,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm4_6' THEN value_as_number END) AS mch_m4_6,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm7_9' THEN value_as_number END) AS mch_m7_9,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm10_12' THEN value_as_number END) AS mch_m10_12,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm13_15' THEN value_as_number END) AS mch_m13_15,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm16_18' THEN value_as_number END) AS mch_m16_18,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm19_21' THEN value_as_number END) AS mch_m19_21,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm22_24' THEN value_as_number END) AS mch_m22_24,

    /* 8. MCHC (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'base' THEN value_as_number END) AS mchc_base,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm1' THEN value_as_number END) AS mchc_m1,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm2' THEN value_as_number END) AS mchc_m2,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm3' THEN value_as_number END) AS mchc_m3,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm4_6' THEN value_as_number END) AS mchc_m4_6,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm7_9' THEN value_as_number END) AS mchc_m7_9,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm10_12' THEN value_as_number END) AS mchc_m10_12,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm13_15' THEN value_as_number END) AS mchc_m13_15,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm16_18' THEN value_as_number END) AS mchc_m16_18,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm19_21' THEN value_as_number END) AS mchc_m19_21,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm22_24' THEN value_as_number END) AS mchc_m22_24,

    /* 9. TG (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'base' THEN value_as_number END) AS tg_base,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm1' THEN value_as_number END) AS tg_m1,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm2' THEN value_as_number END) AS tg_m2,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm3' THEN value_as_number END) AS tg_m3,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm4_6' THEN value_as_number END) AS tg_m4_6,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm7_9' THEN value_as_number END) AS tg_m7_9,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm10_12' THEN value_as_number END) AS tg_m10_12,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm13_15' THEN value_as_number END) AS tg_m13_15,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm16_18' THEN value_as_number END) AS tg_m16_18,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm19_21' THEN value_as_number END) AS tg_m19_21,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm22_24' THEN value_as_number END) AS tg_m22_24,

    /* 10. AST (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'base' THEN value_as_number END) AS ast_base,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm1' THEN value_as_number END) AS ast_m1,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm2' THEN value_as_number END) AS ast_m2,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm3' THEN value_as_number END) AS ast_m3,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm4_6' THEN value_as_number END) AS ast_m4_6,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm7_9' THEN value_as_number END) AS ast_m7_9,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm10_12' THEN value_as_number END) AS ast_m10_12,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm13_15' THEN value_as_number END) AS ast_m13_15,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm16_18' THEN value_as_number END) AS ast_m16_18,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm19_21' THEN value_as_number END) AS ast_m19_21,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm22_24' THEN value_as_number END) AS ast_m22_24,

    /* 11. ALT (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'base' THEN value_as_number END) AS alt_base,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm1' THEN value_as_number END) AS alt_m1,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm2' THEN value_as_number END) AS alt_m2,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm3' THEN value_as_number END) AS alt_m3,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm4_6' THEN value_as_number END) AS alt_m4_6,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm7_9' THEN value_as_number END) AS alt_m7_9,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm10_12' THEN value_as_number END) AS alt_m10_12,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm13_15' THEN value_as_number END) AS alt_m13_15,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm16_18' THEN value_as_number END) AS alt_m16_18,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm19_21' THEN value_as_number END) AS alt_m19_21,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm22_24' THEN value_as_number END) AS alt_m22_24,

    /* 12. HDL (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'base' THEN value_as_number END) AS hdl_base,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm1' THEN value_as_number END) AS hdl_m1,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm2' THEN value_as_number END) AS hdl_m2,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm3' THEN value_as_number END) AS hdl_m3,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm4_6' THEN value_as_number END) AS hdl_m4_6,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm7_9' THEN value_as_number END) AS hdl_m7_9,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm10_12' THEN value_as_number END) AS hdl_m10_12,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm13_15' THEN value_as_number END) AS hdl_m13_15,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm16_18' THEN value_as_number END) AS hdl_m16_18,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm19_21' THEN value_as_number END) AS hdl_m19_21,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm22_24' THEN value_as_number END) AS hdl_m22_24,

    /* 13. LDL (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'base' THEN value_as_number END) AS ldl_base,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm1' THEN value_as_number END) AS ldl_m1,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm2' THEN value_as_number END) AS ldl_m2,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm3' THEN value_as_number END) AS ldl_m3,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm4_6' THEN value_as_number END) AS ldl_m4_6,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm7_9' THEN value_as_number END) AS ldl_m7_9,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm10_12' THEN value_as_number END) AS ldl_m10_12,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm13_15' THEN value_as_number END) AS ldl_m13_15,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm16_18' THEN value_as_number END) AS ldl_m16_18,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm19_21' THEN value_as_number END) AS ldl_m19_21,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm22_24' THEN value_as_number END) AS ldl_m22_24,

    /* 14. SCr (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'base' THEN value_as_number END) AS scr_base,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm1' THEN value_as_number END) AS scr_m1,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm2' THEN value_as_number END) AS scr_m2,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm3' THEN value_as_number END) AS scr_m3,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm4_6' THEN value_as_number END) AS scr_m4_6,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm7_9' THEN value_as_number END) AS scr_m7_9,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm10_12' THEN value_as_number END) AS scr_m10_12,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm13_15' THEN value_as_number END) AS scr_m13_15,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm16_18' THEN value_as_number END) AS scr_m16_18,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm19_21' THEN value_as_number END) AS scr_m19_21,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm22_24' THEN value_as_number END) AS scr_m22_24,

    /* 15. ALK_P (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'base' THEN value_as_number END) AS alkp_base,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm1' THEN value_as_number END) AS alkp_m1,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm2' THEN value_as_number END) AS alkp_m2,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm3' THEN value_as_number END) AS alkp_m3,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm4_6' THEN value_as_number END) AS alkp_m4_6,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm7_9' THEN value_as_number END) AS alkp_m7_9,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm10_12' THEN value_as_number END) AS alkp_m10_12,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm13_15' THEN value_as_number END) AS alkp_m13_15,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm16_18' THEN value_as_number END) AS alkp_m16_18,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm19_21' THEN value_as_number END) AS alkp_m19_21,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm22_24' THEN value_as_number END) AS alkp_m22_24,

    /* 16. Cholesterol (baseline + 10 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'base' THEN value_as_number END) AS cholesterol_base,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm1' THEN value_as_number END) AS cholesterol_m1,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm2' THEN value_as_number END) AS cholesterol_m2,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm3' THEN value_as_number END) AS cholesterol_m3,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm4_6' THEN value_as_number END) AS cholesterol_m4_6,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm7_9' THEN value_as_number END) AS cholesterol_m7_9,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm10_12' THEN value_as_number END) AS cholesterol_m10_12,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm13_15' THEN value_as_number END) AS cholesterol_m13_15,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm16_18' THEN value_as_number END) AS cholesterol_m16_18,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm19_21' THEN value_as_number END) AS cholesterol_m19_21,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm22_24' THEN value_as_number END) AS cholesterol_m22_24

FROM ranked_labs WHERE rn = 1
GROUP BY person_id;


/* ==========================================
   Part 6
   ========================================== */

DROP TABLE IF EXISTS feature_lab_remarks_wide;
CREATE TEMP TABLE feature_lab_remarks_wide AS
WITH lab_segments AS (
    SELECT 
        f.person_id,
        cs.set_name,
        m.measurement_id,
        m.value_as_number,
        m.range_high,
        m.range_low,
        m.value_as_concept_id,
        CASE 
            WHEN m.measurement_date <= f.index_date THEN 'base'
            WHEN m.measurement_date > f.index_date AND m.measurement_date <= (f.index_date + INTERVAL '1 month') THEN 'm1'
            WHEN m.measurement_date > (f.index_date + INTERVAL '1 month') AND m.measurement_date <= (f.index_date + INTERVAL '2 month') THEN 'm2'
            WHEN m.measurement_date > (f.index_date + INTERVAL '2 month') AND m.measurement_date <= (f.index_date + INTERVAL '3 month') THEN 'm3'
            WHEN m.measurement_date > (f.index_date + INTERVAL '3 month') AND m.measurement_date <= (f.index_date + INTERVAL '6 month') THEN 'm4_6'
            WHEN m.measurement_date > (f.index_date + INTERVAL '6 month') AND m.measurement_date <= (f.index_date + INTERVAL '9 month') THEN 'm7_9'
            WHEN m.measurement_date > (f.index_date + INTERVAL '9 month') AND m.measurement_date <= (f.index_date + INTERVAL '12 month') THEN 'm10_12'
            WHEN m.measurement_date > (f.index_date + INTERVAL '12 month') AND m.measurement_date <= (f.index_date + INTERVAL '15 month') THEN 'm13_15'
            WHEN m.measurement_date > (f.index_date + INTERVAL '15 month') AND m.measurement_date <= (f.index_date + INTERVAL '18 month') THEN 'm16_18'
            WHEN m.measurement_date > (f.index_date + INTERVAL '18 month') AND m.measurement_date <= (f.index_date + INTERVAL '21 month') THEN 'm19_21'
            WHEN m.measurement_date > (f.index_date + INTERVAL '21 month') AND m.measurement_date <= (f.index_date + INTERVAL '24 month') THEN 'm22_24'
        END AS time_point,
        CASE 
            WHEN m.measurement_date <= f.index_date THEN f.index_date
            WHEN m.measurement_date <= (f.index_date + INTERVAL '1 month') THEN f.index_date + INTERVAL '1 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '2 month') THEN f.index_date + INTERVAL '2 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '3 month') THEN f.index_date + INTERVAL '3 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '6 month') THEN f.index_date + INTERVAL '6 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '9 month') THEN f.index_date + INTERVAL '9 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '12 month') THEN f.index_date + INTERVAL '12 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '15 month') THEN f.index_date + INTERVAL '15 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '18 month') THEN f.index_date + INTERVAL '18 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '21 month') THEN f.index_date + INTERVAL '21 month'
            WHEN m.measurement_date <= (f.index_date + INTERVAL '24 month') THEN f.index_date + INTERVAL '24 month'
        END AS target_date,
        m.measurement_date
    FROM final_flag f
    JOIN measurement m ON f.person_id = m.person_id
    JOIN lab_concept_seed cs ON m.measurement_concept_id = cs.concept_id
    WHERE m.measurement_date >= f.index_date - INTERVAL '1 year'
      AND m.measurement_date <= f.feature_cutoff_date
),
ranked_labs AS (
    SELECT *,
        CASE
            WHEN value_as_concept_id = 4267416 THEN 1
            WHEN value_as_concept_id = 4267417 THEN -1
            WHEN range_high IS NOT NULL AND value_as_number > range_high THEN 1
            WHEN range_low IS NOT NULL AND value_as_number < range_low THEN -1
            WHEN value_as_number IS NOT NULL
             AND (range_low IS NOT NULL OR range_high IS NOT NULL) THEN 0
            ELSE NULL
        END AS remark_val,
        ROW_NUMBER() OVER (
            PARTITION BY person_id, set_name, time_point 
            ORDER BY ABS(EXTRACT(EPOCH FROM (measurement_date - target_date))) ASC,
                     measurement_id DESC
        ) AS rn
    FROM lab_segments
    WHERE time_point IS NOT NULL
)
SELECT 
    person_id,
    
    -- 1. TSH
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'base' THEN remark_val END) AS tsh_rem_base,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm1' THEN remark_val END) AS tsh_rem_m1,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm2' THEN remark_val END) AS tsh_rem_m2,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm3' THEN remark_val END) AS tsh_rem_m3,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm4_6' THEN remark_val END) AS tsh_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm7_9' THEN remark_val END) AS tsh_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm10_12' THEN remark_val END) AS tsh_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm13_15' THEN remark_val END) AS tsh_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm16_18' THEN remark_val END) AS tsh_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm19_21' THEN remark_val END) AS tsh_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_TSH' AND time_point = 'm22_24' THEN remark_val END) AS tsh_rem_m22_24,

    -- 2. FT4
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'base' THEN remark_val END) AS ft4_rem_base,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm1' THEN remark_val END) AS ft4_rem_m1,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm2' THEN remark_val END) AS ft4_rem_m2,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm3' THEN remark_val END) AS ft4_rem_m3,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm4_6' THEN remark_val END) AS ft4_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm7_9' THEN remark_val END) AS ft4_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm10_12' THEN remark_val END) AS ft4_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm13_15' THEN remark_val END) AS ft4_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm16_18' THEN remark_val END) AS ft4_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm19_21' THEN remark_val END) AS ft4_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_FT4' AND time_point = 'm22_24' THEN remark_val END) AS ft4_rem_m22_24,

    -- 3. FT3
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'base' THEN remark_val END) AS ft3_rem_base,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm1' THEN remark_val END) AS ft3_rem_m1,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm2' THEN remark_val END) AS ft3_rem_m2,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm3' THEN remark_val END) AS ft3_rem_m3,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm4_6' THEN remark_val END) AS ft3_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm7_9' THEN remark_val END) AS ft3_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm10_12' THEN remark_val END) AS ft3_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm13_15' THEN remark_val END) AS ft3_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm16_18' THEN remark_val END) AS ft3_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm19_21' THEN remark_val END) AS ft3_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_FT3' AND time_point = 'm22_24' THEN remark_val END) AS ft3_rem_m22_24,

    -- 4. Total T3
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'base' THEN remark_val END) AS total_t3_rem_base,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm1' THEN remark_val END) AS total_t3_rem_m1,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm2' THEN remark_val END) AS total_t3_rem_m2,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm3' THEN remark_val END) AS total_t3_rem_m3,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm4_6' THEN remark_val END) AS total_t3_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm7_9' THEN remark_val END) AS total_t3_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm10_12' THEN remark_val END) AS total_t3_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm13_15' THEN remark_val END) AS total_t3_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm16_18' THEN remark_val END) AS total_t3_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm19_21' THEN remark_val END) AS total_t3_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_TotalT3' AND time_point = 'm22_24' THEN remark_val END) AS total_t3_rem_m22_24,

    -- 5. Total T4
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'base' THEN remark_val END) AS total_t4_rem_base,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm1' THEN remark_val END) AS total_t4_rem_m1,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm2' THEN remark_val END) AS total_t4_rem_m2,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm3' THEN remark_val END) AS total_t4_rem_m3,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm4_6' THEN remark_val END) AS total_t4_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm7_9' THEN remark_val END) AS total_t4_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm10_12' THEN remark_val END) AS total_t4_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm13_15' THEN remark_val END) AS total_t4_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm16_18' THEN remark_val END) AS total_t4_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm19_21' THEN remark_val END) AS total_t4_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_TotalT4' AND time_point = 'm22_24' THEN remark_val END) AS total_t4_rem_m22_24,

    -- 6. RBC
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'base' THEN remark_val END) AS rbc_rem_base,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm1' THEN remark_val END) AS rbc_rem_m1,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm2' THEN remark_val END) AS rbc_rem_m2,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm3' THEN remark_val END) AS rbc_rem_m3,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm4_6' THEN remark_val END) AS rbc_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm7_9' THEN remark_val END) AS rbc_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm10_12' THEN remark_val END) AS rbc_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm13_15' THEN remark_val END) AS rbc_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm16_18' THEN remark_val END) AS rbc_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm19_21' THEN remark_val END) AS rbc_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_rbc' AND time_point = 'm22_24' THEN remark_val END) AS rbc_rem_m22_24,

    -- 4. HGB
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'base' THEN remark_val END) AS hgb_rem_base,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm1' THEN remark_val END) AS hgb_rem_m1,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm2' THEN remark_val END) AS hgb_rem_m2,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm3' THEN remark_val END) AS hgb_rem_m3,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm4_6' THEN remark_val END) AS hgb_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm7_9' THEN remark_val END) AS hgb_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm10_12' THEN remark_val END) AS hgb_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm13_15' THEN remark_val END) AS hgb_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm16_18' THEN remark_val END) AS hgb_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm19_21' THEN remark_val END) AS hgb_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_hgb' AND time_point = 'm22_24' THEN remark_val END) AS hgb_rem_m22_24,

    -- 5. HCT
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'base' THEN remark_val END) AS hct_rem_base,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm1' THEN remark_val END) AS hct_rem_m1,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm2' THEN remark_val END) AS hct_rem_m2,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm3' THEN remark_val END) AS hct_rem_m3,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm4_6' THEN remark_val END) AS hct_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm7_9' THEN remark_val END) AS hct_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm10_12' THEN remark_val END) AS hct_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm13_15' THEN remark_val END) AS hct_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm16_18' THEN remark_val END) AS hct_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm19_21' THEN remark_val END) AS hct_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_hct' AND time_point = 'm22_24' THEN remark_val END) AS hct_rem_m22_24,

    -- 6. MCV
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'base' THEN remark_val END) AS mcv_rem_base,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm1' THEN remark_val END) AS mcv_rem_m1,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm2' THEN remark_val END) AS mcv_rem_m2,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm3' THEN remark_val END) AS mcv_rem_m3,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm4_6' THEN remark_val END) AS mcv_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm7_9' THEN remark_val END) AS mcv_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm10_12' THEN remark_val END) AS mcv_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm13_15' THEN remark_val END) AS mcv_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm16_18' THEN remark_val END) AS mcv_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm19_21' THEN remark_val END) AS mcv_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_mcv' AND time_point = 'm22_24' THEN remark_val END) AS mcv_rem_m22_24,

    -- 7. MCH
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'base' THEN remark_val END) AS mch_rem_base,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm1' THEN remark_val END) AS mch_rem_m1,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm2' THEN remark_val END) AS mch_rem_m2,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm3' THEN remark_val END) AS mch_rem_m3,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm4_6' THEN remark_val END) AS mch_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm7_9' THEN remark_val END) AS mch_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm10_12' THEN remark_val END) AS mch_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm13_15' THEN remark_val END) AS mch_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm16_18' THEN remark_val END) AS mch_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm19_21' THEN remark_val END) AS mch_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_mch' AND time_point = 'm22_24' THEN remark_val END) AS mch_rem_m22_24,

    -- 8. MCHC
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'base' THEN remark_val END) AS mchc_rem_base,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm1' THEN remark_val END) AS mchc_rem_m1,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm2' THEN remark_val END) AS mchc_rem_m2,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm3' THEN remark_val END) AS mchc_rem_m3,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm4_6' THEN remark_val END) AS mchc_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm7_9' THEN remark_val END) AS mchc_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm10_12' THEN remark_val END) AS mchc_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm13_15' THEN remark_val END) AS mchc_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm16_18' THEN remark_val END) AS mchc_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm19_21' THEN remark_val END) AS mchc_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_mchc' AND time_point = 'm22_24' THEN remark_val END) AS mchc_rem_m22_24,

    -- 9. TG
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'base' THEN remark_val END) AS tg_rem_base,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm1' THEN remark_val END) AS tg_rem_m1,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm2' THEN remark_val END) AS tg_rem_m2,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm3' THEN remark_val END) AS tg_rem_m3,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm4_6' THEN remark_val END) AS tg_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm7_9' THEN remark_val END) AS tg_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm10_12' THEN remark_val END) AS tg_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm13_15' THEN remark_val END) AS tg_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm16_18' THEN remark_val END) AS tg_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm19_21' THEN remark_val END) AS tg_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_tg' AND time_point = 'm22_24' THEN remark_val END) AS tg_rem_m22_24,

    -- 10. AST
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'base' THEN remark_val END) AS ast_rem_base,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm1' THEN remark_val END) AS ast_rem_m1,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm2' THEN remark_val END) AS ast_rem_m2,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm3' THEN remark_val END) AS ast_rem_m3,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm4_6' THEN remark_val END) AS ast_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm7_9' THEN remark_val END) AS ast_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm10_12' THEN remark_val END) AS ast_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm13_15' THEN remark_val END) AS ast_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm16_18' THEN remark_val END) AS ast_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm19_21' THEN remark_val END) AS ast_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_AST' AND time_point = 'm22_24' THEN remark_val END) AS ast_rem_m22_24,

    -- 11. ALT
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'base' THEN remark_val END) AS alt_rem_base,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm1' THEN remark_val END) AS alt_rem_m1,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm2' THEN remark_val END) AS alt_rem_m2,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm3' THEN remark_val END) AS alt_rem_m3,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm4_6' THEN remark_val END) AS alt_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm7_9' THEN remark_val END) AS alt_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm10_12' THEN remark_val END) AS alt_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm13_15' THEN remark_val END) AS alt_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm16_18' THEN remark_val END) AS alt_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm19_21' THEN remark_val END) AS alt_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_ALT' AND time_point = 'm22_24' THEN remark_val END) AS alt_rem_m22_24,

    -- 12. HDL
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'base' THEN remark_val END) AS hdl_rem_base,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm1' THEN remark_val END) AS hdl_rem_m1,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm2' THEN remark_val END) AS hdl_rem_m2,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm3' THEN remark_val END) AS hdl_rem_m3,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm4_6' THEN remark_val END) AS hdl_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm7_9' THEN remark_val END) AS hdl_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm10_12' THEN remark_val END) AS hdl_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm13_15' THEN remark_val END) AS hdl_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm16_18' THEN remark_val END) AS hdl_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm19_21' THEN remark_val END) AS hdl_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_HDL' AND time_point = 'm22_24' THEN remark_val END) AS hdl_rem_m22_24,

    -- 13. LDL
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'base' THEN remark_val END) AS ldl_rem_base,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm1' THEN remark_val END) AS ldl_rem_m1,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm2' THEN remark_val END) AS ldl_rem_m2,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm3' THEN remark_val END) AS ldl_rem_m3,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm4_6' THEN remark_val END) AS ldl_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm7_9' THEN remark_val END) AS ldl_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm10_12' THEN remark_val END) AS ldl_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm13_15' THEN remark_val END) AS ldl_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm16_18' THEN remark_val END) AS ldl_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm19_21' THEN remark_val END) AS ldl_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_LDL' AND time_point = 'm22_24' THEN remark_val END) AS ldl_rem_m22_24,

    -- 14. SCr
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'base' THEN remark_val END) AS scr_rem_base,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm1' THEN remark_val END) AS scr_rem_m1,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm2' THEN remark_val END) AS scr_rem_m2,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm3' THEN remark_val END) AS scr_rem_m3,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm4_6' THEN remark_val END) AS scr_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm7_9' THEN remark_val END) AS scr_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm10_12' THEN remark_val END) AS scr_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm13_15' THEN remark_val END) AS scr_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm16_18' THEN remark_val END) AS scr_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm19_21' THEN remark_val END) AS scr_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_SCr' AND time_point = 'm22_24' THEN remark_val END) AS scr_rem_m22_24,

    -- 15. ALK_P
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'base' THEN remark_val END) AS alkp_rem_base,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm1' THEN remark_val END) AS alkp_rem_m1,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm2' THEN remark_val END) AS alkp_rem_m2,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm3' THEN remark_val END) AS alkp_rem_m3,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm4_6' THEN remark_val END) AS alkp_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm7_9' THEN remark_val END) AS alkp_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm10_12' THEN remark_val END) AS alkp_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm13_15' THEN remark_val END) AS alkp_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm16_18' THEN remark_val END) AS alkp_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm19_21' THEN remark_val END) AS alkp_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_ALK_P' AND time_point = 'm22_24' THEN remark_val END) AS alkp_rem_m22_24,

    -- 16. Cholesterol
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'base' THEN remark_val END) AS chol_rem_base,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm1' THEN remark_val END) AS chol_rem_m1,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm2' THEN remark_val END) AS chol_rem_m2,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm3' THEN remark_val END) AS chol_rem_m3,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm4_6' THEN remark_val END) AS chol_rem_m4_6,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm7_9' THEN remark_val END) AS chol_rem_m7_9,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm10_12' THEN remark_val END) AS chol_rem_m10_12,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm13_15' THEN remark_val END) AS chol_rem_m13_15,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm16_18' THEN remark_val END) AS chol_rem_m16_18,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm19_21' THEN remark_val END) AS chol_rem_m19_21,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm22_24' THEN remark_val END) AS chol_rem_m22_24

FROM ranked_labs 
WHERE rn = 1 
GROUP BY person_id;

/* ==========================================
   combine
   ========================================== */
--feature_age
--feature_sex
--feature_height
--feature_weight
--feature_bmi
--feature_cci_score
--feature_alcohol
--feature_smoking
--feature_amio_cumulative_dose
--feature_amio_data_quality
--feature_amio_aver_dose_kg
--feature_amio_duration_span
--feature_amio_sum_days
--feature_amio_pdd
--feature_rx_dynamic_wide
--feature_dx_dynamic_wide
--feature_lab_values_wide
--feature_lab_values_wide
--feature_window_observation

DROP TABLE IF EXISTS feature_all;
CREATE TEMP TABLE feature_all AS
SELECT *
FROM final_flag f
LEFT JOIN feature_age                  USING (person_id)
LEFT JOIN feature_sex                  USING (person_id)
LEFT JOIN feature_height               USING (person_id)
LEFT JOIN feature_weight               USING (person_id)
LEFT JOIN feature_bmi                  USING (person_id)
LEFT JOIN feature_cci_score            USING (person_id)
LEFT JOIN feature_alcohol              USING (person_id)
LEFT JOIN feature_smoking              USING (person_id)
LEFT JOIN feature_amio_cumulative_dose USING (person_id)
LEFT JOIN feature_amio_data_quality    USING (person_id)
LEFT JOIN feature_amio_aver_dose_kg    USING (person_id)
LEFT JOIN feature_amio_duration_span   USING (person_id)
LEFT JOIN feature_amio_sum_days        USING (person_id)
LEFT JOIN feature_amio_pdd             USING (person_id)
LEFT JOIN feature_rx_dynamic_wide      USING (person_id)
LEFT JOIN feature_dx_dynamic_wide      USING (person_id)
LEFT JOIN feature_window_observation   USING (person_id)
LEFT JOIN feature_lab_values_wide      USING (person_id)
LEFT JOIN feature_lab_remarks_wide      USING (person_id);

/* 조기 추적 종료 무사건 환자를 음성(0)으로 포함하는 분석 데이터 */
DROP TABLE IF EXISTS feature_all_censored_as_zero;
CREATE TEMP TABLE feature_all_censored_as_zero AS
SELECT *
FROM feature_all;

/* 조기 추적 종료 무사건 환자를 제외하는 complete-case 분석: 현재 비활성화
-- DROP TABLE IF EXISTS feature_all_complete_case;
-- CREATE TEMP TABLE feature_all_complete_case AS
-- SELECT *
-- FROM feature_all
-- WHERE aitd_flag_complete_case IS NOT NULL;
*/

/* ------------------------------------------------------------------------
   모델 입력용 최종 wide 테이블

   - 요청된 변수만 남기고 내부 컬럼명을 분석용 이름으로 정리한다.
   - sex는 남성=1, 여성=0, 기타/미상=NULL이다.
   - charlson_tot_grp는 Glasheen 2019 CDMF 기준의 연속형 Charlson 총점이며,
     나이는 별도 age 변수로 제공하므로 CCI 점수에 포함하지 않는다.
   - dx_anemia와 dx_anemias는 같은 의미이므로 dx_anemia 하나만 둔다.
   - 병용약물과 동반질환도 검사실 값과 동일하게 base부터 m22_24까지
     구간별 컬럼으로 펼쳐진다. 동반질환은 누적 상태로 유지되며,
     관찰하지 못한 미래 구간은 NULL이다.
   - 검사실 NULL이 미측정인지 미관찰인지 구분할 수 있도록 각 추적구간의
     관찰 완료 여부(m1_complete_flag~m22_24_complete_flag)를 포함한다.
   - 검사실 값은 각 검사마다 base, m1, m2, m3, m4_6, m7_9,
     m10_12, m13_15, m16_18, m19_21, m22_24 컬럼으로 펼쳐진다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS feature_model_wide;
CREATE TEMP TABLE feature_model_wide AS
SELECT *
FROM (
  SELECT
    person_id,
    aitd_flag AS outcome
  FROM final_flag
) outcome_feature
LEFT JOIN (
  SELECT person_id, age_at_index AS age
  FROM feature_age
) age_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, male_flag AS sex
  FROM feature_sex
) sex_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, height_cm AS height
  FROM feature_height
) height_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, weight_kg AS weight
  FROM feature_weight
) weight_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, bmi
  FROM feature_bmi
) bmi_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, charlson_index AS charlson_tot_grp
  FROM feature_cci_score
) charlson_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, current_drinker_flag AS alcohol
  FROM feature_alcohol
) alcohol_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, current_smoker_flag AS smoking
  FROM feature_smoking
) smoking_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, cumulative_dose_g
  FROM feature_amio_cumulative_dose
) cumulative_dose_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, aver_dose_g_per_kg AS aver_dose_kg
  FROM feature_amio_aver_dose_kg
) average_dose_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, duration_span_days AS duration
  FROM feature_amio_duration_span
) duration_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, pdd_g_per_day AS pdd
  FROM feature_amio_pdd
) pdd_feature USING (person_id)
LEFT JOIN (
  SELECT person_id, sum_days
  FROM feature_amio_sum_days
) therapeutic_days_feature USING (person_id)
LEFT JOIN feature_rx_dynamic_wide USING (person_id)
LEFT JOIN feature_dx_dynamic_wide USING (person_id)
LEFT JOIN feature_lab_values_wide USING (person_id)
LEFT JOIN (
  SELECT
    person_id,
    m1_complete_flag,
    m2_complete_flag,
    m3_complete_flag,
    m4_6_complete_flag,
    m7_9_complete_flag,
    m10_12_complete_flag,
    m13_15_complete_flag,
    m16_18_complete_flag,
    m19_21_complete_flag,
    m22_24_complete_flag
  FROM feature_window_observation
) observation_mask USING (person_id);

/* 민감도 분석 1: 조기 추적 소실 무사건 환자를 outcome=0으로 포함 */
DROP TABLE IF EXISTS feature_model_wide_censored_as_zero;
CREATE TEMP TABLE feature_model_wide_censored_as_zero AS
SELECT *
FROM feature_model_wide;

/* ------------------------------------------------------------------------
   SMART Task 1: 전체 코호트에서 AITD 이진예측

   outcome
     0 = 추적기간 중 TSH 기준 AITD 없음
     1 = 추적기간 중 저하증 또는 중독증 발생

   추적 소실 무사건 환자는 현재 연구 방침에 따라 outcome=0으로 포함한다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS smart_task1_labels;
CREATE TEMP TABLE smart_task1_labels AS
SELECT
    person_id,
    aitd_flag::int AS label
FROM final_flag;

DROP TABLE IF EXISTS feature_model_task1;
CREATE TEMP TABLE feature_model_task1 AS
SELECT *
FROM feature_model_wide_censored_as_zero;

/* ------------------------------------------------------------------------
   SMART Task 2: 실제 AITD 양성군에서 저하증 대 중독증 이진분류

   subtype_outcome
     0 = hypothyroidism (TSH >= 4.5)
     1 = thyrotoxicosis (TSH <= 0.35)

   최초 사건일에 저하증·중독증 값이 동시에 존재하는 mixed(class=3)는
   이진 정답을 하나로 정할 수 없으므로 Task 2 학습 대상에서 제외한다.
   feature_model_task2의 기존 outcome은 대상자가 모두 AITD 양성이므로 항상 1이다.
   SMART 입력을 만들 때 정답은 subtype_outcome을 사용하고 outcome은 피처에서 제외한다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS smart_task2_labels;
CREATE TEMP TABLE smart_task2_labels AS
SELECT
    person_id,
    CASE
        WHEN aitd_class = 1 THEN 0
        WHEN aitd_class = 2 THEN 1
    END::int AS label
FROM final_flag
WHERE aitd_flag = 1
  AND aitd_class IN (1, 2);

DROP TABLE IF EXISTS feature_model_task2;
CREATE TEMP TABLE feature_model_task2 AS
SELECT
    m.*,
    l.label AS subtype_outcome
FROM feature_model_wide_censored_as_zero m
JOIN smart_task2_labels l USING (person_id);

/* Task별 라벨 분포 및 Task 2 mixed 제외 건수 확인 */
SELECT
    'task1_aitd'::text AS task,
    COUNT(*) AS n_total,
    COUNT(*) FILTER (WHERE label = 0) AS n_label_0,
    COUNT(*) FILTER (WHERE label = 1) AS n_label_1,
    0::bigint AS n_mixed_excluded
FROM smart_task1_labels

UNION ALL

SELECT
    'task2_subtype'::text AS task,
    COUNT(*) AS n_total,
    COUNT(*) FILTER (WHERE label = 0) AS n_label_0,
    COUNT(*) FILTER (WHERE label = 1) AS n_label_1,
    (SELECT COUNT(*) FROM final_flag WHERE aitd_class = 3)::bigint
        AS n_mixed_excluded
FROM smart_task2_labels;

/* 민감도 분석 2: 조기 추적 소실 무사건 환자 제외 — 현재 비활성화
-- DROP TABLE IF EXISTS feature_model_wide_complete_case;
-- CREATE TEMP TABLE feature_model_wide_complete_case AS
-- SELECT m.*
-- FROM feature_model_wide m
-- JOIN final_flag f USING (person_id)
-- WHERE f.aitd_flag_complete_case IS NOT NULL;
*/

/* 전체 환자 행은 export_smart_v2.sql에서 CSV로 저장한다.
   psql 화면·로그에 환자 단위 자료가 출력되지 않도록 여기서는 건수만 확인한다. */
SELECT
    (SELECT COUNT(*) FROM feature_model_task1) AS n_task1_rows,
    (SELECT COUNT(*) FROM feature_model_task2) AS n_task2_rows;
