/* ========================================================================
   File Name      : qa3_postgresql.sql
   Description    : 통합 replication SQL 실행 후 필수 무결성 검사
   SQL Dialect    : PostgreSQL
   Dependencies   : cohort3_selection.sql, labeling3.sql,
                    feature3_extraction.sql
   ======================================================================== */

/* 위반 건수가 한 건이라도 있으면 dataset export 전에 실행을 중단한다. */
DO $validation$
BEGIN
    IF EXISTS (
        SELECT person_id
        FROM final_flag
        GROUP BY person_id
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'final_flag contains duplicate person_id values';
    END IF;

    IF EXISTS (
        SELECT person_id
        FROM feature_all_censored_as_zero
        GROUP BY person_id
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'feature dataset contains duplicate person_id values';
    END IF;

    IF (SELECT COUNT(*) FROM final_flag)
       <> (SELECT COUNT(*) FROM feature_all_censored_as_zero) THEN
        RAISE EXCEPTION 'Row count differs between final_flag and feature dataset';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM final_flag
        WHERE aitd_flag NOT IN (0, 1)
           OR aitd_flag IS NULL
    ) THEN
        RAISE EXCEPTION 'aitd_flag contains NULL or non-binary values';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM final_flag
        WHERE aitd_event_date = index_date
    ) THEN
        RAISE EXCEPTION 'Index-day AITD remains after index-day exclusion';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM final_flag
        WHERE feature_cutoff_date > analysis_end_date
           OR (
                aitd_flag = 1
                AND feature_cutoff_date >= aitd_event_date
              )
    ) THEN
        RAISE EXCEPTION 'Invalid feature cutoff at or after event/censoring date';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM final_flag
        WHERE feature_cutoff_date < index_date
           OR feature_cutoff_date > index_date + INTERVAL '21 months'
    ) THEN
        RAISE EXCEPTION 'Feature cutoff is outside baseline-to-21-month range';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM final_flag
        WHERE last_complete_observation_window NOT IN (
            'base', 'm1', 'm2', 'm3', 'm4_6',
            'm7_9', 'm10_12', 'm13_15', 'm16_18', 'm19_21'
        )
    ) THEN
        RAISE EXCEPTION 'Unknown last_complete_observation_window value';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'feature_all_censored_as_zero'::regclass
          AND attnum > 0
          AND NOT attisdropped
          AND attname LIKE '%m22_24%'
    ) THEN
        RAISE EXCEPTION 'm22_24 feature column exists; this window is outcome-only';
    END IF;
END
$validation$;

DROP TABLE IF EXISTS pg_temp.replication_qa_summary;
CREATE TEMP TABLE replication_qa_summary AS
SELECT 1 AS item_order, 'final_cohort_rows'::text AS item,
       COUNT(*)::bigint AS value
FROM final_cohort

UNION ALL

SELECT 2, 'aitd_positive', COUNT(*)::bigint
FROM final_flag
WHERE aitd_flag = 1

UNION ALL

SELECT 3, 'aitd_negative', COUNT(*)::bigint
FROM final_flag
WHERE aitd_flag = 0

UNION ALL

SELECT 4, 'early_censored_negative', COUNT(*)::bigint
FROM final_flag
WHERE early_censor_flag = 1

UNION ALL

SELECT 5, 'index_day_aitd', COUNT(*)::bigint
FROM final_flag
WHERE aitd_event_date = index_date

UNION ALL

SELECT 6, 'feature_dataset_rows', COUNT(*)::bigint
FROM feature_all_censored_as_zero

UNION ALL

SELECT 7, 'patients_with_numeric_mcv', COUNT(*)::bigint
FROM feature_all_censored_as_zero
WHERE COALESCE(
    mcv_base, mcv_m1, mcv_m2, mcv_m3, mcv_m4_6,
    mcv_m7_9, mcv_m10_12, mcv_m13_15, mcv_m16_18, mcv_m19_21
) IS NOT NULL

UNION ALL

SELECT 8, 'patients_with_numeric_mch', COUNT(*)::bigint
FROM feature_all_censored_as_zero
WHERE COALESCE(
    mch_base, mch_m1, mch_m2, mch_m3, mch_m4_6,
    mch_m7_9, mch_m10_12, mch_m13_15, mch_m16_18, mch_m19_21
) IS NOT NULL

UNION ALL

SELECT 9, 'patients_with_numeric_mchc', COUNT(*)::bigint
FROM feature_all_censored_as_zero
WHERE COALESCE(
    mchc_base, mchc_m1, mchc_m2, mchc_m3, mchc_m4_6,
    mchc_m7_9, mchc_m10_12, mchc_m13_15, mchc_m16_18, mchc_m19_21
) IS NOT NULL;

SELECT item_order, item, value
FROM replication_qa_summary
ORDER BY item_order;

SELECT
    aitd_event_window,
    COUNT(*) AS n
FROM final_flag
WHERE aitd_flag = 1
GROUP BY aitd_event_window
ORDER BY MIN(aitd_event_date);

SELECT
    last_complete_observation_window,
    COUNT(*) AS n
FROM final_flag
GROUP BY last_complete_observation_window
ORDER BY MIN(feature_cutoff_date - index_date);
