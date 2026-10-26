# PTEN Hands-on Lab: drilling ML, a DSA agent, and RAG on Snowflake

Two hands-on labs on **synthetic data shaped like PTEN's**: tall/skinny 1-minute tag values by rig,
well, rig state and stand (20 rigs, 40 tags, 14 days, about 16M rows). Everything runs from two
notebooks in your own Snowflake account.

| Lab | Notebook | Time | You build |
|---|---|---|---|
| A | `lab-a-ml-to-agent/PTEN_HOL_A_ML_TO_AGENT.ipynb` | 60 min | Stand-level features in the Feature Store, a stuck-pipe XGBoost model with experiment tracking, Model Registry batch scores, drilling insights (MSE, connection flat time, drag, rig-state classifier), a model inference service on Snowpark Container Services, a DSA Cortex Agent, and the PTEN+ DSA app with end-user feedback |
| B | `lab-b-rag/PTEN_HOL_B_RAG.ipynb` | 30 to 60 min | Parse, chunk and index drilling documents with Cortex Search; Level 1, a LangChain chain evaluated with TruLens; Level 2, the same search as a tool on the DSA agent |

## What you need

- A Snowflake account where you can use the **ACCOUNTADMIN** role.
- *Optional, for one step (A5):* Docker or Podman and the Snowflake CLI (`snow`) on your laptop, to
  build the app's container image. **No Docker? That's fine:** you can follow that step on the
  presenter's screen, and nothing after it depends on it.

## How the lab runs

The notebooks drive everything. The only things outside them are a one-statement pre-step (so
Snowflake can read this repository) and teardown at the end.

| # | Where | What happens | Time |
|---|---|---|---|
| 1 | SQL file in Workspaces | Create a Git API integration (below) | 1 min |
| 2 | Snowsight | Create a Git workspace from this repository | 1 min |
| 3 | Lab A notebook, **Run all** | First cells set up the account (`setup/00_setup.sql`) and generate the data (`setup/01_generate_synthetic.sql`), then features, model, scores, insights (`setup/02_insights.sql`), the inference service, and the agent (`dsa_agent.sql`) | about 40 min |
| 4 | Laptop + Lab A notebook | A5: build and push the app image, then the notebook deploys it (`deploy_app.sql`) | about 7 min |
| 5 | Lab B notebook, **Run all** | Turn on PyPI access first, then parse and index documents (`rag_foundation.sql`), LangChain + TruLens, and the agent's document tool (`add_search_to_agent.sql`) | 25 to 40 min |
| 6 | SQL file in Workspaces | Teardown: `setup/99_teardown.sql` | 1 min |

The notebooks run the repo's SQL files statement by statement, so you can open any `.sql` file to
read exactly what a step does. **Run all** is a good way to start: everything runs in order while you
read along. The longest single wait is about 6 minutes in A3b, while the model inference service
builds.

### 1. Let Snowflake read this repository

Open **Projects » Workspaces**, create a SQL file in your default workspace, and run:

```sql
USE ROLE ACCOUNTADMIN;
CREATE API INTEGRATION IF NOT EXISTS HOL_PTEN_GIT
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/sfc-gh-srahman')
  ENABLED = TRUE;
```

The repository is public, so no credentials are needed.

### 2. Create a Git workspace

1. **Projects » Workspaces »** the workspace menu **» From Git repository**.
2. Repository URL: `https://github.com/sfc-gh-srahman/pten-hol`
3. API integration: `HOL_PTEN_GIT`
4. Authentication: **Public repository**, then **Create**.

The workspace is yours. Edit and experiment freely. Changes stay in your workspace; you can't push
them back to this public repository.

### 3. Lab A

Open `lab-a-ml-to-agent/PTEN_HOL_A_ML_TO_AGENT.ipynb` and connect it. Any runtime and warehouse your
account already has will do to start, for example the default CPU compute pool and `COMPUTE_WH`.
The first code cells create `HOL_PTEN_WH` and switch to it. Then **Run all**, or step through cell by
cell.

### 4. The app (A5)

From a laptop with Docker or Podman:

