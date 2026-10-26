-- Lab A, block A4: the DSA agent layer.
-- Run from the notebook (SQL cells) or directly. Creates:
--   AGENT.DSA_DRILLING_SV          semantic view (Cortex Analyst tool)
--   AGENT.GET_TAG_WINDOW(...)      selective tag retrieval (custom tool)
--   AGENT.SCORE_RIG_NOW(...)       live model scoring through the registry (custom tool)
--   AGENT.DSA_AGENT                the agent (document search slot is added in Lab B)
USE WAREHOUSE HOL_PTEN_WH;
USE SCHEMA HOL_PTEN_ML.AGENT;

-- 1. Semantic view: business vocabulary over scores, rigs/wells and NPT events
CREATE OR REPLACE SEMANTIC VIEW HOL_PTEN_ML.AGENT.DSA_DRILLING_SV
  TABLES (
    rigs AS HOL_PTEN_ML.AGG.WELL_HEADER PRIMARY KEY (rig_id)
      WITH SYNONYMS = ('rig', 'well', 'fleet') COMMENT = 'One row per rig and its current well',
    scores AS HOL_PTEN_ML.PREDICTIONS.STUCK_PIPE_SCORES PRIMARY KEY (rig_id, stand_no)
      WITH SYNONYMS = ('risk', 'stuck pipe risk', 'model scores') COMMENT = 'Model risk of stuck pipe in the 3 hours after each stand',
    npt AS HOL_PTEN_ML.LABELS.NPT_EVENTS PRIMARY KEY (event_id)
      WITH SYNONYMS = ('non-productive time', 'downtime', 'incidents') COMMENT = 'Recorded NPT events',
    mse AS HOL_PTEN_ML.AGG.STAND_MSE PRIMARY KEY (rig_id, stand_no)
      WITH SYNONYMS = ('mechanical specific energy', 'drilling efficiency', 'ROP efficiency')
      COMMENT = 'Mechanical Specific Energy and drilling parameters per stand',
    connections AS HOL_PTEN_ML.AGG.CONNECTION_TIMES PRIMARY KEY (rig_id, stand_no)
      WITH SYNONYMS = ('connection time', 'flat time', 'pipe connections')
      COMMENT = 'Minutes spent making each pipe connection',
    overpull AS HOL_PTEN_ML.AGG.OVERPULL_TREND PRIMARY KEY (rig_id, stand_no)
      WITH SYNONYMS = ('drag', 'overpull', 'pick-up slack-off', 'hookload drag')
      COMMENT = 'Pick-up vs slack-off hookload per connection; rising drag signals poor hole condition'
  )
  RELATIONSHIPS (
    scores_to_rigs AS scores (rig_id) REFERENCES rigs,
    npt_to_rigs AS npt (rig_id) REFERENCES rigs,
    mse_to_rigs AS mse (rig_id) REFERENCES rigs,
    connections_to_rigs AS connections (rig_id) REFERENCES rigs,
    overpull_to_rigs AS overpull (rig_id) REFERENCES rigs
  )
  FACTS (
    scores.risk AS stuck_pipe_risk COMMENT = 'Probability 0 to 1 of stuck pipe within 3 hours',
    npt.npt_minutes AS duration_min COMMENT = 'Event duration in minutes',
    mse.mse_value AS mse_ksi COMMENT = 'Mechanical Specific Energy in ksi; lower is more efficient',
    mse.rop AS avg_rop_fph COMMENT = 'Average rate of penetration in ft/h while drilling the stand',
    mse.wob AS avg_wob_klb COMMENT = 'Average weight on bit in klb',
    mse.surface_rpm AS avg_rpm COMMENT = 'Average surface RPM',
    connections.conn_minutes AS connection_min COMMENT = 'Minutes to make the connection',
    overpull.drag AS drag_klb COMMENT = 'Pick-up minus slack-off hookload in klb',
    overpull.drag_trend AS drag_5conn_avg_klb COMMENT = 'Rolling 5-connection average drag in klb'
  )
  DIMENSIONS (
    rigs.rig_id AS rig_id, rigs.basin AS basin, rigs.operator AS operator, rigs.rig_class AS rig_class,
    scores.stand_no AS stand_no COMMENT = 'Drill-pipe stand number on the well',
    scores.stand_end_ts AS stand_end_ts COMMENT = 'When the stand finished drilling',
    scores.stand_date AS TO_DATE(stand_end_ts),
    scores.is_high_risk AS stuck_pipe_risk >= 0.5 COMMENT = 'True when risk is 0.5 or higher',
    npt.event_type AS event_type COMMENT = 'STUCK_PIPE, LOST_CIRCULATION or EQUIPMENT_FAILURE',
    npt.event_start_ts AS event_start_ts, npt.event_date AS TO_DATE(event_start_ts),
    mse.mse_stand_no AS stand_no, mse.mse_date AS TO_DATE(stand_end_ts),
    connections.connection_stand_no AS stand_no, connections.connection_date AS TO_DATE(connection_start_ts),
    overpull.overpull_stand_no AS stand_no, overpull.overpull_date AS TO_DATE(connection_ts)
  )
  METRICS (
    scores.max_risk AS MAX(scores.risk) COMMENT = 'Highest risk in the period',
    scores.avg_risk AS AVG(scores.risk),
    scores.high_risk_stands AS COUNT_IF(scores.risk >= 0.5) COMMENT = 'Stands with risk of at least 0.5',
    npt.npt_events AS COUNT(npt.event_id),
    npt.npt_hours AS SUM(npt.npt_minutes) / 60,
    mse.avg_mse AS AVG(mse.mse_value) COMMENT = 'Average MSE in ksi',
    mse.avg_rop AS AVG(mse.rop) COMMENT = 'Average ROP in ft/h',
    connections.median_connection_min AS MEDIAN(connections.conn_minutes) COMMENT = 'Median connection time in minutes',
    connections.connection_count AS COUNT(connections.conn_minutes),
    connections.connection_hours AS SUM(connections.conn_minutes) / 60 COMMENT = 'Total hours spent on connections',
    overpull.max_drag AS MAX(overpull.drag) COMMENT = 'Highest drag in klb',
    overpull.avg_drag AS AVG(overpull.drag) COMMENT = 'Average drag in klb'
  )
  COMMENT = 'DSA drilling: stuck-pipe scores, MSE, connection time, drag, rigs and NPT events';

