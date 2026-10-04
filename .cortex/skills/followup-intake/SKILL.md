---
name: followup-intake
description: "Ingest new radiology reports and turn them into tracked follow-up loops. Runs AI extraction with verbatim evidence quotes, deterministic rules, pathway routing and priority, refreshes the Dynamic Tables, and prints the new loops. Triggers: new report, intake, process reports, ingest report, followup-intake, what loops did this report create."
---

# followup-intake

**Input:** report text files in a folder (for example `demo/inbox`).
**Processing:** `CORE.INGEST_REPORT` lands each file, then `CORE.PROCESS_NEW_REPORTS()` runs. That is the same procedure the Task and the app call, and it does extraction with quotes, rules, routing, priority, Dynamic Table refresh and AI_FILTER.
**Output:** the new loops.

## Fixed SQL - run ONLY these statements. Never write other SQL, never query tables directly, never guess column names. Never read `FFU.KEY.*`.

| Purpose | Statement | Returned columns |
| --- | --- | --- |
| Land one file | `CALL FFU.CORE.INGEST_REPORT('<REPORT_ID>', '<PATIENT_ID>', '<YYYY-MM-DD>', '<MODALITY>', '<CPT>', '<FACILITY>', $$<file text>$$);` | `INGEST_REPORT` (a message) |
| Process | `CALL FFU.CORE.PROCESS_NEW_REPORTS();` | `LOOP_ID, PATIENT_ID, FINDING_TYPE, SIZE, TIER, PATHWAY, STATUS, PRIORITY_SCORE, DUE_END, PATIENT_NOTIFIED, QUOTE, QUOTE_VERIFIED, STATUS_REASON, QA_FLAG` |
| If PROCESS returned 0 rows | `CALL FFU.CORE.SHOW_LOOPS('<PATIENT_ID>');` (once per patient landed) | `LOOP_ID, PATIENT_ID, FINDING_TYPE, SIZE, TIER, PATHWAY, STATUS, STATUS_REASON, PRIORITY_SCORE, DUE_END, DAYS_OVERDUE, CLINICIAN_ACKED, PATIENT_NOTIFIED, QUOTE, QUOTE_VERIFIED, SIM_DATE` |

`PROCESS_NEW_REPORTS` may return 0 rows if the background Task already processed the report. That is normal; use `SHOW_LOOPS`.

## Steps
1. List the `*.txt` files in the folder. The file name is `<REPORT_ID>_<PATIENT_ID>_<YYYY-MM-DD>_<MODALITY>_<CPT>.txt`.
   - `MODALITY` may contain an underscore (for example `CT_CHEST`): the last part is the CPT, and everything between the date and the CPT is the modality.
   - FACILITY is `HOSPITAL` unless the folder name contains `outside`; then use `Outside hospital`.
   - If a name doesn't fit, ask the user. Don't guess.
2. Read each file and call `INGEST_REPORT` with the text exactly as-is. If the text contains `$$`, stop and tell the user.
3. Call `PROCESS_NEW_REPORTS` once. If it returns 0 rows, call `SHOW_LOOPS` for each patient.
4. Print a table: loop_id, patient, finding and size, tier, priority, due date, status, patient told, and quote (verified yes/no). Then one line per loop:
   - `QUOTE_VERIFIED = FALSE`: "QUOTE NOT FOUND IN SOURCE - review before relying on this loop".
   - `PATHWAY <> STANDARD`: rerouted, with `STATUS_REASON`.
   - `QA_FLAG` set: a QA note for the radiologist (never change the recommendation).
   - `PATIENT_NOTIFIED = FALSE`: "patient not told".

## Rules
- AI only extracts and quotes. Status and priority come from the SQL rules (`sql/07_rules.sql`, `docs/RULE_SHEET.md`).
- Never diagnose; never send anything to a patient.
