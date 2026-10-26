-- PTEN hands-on lab: remove everything the labs created. Idempotent; safe to re-run.
-- Order matters: services before the compute pool, account objects after the database.
USE ROLE ACCOUNTADMIN;

-- 1. SPCS services (Lab A: app + model inference service). DROP SERVICE IF EXISTS still
--    fails when the database is already gone, so tolerate that on a re-run.
EXECUTE IMMEDIATE $$
BEGIN
  DROP SERVICE IF EXISTS HOL_PTEN_ML.APP.DSA_APP;
  DROP SERVICE IF EXISTS HOL_PTEN_ML.ML.STUCK_PIPE_SVC;
EXCEPTION
  WHEN OTHER THEN RETURN 'services skipped: ' || SQLERRM;
END;
$$;

-- 2. Database: everything schema-scoped goes with it. That includes agent AGENT.DSA_AGENT,
--    external agent DOCS.PTEN_DRILLING_RAG (TruLens, Lab B), search service
--    DOCS.DRILLING_DOCS_SEARCH, semantic view, procedures, feature store, model registry,
--    experiments, stages, image repository APP.IMAGES and network rule APP.HOL_PTEN_PYPI_RULE.
DROP DATABASE IF EXISTS HOL_PTEN_ML;

-- 3. Account-level objects
ALTER COMPUTE POOL IF EXISTS HOL_PTEN_POOL STOP ALL;
DROP COMPUTE POOL IF EXISTS HOL_PTEN_POOL;
DROP INTEGRATION IF EXISTS HOL_PTEN_PYPI_EAI;
DROP WAREHOUSE IF EXISTS HOL_PTEN_WH;
DROP ROLE IF EXISTS HOL_PTEN_ROLE;
-- Git API integration from the README's pre-lab step. Drop it after deleting the Git workspace:
--   DROP API INTEGRATION IF EXISTS HOL_PTEN_GIT;

-- Not reverted: ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION' (00_setup.sql).
-- Reset it only if the account did not use cross-region inference before the lab:
--   ALTER ACCOUNT UNSET CORTEX_ENABLED_CROSS_REGION;
