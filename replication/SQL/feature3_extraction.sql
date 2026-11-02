/* ========================================================================
   File Name      : feature3_extraction.sql
   Description    : replication 월 구간별 특징 추출
   SQL Dialect    : PostgreSQL
   Dependencies   : labeling3.sql (TEMP TABLE final_flag)
   ======================================================================== */

/* ==========================================
   Part 1
   ========================================== */

/* Age */

DROP TABLE IF EXISTS pg_temp.feature_age;
CREATE TEMP TABLE feature_age AS
SELECT
    f.person_id,
    EXTRACT(YEAR FROM AGE(f.index_date, p.birth_datetime)) AS age_at_index
FROM final_flag f
JOIN person p ON f.person_id = p.person_id;

/* Sex */

DROP TABLE IF EXISTS pg_temp.feature_sex;
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

DROP TABLE IF EXISTS pg_temp.feature_height;
CREATE TEMP TABLE feature_height AS
WITH height_raw AS (
    SELECT
        f.person_id,
        m.value_as_number AS height_cm,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY ABS(m.measurement_date - f.index_date)
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

DROP TABLE IF EXISTS pg_temp.feature_weight;
CREATE TEMP TABLE feature_weight AS
WITH weight_raw AS (
    SELECT
        f.person_id,
        m.value_as_number AS weight_kg,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY ABS(m.measurement_date - f.index_date)
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

DROP TABLE IF EXISTS pg_temp.feature_bmi;
CREATE TEMP TABLE feature_bmi AS
WITH bmi_measured_raw AS (
    SELECT
        f.person_id,
        m.value_as_number AS bmi_measured,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY ABS(m.measurement_date - f.index_date)
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

/* CCI */

/* CCI Concept Sets */
DROP TABLE IF EXISTS pg_temp.feature_cci_concept_set;
CREATE TEMP TABLE feature_cci_concept_set AS
WITH cci_concept_seed (set_name, concept_id) AS (
  VALUES
    ('CHARLSON_MI', 312327),
    ('CHARLSON_MI', 314666),
    ('CHARLSON_MI', 434376),
    ('CHARLSON_MI', 4270024),
    ('CHARLSON_MI', 438170),
    ('CHARLSON_MI', 4108217),
    ('CHARLSON_MI', 4108677),
    ('CHARLSON_MI', 4108218),
    ('CHARLSON_CHF', 316139),
    ('CHARLSON_PVD', 321052),
    ('CHARLSON_CVD', 381591),
    ('CHARLSON_DEMENTIA', 4182210),
    ('CHARLSON_COPD', 255573),
    ('CHARLSON_RHEUM', 80809),
    ('CHARLSON_PUD', 4027663),
    ('CHARLSON_DM', 4008576),
    ('CHARLSON_DM_COMP', 376112),
    ('CHARLSON_DM_COMP', 376065),
    ('CHARLSON_DM_COMP', 4222415),
    ('CHARLSON_DM_COMP', 377821),
    ('CHARLSON_DM_COMP', 4175440),
    ('CHARLSON_DM_COMP', 37016768),
    ('CHARLSON_DM_COMP', 4225055),
    ('CHARLSON_DM_COMP', 4224879),
    ('CHARLSON_DM_COMP', 37017431),
    ('CHARLSON_DM_COMP', 37017432),
    ('CHARLSON_DM_COMP', 443731),
    ('CHARLSON_DM_COMP', 192279),
    ('CHARLSON_DM_COMP', 200687),
    ('CHARLSON_DM_COMP', 4128221),
    ('CHARLSON_DM_COMP', 45769905),
    ('CHARLSON_DM_COMP', 45757535),
    ('CHARLSON_DM_COMP', 4096670),
    ('CHARLSON_DM_COMP', 4174977),
    ('CHARLSON_DM_COMP', 443733),
    ('CHARLSON_DM_COMP', 376979),
    ('CHARLSON_DM_COMP', 4221495),
    ('CHARLSON_DM_COMP', 4225656),
    ('CHARLSON_DM_COMP', 42538169),
    ('CHARLSON_DM_COMP', 45763583),
    ('CHARLSON_DM_COMP', 43530656),
    ('CHARLSON_DM_COMP', 43530685),
    ('CHARLSON_DM_COMP', 4227210),
    ('CHARLSON_DM_COMP', 380096),
    ('CHARLSON_DM_COMP', 4226121),
    ('CHARLSON_DM_COMP', 43530690),
    ('CHARLSON_DM_COMP', 4222876),
    ('CHARLSON_DM_COMP', 4223303),
    ('CHARLSON_DM_COMP', 45757507),
    ('CHARLSON_DM_COMP', 318712),
    ('CHARLSON_DM_COMP', 321822),
    ('CHARLSON_DM_COMP', 443729),
    ('CHARLSON_DM_COMP', 4200875),
    ('CHARLSON_DM_COMP', 36713094),
    ('CHARLSON_DM_COMP', 4131908),
    ('CHARLSON_DM_COMP', 43531616),
    ('CHARLSON_DM_COMP', 4029423),
    ('CHARLSON_DM_COMP', 45769876),
    ('CHARLSON_DM_COMP', 45757363),
    ('CHARLSON_DM_COMP', 443734),
    ('CHARLSON_DM_COMP', 439770),
    ('CHARLSON_DM_COMP', 4095288),
    ('CHARLSON_DM_COMP', 4228443),
    ('CHARLSON_DM_COMP', 4224254),
    ('CHARLSON_DM_COMP', 4226238),
    ('CHARLSON_DM_COMP', 201530),
    ('CHARLSON_DM_COMP', 201531),
    ('CHARLSON_DM_COMP', 36715571),
    ('CHARLSON_DM_COMP', 36717156),
    ('CHARLSON_DM_COMP', 42536604),
    ('CHARLSON_DM_COMP', 42536605),
    ('CHARLSON_DM_COMP', 4221933),
    ('CHARLSON_DM_COMP', 443732),
    ('CHARLSON_DM_COMP', 435216),
    ('CHARLSON_DM_COMP', 4063043),
    ('CHARLSON_DM_COMP', 4063042),
    ('CHARLSON_DM_COMP', 4058243),
    ('CHARLSON_DM_COMP', 43531007),
    ('CHARLSON_DM_COMP', 44793113),
    ('CHARLSON_HEMI_PARA', 374022),
    ('CHARLSON_HEMI_PARA', 192606),
    ('CHARLSON_RENAL', 46271022),
    ('CHARLSON_MALIGNANCY', 4162253),
    ('CHARLSON_LIVER_MILD', 193256),
    ('CHARLSON_LIVER_MOD_SEV', 4064161),
    ('CHARLSON_METASTATIC', 432851),
    ('CHARLSON_HIV', 46284256)
)
SELECT cs.set_name,
       ca.descendant_concept_id AS concept_id
FROM cci_concept_seed cs
JOIN concept_ancestor ca
  ON cs.concept_id = ca.ancestor_concept_id;


/* CCI Comorbidity Flags */
DROP TABLE IF EXISTS pg_temp.feature_cci_flags;
CREATE TEMP TABLE feature_cci_flags AS
SELECT
    f.person_id,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_MI' THEN 1 ELSE 0 END)          AS mi,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_CHF' THEN 1 ELSE 0 END)         AS chf,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_PVD' THEN 1 ELSE 0 END)         AS pvd,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_CVD' THEN 1 ELSE 0 END)         AS cvd,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_DEMENTIA' THEN 1 ELSE 0 END)    AS dementia,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_COPD' THEN 1 ELSE 0 END)        AS copd,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_RHEUM' THEN 1 ELSE 0 END)       AS rheum,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_PUD' THEN 1 ELSE 0 END)         AS pud,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_DM' THEN 1 ELSE 0 END)          AS dm,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_DM_COMP' THEN 2 ELSE 0 END)     AS dm_comp,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_RENAL' THEN 2 ELSE 0 END)       AS renal,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_MALIGNANCY' THEN 2 ELSE 0 END)  AS malignancy,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_LIVER_MILD' THEN 1 ELSE 0 END)  AS liver_mild,   
    MAX(CASE WHEN cs.set_name = 'CHARLSON_LIVER_MOD_SEV' THEN 3 ELSE 0 END) AS liver_mod_sev, 
    MAX(CASE WHEN cs.set_name = 'CHARLSON_HEMI_PARA' THEN 2 ELSE 0 END)   AS hemi_para,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_METASTATIC' THEN 6 ELSE 0 END)  AS metastatic,
    MAX(CASE WHEN cs.set_name = 'CHARLSON_HIV' THEN 6 ELSE 0 END)         AS hiv