-- 2. Selective tag retrieval: the Oct 23 pain point (rig + tags + state + window)
--    Agent procedure tools must return a single cell, so both tools return one VARIANT:
--    an array of row objects (an empty array when nothing matches).
CREATE OR REPLACE PROCEDURE HOL_PTEN_ML.AGENT.GET_TAG_WINDOW(
    RIG_ID STRING, TAGS STRING, STATE STRING, START_TS STRING, END_TS STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Returns 10-minute summaries of selected tags for one rig, filtered by rig state and time window (JSON array)'
AS
$$
DECLARE
  result VARIANT;
BEGIN
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('tag', tag, 'bucket_start', bucket_start, 'avg_value', avg_value,
                                    'min_value', min_value, 'max_value', max_value, 'n', n))
           WITHIN GROUP (ORDER BY tag, bucket_start)
    INTO :result
    FROM (
      SELECT tag, TIME_SLICE(ts, 10, 'MINUTE') AS bucket_start,
             ROUND(AVG(value), 2) AS avg_value, ROUND(MIN(value), 2) AS min_value,
             ROUND(MAX(value), 2) AS max_value, COUNT(*) AS n
      FROM HOL_PTEN_ML.RAW.TAG_VALUE
      WHERE rig_id = :RIG_ID
        AND ARRAY_CONTAINS(tag::VARIANT, SPLIT(UPPER(REPLACE(:TAGS, ' ', '')), ','))
        AND (:STATE IS NULL OR :STATE = '' OR UPPER(:STATE) = 'ANY' OR state = UPPER(:STATE))
        AND ts BETWEEN TRY_TO_TIMESTAMP_NTZ(:START_TS) AND TRY_TO_TIMESTAMP_NTZ(:END_TS)
      GROUP BY 1, 2 ORDER BY 1, 2 LIMIT 2000);
  RETURN result;
END;
$$;

-- 3. Live scoring: run the registered model on a rig's most recent stands
CREATE OR REPLACE PROCEDURE HOL_PTEN_ML.AGENT.SCORE_RIG_NOW(RIG_ID STRING, LAST_N_STANDS INT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Scores the latest stands of one rig with STUCK_PIPE_MODEL V1 served from SPCS (STUCK_PIPE_SVC), as a JSON array'
AS
$$
DECLARE
  result VARIANT;
BEGIN
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('rig_id', rig_id, 'stand_no', stand_no, 'stand_end_ts', stand_end_ts,
                                    'stuck_pipe_risk', stuck_pipe_risk))
           WITHIN GROUP (ORDER BY stand_no)
    INTO :result
    FROM (
      WITH f AS (
        SELECT * FROM HOL_PTEN_ML.FEATURE_STORE."STAND_DRILLING_FEATURES$V1"
        WHERE rig_id = :RIG_ID QUALIFY ROW_NUMBER() OVER (ORDER BY stand_no DESC) <= LEAST(GREATEST(:LAST_N_STANDS, 1), 20))   -- clamp to 1..20
      SELECT rig_id, stand_no, stand_end_ts,
             ROUND(HOL_PTEN_ML.ML.STUCK_PIPE_SVC!PREDICT_PROBA(   -- SPCS inference service: warm, ~3 s vs ~12 s cold warehouse UDF
               hookload_avg, hookload_max, hookload_slope, torque_avg, torque_std, torque_slope,
               rop_avg, rop_slope, rpm_avg, spp_avg, wob_avg):"output_feature_1"::FLOAT, 4) AS stuck_pipe_risk
      FROM f);
  RETURN result;
