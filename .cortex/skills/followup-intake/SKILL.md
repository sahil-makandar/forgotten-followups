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
| Land one PDF (outside report) | shell: `snow stage copy <path>.pdf @FFU.APP.OUTSIDE_DOCS -c hospital --overwrite`, then `CALL FFU.CORE.INGEST_OUTSIDE_PDF('<file name>.pdf', '<REPORT_ID>', '<PATIENT_ID>', '<YYYY-MM-DD>', '<MODALITY>', '<CPT>', 'Outside hospital (PDF)');` | `INGEST_OUTSIDE_PDF` (a message: parsed N chars, or "review by hand") |
| Process | `CALL FFU.CORE.PROCESS_NEW_REPORTS();` | same columns as SHOW_LOOPS below |
| If PROCESS returned 0 rows | `CALL FFU.CORE.SHOW_LOOPS('<PATIENT_ID>');` (once per patient landed) | `LOOP_ID, PATIENT_ID, FINDING_TYPE, SIZE, TIER, PATHWAY, STATUS, STATUS_REASON, PRIORITY_SCORE, PRIORITY_BREAKDOWN, DUE_END, DAYS_OVERDUE, CLINICIAN_ACKED, PATIENT_NOTIFIED, QUOTE, QUOTE_VERIFIED, QA_FLAG, SIM_DATE` |

`PROCESS_NEW_REPORTS` may return 0 rows if the background Task already processed the report. That is normal; use `SHOW_LOOPS`.

### INGEST_REPORT takes exactly 7 arguments, in this order (live signature)
`CORE.INGEST_REPORT(REPORT_ID, PATIENT_ID, REPORT_DATE, MODALITY, CPT, FACILITY, TEXT)`

FACILITY is the 6th argument and is never optional; the report text is always the 7th and last. A call with 6 arguments fails with "Invalid argument types for function 'INGEST_REPORT'". Example for `demo/inbox/RDEMO001_P09901_2026-10-04_CT_CHEST_71275.txt`:

```sql
CALL FFU.CORE.INGEST_REPORT('RDEMO001', 'P09901', '2026-10-04', 'CT_CHEST', '71275', 'HOSPITAL', $$<file text>$$);
```

`INGEST_OUTSIDE_PDF` also takes 7 arguments: `(FILE_NAME, REPORT_ID, PATIENT_ID, REPORT_DATE, MODALITY, CPT, FACILITY)`, with FACILITY last.

The message tells you what happened: `ingested <id>`, `skipped <id>: already ingested` (fine on a re-run), or `not ingested ...` (unknown patient, empty text or missing id: report it and continue).

## Steps
1. List the `*.pdf` and `*.txt` files in the folder. If both a `.pdf` and a `.txt` share a REPORT_ID, use the PDF only (AI_PARSE_DOCUMENT reads it). The file name is `<REPORT_ID>_<PATIENT_ID>_<YYYY-MM-DD>_<MODALITY>_<CPT>.<ext>`.
   - `MODALITY` may contain an underscore (for example `CT_CHEST`): the last part is the CPT, and everything between the date and the CPT is the modality.
   - FACILITY is `HOSPITAL` unless the folder name contains `outside`; then use `Outside hospital`.
   - If a name doesn't fit, ask the user. Don't guess.
2. Read each `.txt` file and call `INGEST_REPORT` with all 7 arguments (FACILITY 6th) and the text exactly as-is (if the text contains `$$`, stop and tell the user). For each `.pdf`, upload it and call `INGEST_OUTSIDE_PDF`; if it says "review by hand" or "not ingested", report that and continue.
3. Call `PROCESS_NEW_REPORTS` once. If it returns 0 rows, call `SHOW_LOOPS` for each patient.
4. Print one compact block per loop, ALWAYS with these fields copied from the result (never `--`; if a value is NULL, write `n/a`):
   - loop_id, patient, finding and size, tier, status, due date;
   - **Priority:** `PRIORITY_SCORE` = `PRIORITY_BREAKDOWN`;
   - **Clinician acknowledged:** `CLINICIAN_ACKED` - **Patient notified:** `PATIENT_NOTIFIED`;
   - **Quote:** `QUOTE` (verified: `QUOTE_VERIFIED`).

   Then add these flags where they apply:
   - `QUOTE_VERIFIED = FALSE`: "QUOTE NOT FOUND IN SOURCE - review before relying on this loop".
   - `PATHWAY <> STANDARD`: rerouted, with `STATUS_REASON`.
   - `QA_FLAG` set: a QA note for the radiologist (never change the recommendation).
   - `PATIENT_NOTIFIED = FALSE`: "patient not told". `CLINICIAN_ACKED = FALSE`: "clinician has not acknowledged".

## Rules
- AI only extracts and quotes. Status and priority come from the SQL rules (`sql/07_rules.sql`, `docs/RULE_SHEET.md`).
- Never diagnose; never send anything to a patient.

## Reply length
Keep the reply short: at most about 15 lines plus one compact table. No preamble, no restating the steps, no long explanations. Long replies get cut off by network errors.