FROM final_flag f
LEFT JOIN condition_occurrence co ON f.person_id = co.person_id 
    AND co.condition_start_date BETWEEN f.index_date - INTERVAL '1 year' AND f.index_date
LEFT JOIN feature_cci_concept_set cs ON co.condition_concept_id = cs.concept_id
GROUP BY f.person_id;

/* CCI Final Score */
DROP TABLE IF EXISTS pg_temp.feature_cci_score;
CREATE TEMP TABLE feature_cci_score AS
SELECT
    person_id,
    /*
       중증도 단계가 있는 범주는 동시에 더하지 않고 가장 높은 가중치만 사용한다.
       - 당뇨: 합병증 없음(1) vs 합병증 있음(2)
       - 간질환: 경증(1) vs 중등도·중증(3)
       - 악성종양: 비전이(2) vs 전이(6)
       나이는 feature_age로 별도 제공하므로 이 점수에는 포함하지 않는다.
    */
    (mi + chf + pvd + cvd + dementia + copd + rheum + pud
     + GREATEST(dm, dm_comp)
     + renal
     + GREATEST(malignancy, metastatic)
     + GREATEST(liver_mild, liver_mod_sev)
     + hemi_para + hiv) AS charlson_index
FROM feature_cci_flags;

/* ------------------------------------------------------------------------
   Glasheen et al. (2019) CDMF CCI 구현

   Reference:
   Glasheen WP, et al. Charlson Comorbidity Index: ICD-9 Update and
   ICD-10 Translation. Am Health Drug Benefits. 2019;12:188-197.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC6684052/

   위의 기존 OMOP concept seed 방식은 원본 코드와 비교하기 위해 남겨 두었고,
   아래에서 논문 부록의 ICD-9-CM/ICD-10-CM 코드 및 6개 계층 규칙을 적용하여
   feature_cci_flags와 feature_cci_score를 최종적으로 다시 생성한다.

   한국 데이터의 KCD7은 ICD-10 계열 코드로 처리한다. source vocabulary가 없는
   레코드는 코드가 영문자로 시작하면 ICD-10/KCD, 숫자로 시작하면 ICD-9로
   보조 판정한다.
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.feature_cci_code_rule;
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
DROP TABLE IF EXISTS pg_temp.feature_cci_diagnosis_normalized;
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
DROP TABLE IF EXISTS pg_temp.feature_cci_code_match;
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
DROP TABLE IF EXISTS pg_temp.feature_cci_flags;
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
DROP TABLE IF EXISTS pg_temp.feature_cci_score;
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
DROP TABLE IF EXISTS pg_temp.feature_cci_source_quality;
CREATE TEMP TABLE feature_cci_source_quality AS
SELECT
    code_system,
    COUNT(*) AS n_diagnosis,
    COUNT(*) FILTER (WHERE normalized_code IS NULL OR normalized_code = '') AS n_code_missing
FROM feature_cci_diagnosis_normalized
GROUP BY code_system;

/* Alcohol */