END;
$$;

-- 4. The DSA agent
CREATE OR REPLACE AGENT HOL_PTEN_ML.AGENT.DSA_AGENT
  COMMENT = 'PTEN HoL: drilling data science assistant'
  PROFILE = '{"display_name": "DSA Drilling Assistant", "color": "blue"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 60
    tokens: 32000
instructions:
  orchestration: >
    You help drilling engineers and data scientists. For questions about risk scores, rigs,
    basins, operators or NPT events use DrillingAnalyst. For raw sensor behavior on a specific rig
    (hookload, torque, ROP, RPM, SPP, WOB, flow, block height) use GetTagWindow with the tag names
    HOOKLOAD_KLB, TORQUE_KFTLB, ROP_FPH, RPM, SPP_PSI, WOB_KLB, FLOW_IN_GPM, BLOCK_HEIGHT_FT.
    Data covers 2026-10-01 to 2026-10-14. To re-score a rig with the model use ScoreRigNow.
    DrillingAnalyst also covers drilling efficiency (MSE in ksi with ROP, WOB, RPM per stand),
    connection / flat time per connection (fleet median is about 14 minutes), and drag
    (pick-up minus slack-off hookload per connection). When explaining a stuck-pipe risk spike,
    check whether drag was trending up on that rig before it.
    For GetTagWindow, request all needed tags in ONE call (comma-separated TAGS), use state DRILLING unless
    asked otherwise, and answer from that single result; do not call it again per tag or re-query to verify.
  response: >
    Be concise and practical. Lead with the answer, then the evidence. Say which tool and time
    window the numbers came from.
  sample_questions:
    - question: "Which 5 rigs had the highest stuck-pipe risk on October 12?"
    - question: "Show torque and hookload for RIG_007 while drilling on 2026-10-10 between 06:00 and 12:00"
    - question: "Re-score the last 5 stands on RIG_003"
    - question: "Which rigs have the slowest median connection time versus the fleet, and how many hours is that?"
    - question: "Is RIG_007 showing rising drag before its stuck-pipe risk spikes?"
    - question: "Which basin drills most efficiently by average MSE and ROP?"
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: DrillingAnalyst
      description: Stuck-pipe risk scores per stand, rig and well attributes, NPT events, drilling efficiency (MSE, ROP, WOB, RPM per stand), connection / flat time per connection, and drag (pick-up minus slack-off hookload).
  - tool_spec:
      type: generic
      name: GetTagWindow
      description: 10-minute summaries of chosen sensor tags for one rig, filtered by rig state and time window.
      input_schema:
        type: object
        properties:
          RIG_ID: {type: string, description: "Rig id such as RIG_007"}
          TAGS: {type: string, description: "Comma separated tag names, e.g. TORQUE_KFTLB,HOOKLOAD_KLB"}
          STATE: {type: string, description: "DRILLING, CONNECTION, CIRCULATING, TRIPPING, NPT or ANY"}
          START_TS: {type: string, description: "Window start, YYYY-MM-DD HH:MI:SS"}
          END_TS: {type: string, description: "Window end, YYYY-MM-DD HH:MI:SS"}
        required: [RIG_ID, TAGS, STATE, START_TS, END_TS]
  - tool_spec:
      type: generic
      name: ScoreRigNow
      description: Runs the registered stuck-pipe model on the most recent stands of one rig.
      input_schema:
        type: object
        properties:
          RIG_ID: {type: string, description: "Rig id such as RIG_003"}
          LAST_N_STANDS: {type: integer, description: "How many recent stands to score, 1 to 20"}
        required: [RIG_ID, LAST_N_STANDS]
tool_resources:
  DrillingAnalyst:
    semantic_view: HOL_PTEN_ML.AGENT.DSA_DRILLING_SV
    execution_environment: {type: warehouse, warehouse: HOL_PTEN_WH}
  GetTagWindow:
    type: procedure
    identifier: HOL_PTEN_ML.AGENT.GET_TAG_WINDOW
    execution_environment: {type: warehouse, warehouse: HOL_PTEN_WH}
  ScoreRigNow:
    type: procedure
    identifier: HOL_PTEN_ML.AGENT.SCORE_RIG_NOW
    execution_environment: {type: warehouse, warehouse: HOL_PTEN_WH}
$$;

-- 5. Smoke tests
CALL HOL_PTEN_ML.AGENT.GET_TAG_WINDOW('RIG_007', 'TORQUE_KFTLB,HOOKLOAD_KLB', 'DRILLING', '2026-10-10 06:00:00', '2026-10-10 08:00:00');
CALL HOL_PTEN_ML.AGENT.SCORE_RIG_NOW('RIG_003', 5);
