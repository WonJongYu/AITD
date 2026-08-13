/* ========================================================================
   PostgreSQL psql runner for the complete replication extraction pipeline

   Run from a new, empty closed-network result directory. \ir resolves the
   analysis files relative to this script, while \copy writes to the current
   client directory:

     psql -X -v ON_ERROR_STOP=1 \
       -v cdm_schema=cdm \
       -v vocabulary_schema=cdm \
       -d DATABASE_NAME \
       -f /approved/path/replication/run_all_replication_postgresql.sql

   The four analysis SQL files run in one connection because they exchange
   PostgreSQL TEMP TABLEs. Output CSV files are written by the psql client to
   its current working directory and must remain inside the closed network.
   ======================================================================== */

\set ON_ERROR_STOP on
\pset pager off

/* Command-line -v values override these defaults. */
\if :{?cdm_schema}
\else
\set cdm_schema 'cdm'
\endif

\if :{?vocabulary_schema}
\else
\set vocabulary_schema 'cdm'
\endif

\echo '============================================================'
\echo 'Replication pipeline starting'
\echo 'CDM schema       :' :cdm_schema
\echo 'Vocabulary schema:' :vocabulary_schema
\echo '============================================================'

BEGIN;

/* Safely quote schema identifiers and keep TEMP tables first. */
SELECT set_config(
    'search_path',
    format('pg_temp,%I,%I,public', :'cdm_schema', :'vocabulary_schema'),
    false
);
SET DateStyle TO 'ISO, YMD';

\echo '[1/5] Cohort selection'
\ir cohort3_selection.sql

\echo '[2/5] AITD labeling'
\ir labeling3.sql

\echo '[3/5] Descriptive statistics'
\ir demographics3_extraction.sql

\echo '[4/5] Feature extraction'
\ir feature3_extraction.sql

\echo '[5/5] Integrity checks'
\ir qa3_postgresql.sql

COMMIT;

\echo 'Writing closed-network CSV outputs in the current directory'
\copy (SELECT * FROM feature_all_censored_as_zero ORDER BY person_id) TO 'dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy (SELECT stage_order, stage, n FROM cohort_flow_summary ORDER BY stage_order) TO 'cohort_flow_summary.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy (SELECT item_order, item, value FROM replication_qa_summary ORDER BY item_order) TO 'replication_qa_summary.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\echo '============================================================'
\echo 'Replication SQL pipeline completed successfully'
\echo 'Created: dataset.csv, cohort_flow_summary.csv, replication_qa_summary.csv'
\echo '============================================================'