DROP TABLE IF EXISTS pg_temp.feature_alcohol;
CREATE TEMP TABLE feature_alcohol AS
WITH alc_raw AS (
    SELECT
        f.person_id,
        o.observation_concept_id,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY o.observation_date DESC
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

DROP TABLE IF EXISTS pg_temp.feature_smoking;
CREATE TEMP TABLE feature_smoking AS
WITH smoke_raw AS (
    SELECT
        f.person_id,
        o.observation_concept_id,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id
            ORDER BY o.observation_date DESC
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


DROP TABLE IF EXISTS pg_temp.concept_seed;
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

DROP TABLE IF EXISTS pg_temp.concept_set;
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



DROP TABLE IF EXISTS pg_temp.tmp_amio_strength;
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


DROP TABLE IF EXISTS pg_temp.feature_amio_rx_unit;
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

DROP TABLE IF EXISTS pg_temp.feature_amio_cumulative_dose;
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
DROP TABLE IF EXISTS pg_temp.feature_amio_data_quality;
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

DROP TABLE IF EXISTS pg_temp.feature_amio_aver_dose_kg;
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

DROP TABLE IF EXISTS pg_temp.feature_amio_duration_span;
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

DROP TABLE IF EXISTS pg_temp.feature_amio_sum_days;
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
DROP TABLE IF EXISTS pg_temp.feature_amio_calculable_sum_days;
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

DROP TABLE IF EXISTS pg_temp.feature_amio_pdd;
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

/* ------------------------------------------------------------------------
   공통 observation landmark

   원 논문의 feature 수집시점은 baseline, 1, 2, 3, 6, 9, 12, 15,
   18, 21개월이다. feature_cutoff_date까지 완전히 종료된 시점만 만든다.
   22~24개월은 outcome 관찰구간이므로 feature landmark를 만들지 않는다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.feature_observation_landmarks;
CREATE TEMP TABLE feature_observation_landmarks AS
SELECT
    f.person_id,
    v.landmark_name,
    v.landmark_month,
    CASE
        WHEN v.landmark_month = 0 THEN (f.index_date - INTERVAL '1 year')::date
        ELSE (f.index_date + make_interval(months => v.previous_month))::date
    END AS window_start_date,
    (f.index_date + make_interval(months => v.landmark_month))::date AS landmark_date,
    (f.index_date - INTERVAL '1 year')::date AS history_start_date,
    f.feature_cutoff_date::date
FROM final_flag f
CROSS JOIN (
    VALUES
        ('base', 0,  0),
        ('m1',   1,  0),
        ('m2',   2,  1),
        ('m3',   3,  2),
        ('m4_6',    6,  3),
        ('m7_9',    9,  6),
        ('m10_12', 12,  9),
        ('m13_15', 15, 12),
        ('m16_18', 18, 15),
        ('m19_21', 21, 18)
) AS v(landmark_name, landmark_month, previous_month)
WHERE f.index_date + make_interval(months => v.landmark_month)
      <= f.feature_cutoff_date;

/* ------------------------------------------------------------------------
   관찰시점별 Charlson index

   각 landmark 직전 1년의 진단을 사용해 CCI를 다시 계산한다. 따라서 새 진단이
   생기거나 과거 진단이 rolling 1-year window 밖으로 나가면 점수가 갱신된다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.feature_cci_score_long;
CREATE TEMP TABLE feature_cci_score_long AS
WITH diagnosis_normalized AS (
    SELECT
        l.person_id,
        l.landmark_name,
        l.landmark_month,
        l.landmark_date,
        co.condition_occurrence_id,
        REGEXP_REPLACE(
            UPPER(COALESCE(NULLIF(co.condition_source_value, ''), src.concept_code)),
            '[^A-Z0-9]', '', 'g'
        ) AS normalized_code,
        CASE
            WHEN src.vocabulary_id = 'ICD9CM' THEN 'ICD9CM'
            WHEN src.vocabulary_id IN ('ICD10CM', 'ICD10', 'KCD7') THEN 'ICD10CM'
            WHEN src.vocabulary_id IS NOT NULL THEN NULL
            WHEN UPPER(COALESCE(NULLIF(co.condition_source_value, ''), src.concept_code))
                 ~ '^[[:space:]]*[A-Z]' THEN 'ICD10CM'
            WHEN UPPER(COALESCE(NULLIF(co.condition_source_value, ''), src.concept_code))
                 ~ '^[[:space:]]*[0-9]' THEN 'ICD9CM'
            ELSE NULL
        END AS code_system
    FROM feature_observation_landmarks l
    LEFT JOIN condition_occurrence co
      ON co.person_id = l.person_id
     AND co.condition_start_date >= l.landmark_date - INTERVAL '1 year'
     AND co.condition_start_date <= l.landmark_date
    LEFT JOIN concept src
      ON src.concept_id = co.condition_source_concept_id
), code_match AS (
    SELECT DISTINCT
        d.person_id,
        d.landmark_name,
        d.landmark_month,
        d.landmark_date,
        d.condition_occurrence_id,
        r.set_name
    FROM diagnosis_normalized d
    JOIN feature_cci_code_rule r
      ON r.code_system = d.code_system
     AND d.normalized_code ~ r.code_regex
    WHERE d.normalized_code IS NOT NULL
      AND d.normalized_code <> ''
), flags AS (
    SELECT
        l.person_id,
        l.landmark_name,
        l.landmark_month,
        l.landmark_date,
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
    FROM feature_observation_landmarks l
    LEFT JOIN code_match m
      ON m.person_id = l.person_id
     AND m.landmark_month = l.landmark_month
    GROUP BY
        l.person_id, l.landmark_name, l.landmark_month, l.landmark_date
)
SELECT
    person_id,
    landmark_name,
    landmark_month,
    landmark_date,
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
FROM flags;

/* 최종 환자 테이블에는 마지막 완전 observation window의 CCI를 연결한다. */
DROP TABLE IF EXISTS pg_temp.feature_cci_score;
CREATE TEMP TABLE feature_cci_score AS
WITH ranked AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.person_id
            ORDER BY c.landmark_month DESC
        ) AS rn
    FROM feature_cci_score_long c
)
SELECT
    person_id,
    landmark_name AS cci_snapshot_landmark,
    charlson_index
