# Build log

## 2026-10-04 - Block 1 (foundation)

**Checks:** hospital AZ66410 (org JVHFISR, account PB73401), Azure Central India, ACCOUNTADMIN, cross-region ANY_REGION. AI_COMPLETE works with `claude-sonnet-4-5` and `claude-haiku-4-5`. Payer DK66427 (org WUDPKQN, account AK85293), same region.

**Built (hospital):**
- Resource monitor `FFU_RM` (10 credits per day, notify at 80%, suspend at 100%), attached to `COMPUTE_WH` (XS, 60s auto-suspend).
- Database `FFU`, schemas RAW, KEY, AI, CORE, CTRL, APP, SEC, EVAL.
- `RAW.PATIENTS` (2,000 synthetic patients), `KEY.ANSWER_KEY` (700 index findings, hidden truth written before any text).
- `RAW.REPORTS`: 843 reports generated with AI_COMPLETE (`claude-haiku-4-5`) from the answer key (700 index, 143 in-hospital follow-ups).
- `RAW.ORDERS`, `RAW.NOTIFICATIONS`, `RAW.ACKS`.
- `PAYER_SHARE` database mounted from share `WUDPKQN.AK85293.FFU_SHARE`.

**Built (payer):** `PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS` (73 rows: 50 CT chest, 19 decoy chest X-ray, 3 vascular consult, 1 row for another partner), row access policy `GOV.PARTNER_ROWS`, masking policy `GOV.MASK_SSN`, share `FFU_SHARE`.

**Proof:** from the hospital, the shared table shows 72 rows. The other partner's row is hidden by the row access policy and SSN shows as `****`. Enterprise policies work for the consumer account, so the secure-view fallback was not needed.

**Pre-Block 2 checks:**
- CHANGE_TRACKING was OFF on the payer table; it is now ON, for Dynamic Tables and Streams on the hospital side.
- Report fidelity vs answer key (634 reports with a finding, 66 normal): size mismatches 0. Recommendation mismatches flagged by regex: 6. All 6 were hand-checked and are valid paraphrases ("computed tomography", "vascular surgery consultation"), so the real mismatches are 0.
- Answer-key isolation: only the generators `sql/02`-`04` read `KEY.ANSWER_KEY`. Guard test `tests/check_answer_key_isolation.ps1` passes.
- SSN-like literals were removed from `sql/payer/02_payer_events.sql`; the values are now generated at runtime with HASH.

**Notes:** reports are generated as cached tables, so AI is never re-run on the same input. The payer runbook was run with `snow sql -c payer`.

## 2026-10-04 - Block 2 (engine)

**Built:**
- `AI.EXTRACTIONS` and procedure `AI.EXTRACT_NEW`: AI_COMPLETE (`claude-haiku-4-5`) with a JSON schema returns findings, a verbatim quote and history flags. 843 reports done; 1 report keeps failing schema validation and is retried each run.
- `CTRL.SIM_DATE` and procedure `CTRL.SET_SIM_DATE`; `CORE.CLOSURE_CODES`, including the wrong-test rows and the LDCT 71271 screening-only rule.
- Python UDF `CORE.PRIORITY`, which returns the score plus its breakdown.
- Dynamic Tables `CORE.FINDINGS` and `CORE.LOOPS` (TARGET_LAG DOWNSTREAM) and `CORE.LOOP_STATUS` (1 hour); views `CORE.EVIDENCE` (hospital reports plus the payer share), `CORE.WORKLIST` and `CORE.NEXT_CHECKS`.
- `AI.FOLLOWUP_CHECKS` (cached AI_FILTER results) and procedure `AI.CHECK_FOLLOWUPS`.
- Procedure `CORE.RUN_PIPELINE`; tables `APP.OUTSIDE_REPORT_REQUESTS`, `APP.CANCELLATIONS` and `APP.ALERTS`.
- Serverless alert `APP.OVERDUE_ALERT` (hourly).
- Stream `RAW.REPORTS_STREAM` and task `AI.ON_NEW_REPORT` (1 minute, runs only when the stream has data).

**First check against the hidden key (EVAL only):** 694 of 700 index reports got the right loop status. False greens: 0. Five loops that should be GREEN are RED because AI_FILTER did not confirm the follow-up report; these are now labelled "needs review". One should-be-GREEN report produced no loop. All 18 decoy chest X-ray claims kept their loop from closing; 17 are RED with the reason shown and 1 is not yet due. Quote verified: 911 of 911.

**Clock test:** moving SIM_DATE to 2027-02-04 took RED loops from 161 to 247, and EXECUTE ALERT wrote 169 alert rows. The clock was then reset to 2026-10-04.

## 2026-10-04 - Block 2b (shared procedures and product skills)

**Built:**
- Procedures `CORE.PROCESS_NEW_REPORTS`, `CORE.INGEST_REPORT`, `CORE.AUDIT_LOOP`, `CTRL.DEMO_RESET(bool)`, `EVAL.RUN_EVAL` and table `EVAL.RUNS`. Task `AI.ON_NEW_REPORT` now calls `PROCESS_NEW_REPORTS`.
- Extension slot `CORE.EXTRA_RULES`: a Dynamic Table, because Dynamic Tables cannot read a view that wraps another Dynamic Table. It starts empty from the view `CORE.EXTRA_RULES_EMPTY`.
- Skills `followup-intake`, `loop-auditor`, `guideline-rule-compiler` and `demo-reset` in `.cortex/skills/`.
- Demo inputs: patients P09901 (hero) and P09902 (decoy) with seed report RSEED902, `demo/inbox`, `demo/inbox_outside` and `demo/payer_claims.sql`.
- Thyroid tests written before the rule: `tests/thyroid/01_seed.sql` (6 cases) and `02_check.sql`. A fallback rule is in `demo/fallback_thyroid_rule.sql`.
- `docs/DEMO_SCRIPT.md`. `docs/PLAN_SPEC.md` updated for the new submission requirements.
- `.gitignore`: removed the template rules (build/, lib/, downloads/, var/, config.toml and others). Ignored now: connections.toml, *.p8, data/openi/, plus Python caches.

**Rehearsal (through the procedures):**
- Intake: P09901 is tier 1 and OPEN, the quote is verified, and "patient not told" is flagged.
- Clock to 2027-02-04: the loop goes RED and the alert fires.
- Payer claims: P09901 goes AMBER and a request is filed; the decoy P09902 stays RED (71046 is the wrong test).
- Outside report: P09901 goes GREEN, and the next check opens. The audit says MATCH.
- Thyroid tests: 5 of 7 FAIL before the rule (only the 2 no-loop cases pass) and 7 of 7 PASS with the fallback rule. Eval unchanged: 694/700, 0 false greens.
- `DEMO_RESET(TRUE)` brings back a clean state.

**Eval baseline (`EVAL.RUNS`):** 700 index reports, accuracy 0.991, false greens 0 (upper bound 0.026), 1 missed loop, quote verified 100%.
