"""PTEN+ DSA: drilling data science assistant.

FastAPI service for Snowpark Container Services:
  /            branded single-page app (static/index.html)
  /api/*       dashboard data, parameterized SQL against HOL_PTEN_ML
  /ask         Cortex Agent (HOL_PTEN_ML.AGENT.DSA_AGENT) via the agent REST API (:run)
  /feedback    thumbs up / down on an answer via the agent Feedback REST API (:feedback)

Inside SPCS, Snowflake mounts an OAuth token at /snowflake/session/token and sets
SNOWFLAKE_HOST / SNOWFLAKE_ACCOUNT, so the app authenticates as the service with no stored
secrets. Locally, set SNOWFLAKE_CONNECTION_NAME.
"""
import json
import os
import re
import threading
import time
from datetime import date, datetime

import requests
import snowflake.connector
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

AGENT = os.getenv("AGENT_FQN", "HOL_PTEN_ML.AGENT.DSA_AGENT")
WAREHOUSE = os.getenv("SNOWFLAKE_WAREHOUSE", "HOL_PTEN_WH")
TOKEN_PATH = "/snowflake/session/token"
STATIC = os.path.join(os.path.dirname(__file__), "static")
RIG_RE = re.compile(r"RIG_\d{3}")

app = FastAPI(title="PTEN+ DSA")
app.mount("/static", StaticFiles(directory=STATIC), name="static")


_conn = None
_lock = threading.Lock()
_cache = {}
CACHE_SECONDS = 300   # dashboard data only changes when the pipeline re-runs


def connect():
    """One long-lived connection; opening a session per request was most of the latency."""
    global _conn
    with _lock:
        if _conn is None or _conn.is_closed():
            _conn = _new_connection()
        return _conn


def _new_connection():
    if os.path.exists(TOKEN_PATH):
        return snowflake.connector.connect(
            host=os.environ["SNOWFLAKE_HOST"], account=os.environ["SNOWFLAKE_ACCOUNT"],
            authenticator="oauth", token=open(TOKEN_PATH).read(),
            warehouse=WAREHOUSE, database="HOL_PTEN_ML")
    return snowflake.connector.connect(connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME", "default"),
                                       warehouse=WAREHOUSE, database="HOL_PTEN_ML")


def rows(sql, params=None):
    key = (sql, json.dumps(params or {}, sort_keys=True))
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_SECONDS:
        return hit[1]
    cur = connect().cursor(snowflake.connector.DictCursor)
    cur.execute(sql, params or {})
    out = cur.fetchall()
    result = _clean(out)
    _cache[key] = (time.time(), result)
    return result


def _clean(out):
    return [{k.lower(): (v.isoformat() if isinstance(v, (datetime, date)) else
                         float(v) if hasattr(v, "as_integer_ratio") and not isinstance(v, (int, bool)) else v)
             for k, v in r.items()} for r in out]


def check_rig(rig):
    if not RIG_RE.fullmatch(rig or ""):
        raise HTTPException(400, "rig must look like RIG_007")
    return rig


def check_date(d):
    try:
        return date.fromisoformat(d).isoformat()
    except (TypeError, ValueError):
        raise HTTPException(400, "date must be YYYY-MM-DD")


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC, "index.html"))


@app.get("/api/summary")
def summary():
    """Fleet KPIs for the latest day of data, plus the available date range."""
    r = rows("""
      WITH d AS (SELECT MAX(TO_DATE(stand_end_ts)) AS last_day, MIN(TO_DATE(stand_end_ts)) AS first_day
                 FROM PREDICTIONS.STUCK_PIPE_SCORES)
      SELECT d.first_day, d.last_day,
        (SELECT COUNT(*) FROM AGG.WELL_HEADER) AS rigs,
        (SELECT COUNT_IF(stuck_pipe_risk >= 0.5) FROM PREDICTIONS.STUCK_PIPE_SCORES s
          WHERE TO_DATE(s.stand_end_ts) = d.last_day) AS high_risk_stands_last_day,
        (SELECT COUNT(DISTINCT rig_id) FROM PREDICTIONS.STUCK_PIPE_SCORES s
          WHERE TO_DATE(s.stand_end_ts) = d.last_day AND stuck_pipe_risk >= 0.5) AS rigs_at_risk_last_day,
        (SELECT COUNT(*) FROM LABELS.NPT_EVENTS) AS npt_events,
        (SELECT ROUND(SUM(duration_min) / 60, 1) FROM LABELS.NPT_EVENTS) AS npt_hours,
        (SELECT COUNT(*) FROM PREDICTIONS.STUCK_PIPE_SCORES) AS stands_scored,
        (SELECT MEDIAN(connection_min) FROM AGG.CONNECTION_TIMES) AS fleet_median_connection_min,
        (SELECT ROUND(SUM(hours_above_fleet_median), 0) FROM AGG.CONNECTION_BENCHMARK) AS flat_time_hours_above_median,
        (SELECT ROUND(AVG(mse_ksi), 0) FROM AGG.STAND_MSE) AS avg_mse_ksi
      FROM d""")
    return r[0]