FROM ranked
WHERE rn = 1;

DROP TABLE IF EXISTS pg_temp.rx_feature_concept_seed;
CREATE TEMP TABLE rx_feature_concept_seed (
    set_name   text,
    concept_id bigint
) ON COMMIT PRESERVE ROWS;

DELETE FROM pg_temp.rx_feature_concept_seed
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

DROP TABLE IF EXISTS pg_temp.rx_feature_concept_set;
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

/*
   관찰시점별 병용약물 플래그

   *_window_flag: 해당 observation window와 처방기간이 한 날짜라도 겹침
   *_ever_flag  : baseline lookback 시작일부터 해당 landmark까지 한 번이라도 겹침

   원 논문의 정확한 병용약물 집계 방식이 확인되기 전까지 두 정의를 모두
   보존한다. 최종 환자 snapshot에는 마지막 완전 window의 window_flag를 쓴다.
*/
DROP TABLE IF EXISTS pg_temp.feature_rx_history_long;
CREATE TEMP TABLE feature_rx_history_long AS
WITH rx_records AS (
    SELECT
        de.person_id,
        de.drug_concept_id,
        de.drug_exposure_start_date::date AS rx_start_date,
        COALESCE(
            de.drug_exposure_end_date::date,
            (
                de.drug_exposure_start_date::date
                + (GREATEST(COALESCE(de.days_supply, 1), 1) - 1) * INTERVAL '1 day'
            )::date
        ) AS rx_end_date
    FROM drug_exposure de
)
SELECT
    l.person_id,
    l.landmark_name,
    l.landmark_month,
    l.window_start_date,
    l.landmark_date,
    MAX(CASE WHEN cs.set_name = 'rx_TKIs' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_tkis_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_allopurinol' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_allopurinol_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_antipsychotic' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_antipsychotic_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_NSAID' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_nsaid_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_antiDMs' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_antidms_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_metformin' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_metformin_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_propafenone' AND
                  (l.landmark_month = 0 OR r.rx_end_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS rx_propafenone_window_flag,
    MAX(CASE WHEN cs.set_name = 'rx_TKIs' THEN 1 ELSE 0 END) AS rx_tkis_ever_flag,
    MAX(CASE WHEN cs.set_name = 'rx_allopurinol' THEN 1 ELSE 0 END) AS rx_allopurinol_ever_flag,
    MAX(CASE WHEN cs.set_name = 'rx_antipsychotic' THEN 1 ELSE 0 END) AS rx_antipsychotic_ever_flag,
    MAX(CASE WHEN cs.set_name = 'rx_NSAID' THEN 1 ELSE 0 END) AS rx_nsaid_ever_flag,
    MAX(CASE WHEN cs.set_name = 'rx_antiDMs' THEN 1 ELSE 0 END) AS rx_antidms_ever_flag,
    MAX(CASE WHEN cs.set_name = 'rx_metformin' THEN 1 ELSE 0 END) AS rx_metformin_ever_flag,
    MAX(CASE WHEN cs.set_name = 'rx_propafenone' THEN 1 ELSE 0 END) AS rx_propafenone_ever_flag
FROM feature_observation_landmarks l
LEFT JOIN rx_records r
  ON r.person_id = l.person_id
 AND r.rx_start_date <= l.landmark_date
 AND r.rx_end_date >= l.history_start_date
LEFT JOIN rx_feature_concept_set cs
  ON r.drug_concept_id = cs.concept_id
GROUP BY
    l.person_id, l.landmark_name, l.landmark_month,
    l.window_start_date, l.landmark_date;

/* 환자별 마지막 완전 observation window의 병용약물 snapshot */
DROP TABLE IF EXISTS pg_temp.feature_rx_history;
CREATE TEMP TABLE feature_rx_history AS
WITH ranked AS (
    SELECT
        h.*,
        ROW_NUMBER() OVER (
            PARTITION BY h.person_id
            ORDER BY h.landmark_month DESC
        ) AS rn
    FROM feature_rx_history_long h
)
SELECT
    person_id,
    landmark_name AS rx_snapshot_landmark,
    rx_tkis_window_flag AS rx_tkis_flag,
    rx_allopurinol_window_flag AS rx_allopurinol_flag,
    rx_antipsychotic_window_flag AS rx_antipsychotic_flag,
    rx_nsaid_window_flag AS rx_nsaid_flag,
    rx_antidms_window_flag AS rx_antidms_flag,
    rx_metformin_window_flag AS rx_metformin_flag,
    rx_propafenone_window_flag AS rx_propafenone_flag
FROM ranked
WHERE rn = 1;


SELECT 'rx_TKIs'              AS set_name, SUM(rx_tkis_flag)         AS n_persons FROM feature_rx_history
UNION ALL
SELECT 'rx_allopurinol',                     SUM(rx_allopurinol_flag)            FROM feature_rx_history
UNION ALL
SELECT 'rx_antipsychotic',                   SUM(rx_antipsychotic_flag)          FROM feature_rx_history
UNION ALL
SELECT 'rx_NSAID',                           SUM(rx_nsaid_flag)                  FROM feature_rx_history
UNION ALL
SELECT 'rx_antiDMs',                         SUM(rx_antidms_flag)                FROM feature_rx_history
UNION ALL
SELECT 'rx_metformin',                       SUM(rx_metformin_flag)              FROM feature_rx_history
UNION ALL
SELECT 'rx_propafenone',                          SUM(rx_propafenone_flag)            FROM feature_rx_history
ORDER BY set_name;


/* ==========================================
   Part 4
   ========================================== */

DROP TABLE IF EXISTS pg_temp.dx_code_seed;
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

DROP TABLE IF EXISTS pg_temp.dx_feature_concept_seed;
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



DROP TABLE IF EXISTS pg_temp.dx_feature_concept_set;
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


/*
   관찰시점별 동반질환 플래그

   *_window_flag: 해당 observation window에 새 진단이 기록됨
   *_ever_flag  : baseline lookback 시작일부터 해당 landmark까지 진단된 적 있음

   만성질환은 이전 진단을 다음 landmark에도 유지할 수 있도록 ever_flag를
   함께 보존하며, 최종 환자 snapshot에는 마지막 landmark의 ever_flag를 쓴다.
*/
DROP TABLE IF EXISTS pg_temp.feature_dx_history_long;
CREATE TEMP TABLE feature_dx_history_long AS
SELECT
    l.person_id,
    l.landmark_name,
    l.landmark_month,
    l.window_start_date,
    l.landmark_date,
    MAX(CASE WHEN cs.set_name = 'dx_bradycardia' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_bradycardia_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_goiter' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_goiter_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_anemia' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_anemia_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_hypertension' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_hypertension_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_diabetes' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_diabetes_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_dm_nephropathy' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_dm_nephropathy_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_dm_complications' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_dm_complications_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_gouts' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_gouts_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_chronic_rf' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_chronic_rf_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_renal_dysfunction' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_renal_dysfunction_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_rheumatoid_arthritis' AND
                  (l.landmark_month = 0 OR co.condition_start_date > l.window_start_date)
             THEN 1 ELSE 0 END) AS dx_ra_window_flag,
    MAX(CASE WHEN cs.set_name = 'dx_bradycardia' THEN 1 ELSE 0 END) AS dx_bradycardia_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_goiter' THEN 1 ELSE 0 END) AS dx_goiter_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_anemia' THEN 1 ELSE 0 END) AS dx_anemia_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_hypertension' THEN 1 ELSE 0 END) AS dx_hypertension_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_diabetes' THEN 1 ELSE 0 END) AS dx_diabetes_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_dm_nephropathy' THEN 1 ELSE 0 END) AS dx_dm_nephropathy_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_dm_complications' THEN 1 ELSE 0 END) AS dx_dm_complications_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_gouts' THEN 1 ELSE 0 END) AS dx_gouts_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_chronic_rf' THEN 1 ELSE 0 END) AS dx_chronic_rf_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_renal_dysfunction' THEN 1 ELSE 0 END) AS dx_renal_dysfunction_ever_flag,
    MAX(CASE WHEN cs.set_name = 'dx_rheumatoid_arthritis' THEN 1 ELSE 0 END) AS dx_ra_ever_flag
