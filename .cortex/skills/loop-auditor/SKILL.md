---
name: loop-auditor
description: "Audit a follow-up loop or a patient. Recomputes red/amber/green status from raw rows (hospital reports plus the payer's shared claims), explains it with citations, and flags any mismatch with the label the app shows. Triggers: audit loop, why is this red, why amber, why green, check status, loop-auditor, explain loop, verify loop."
---

# loop-auditor

**Input:** a patient_id (for example `P09901`) or a loop_id (for example `L-RDEMO001-0`).
**Processing:** `FFU.CORE.AUDIT_LOOP(id)` independently re-derives the status from `RAW.REPORTS`, `PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS`, `CORE.CLOSURE_CODES`, the cached `AI.FOLLOWUP_CHECKS`, `APP.CANCELLATIONS` and `CTRL.SIM_DATE`. It does not reuse the status Dynamic Table, and then compares its result with the app's label.
**Output:** a verdict per loop: MATCH or MISMATCH, the status with its reason, and citations.

Connection: `hospital`. Never read `FFU.KEY.*`.

## Steps

1. Run:
   ```sql
   CALL FFU.CORE.AUDIT_LOOP('<id>');
   ```
2. For each row, write a short block:
   - **Verdict:** `MATCH` if `match = TRUE`, else `MISMATCH (app says X, raw rows say Y)`.
   - **Status and why**, in one sentence of plain English:
     - RED: the due date passed and no correct test was found. If the evidence lists a WRONG TEST (for example a chest X-ray, CPT 71046), name it and say it does not close a CT loop.
     - AMBER: a correct test was claimed at another hospital, but its report is not in our records; an outside-report request exists.
     - GREEN: a follow-up report is in our records AND AI_FILTER confirmed it discusses the original finding.
     - REROUTED: give the pathway and the reason.
   - **Citations:** the index report id and date with the exact quote (and whether it was verified), each evidence row (source, id, date, CPT, facility), and the rule line (`rule` column). Cite the rule sheet section from `docs/RULE_SHEET.md`.
   - **Communication:** clinician acknowledged, and patient notified.
3. If any row is a MISMATCH, then:
   - say so first, in bold;
   - suggest refreshing: `ALTER DYNAMIC TABLE FFU.CORE.LOOP_STATUS REFRESH;`;
   - re-run the audit once;
   - if it still mismatches, report it as a defect with both statuses. Do not edit data to make them agree.
4. To check many loops, for example "audit all red loops for clinic C1", list the loop_ids from `FFU.CORE.LOOP_STATUS` and audit up to 20. Report the count of matches and mismatches.

## Rules
- Quote verbatim from the tool output only. Never invent a citation.
- Never change a status by hand; a cancellation needs a reason plus clinician sign-off in `APP.CANCELLATIONS`.
