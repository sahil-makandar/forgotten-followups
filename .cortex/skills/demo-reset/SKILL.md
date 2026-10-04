---
name: demo-reset
description: "Reset the Forgotten Follow-ups demo to its start state before a demo run: CTRL.SIM_DATE back to 2026-10-04, demo reports, alerts and requests cleared, payer demo claims removed, optional removal of live-compiled rules. Triggers: demo reset, reset demo, start demo, prepare demo, demo-reset."
---

# demo-reset

**Input:** optionally "including extensions", which also removes rules added live by guideline-rule-compiler, so the thyroid step can be shown again.
**Processing:** `CTRL.DEMO_RESET(bool)` on the hospital account, then removal of the payer demo claims, then `CTRL.DEMO_STATE()`.
**Output:** the `DEMO_STATE` checklist.

It deletes demo rows only:
- hospital: `set_name = 'DEMO'` reports and their AI rows, `APP.ALERTS`, `APP.OUTSIDE_REPORT_REQUESTS`, demo cancellations;
- payer: `event_id LIKE 'EDEMO%'`.

Run without asking if the user said "reset the demo"; otherwise confirm first.

## Fixed SQL - run ONLY these statements, in this order. Never write other SQL or guess column names.

1. Hospital (`sql_execute`). Use `TRUE` only if the user said "including extensions":
   ```sql
   CALL FFU.CTRL.DEMO_RESET(TRUE);
   ```
2. Payer (shell):
   ```powershell
   snow sql -c payer -q "DELETE FROM PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS WHERE event_id LIKE 'EDEMO%'"
   ```
3. Hospital:
   ```sql
   ALTER DYNAMIC TABLE FFU.CORE.LOOP_STATUS REFRESH;
   ```
4. Hospital:
   ```sql
   CALL FFU.CTRL.DEMO_STATE();
   ```
   It returns the columns `CHECK_NAME, ACTUAL, EXPECTED, RESULT`.

5. If extensions were reset and `sql/rules/thyroid.sql` exists, tell the user to rename it to `sql/rules/thyroid.prev.sql`, so the next take writes the rule fresh. Do not delete it yourself.

## Output
Print the DEMO_STATE table as returned. Then one line: "Demo ready" if every RESULT is PASS (INFO is fine only for thyroid_loops when extensions were kept), else "NOT READY: <failed checks>". Point the user to `docs/DEMO_SCRIPT.md`.