FROM feature_observation_landmarks l
LEFT JOIN condition_occurrence co
  ON co.person_id = l.person_id
 AND co.condition_start_date >= l.history_start_date
 AND co.condition_start_date <= l.landmark_date
LEFT JOIN dx_feature_concept_set cs
  ON co.condition_concept_id = cs.concept_id
GROUP BY
    l.person_id, l.landmark_name, l.landmark_month,
    l.window_start_date, l.landmark_date;

/* 환자별 마지막 완전 observation window의 누적 동반질환 snapshot */
DROP TABLE IF EXISTS pg_temp.feature_dx_history;
CREATE TEMP TABLE feature_dx_history AS
WITH ranked AS (
    SELECT
        h.*,
        ROW_NUMBER() OVER (
            PARTITION BY h.person_id
            ORDER BY h.landmark_month DESC
        ) AS rn
    FROM feature_dx_history_long h
)
SELECT
    person_id,
    landmark_name AS dx_snapshot_landmark,
    dx_bradycardia_ever_flag AS dx_bradycardia_flag,
    dx_goiter_ever_flag AS dx_goiter_flag,
    dx_anemia_ever_flag AS dx_anemia_flag,
    dx_hypertension_ever_flag AS dx_hypertension_flag,
    dx_diabetes_ever_flag AS dx_diabetes_flag,
    dx_dm_nephropathy_ever_flag AS dx_dm_nephropathy_flag,
    dx_dm_complications_ever_flag AS dx_dm_complications_flag,
    dx_gouts_ever_flag AS dx_gouts_flag,
    dx_chronic_rf_ever_flag AS dx_chronic_rf_flag,
    dx_renal_dysfunction_ever_flag AS dx_renal_dysfunction_flag,
    dx_ra_ever_flag AS dx_ra_flag
