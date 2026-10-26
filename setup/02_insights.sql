-- PTEN hands-on lab: derived drilling insights (run after 01_generate_synthetic.sql)
--
-- Three cheap, high-value insights from the same 1-minute tag data. Each one becomes a
-- semantic-view table for the DSA agent and a chart in the PTEN+ app.
--   AGG.STAND_MSE           Pillar 1, drilling optimization: Mechanical Specific Energy per stand
--   AGG.CONNECTION_TIMES    Pillar 1, flat time: minutes per connection, benchmarked vs fleet
--   AGG.OVERPULL_TREND      Pillar 2, wellbore stability: pick-up vs slack-off drag per connection
-- The rig-state classifier (Pillar 5) is Python and lives in the Lab A notebook.

USE WAREHOUSE HOL_PTEN_WH;
USE DATABASE HOL_PTEN_ML;

-- 1. Mechanical Specific Energy (Teale, 1965), per drilling minute, averaged per stand.
--    MSE [psi] = 4*WOB / (pi*d^2)  +  480*Torque*RPM / (d^2 * ROP)
--    WOB in lbf, torque in ft-lbf, d in inches, ROP in ft/h. Reported in ksi.
--    Low MSE at high ROP = efficient drilling; rising MSE at flat ROP = dysfunction or a dull bit.
CREATE OR REPLACE TABLE AGG.STAND_MSE AS
WITH m AS (
  SELECT rig_id, stand_no, ts,
         MAX(IFF(tag = 'WOB_KLB', value, NULL)) * 1000      AS wob_lbf,
         MAX(IFF(tag = 'TORQUE_KFTLB', value, NULL)) * 1000 AS torque_ftlbf,
         MAX(IFF(tag = 'RPM', value, NULL))                 AS rpm,
         MAX(IFF(tag = 'ROP_FPH', value, NULL))             AS rop_fph
  FROM RAW.TAG_VALUE
  WHERE state = 'DRILLING' AND tag IN ('WOB_KLB', 'TORQUE_KFTLB', 'RPM', 'ROP_FPH')
  GROUP BY 1, 2, 3
)
SELECT m.rig_id, m.stand_no, MAX(m.ts) AS stand_end_ts, w.basin,
       ROUND(AVG((4 * wob_lbf / (PI() * POWER(w.bit_diameter_in, 2))
                 + 480 * torque_ftlbf * rpm / (POWER(w.bit_diameter_in, 2) * rop_fph)) / 1000), 1) AS mse_ksi,
       ROUND(AVG(rop_fph), 1) AS avg_rop_fph,
       ROUND(AVG(wob_lbf) / 1000, 1) AS avg_wob_klb,
       ROUND(AVG(rpm), 0) AS avg_rpm
FROM m JOIN AGG.WELL_HEADER w USING (rig_id)
WHERE rop_fph > 5                      -- ignore near-zero ROP minutes (MSE blows up)
GROUP BY 1, 2, 4;

-- 2. Connection (flat) time: minutes spent in CONNECTION per stand.
CREATE OR REPLACE TABLE AGG.CONNECTION_TIMES AS
SELECT a.rig_id, a.stand_no, a.start_ts AS connection_start_ts, w.basin, w.rig_class,
       a.n_samples AS connection_min
FROM AGG.STAND_STATE_TAG_AGG a JOIN AGG.WELL_HEADER w USING (rig_id)
WHERE a.state = 'CONNECTION' AND a.tag = 'HOOKLOAD_KLB';

-- Fleet benchmark: each rig's median vs fleet p50 / p90, and estimated hours lost
-- relative to the fleet median (what the operator actually cares about).
CREATE OR REPLACE VIEW AGG.CONNECTION_BENCHMARK AS
WITH fleet AS (
  SELECT MEDIAN(connection_min) AS fleet_p50, APPROX_PERCENTILE(connection_min, 0.9) AS fleet_p90
  FROM AGG.CONNECTION_TIMES
)
SELECT c.rig_id, c.basin, c.rig_class,
       COUNT(*) AS connections,
       MEDIAN(c.connection_min) AS rig_median_min,
       ANY_VALUE(f.fleet_p50) AS fleet_p50_min,
       ANY_VALUE(f.fleet_p90) AS fleet_p90_min,
       ROUND(SUM(GREATEST(c.connection_min - f.fleet_p50, 0)) / 60, 1) AS hours_above_fleet_median
FROM AGG.CONNECTION_TIMES c CROSS JOIN fleet f
GROUP BY 1, 2, 3;

-- 3. Overpull / drag: pick-up minus slack-off hookload per connection, with a rolling
--    5-connection trend. Rising drag is the classic early sign of poor hole cleaning
--    or differential sticking, independent of the ML score (good for explainability).
CREATE OR REPLACE TABLE AGG.OVERPULL_TREND AS
WITH c AS (
  SELECT rig_id, stand_no, MIN(start_ts) AS connection_ts,
         MAX(IFF(tag = 'HOOKLOAD_PU_KLB', avg_value, NULL)) AS pu_klb,
         MAX(IFF(tag = 'HOOKLOAD_SO_KLB', avg_value, NULL)) AS so_klb
  FROM AGG.STAND_STATE_TAG_AGG
  WHERE state = 'CONNECTION' AND tag IN ('HOOKLOAD_PU_KLB', 'HOOKLOAD_SO_KLB')
  GROUP BY 1, 2
)
SELECT rig_id, stand_no, connection_ts,
       ROUND(pu_klb, 1) AS pickup_klb, ROUND(so_klb, 1) AS slackoff_klb,
       ROUND(pu_klb - so_klb, 1) AS drag_klb,
       ROUND(AVG(pu_klb - so_klb) OVER (PARTITION BY rig_id ORDER BY stand_no ROWS BETWEEN 4 PRECEDING AND CURRENT ROW), 1) AS drag_5conn_avg_klb
FROM c;

-- 4. Sanity checks ---------------------------------------------------------------
SELECT 'STAND_MSE' t, COUNT(*) n, ROUND(AVG(mse_ksi), 1) avg_metric FROM AGG.STAND_MSE
UNION ALL SELECT 'CONNECTION_TIMES', COUNT(*), ROUND(AVG(connection_min), 1) FROM AGG.CONNECTION_TIMES
UNION ALL SELECT 'OVERPULL_TREND', COUNT(*), ROUND(AVG(drag_klb), 1) FROM AGG.OVERPULL_TREND;