```bash
git clone https://github.com/sfc-gh-srahman/pten-hol && cd pten-hol
snow sql -c <connection> -q "SHOW IMAGE REPOSITORIES IN SCHEMA HOL_PTEN_ML.APP"   # copy repository_url
snow spcs image-registry login -c <connection>
docker build --platform linux/amd64 -t <repository_url>/dsa-app:v8 lab-a-ml-to-agent/app   # or podman
docker push <repository_url>/dsa-app:v8
```

Then run the A5 cells. The PTEN+ DSA app is a fleet dashboard (KPI tiles, risk by rig, risk and drag
trend, drilling channels, connection time vs fleet, MSE vs ROP, rig-state classifier, NPT by basin)
beside an embedded agent chat. Click a rig to make it the agent's focus. Thumbs up / down on any
answer appears in **AI & ML » Agents » DSA_AGENT » Observability**.

### 5. Lab B

Open `lab-b-rag/PTEN_HOL_B_RAG.ipynb`. In the notebook's settings, turn on the external access
integration **`HOL_PTEN_PYPI_EAI`** (created in Lab A) so it can `pip install` LangChain and TruLens.
Restart the notebook, then **Run all**. TruLens results appear under **AI & ML » More tools »
TruLens**.

### 6. Teardown

Open `setup/99_teardown.sql` in your workspace and run it. It removes the services, the
`HOL_PTEN_ML` database, the compute pool, the warehouse, the PyPI integration and the lab role. If you
no longer need the Git workspace, delete it, then run `DROP API INTEGRATION HOL_PTEN_GIT;`.

## Objects the lab creates

| Object | Name |
|---|---|
| Database | `HOL_PTEN_ML` (schemas RAW, AGG, LABELS, ML, PREDICTIONS, AGENT, DOCS, APP) |
| Warehouse | `HOL_PTEN_WH` (adaptive) |
| Compute pool | `HOL_PTEN_POOL` |
| Role | `HOL_PTEN_ROLE` (granted to you and to SYSADMIN) |
| Integrations | `HOL_PTEN_PYPI_EAI`, `HOL_PTEN_GIT` |
| Model service | `HOL_PTEN_ML.ML.STUCK_PIPE_SVC` |
| Agent | `HOL_PTEN_ML.AGENT.DSA_AGENT` |
| Search service | `HOL_PTEN_ML.DOCS.DRILLING_DOCS_SEARCH` |
| App | `HOL_PTEN_ML.APP.DSA_APP` |

## Troubleshooting

- **First cell fails with a privilege error:** switch the notebook's role to ACCOUNTADMIN.
- **`ScoreRigNow` slow or failing:** `SHOW SERVICES IN SCHEMA HOL_PTEN_ML.ML`. If `STUCK_PIPE_SVC` is
  suspended, `ALTER SERVICE HOL_PTEN_ML.ML.STUCK_PIPE_SVC RESUME;`. A resumed service takes about a
  minute before its first answer.
- **App not READY:** `SELECT SYSTEM$GET_SERVICE_STATUS('HOL_PTEN_ML.APP.DSA_APP');`. Check that the
  image tag is `v8` and was built for `linux/amd64`.
- **Lab B `%pip install` fails:** turn on `HOL_PTEN_PYPI_EAI` in the notebook's external access
  settings and restart the notebook.
- **Model not available in your region:** setup enables cross-region inference
  (`CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'`). Teardown leaves that setting in place.

## Repository layout

```
setup/              00 account setup, 01 synthetic data, 02 insights (run by Lab A), 99 teardown
lab-a-ml-to-agent/  notebook, dsa_agent.sql, deploy_app.sql, app/ (FastAPI service + web UI)
lab-b-rag/          notebook, rag_foundation.sql, add_search_to_agent.sql, docs/ (sample PDFs + source)
reference/          RAG architecture mapping (linked from Lab B)
deck/               the lab slides (open deck/index.html in a browser)
```

## About the data and documents

- All data is synthetic. Tag names are generic, and stuck-pipe precursors are injected before
  labeled events so the model has a real signal to find.
- Documents in `lab-b-rag/docs/` are lab-authored samples for illustration, not operational guidance.
