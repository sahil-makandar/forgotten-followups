---
name: guideline-rule-compiler
description: "Turn a clinical guideline paragraph into a deterministic SQL follow-up rule plus tests, install it in the extension slot, run its tests, and re-run the evaluation. Used for live extensions such as thyroid nodule follow-up per the ACR incidental thyroid rule. Triggers: add rule, new finding type, compile guideline, add thyroid, guideline-rule-compiler, extend rules."
---

# guideline-rule-compiler

**Input:** a finding type and a guideline paragraph (paraphrased), for example: "Add thyroid nodule follow-up per the ACR incidental thyroid rule: ultrasound if 1.5 cm or more, or 1 cm or more under age 35, or any size with suspicious features".
**Processing:**
1. Write a SQL rule into the extension slot `FFU.CORE.EXTRA_RULES`.
2. Add its closure codes.
3. Refresh the loops.
4. Run the pre-written tests.
5. Re-run the evaluation.

**Output:** the rule SQL file, the test results (PASS/FAIL per case), the eval before and after, and the new rule-sheet entry.

Connection: `hospital`. Never read `FFU.KEY.*`. AI extraction already tags `finding_type`, `long_mm`/`short_mm`, `suspicious` and `negated`; the rule must only use columns of `FFU.CORE.FINDINGS` and `FFU.RAW.PATIENTS`.

## Steps

1. **Baseline.** Run `CALL FFU.EVAL.RUN_EVAL('before-<rule>');` and keep the numbers.

2. **Read the contract.** The new rule must return exactly the columns of `FFU.CORE.EXTRA_RULES_EMPTY`, in the same order:
   `loop_id, finding_key, report_id, patient_id, clinic_id, report_date, finding_type, nodule_type, location, long_mm, short_mm, avg_mm, solid_mm, aorta_cm, hedged, stable, suspicious, quote, quote_verified, age, sex, smoking, tb_history, tier, pathway, reroute_reason, guideline_action, action, due_min_months, due_max_months, due_start, due_end, qa_flag`.
   - `loop_id` = `'L-' || finding_key`.
   - `pathway` = `'STANDARD'` unless the guideline excludes the patient.
   - `action` is a new action code (for example `THYROID_ULTRASOUND`).
   - Filter with `NOT negated`.
   - Due dates: `DATEADD(day, ROUND(30.4 * months), report_date)`.
   - Size thresholds use `long_mm` (the largest diameter, as the ACR papers do), and boundaries are inclusive exactly as the text says ("1.5 cm or more" means `>= 15`).

3. **Write `sql/rules/<rule_name>.sql`.** It contains:
   - `CREATE OR REPLACE DYNAMIC TABLE FFU.CORE.EXTRA_RULES TARGET_LAG = DOWNSTREAM WAREHOUSE = COMPUTE_WH REFRESH_MODE = FULL AS SELECT * FROM FFU.CORE.EXTRA_RULES_EMPTY UNION ALL <new rule SELECT>;`
     It must be a Dynamic Table, not a view, because Dynamic Tables can't read views over `CORE.FINDINGS`. A reference shape is in `demo/fallback_thyroid_rule.sql`; don't copy it for the live demo. If other compiled rules already exist in `sql/rules/`, include them too, so nothing is lost.
   - `INSERT INTO FFU.CORE.CLOSURE_CODES ...` for the correct test(s), plus `closes = FALSE` rows for common wrong tests, with a note. Guard with `WHERE NOT EXISTS`.
   - A header comment citing the guideline (URL) in our own words.

   Show the file to the user before running it.

4. **Install and refresh:**
   - Run the file with `snow sql -c hospital -f sql/rules/<rule_name>.sql`.
   - Then run `ALTER DYNAMIC TABLE FFU.CORE.EXTRA_RULES REFRESH;` and `CALL FFU.CORE.PROCESS_NEW_REPORTS();`. This refreshes the Dynamic Tables, so the new loops appear in the app.

5. **Test.** If `tests/<rule_name>/02_check.sql` exists (for thyroid: `tests/thyroid/01_seed.sql` seeds the cases, `02_check.sql` checks them), run the check and print every row. If any row is `FAIL`:
   - show it;
   - fix the rule once, re-install and re-test;
   - if it still fails, stop and report the failure honestly. Never edit the tests or the expected table to make them pass.

   If no test exists, write `tests/<rule_name>/` with at least: 2 cases above the threshold, 1 at the boundary, 1 below, 1 negated and 1 with suspicious features. Expected values come from the guideline text, not from the rule output.

6. **Re-run the eval** with `CALL FFU.EVAL.RUN_EVAL('after-<rule>');` and show before vs after. Existing accuracy and false greens must not get worse; if they do, report it and offer to roll back with `CALL FFU.CTRL.DEMO_RESET(TRUE);`.

7. **Document.** Append a section to `docs/RULE_SHEET.md`: the paraphrased rule, the closure codes, the tier, the citation, and "added by guideline-rule-compiler on <date>, pending clinician sign-off". Also append a line to `docs/BUILD_LOG.md`.

## Thyroid reference (ACR 2015 white paper, paraphrased)
Source: Hoang JK et al., J Am Coll Radiol 2015;12:143-150, https://www.acr.org/Clinical-Resources/Clinical-Tools-and-Reference/Incidental-Findings
- Ultrasound if the nodule is 1.5 cm or more (age 35 or over), or 1.0 cm or more (under 35), or any size with suspicious features (abnormal lymph nodes, local invasion, PET avidity).
- Tier 1 when suspicious, otherwise tier 2.
- Closed by thyroid ultrasound, CPT 76536, within 3 months.
