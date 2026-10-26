-- Lab B, block B4: Level 2, fully managed RAG.
-- Same agent as Lab A plus one Cortex Search tool. ALTER AGENT replaces the whole
-- specification, so the full Lab A spec is repeated here with DrillingDocs added.
USE WAREHOUSE HOL_PTEN_WH;
ALTER AGENT HOL_PTEN_ML.AGENT.DSA_AGENT MODIFY LIVE VERSION SET SPECIFICATION =
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
    - question: "Which rigs showed stuck-pipe risk on October 12, and what does our practice guide say to check?"
    - question: "Which 5 rigs had the highest stuck-pipe risk on October 12?"
    - question: "Show torque and hookload for RIG_007 while drilling on 2026-10-10 between 06:00 and 12:00"
    - question: "Re-score the last 5 stands on RIG_003"
    - question: "Which rigs have the slowest median connection time versus the fleet, and how many hours is that?"
    - question: "Is RIG_007 showing rising drag before its stuck-pipe risk spikes?"
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
  - tool_spec:
      type: cortex_search
      name: DrillingDocs
      description: Drilling practice documents - stuck pipe prevention, hole cleaning, rig state definitions and KPIs.
tool_resources:
  DrillingDocs:
    search_service: HOL_PTEN_ML.DOCS.DRILLING_DOCS_SEARCH
    max_results: 4
    title_column: TITLE
    id_column: RELATIVE_PATH
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