FROM ranked
WHERE rn = 1;

/* Python/후속 모델링에서 바로 사용할 수 있는 환자×landmark 동적 이력 */
DROP TABLE IF EXISTS pg_temp.feature_rx_dx_history_long;
CREATE TEMP TABLE feature_rx_dx_history_long AS
SELECT
    l.person_id,
    l.landmark_name,
    l.landmark_month,
    l.window_start_date,
    l.landmark_date,
    c.charlson_index,
    r.rx_tkis_window_flag,
    r.rx_allopurinol_window_flag,
    r.rx_antipsychotic_window_flag,
    r.rx_nsaid_window_flag,
    r.rx_antidms_window_flag,
    r.rx_metformin_window_flag,
    r.rx_propafenone_window_flag,
    r.rx_tkis_ever_flag,
    r.rx_allopurinol_ever_flag,
    r.rx_antipsychotic_ever_flag,
    r.rx_nsaid_ever_flag,
    r.rx_antidms_ever_flag,
    r.rx_metformin_ever_flag,
    r.rx_propafenone_ever_flag,
    d.dx_bradycardia_window_flag,
    d.dx_goiter_window_flag,
    d.dx_anemia_window_flag,
    d.dx_hypertension_window_flag,
    d.dx_diabetes_window_flag,
    d.dx_dm_nephropathy_window_flag,
    d.dx_dm_complications_window_flag,
    d.dx_gouts_window_flag,
    d.dx_chronic_rf_window_flag,
    d.dx_renal_dysfunction_window_flag,
    d.dx_ra_window_flag,
    d.dx_bradycardia_ever_flag,
    d.dx_goiter_ever_flag,
    d.dx_anemia_ever_flag,
    d.dx_hypertension_ever_flag,
    d.dx_diabetes_ever_flag,
    d.dx_dm_nephropathy_ever_flag,
    d.dx_dm_complications_ever_flag,
    d.dx_gouts_ever_flag,
    d.dx_chronic_rf_ever_flag,
    d.dx_renal_dysfunction_ever_flag,
    d.dx_ra_ever_flag
FROM feature_observation_landmarks l
LEFT JOIN feature_rx_history_long r
  ON r.person_id = l.person_id
 AND r.landmark_month = l.landmark_month
LEFT JOIN feature_dx_history_long d
  ON d.person_id = l.person_id
 AND d.landmark_month = l.landmark_month
LEFT JOIN feature_cci_score_long c
  ON c.person_id = l.person_id
 AND c.landmark_month = l.landmark_month;


SELECT 'dx_bradycardia' AS dx, COUNT(*) AS cnt
FROM feature_dx_history WHERE dx_bradycardia_flag = 1
UNION ALL
SELECT 'dx_goiter', COUNT(*) FROM feature_dx_history WHERE dx_goiter_flag = 1
UNION ALL
SELECT 'dx_anemia', COUNT(*) FROM feature_dx_history WHERE dx_anemia_flag = 1
UNION ALL
SELECT 'dx_hypertension', COUNT(*) FROM feature_dx_history WHERE dx_hypertension_flag = 1
UNION ALL
SELECT 'dx_diabetes', COUNT(*) FROM feature_dx_history WHERE dx_diabetes_flag = 1
UNION ALL
SELECT 'dx_dm_nephropathy', COUNT(*) FROM feature_dx_history WHERE dx_dm_nephropathy_flag = 1
UNION ALL
SELECT 'dx_dm_complications', COUNT(*) FROM feature_dx_history WHERE dx_dm_complications_flag = 1
UNION ALL
SELECT 'dx_gouts', COUNT(*) FROM feature_dx_history WHERE dx_gouts_flag = 1
UNION ALL
SELECT 'dx_chronic_rf', COUNT(*) FROM feature_dx_history WHERE dx_chronic_rf_flag = 1
UNION ALL
SELECT 'dx_renal_dysfunction', COUNT(*) FROM feature_dx_history WHERE dx_renal_dysfunction_flag = 1
UNION ALL
SELECT 'dx_rheumatoid_arthritis', COUNT(*) FROM feature_dx_history WHERE dx_ra_flag = 1;



/* ==========================================
   Part 5
   ========================================== */

/* Lab Concept Seed */
DROP TABLE IF EXISTS pg_temp.lab_concept_seed;
CREATE TEMP TABLE lab_concept_seed (
    set_name TEXT,
    concept_id INT
);

INSERT INTO lab_concept_seed (set_name, concept_id) VALUES
    ('lab_TSH', 3009201), 
    ('lab_FT4', 3008598), 
    ('lab_FT4', 42529233),
    -- Free triiodothyronine (FT3), LOINC 14928-6
    ('lab_FT3', 3026989),
    ('lab_rbc', 3026361), 
    ('lab_hgb', 3000963),
    ('lab_hct', 3009542),
    -- Mean corpuscular volume (MCV), Gil CDM concept
    ('lab_mcv', 37065843),
    -- Mean corpuscular hemoglobin (MCH), Gil CDM concept
    ('lab_mch', 37045413),
    -- Mean corpuscular hemoglobin concentration (MCHC), Gil CDM concept
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

   - 양성/조기 추적 종료: 실제 종료점 직전의 마지막 완전 관찰시점으로
     feature_cutoff_date가 설정됨
   - 완전 추적 음성: 논문의 마지막 feature 수집시점인 21개월까지 모두 1
   - 조기 추적 종료: 종료 이전의 마지막 완전 observation window까지만 사용
   - 22~24개월은 outcome 관찰구간이며 feature 수집구간이 아님
   ------------------------------------------------------------------------ */

