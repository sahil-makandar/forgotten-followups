---
name: demo-reset
description: "Reset the Forgotten Follow-ups demo to its start state before a demo run: CTRL.SIM_DATE back to 2026-10-04, demo reports, alerts and requests cleared, payer demo claims removed, optional removal of live-compiled rules. Triggers: demo reset, reset demo, start demo, prepare demo, demo-reset."
---

# demo-reset

**Input:** optionally "including extensions", which also removes rules added live by guideline-rule-compiler, so the thyroid step can be shown again.
**Processing:** `FFU.CTRL.DEMO_RESET(<bool>)` runs on the hospital account, then the payer demo claims are removed on the payer account, then a warm-up runs.
**Output:** a checklist showing the state is clean.

This deletes demo rows only:
- hospital: `set_name = 'DEMO'` reports and their AI rows, all `APP.ALERTS` and `APP.OUTSIDE_REPORT_REQUESTS`, demo cancellations;
- payer: `event_id LIKE 'EDEMO%'`.

Tell the user that before running, and ask for confirmation unless they already said "reset the demo".

## Steps

1. Hospital:
   ```sql
   CALL FFU.CTRL.DEMO_RESET(<TRUE if "including extensions", else FALSE>);
   ```
2. Payer (plain SQL; that account has no AI):
   ```powershell
   snow sql -c payer -q "DELETE FROM PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS WHERE event_id LIKE 'EDEMO%'"
   ```
   Then refresh the status so the share change is seen: `ALTER DYNAMIC TABLE FFU.CORE.LOOP_STATUS REFRESH;`
3. Warm the warehouse and check the start state with one query:
   ```sql
   SELECT (SELECT MAX(sim_date) FROM FFU.CTRL.SIM_DATE) sim_date,
          (SELECT COUNT(*) FROM FFU.RAW.REPORTS WHERE set_name = 'DEMO') demo_reports,
          (SELECT COUNT(*) FROM FFU.APP.ALERTS) alerts,
          (SELECT COUNT(*) FROM FFU.CORE.LOOP_STATUS WHERE patient_id = 'P09902') decoy_loops,
          (SELECT COUNT(*) FROM FFU.CORE.LOOPS WHERE finding_type = 'THYROID_NODULE') thyroid_loops,
          (SELECT COUNT(*) FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS WHERE event_id LIKE 'EDEMO%') demo_claims;
   ```
   Expected values: sim_date 2026-10-04, demo_reports 0, alerts 0, decoy_loops 1, demo_claims 0, and thyroid_loops 0 if extensions were reset.
4. Print the checklist with PASS/FAIL per line. Remind the user of the demo order in `docs/DEMO_SCRIPT.md`.
