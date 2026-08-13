/* ========================================================================
   File Name      : run_all_v2.sql
   Description    : V2 코호트·라벨·데모그래픽·피처를 한 세션에서 순차 실행
   Client         : PostgreSQL psql (\ir 메타 명령 사용)

   실행 예시
     1) OMOP CDM/vocabulary schema가 search_path에 포함되도록 접속한다.
     2) CSV 상대경로를 안전하게 처리하는 wrapper 실행을 권장한다.
          bash run_all_v2.sh -h HOST -p 5432 -U USER -d DATABASE
        Windows PowerShell에서는 다음 wrapper를 사용한다.
          .\run_all_v2.ps1 -h HOST -p 5432 -U USER -d DATABASE
        또는 SQL/DL 디렉터리에서 psql로 직접 실행한다.
          psql ... -f run_all_v2.sql

   주의
     - 중간 및 최종 결과는 TEMP TABLE이므로 같은 DB 세션에서만 유지된다.
     - 어느 단계에서든 오류가 발생하면 ON_ERROR_STOP이 이후 실행을 중지한다.
       psql -f 실행은 접속 종료와 함께 미완료 트랜잭션이 롤백된다.
       대화형 psql에서 오류가 나면 ROLLBACK;을 실행한 뒤 수정·재실행한다.
   ======================================================================== */

\set ON_ERROR_STOP on

BEGIN;

\echo '[1/5] cohort2_selection.sql'
\ir cohort2_selection.sql

\echo '[2/5] labeling2.sql'
\ir labeling2.sql

\echo '[3/5] demographics2_extraction.sql'
\ir demographics2_extraction.sql

\echo '[4/5] feature2_extraction.sql'
\ir feature2_extraction.sql

COMMIT;

/* 전체 단계가 같은 환자 흐름으로 연결되었는지 최종 건수를 확인한다. */
SELECT
    (SELECT COUNT(*) FROM final_cohort) AS n_final_cohort,
    (SELECT COUNT(*) FROM final_flag) AS n_final_flag,
    (SELECT COUNT(*) FROM baseline_all) AS n_demographics,
    (SELECT COUNT(*) FROM feature_model_task1) AS n_task1_rows,
    (SELECT COUNT(*) FROM feature_model_task2) AS n_task2_rows;

\echo '[5/5] export_smart_v2.sql'
\ir export_smart_v2.sql

/* 추적 소실 무사건 환자 제외 결과 건수: 현재 비활성화
-- , (SELECT COUNT(*) FROM feature_model_wide_complete_case)
--       AS n_feature_complete_case
*/
