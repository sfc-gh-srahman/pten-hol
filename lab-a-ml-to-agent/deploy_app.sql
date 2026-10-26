-- Lab A, block A5: deploy the DSA app to Snowpark Container Services.
-- Run from the notebook (A5). Prerequisite: the app image is pushed from a laptop (Docker or Podman):
--   snow spcs image-registry login
--   docker build --platform linux/amd64 -t <repository_url>/dsa-app:v8 lab-a-ml-to-agent/app
--   docker push <repository_url>/dsa-app:v8
USE WAREHOUSE HOL_PTEN_WH;
USE SCHEMA HOL_PTEN_ML.APP;

CREATE SERVICE IF NOT EXISTS HOL_PTEN_ML.APP.DSA_APP
  IN COMPUTE POOL HOL_PTEN_POOL
  FROM SPECIFICATION $$
spec:
  containers:
  - name: dsa-app
    image: /hol_pten_ml/app/images/dsa-app:v8
    env:
      AGENT_FQN: HOL_PTEN_ML.AGENT.DSA_AGENT
      SNOWFLAKE_WAREHOUSE: HOL_PTEN_WH
    readinessProbe:
      port: 8080
      path: /healthz
  endpoints:
  - name: ui
    port: 8080
    public: true
serviceRoles:
- name: app_user
  endpoints: [ui]
$$
  QUERY_WAREHOUSE = HOL_PTEN_WH
  COMMENT = 'PTEN HoL: DSA Drilling Assistant front end';

-- Who can open the app: grant the service role to an account role
GRANT SERVICE ROLE HOL_PTEN_ML.APP.DSA_APP!APP_USER TO ROLE HOL_PTEN_ROLE;

SELECT SYSTEM$GET_SERVICE_STATUS('HOL_PTEN_ML.APP.DSA_APP');
SHOW ENDPOINTS IN SERVICE HOL_PTEN_ML.APP.DSA_APP;   -- open ingress_url in a browser (Snowflake login)