@app.get("/api/risk_by_rig")
def risk_by_rig(day: str):
    return rows("""
      SELECT s.rig_id, w.basin, w.rig_class,
             ROUND(MAX(s.stuck_pipe_risk), 3) AS max_risk,
             ROUND(AVG(s.stuck_pipe_risk), 3) AS avg_risk,
             COUNT_IF(s.stuck_pipe_risk >= 0.5) AS high_risk_stands
      FROM PREDICTIONS.STUCK_PIPE_SCORES s JOIN AGG.WELL_HEADER w USING (rig_id)
      WHERE TO_DATE(s.stand_end_ts) = %(day)s
      GROUP BY 1, 2, 3 ORDER BY max_risk DESC""", {"day": check_date(day)})


@app.get("/api/risk_trend")
def risk_trend(rig: str):
    rig = check_rig(rig)
    return {
        "scores": rows("""SELECT stand_no, stand_end_ts, ROUND(stuck_pipe_risk, 4) AS risk
                          FROM PREDICTIONS.STUCK_PIPE_SCORES WHERE rig_id = %(rig)s ORDER BY stand_no""", {"rig": rig}),
        "events": rows("""SELECT event_id, event_type, event_start_ts, duration_min
                          FROM LABELS.NPT_EVENTS WHERE rig_id = %(rig)s ORDER BY event_start_ts""", {"rig": rig}),
    }


@app.get("/api/tags")
def tags(rig: str, day: str):
    """10-minute averages of the core drilling channels for one rig and day (DRILLING state)."""
    return rows("""
      SELECT TIME_SLICE(ts, 10, 'MINUTE') AS bucket, tag, ROUND(AVG(value), 2) AS v
      FROM RAW.TAG_VALUE
      WHERE rig_id = %(rig)s AND state = 'DRILLING'
        AND tag IN ('TORQUE_KFTLB', 'HOOKLOAD_KLB', 'ROP_FPH', 'SPP_PSI')
        AND ts >= %(day)s::DATE AND ts < DATEADD(DAY, 1, %(day)s::DATE)
      GROUP BY 1, 2 ORDER BY 1""", {"rig": check_rig(rig), "day": check_date(day)})


@app.get("/api/npt")
def npt():
    return rows("""
      SELECT w.basin, e.event_type, COUNT(*) AS events, ROUND(SUM(e.duration_min) / 60, 1) AS hours
      FROM LABELS.NPT_EVENTS e JOIN AGG.WELL_HEADER w USING (rig_id)
      GROUP BY 1, 2 ORDER BY 1, 2""")


@app.get("/api/connections")
def connections():
    """Flat time: each rig's median connection vs the fleet p50 / p90."""
    return rows("""SELECT rig_id, basin, connections, rig_median_min, fleet_p50_min, fleet_p90_min,
                          hours_above_fleet_median
                   FROM AGG.CONNECTION_BENCHMARK ORDER BY rig_median_min DESC, hours_above_fleet_median DESC""")


@app.get("/api/mse")
def mse(rig: str):
    """Drilling efficiency per stand for one rig, with the stuck-pipe score for colouring."""
    return rows("""SELECT m.stand_no, m.mse_ksi, m.avg_rop_fph, m.avg_wob_klb, m.avg_rpm,
                          ROUND(s.stuck_pipe_risk, 3) AS risk
                   FROM AGG.STAND_MSE m LEFT JOIN PREDICTIONS.STUCK_PIPE_SCORES s USING (rig_id, stand_no)
                   WHERE m.rig_id = %(rig)s ORDER BY m.stand_no""", {"rig": check_rig(rig)})


