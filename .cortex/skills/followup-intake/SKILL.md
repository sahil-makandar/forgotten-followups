---
name: followup-intake
description: "Ingest new radiology reports and turn them into tracked follow-up loops. Runs AI extraction with verbatim evidence quotes, deterministic rules, pathway routing and priority, refreshes the Dynamic Tables, and prints the new loops. Triggers: new report, intake, process reports, ingest report, followup-intake, what loops did this report create."
---

# followup-intake

**Input:** one or more report text files, or report rows already in `FFU.RAW.REPORTS`.
**Processing:** `FFU.CORE.INGEST_REPORT` lands the file, then `FFU.CORE.PROCESS_NEW_REPORTS()` does the rest. This is the same procedure the Task `FFU.AI.ON_NEW_REPORT` and the app's refresh button call, so there is one shared path.
**Output:** a table of the new loops with tier, priority, due date, status, "patient told" and the verified quote.

Connection: `hospital`. Warehouse: `COMPUTE_WH`. Never read `FFU.KEY.*`; that schema is the hidden answer key.

## Steps

1. **Find the input.** If the user gives a folder or file, list `*.txt` files. The file name pattern is
   `<REPORT_ID>_<PATIENT_ID>_<YYYY-MM-DD>_<MODALITY>_<CPT>.txt`, for example `demo/inbox/RDEMO001_P09901_2026-10-04_CT_CHEST_71275.txt`.
   If a name doesn't match the pattern, ask the user for the missing fields. Do not guess them.

2. **Land each report** with a bound call. Pass the file text as-is; never edit the clinical text:
   ```sql
   CALL FFU.CORE.INGEST_REPORT('<REPORT_ID>', '<PATIENT_ID>', '<DATE>', '<MODALITY>', '<CPT>', 'HOSPITAL', $$<file text>$$);
   ```
   If the text contains `$$`, stop and tell the user.

3. **Process:**
   ```sql
   CALL FFU.CORE.PROCESS_NEW_REPORTS();
   ```
   It extracts only reports not seen before (AI output is cached), refreshes `CORE.FINDINGS`, `CORE.LOOPS` and `CORE.LOOP_STATUS`, runs AI_FILTER on candidate follow-ups, and files outside-report requests for AMBER loops.

4. **Print the result** as a short table: loop_id, patient, finding and size, tier, priority score, due date, status, patient notified, and the quote with its verified flag. Then add one line per loop:
   - `quote_verified = FALSE`: say "QUOTE NOT FOUND IN SOURCE - do not rely on this loop until reviewed".
   - `pathway <> 'STANDARD'`: say it was rerouted, and why (`status_reason`).
   - `qa_flag` set: show it as a QA note for the radiologist. Never change the radiologist's recommendation.
   - `patient_notified = FALSE`: flag "patient not told".

5. If no new loops come back, say so, and show whether any reports were extracted but produced no actionable finding (for example negated, or "no follow-up needed").

## Rules
- AI only extracts and quotes. Status and priority come from the SQL rules in `sql/07_rules.sql` (signed rule sheet `docs/RULE_SHEET.md`).
- This tool never diagnoses and never sends anything to a patient.