DROP TABLE IF EXISTS pg_temp.feature_window_observation;
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
    CASE WHEN feature_cutoff_date >= index_date + INTERVAL '21 month' THEN 1 ELSE 0 END AS m19_21_complete_flag
FROM final_flag;


  
/* [Part 5] Longitudinal Lab Values - Baseline + 9 Follow-up Windows */

DROP TABLE IF EXISTS pg_temp.feature_lab_values_wide;
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
    /* 1. TSH (baseline + 9 follow-up windows) */
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

    /* 2. FT4 (baseline + 9 follow-up windows) */
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

    /* 3. FT3 (baseline + 9 follow-up windows) */
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

    /* 4. RBC (baseline + 9 follow-up windows) */
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

    /* 4. HGB (baseline + 9 follow-up windows) */
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

    /* 5. HCT (baseline + 9 follow-up windows) */
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

    /* 6. MCV (baseline + 9 follow-up windows) */
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

    /* 7. MCH (baseline + 9 follow-up windows) */
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

    /* 8. MCHC (baseline + 9 follow-up windows) */
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

    /* 9. TG (baseline + 9 follow-up windows) */
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

    /* 10. AST (baseline + 9 follow-up windows) */
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

    /* 11. ALT (baseline + 9 follow-up windows) */
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

    /* 12. HDL (baseline + 9 follow-up windows) */
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

    /* 13. LDL (baseline + 9 follow-up windows) */
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

    /* 14. SCr (baseline + 9 follow-up windows) */
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

    /* 15. ALK_P (baseline + 9 follow-up windows) */
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

    /* 16. Cholesterol (baseline + 9 follow-up windows) */
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'base' THEN value_as_number END) AS cholesterol_base,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm1' THEN value_as_number END) AS cholesterol_m1,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm2' THEN value_as_number END) AS cholesterol_m2,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm3' THEN value_as_number END) AS cholesterol_m3,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm4_6' THEN value_as_number END) AS cholesterol_m4_6,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm7_9' THEN value_as_number END) AS cholesterol_m7_9,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm10_12' THEN value_as_number END) AS cholesterol_m10_12,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm13_15' THEN value_as_number END) AS cholesterol_m13_15,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm16_18' THEN value_as_number END) AS cholesterol_m16_18,
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm19_21' THEN value_as_number END) AS cholesterol_m19_21

FROM ranked_labs WHERE rn = 1
GROUP BY person_id;


/* ==========================================
   Part 6
   ========================================== */

DROP TABLE IF EXISTS pg_temp.feature_lab_remarks_wide;
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

    -- 4. RBC
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
    MAX(CASE WHEN set_name = 'lab_Cholesterol' AND time_point = 'm19_21' THEN remark_val END) AS chol_rem_m19_21

FROM ranked_labs 
WHERE rn = 1 
GROUP BY person_id;

/* ------------------------------------------------------------------------
   원 논문 방식의 검사 변화율

   - feature_cutoff_date 이내의 실제 측정값만 사용한다.
   - 같은 검사에서 최초값과 최종값 사이의 변화를 실제 검사일 간격으로
     나눈 뒤 365를 곱해 연환산한다.
   - 두 검사일이 없거나 같은 날뿐이면 NULL이며 Python에서 0으로 처리한다.
   - 논문은 어떤 두 측정값을 썼는지 명시하지 않아 최초-최종값으로 구현한다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.feature_lab_slopes;
CREATE TEMP TABLE feature_lab_slopes AS
WITH eligible AS (
    SELECT
        f.person_id,
        cs.set_name,
        m.measurement_date,
        m.measurement_id,
        m.value_as_number,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id, cs.set_name
            ORDER BY m.measurement_date, m.measurement_id
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id, cs.set_name
            ORDER BY m.measurement_date DESC, m.measurement_id DESC
        ) AS rn_last
    FROM final_flag f
    JOIN measurement m
      ON m.person_id = f.person_id
     AND m.measurement_date >= f.index_date - INTERVAL '1 year'
     AND m.measurement_date <= f.feature_cutoff_date
     AND m.value_as_number IS NOT NULL
    JOIN lab_concept_seed cs
      ON cs.concept_id = m.measurement_concept_id
     AND cs.set_name IN ('lab_AST', 'lab_ALT', 'lab_SCr', 'lab_Cholesterol')
), paired AS (
    SELECT
        person_id,
        set_name,
        MAX(measurement_date) FILTER (WHERE rn_first = 1) AS first_date,
        MAX(value_as_number) FILTER (WHERE rn_first = 1) AS first_value,
        MAX(measurement_date) FILTER (WHERE rn_last = 1) AS last_date,
        MAX(value_as_number) FILTER (WHERE rn_last = 1) AS last_value
    FROM eligible
    GROUP BY person_id, set_name
), annualized AS (
    SELECT
        person_id,
        set_name,
        CASE
            WHEN last_date > first_date
            THEN (last_value - first_value)
                 / NULLIF((last_date - first_date)::numeric, 0) * 365.0
            ELSE NULL
        END AS annualized_slope
    FROM paired
)
SELECT
    person_id,
    MAX(annualized_slope) FILTER (WHERE set_name = 'lab_AST') AS ast_slope,
    MAX(annualized_slope) FILTER (WHERE set_name = 'lab_ALT') AS alt_slope,
    MAX(annualized_slope) FILTER (WHERE set_name = 'lab_SCr') AS scr_slope,
    MAX(annualized_slope) FILTER (WHERE set_name = 'lab_Cholesterol') AS cholesterol_slope
FROM annualized
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
--feature_rx_history
--feature_dx_history
--feature_lab_values_wide
--feature_lab_values_wide
--feature_window_observation

DROP TABLE IF EXISTS pg_temp.feature_all;
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
LEFT JOIN feature_rx_history           USING (person_id)
LEFT JOIN feature_dx_history           USING (person_id)
LEFT JOIN feature_window_observation   USING (person_id)
LEFT JOIN feature_lab_values_wide      USING (person_id)
LEFT JOIN feature_lab_remarks_wide     USING (person_id)
LEFT JOIN feature_lab_slopes           USING (person_id);

/* 조기 추적 종료 무사건 환자를 음성(0)으로 포함하는 분석 데이터 */
DROP TABLE IF EXISTS pg_temp.feature_all_censored_as_zero;
CREATE TEMP TABLE feature_all_censored_as_zero AS
SELECT *
FROM feature_all;