@app.get("/api/overpull")
def overpull(rig: str):
    return rows("""SELECT stand_no, drag_klb, drag_5conn_avg_klb FROM AGG.OVERPULL_TREND
                   WHERE rig_id = %(rig)s ORDER BY stand_no""", {"rig": check_rig(rig)})


@app.get("/api/rig_state")
def rig_state(rig: str):
    """Classifier output (scored for the held-out day) vs the given state, per minute."""
    rig = check_rig(rig)
    return {
        "minutes": rows("""SELECT ts, given_state, predicted_state FROM PREDICTIONS.RIG_STATE_PREDICTIONS
                           WHERE rig_id = %(rig)s ORDER BY ts""", {"rig": rig}),
        "accuracy": rows("""SELECT ROUND(AVG(IFF(given_state = predicted_state, 1, 0)), 4) AS acc, COUNT(*) AS n
                            FROM PREDICTIONS.RIG_STATE_PREDICTIONS""")[0],
    }


class Ask(BaseModel):
    question: str
    rig: str | None = None


def agent_url(action):
    db, schema, name = AGENT.split(".")
    host = os.getenv("SNOWFLAKE_HOST") or connect().host
    return f"https://{host}/api/v2/databases/{db}/schemas/{schema}/agents/{name}:{action}"


def auth_headers():
    """SPCS: the mounted OAuth token. Locally: the connector's session token."""
    if os.path.exists(TOKEN_PATH):
        return {"Authorization": f"Bearer {open(TOKEN_PATH).read()}",
                "X-Snowflake-Authorization-Token-Type": "OAUTH"}
    return {"Authorization": f'Snowflake Token="{connect().rest.token}"'}


@app.post("/ask")
def ask(body: Ask):
    question = body.question.strip()[:2000]
    if not question:
        raise HTTPException(400, "question is empty")
    # Fleet-wide by default; a rig is only injected when the user opts into focus mode.
    if body.rig and RIG_RE.fullmatch(body.rig):
        question = f"(Context: the user is focused on {body.rig}; answer for that rig unless the question names others.) {question}"
    else:
        question = ("(Context: fleet-wide analysis across all rigs, 2026-10-01 to 2026-10-14. "
                    "Compare rigs and basins rather than drilling into one rig unless asked.) " + question)
    payload = {"messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
               "stream": False}
    r = requests.post(agent_url("run"), json=payload, timeout=120,
                      headers={**auth_headers(), "Content-Type": "application/json", "Accept": "application/json"})
    if r.status_code != 200:
        raise HTTPException(502, f"agent error {r.status_code}: {r.text[:300]}")
    resp = r.json()
    content = resp.get("content", [])
    answer = "\n\n".join(c.get("text", "") for c in content if c.get("type") == "text")
    tools = [c["tool_use"].get("name") for c in content if c.get("type") == "tool_use" and "tool_use" in c]
    # The feedback API keys on the HTTP request id of this :run call
    request_id = r.headers.get("X-Snowflake-Request-Id") or resp.get("request_id")
    return {"answer": answer, "request_id": request_id,
            "tools": [t for t in tools if t and not t.startswith("system_")]}


class Feedback(BaseModel):
    request_id: str
    positive: bool
    message: str | None = None
    categories: list[str] | None = None


@app.post("/feedback")
def feedback(body: Feedback):
    """Thumbs up / down on one agent answer; shows up in the agent's Monitoring tab."""
    if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", body.request_id):
        raise HTTPException(400, "bad request_id")
    payload = {"orig_request_id": body.request_id, "positive": body.positive,
               "feedback_message": (body.message or "")[:2000],
               "categories": [c[:100] for c in (body.categories or [])][:5]}
    r = requests.post(agent_url("feedback"), json=payload, timeout=30,
                      headers={**auth_headers(), "Content-Type": "application/json"})
    if r.status_code != 200:
        raise HTTPException(502, f"feedback error {r.status_code}: {r.text[:300]}")
    try:
        return r.json()
    except ValueError:   # success can come back with an empty body
        return {"status": "Feedback submitted successfully"}
