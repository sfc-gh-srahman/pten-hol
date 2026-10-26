-- PTEN hands-on lab: synthetic drilling data shaped like PTEN's
--
-- Mirrors a common drilling data pattern: a time-series engine (QuestDB here) computes
-- 1-second / 1-minute aggregates that land in Snowflake as a tall/skinny table (rig, well, ts, tag, value,
-- state, stand). This lab uses 1-minute grain:
--   20 rigs x 40 tags x 14 days x 1,440 min  ~= 16M rows in RAW.TAG_VALUE
-- Scale up by changing the two variables below (100 rigs / longer window).
--
-- Stuck-pipe precursors are injected for 120 minutes before each labeled STUCK_PIPE
-- event (overpull on hookload, torque rising, ROP and RPM falling), so a model can
-- learn real signal. Values are synthetic; tag names are generic, not PTEN's.

-- Runs as the admin (or HOL_PTEN_ROLE) role
USE WAREHOUSE HOL_PTEN_WH;
USE DATABASE HOL_PTEN_ML;

SET n_rigs = 20;
SET n_days = 14;
SET start_ts = '2026-10-01 00:00:00'::TIMESTAMP_NTZ;

-- 1. Rigs / wells -----------------------------------------------------------
CREATE OR REPLACE TABLE AGG.WELL_HEADER AS
SELECT
  'RIG_' || LPAD(n + 1, 3, '0')                                        AS rig_id,
  'WELL_' || LPAD(n + 1, 3, '0')                                       AS well_id,
  ARRAY_CONSTRUCT('Permian - Midland', 'Permian - Delaware', 'Eagle Ford', 'Haynesville')[MOD(n, 4)]::STRING AS basin,
  ARRAY_CONSTRUCT('Operator A', 'Operator B', 'Operator C')[MOD(n, 3)]::STRING AS operator,
  ARRAY_CONSTRUCT('APEX-XK 1500', 'APEX-XC 1500', 'APEX-PK 1000')[MOD(n, 3)]::STRING AS rig_class,
  $start_ts                                                           AS spud_ts,
  9500 + MOD(n * 733, 6000)                                            AS planned_td_ft,
  8.75                                                                 AS bit_diameter_in,
  -- crew efficiency: extra connection minutes for this rig (a few rigs are slow)
  IFF(n IN (4, 11, 17), 9, MOD(n * 7, 5))                              AS crew_extra_min
FROM (SELECT SEQ4() AS n FROM TABLE(GENERATOR(ROWCOUNT => 1000))) WHERE n < $n_rigs;

-- 2. NPT events (ground truth) ------------------------------------------------
-- 3 events per rig; ~75% stuck pipe, the rest other NPT types (noise for the model)
CREATE OR REPLACE TABLE LABELS.NPT_EVENTS AS
SELECT
  'NPT_' || LPAD(e + 1, 4, '0')                                        AS event_id,
  w.rig_id, w.well_id,
  DATEADD(MINUTE, 1800 + MOD(ABS(HASH(e, 'pten')), $n_days * 1440 - 3600), $start_ts) AS event_start_ts,
  IFF(MOD(e, 4) = 3, ARRAY_CONSTRUCT('LOST_CIRCULATION', 'EQUIPMENT_FAILURE')[MOD(FLOOR(e / 4), 2)]::STRING, 'STUCK_PIPE') AS event_type,
  30 + MOD(ABS(HASH(e, 'dur')), 150)                                   AS duration_min
FROM (SELECT SEQ4() AS e FROM TABLE(GENERATOR(ROWCOUNT => 1000))) g
JOIN (SELECT rig_id, well_id, ROW_NUMBER() OVER (ORDER BY rig_id) - 1 AS r FROM AGG.WELL_HEADER) w
  ON MOD(g.e, $n_rigs) = w.r
WHERE g.e < $n_rigs * 3;

