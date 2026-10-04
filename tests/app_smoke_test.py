"""Headless smoke test for the Streamlit app: every page and every button, against the real hospital account.

Run:  .venv\\Scripts\\python.exe tests\\app_smoke_test.py
Uses the default Snowflake connection (hospital). The caller's-rights connection is unavailable locally, so the
"View as analyst" toggle is expected to show its fallback message. Restores the demo clock afterwards.
"""
import os
import sys
import traceback

from streamlit.testing.v1 import AppTest

APP = os.path.join(os.path.dirname(__file__), "..", "app", "streamlit_app.py")
TIMEOUT = 600
results = []


def check(name, at):
    errs = [e.value for e in at.exception]
    results.append((name, not errs, errs[0] if errs else ""))
    print(("PASS " if not errs else "FAIL ") + name + ("" if not errs else f"\n     {errs[0][:400]}"), flush=True)
    return not errs


def fresh(page):
    at = AppTest.from_file(APP, default_timeout=TIMEOUT)
    at.run()
    at.sidebar.radio[0].set_value(page).run()
    return at


def button(at, label_start):
    for b in at.button:
        if b.label.startswith(label_start):
            return b
    raise AssertionError(f"button not found: {label_start}")


try:
    # Worklist: load, filters, analyst toggle.
    at = fresh("Worklist"); check("Worklist loads (no filters)", at)
    at.multiselect[0].set_value([at.multiselect[0].options[0]]).run(); check("Worklist finding-type filter", at)
    at.multiselect[1].set_value([at.multiselect[1].options[0]]).run(); check("Worklist tier filter", at)
    at.toggle[0].set_value(True).run(); check("Worklist view-as-analyst toggle", at)

    # Patient 360: hero, decoy, empty patient, audit button.
    at = fresh("Patient 360"); check("Patient 360 loads (P09901)", at)
    at.text_input[0].set_value("P09902").run(); check("Patient 360 decoy P09902", at)
    button(at, "Audit this loop").click().run(); check("Patient 360 audit button", at)
    at.text_input[0].set_value("NOBODY").run(); check("Patient 360 unknown patient", at)

    # Copilot: one example question through the agent, the draft-letter button, and approval.
    at = fresh("Copilot chat"); check("Copilot loads", at)
    button(at, "Which loops were closed only").click().run(); check("Copilot example question (agent)", at)
    at = fresh("Copilot chat")
    button(at, "Draft the patient letter").click().run(); check("Copilot draft letter (agent tool)", at)
    at = fresh("Copilot chat")
    if at.text_input:
        at.text_input[0].set_value("Smoke Test Clinician").run()
        button(at, "Approve").click().run(); check("Copilot approve draft", at)

    # Alerts and Results.
    at = fresh("Alerts"); check("Alerts loads", at)
    at = fresh("Results"); check("Results loads", at)

    # Sidebar buttons: refresh, then move the clock (restored below).
    at = fresh("Worklist")
    at.sidebar.button[1].click().run(); check("Sidebar refresh (process new reports)", at)
    import datetime as dt
    at.sidebar.date_input[0].set_value(dt.date(2027, 2, 4)).run()
    at.sidebar.button[0].click().run(); check("Sidebar move clock and run alert", at)
except Exception:  # noqa: BLE001 - report harness failures as a failed check
    results.append(("harness", False, traceback.format_exc()))
    print("FAIL harness\n" + traceback.format_exc())
finally:
    # Restore the demo state (clock, demo alerts) so the app and official eval stay clean.
    import snowflake.connector
    c = snowflake.connector.connect(connection_name=os.getenv("SNOWFLAKE_DEFAULT_CONNECTION_NAME", "hospital"))
    c.cursor().execute("CALL FFU.CTRL.DEMO_RESET(FALSE)")
    c.close()
    print("demo state restored (DEMO_RESET(FALSE))")

failed = [r for r in results if not r[1]]
print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
sys.exit(1 if failed else 0)
