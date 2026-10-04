---
name: loop-auditor
description: "Audit a follow-up loop or a patient. Recomputes red/amber/green status from raw rows (hospital reports plus the payer's shared claims), explains it with citations, and flags any mismatch with the label the app shows. Also moves the demo clock and fires the overdue alert. Triggers: audit loop, why is this red, why amber, why green, check status, loop-auditor, explain loop, verify loop, advance clock, overdue alert."
---

# loop-auditor

**Input:** a patient_id (for example `P09901`), a loop_id (for example `L-RDEMO001-0`), or several of them. Optionally a new demo date, for example "move the clock to 2027-02-04".
**Processing:** `CORE.AUDIT_LOOP(id)` independently re-derives the status from `RAW.REPORTS`, the payer share, `CORE.CLOSURE_CODES`, the cached `AI.FOLLOWUP_CHECKS`, `APP.CANCELLATIONS` and `CTRL.SIM_DATE`, then compares it with the app's label.
**Output:** a verdict per loop (MATCH or MISMATCH), the status with its reason, and citations.

## Fixed SQL - run ONLY these statements. Never write other SQL, never query tables directly, never guess column names. Never read `FFU.KEY.*`.

| Purpose | Statement | Returned columns |
| --- | --- | --- |
| Audit (one call per id) | `CALL FFU.CORE.AUDIT_LOOP('<id>');` | `LOOP_ID, APP_STATUS, AUDIT_STATUS, MATCH, RULE, INDEX_CITATION, EVIDENCE, COMMUNICATION` |
| Move the clock and fire the alert | `CALL FFU.CTRL.ADVANCE_CLOCK('<YYYY-MM-DD>', '<P1,P2 or ALL>');` | `LOOP_ID, PATIENT_ID, TIER, MESSAGE, SIM_DATE, FIRED_AT` |
| Current loop view | `CALL FFU.CORE.SHOW_LOOPS('<id or WORKLIST>');` | `LOOP_ID, PATIENT_ID, FINDING_TYPE, SIZE, TIER, PATHWAY, STATUS, STATUS_REASON, PRIORITY_SCORE, DUE_END, DAYS_OVERDUE, CLINICIAN_ACKED, PATIENT_NOTIFIED, QUOTE, QUOTE_VERIFIED, SIM_DATE` |
| Refresh after a MISMATCH (once) | `ALTER DYNAMIC TABLE FFU.CORE.LOOP_STATUS REFRESH;` | - |

## Steps
1. If the user asked to move the clock, call `ADVANCE_CLOCK` first and print its rows as "Alerts fired".
2. Call `AUDIT_LOOP` for each id.
3. For each returned row, write a short block:
   - **Verdict:** `MATCH` if `MATCH` is true, else **`MISMATCH (app says APP_STATUS, raw rows say AUDIT_STATUS)`**.
   - **Status and why**, in one sentence:
     - RED: the due date passed and no correct test was found. If `EVIDENCE` contains `WRONG TEST`, name the CPT and say it does not close this loop.
     - AMBER: a correct test was claimed at another hospital, but its report is not in our records, and an outside report was requested.
     - GREEN: a follow-up report is in our records AND AI_FILTER confirmed it discusses the finding.
     - REROUTED: give the pathway and the reason from `RULE`.
   - **Citations:** `INDEX_CITATION` verbatim, each part of `EVIDENCE` verbatim, `RULE` verbatim, and the matching section of `docs/RULE_SHEET.md`.
   - **Communication:** `COMMUNICATION` verbatim.
4. On any MISMATCH:
   - run the refresh once and audit again;
   - if it still mismatches, report it as a defect with both statuses.

   Never edit data to make them agree.

## Rules
- Quote only from tool output. Never invent a citation.
- Status changes only through the rules; a cancellation needs a reason plus clinician sign-off.