-- 3. Wide 1-minute frame per rig (core drilling channels) ----------------------
CREATE OR REPLACE TRANSIENT TABLE RAW._MINUTE_WIDE AS
WITH mins AS (
  SELECT m FROM (SELECT SEQ4() AS m FROM TABLE(GENERATOR(ROWCOUNT => 100000))) WHERE m < $n_days * 1440
),
frame AS (
  SELECT w.rig_id, w.well_id, mins.m,
         DATEADD(MINUTE, mins.m, $start_ts) AS ts,
         FLOOR(mins.m / 90) + 1          AS stand_no,      -- ~90 min per stand
         MOD(mins.m, 90)                 AS pos,           -- minute within stand
         -- connection length: 10 min base + crew factor + per-stand jitter (0-4 min)
         10 + w.crew_extra_min + MOD(ABS(HASH(w.rig_id, FLOOR(mins.m / 90))), 5) AS conn_len
  FROM AGG.WELL_HEADER w CROSS JOIN mins
),
ev AS (
  SELECT f.rig_id, f.m,
         MAX(IFF(e.event_type = 'STUCK_PIPE'
                 AND DATEDIFF(MINUTE, f.ts, e.event_start_ts) BETWEEN 0 AND 120,
                 1 - DATEDIFF(MINUTE, f.ts, e.event_start_ts) / 120, 0)) AS p,   -- precursor ramp 0..1
         -- drag builds earlier than the other precursors (6 h), as hole cleaning degrades
         MAX(IFF(e.event_type = 'STUCK_PIPE'
                 AND DATEDIFF(MINUTE, f.ts, e.event_start_ts) BETWEEN 0 AND 360,
                 1 - DATEDIFF(MINUTE, f.ts, e.event_start_ts) / 360, 0)) AS p_drag,
         MAX(IFF(f.ts >= e.event_start_ts
                 AND f.ts < DATEADD(MINUTE, e.duration_min, e.event_start_ts), 1, 0)) AS in_npt
  FROM frame f JOIN LABELS.NPT_EVENTS e
    ON e.rig_id = f.rig_id
   AND f.ts BETWEEN DATEADD(MINUTE, -360, e.event_start_ts) AND DATEADD(MINUTE, e.duration_min, e.event_start_ts)
  GROUP BY 1, 2
)
SELECT f.*,
       COALESCE(ev.p, 0) AS p,
       COALESCE(ev.p_drag, 0) AS p_drag,
       CASE WHEN COALESCE(ev.in_npt, 0) = 1 THEN 'NPT'
            WHEN MOD(f.stand_no, 37) = 0   THEN 'TRIPPING'
            WHEN f.pos < 60                THEN 'DRILLING'
            WHEN f.pos < 60 + f.conn_len   THEN 'CONNECTION'
            ELSE 'CIRCULATING' END        AS state
FROM frame f LEFT JOIN ev ON ev.rig_id = f.rig_id AND ev.m = f.m;

