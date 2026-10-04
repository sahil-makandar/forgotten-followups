"""Generates eval/eval_harness.ipynb (Snowflake Workspace notebook, nbformat 4.5). Run: .venv\\Scripts\\python.exe eval\\make_notebook.py"""
import json
import os
import uuid


def cid():
    return uuid.uuid4().hex[:8]


def md(text):
    return {"cell_type": "markdown", "id": cid(), "metadata": {}, "source": text}


def sql(name, query):
    return {"cell_type": "code", "id": cid(), "execution_count": None, "outputs": [],
            "metadata": {"codeCollapsed": False, "language": "sql", "name": name, "resultVariableName": name},
            "source": f"%%sql -r {name}\n{query}"}


def py(code):
    return {"cell_type": "code", "id": cid(), "execution_count": None, "metadata": {}, "outputs": [], "source": code}


PRIORITY_TEST = """WITH s AS (
  SELECT FFU.CORE.PRIORITY(1, 0.0, 40, 'NEVER', 'F', 'SOLID', FALSE):score::FLOAT AS t1_min,
         FFU.CORE.PRIORITY(2, 99.0, 90, 'CURRENT', 'M', 'SOLID', TRUE):score::FLOAT AS t2_max,
         FFU.CORE.PRIORITY(2, 0.0, 40, 'NEVER', 'F', 'SOLID', FALSE):score::FLOAT AS t2_min,
         FFU.CORE.PRIORITY(3, 99.0, 90, 'CURRENT', 'M', 'GROUND_GLASS', TRUE):score::FLOAT AS t3_max)
SELECT 'tier2 max < tier1 min' AS test, t2_max || ' < ' || t1_min AS detail, IFF(t2_max < t1_min, 'PASS', 'FAIL') AS result FROM s
UNION ALL SELECT 'tier3 max < tier2 min', t3_max || ' < ' || t2_min, IFF(t3_max < t2_min, 'PASS', 'FAIL') FROM s"""

CHART = '''import pandas as pd
import matplotlib.pyplot as plt

# Small, bounded table (6 rows): safe to collect on either notebook runtime.
b = baselines.copy() if isinstance(baselines, pd.DataFrame) else baselines.to_pandas()
fig, axes = plt.subplots(1, 2, figsize=(11, 4))
for ax, col, title in [(axes[0], "ACCURACY", "Loop-status accuracy"),
                       (axes[1], "FALSE_GREEN_RATE", "False-green rate (lower is safer)")]:
    b.pivot(index="SET_NAME", columns="METHOD", values=col).astype(float).plot.bar(ax=ax, rot=0)
    ax.set_title(title)
    ax.set_xlabel("Set")
plt.tight_layout()
plt.show()'''

cells = [
    md("# Forgotten Follow-ups - evaluation harness\n\nRe-runs and shows the evaluation in Snowflake. All data is synthetic "
       "except Set A (real, de-identified, labels pending). Impact numbers are **simulated**.\n\n"
       "**Protocol:** official Set C numbers only come from the `CTRL.DEMO_RESET(TRUE)` state. The next cell runs the "
       "eval and records whether that state held (`OFFICIAL` column)."),
    sql("eval_now", "CALL FFU.EVAL.RUN_EVAL('notebook-run')"),
    md("## Set C runs (hidden answer key, 700 index reports)"),
    sql("official_runs", "SELECT run_at, label, official, state_note, n, correct, accuracy, false_green, false_green_upper95,\n"
                         "       missed_loops, quote_verified_rate\nFROM FFU.EVAL.RUNS ORDER BY run_at DESC LIMIT 10"),
    md("## System vs baselines\n\nKEYWORD: recommend/follow-up opens a loop, any later event closes it. AI_ONLY: the model "
       "picks the status itself, with no rules. False-green rate = wrong greens / loops that should not be green (the safety metric)."),
    sql("baselines", "SELECT method, set_name, n, correct, accuracy, acc_ci_low, acc_ci_high, false_greens,\n"
                     "       should_not_be_green, false_green_rate, false_green_upper95_rule_of_3\n"
                     "FROM FFU.EVAL.BASELINE_SUMMARY ORDER BY set_name, method"),
    py(CHART),
    md("## Set B: trap reports (labels written first, held out)"),
    sql("setb_traps", "SELECT trap, COUNT(*) AS findings, COUNT_IF(status_ok) AS status_ok, COUNT_IF(false_green) AS false_greens,\n"
                      "       LISTAGG(IFF(status_ok, NULL, case_id || ' expected ' || expect_status || ' got ' || got_status), '; ') AS misses\n"
                      "FROM FFU.EVAL.SETB_RESULTS GROUP BY trap ORDER BY trap"),
    md("## Priority scale test (tier bands never overlap)"),
    sql("priority_test", PRIORITY_TEST),
    md("## Simulated impact on the synthetic hospital\n\n**SIMULATED.** Recall recovers an assumed 59% of not-done loops "
       "(derived from Nodule Net, 37% to 74%)."),
    sql("simulated", "SELECT * FROM FFU.EVAL.SIMULATED_IMPACT"),
    md("## Re-run everything\n\n1. `CALL FFU.CTRL.DEMO_RESET(TRUE);`, and remove the `EDEMO%` claims on the payer account.\n"
       "2. Re-run this notebook (the first SQL cell records a run; `OFFICIAL` is TRUE only from the clean state).\n"
       "3. Locally: `eval/02_baselines.sql`, `eval/setB/04_score.sql`, `eval/03_simulated_impact.sql`, then "
       "`eval/export_metrics.ps1` to write `eval/metrics.json`."),
]

nb = {"cells": cells, "nbformat": 4, "nbformat_minor": 5,
      "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
                   "language_info": {"name": "python", "version": "3.11"}}}
out = os.path.join(os.path.dirname(__file__), "eval_harness.ipynb")
with open(out, "w", encoding="utf-8") as f:
    json.dump(nb, f, indent=1)
ids = [c["id"] for c in cells]
print(f"wrote {out}: {len(cells)} cells, unique ids: {len(set(ids)) == len(ids)}")