/* 조기 추적 종료 무사건 환자를 제외하는 complete-case 분석 데이터 */
DROP TABLE IF EXISTS pg_temp.feature_all_complete_case;
CREATE TEMP TABLE feature_all_complete_case AS
SELECT *
FROM feature_all
WHERE aitd_flag_complete_case IS NOT NULL;

/* ------------------------------------------------------------------------
   모델 입력용 최종 wide 테이블

   - 요청된 변수만 남기고 내부 컬럼명을 분석용 이름으로 정리한다.
   - sex는 남성=1, 여성=0, 기타/미상=NULL이다.
   - charlson_tot_grp는 Glasheen 2019 CDMF 기준의 연속형 Charlson 총점이며,
     나이는 별도 age 변수로 제공하므로 CCI 점수에 포함하지 않는다.
   - dx_anemia와 dx_anemias는 같은 의미이므로 dx_anemia 하나만 둔다.
   - 검사실 값은 각 검사마다 base, m1, m2, m3, m4_6, m7_9,
     m10_12, m13_15, m16_18, m19_21 컬럼으로 펼쳐진다.
   - 22~24개월은 outcome 관찰구간이므로 feature 컬럼으로 만들지 않는다.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS pg_temp.feature_model_wide;
CREATE TEMP TABLE feature_model_wide AS
SELECT *
FROM (
  SELECT person_id, aitd_flag AS outcome
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
LEFT JOIN (
  SELECT
    person_id,
    rx_tkis_flag AS rx_tkis,
    rx_allopurinol_flag AS rx_allopurinol,
    rx_antipsychotic_flag AS rx_antipsychotic,
    rx_nsaid_flag AS rx_nsaid,
    rx_antidms_flag AS rx_antidms,
    rx_metformin_flag AS rx_metformin,
    rx_propafenone_flag AS rx_propafenone
  FROM feature_rx_history
) rx_feature USING (person_id)
LEFT JOIN (
  SELECT
    person_id,
    dx_bradycardia_flag AS dx_bradycardia,
    dx_goiter_flag AS dx_goiter,
    dx_anemia_flag AS dx_anemia,
    dx_hypertension_flag AS dx_hypertension,
    dx_diabetes_flag AS dx_diabetes,
    dx_dm_nephropathy_flag AS dx_dmnephropathys,
    dx_dm_complications_flag AS dx_dm_coms,
    dx_gouts_flag AS dx_gouts,
    dx_chronic_rf_flag AS dx_chronic_rfs,
    dx_renal_dysfunction_flag AS dx_renal_dyss,
    dx_ra_flag AS dx_ras
  FROM feature_dx_history
) dx_feature USING (person_id)
LEFT JOIN feature_lab_values_wide USING (person_id)
LEFT JOIN feature_lab_slopes USING (person_id);

/* 민감도 분석 1: 조기 추적 소실 무사건 환자를 outcome=0으로 포함 */
DROP TABLE IF EXISTS pg_temp.feature_model_wide_censored_as_zero;
CREATE TEMP TABLE feature_model_wide_censored_as_zero AS
SELECT *
FROM feature_model_wide;

/* 민감도 분석 2: 조기 추적 소실 무사건 환자를 제외 */
DROP TABLE IF EXISTS pg_temp.feature_model_wide_complete_case;
CREATE TEMP TABLE feature_model_wide_complete_case AS
SELECT m.*
FROM feature_model_wide m
JOIN final_flag f USING (person_id)
WHERE f.aitd_flag_complete_case IS NOT NULL;

/*
   Python dataset.csv는 cutoff/생존분석 보조 컬럼과 remark를 포함한
   feature_all_censored_as_zero를 사용한다. 전체 행은 psql runner의 \copy로
   저장하고 콘솔에는 환자 수준 자료를 출력하지 않는다.
*/
SELECT
    COUNT(*) AS n_rows,
    COUNT(DISTINCT person_id) AS n_patients,
    COUNT(*) FILTER (WHERE aitd_flag = 1) AS n_aitd
FROM feature_all_censored_as_zero;