CREATE OR REPLACE TRANSIENT TABLE RAW._MINUTE_CORE AS
SELECT rig_id, well_id, ts, m, stand_no, state, p, p_drag,
  250 + 20 * SIN(m / 300) + NORMAL(0, 6, RANDOM()) + p * 70                                   AS hookload_klb,
  IFF(state = 'DRILLING', 18, 3) + NORMAL(0, 1.2, RANDOM()) + p * 14                          AS torque_kftlb,
  CASE state WHEN 'DRILLING' THEN 3200 WHEN 'CIRCULATING' THEN 3000 WHEN 'NPT' THEN 1500 ELSE 250 END
        + NORMAL(0, 60, RANDOM()) + p * 180                                                    AS spp_psi,
  GREATEST(0, IFF(state = 'DRILLING', 120, IFF(state = 'CIRCULATING', 40, 0)) + NORMAL(0, 4, RANDOM()) - p * 45) AS rpm,
  GREATEST(0, IFF(state = 'DRILLING', 85 + NORMAL(0, 12, RANDOM()) - p * 60, 0))              AS rop_fph,
  GREATEST(0, IFF(state = 'DRILLING', 25 + NORMAL(0, 3, RANDOM()) + p * 6, 0))                AS wob_klb,
  IFF(state = 'DRILLING', 95 - 1.5 * MOD(m, 60), 5 + MOD(m, 15) * 6) + NORMAL(0, 0.5, RANDOM()) AS block_height_ft,
  GREATEST(0, IFF(state IN ('DRILLING', 'CIRCULATING'), 620, 0) + NORMAL(0, 15, RANDOM()) - p * 40) AS flow_in_gpm,
  -- pick-up / slack-off hookload, measured only during connections. Drag (PU - SO) is
  -- ~40 klb normally and grows as hole conditions deteriorate before stuck pipe.
  IFF(state = 'CONNECTION', 272 + 20 * SIN(m / 300) + NORMAL(0, 4, RANDOM()) + p_drag * 55, NULL) AS hookload_pu_klb,
  IFF(state = 'CONNECTION', 232 + 20 * SIN(m / 300) + NORMAL(0, 4, RANDOM()) - p_drag * 25, NULL) AS hookload_so_klb
FROM RAW._MINUTE_WIDE;

-- 4. Tall/skinny tag table: 10 core channels + 32 auxiliary channels ---------
-- (UNPIVOT drops NULLs, so PU/SO rows exist only for connection minutes)
CREATE OR REPLACE TABLE RAW.TAG_VALUE (
  rig_id STRING, well_id STRING, ts TIMESTAMP_NTZ, tag STRING, value FLOAT, state STRING, stand_no INT
) CLUSTER BY (rig_id, tag, TO_DATE(ts))
COMMENT = 'Synthetic 1-minute tag values, tall/skinny, shaped like PTEN QuestDB output';

INSERT INTO RAW.TAG_VALUE
SELECT rig_id, well_id, ts, UPPER(tag), value, state, stand_no FROM RAW._MINUTE_CORE
  UNPIVOT (value FOR tag IN (hookload_klb, torque_kftlb, spp_psi, rpm, rop_fph, wob_klb, block_height_ft, flow_in_gpm,
                             hookload_pu_klb, hookload_so_klb))
UNION ALL
SELECT c.rig_id, c.well_id, c.ts, 'AUX_' || LPAD(a.k, 2, '0'), 50 + 10 * SIN(c.m / (37 + a.k)) + NORMAL(0, 2, RANDOM()),
       c.state, c.stand_no
FROM RAW._MINUTE_CORE c
CROSS JOIN (SELECT SEQ4() + 1 AS k FROM TABLE(GENERATOR(ROWCOUNT => 32))) a
ORDER BY 1, 4, 3;

-- 5. Stand / state / tag aggregates (what the agent and model read) ---------
CREATE OR REPLACE TABLE AGG.STAND_STATE_TAG_AGG AS
SELECT rig_id, well_id, stand_no, state, tag,
       MIN(ts) AS start_ts, MAX(ts) AS end_ts, COUNT(*) AS n_samples,
       AVG(value) AS avg_value, MIN(value) AS min_value, MAX(value) AS max_value,
       STDDEV(value) AS std_value,
       REGR_SLOPE(value, DATEDIFF(SECOND, '2026-01-01', ts) / 60) AS slope_per_min
FROM RAW.TAG_VALUE
GROUP BY 1, 2, 3, 4, 5;

DROP TABLE RAW._MINUTE_WIDE;
DROP TABLE RAW._MINUTE_CORE;

-- 6. Sanity checks ------------------------------------------------------------
SELECT 'TAG_VALUE' t, COUNT(*) n FROM RAW.TAG_VALUE
UNION ALL SELECT 'STAND_STATE_TAG_AGG', COUNT(*) FROM AGG.STAND_STATE_TAG_AGG
UNION ALL SELECT 'NPT_EVENTS', COUNT(*) FROM LABELS.NPT_EVENTS;
