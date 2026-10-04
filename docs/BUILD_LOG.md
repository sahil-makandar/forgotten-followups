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

## 2026-10-04 - Thyroid rule (guideline-rule-compiler)

**Rule:** ACR 2015 incidental thyroid white paper (Hoang JK et al., JACR 2015;12:143-150).
- Thyroid ultrasound if nodule >= 1.5 cm (age 35+), >= 1.0 cm (under 35), or any size with suspicious features.
- Tier 1 if suspicious, tier 2 otherwise. Due within 3 months.
- Closure: CPT 76536 (closes), CPT 70491 (does not close).

**File:** `sql/rules/thyroid.sql`: Dynamic Table `FFU.CORE.EXTRA_RULES`.

**Tests:** `tests/thyroid/02_check.sql`: 7/7 PASS (6 clinical cases + closure codes).

**Eval:** before 690/700 (98.57%), 0 false greens, 1 missed loop. After: 690/700 (98.57%), 0 false greens, 1 missed loop. No regression.

## 2026-10-04 - Block 3 (copilot and app)

**Built:**
- **Access control** (`sql/11`): roles `FFU_COORDINATOR`, `FFU_ANALYST` and `FFU_APP_OWNER`; secure views `SEC.LOOPS_V` and `SEC.REPORTS_V` with `CURRENT_ROLE()` checks, mapped through `SEC.ROLE_CLINICS`.
  - Tested: the coordinator sees clinics C1 and C2 only (312 loops, 444 reports). The analyst sees all 611 loops with hashed patient IDs, `***` quotes, age bands and 0 reports.
  - `IS_ROLE_IN_SESSION` was replaced, because secondary roles made every role look like ACCOUNTADMIN.
- **Copilot** (`sql/12`): `APP.RULE_TEXT` (R1-R7, paraphrased), Cortex Search `APP.REPORT_SEARCH` (reports plus rules), view `APP.LOOP_EXPLANATION`, `APP.EXPLAIN_PRIORITY` and the tool procedure `APP.EXPLAIN_PRIORITY_TOOL`, `APP.DRAFT_LETTER` (claude-sonnet-4-5; drafts are logged as PENDING_CLINICIAN_APPROVAL), `APP.APPROVE_DRAFT`, `APP.VERIFY_QUOTE`, and semantic view `APP.LOOPS_SV` over the secure view.
- **Agent** `APP.FFU_AGENT` (`agent/FFU_AGENT.agent.yaml`) with tools loop_analytics (Analyst), search_reports_and_rules, explain_priority and draft_letter.
  - `cortex agent-studio agent-write` could not take multi-line YAML from PowerShell, so the agent is created with `agent/create_agent.sql` (CREATE AGENT FROM SPECIFICATION, same YAML).
  - `APP.ASK_AGENT` wraps `DATA_AGENT_RUN` for the app.
- **Streamlit** `FFU.APP.FFU_APP` (container runtime, `SYSTEM_COMPUTE_POOL_CPU`). Pages: Worklist, Patient loop timeline (quote highlighted, audit button), Copilot chat with approvals, Alerts, Results.

**Checks:**
- Agent "who is first and why": rank 1 of 211, score breakdown, verified report line, and rules R3 and R7.
- "Closed only by outside claims": 49, which matches the AMBER count.
- Explain tool: 2 bugs fixed. A UDF parameter name shadowed a column, and a UDF with a subquery could not be used inside LISTAGG.
- Secure view fixes: `days_overdue` now counts RED loops only, and `closed_by_outside_claim_only` now means status AMBER.

## 2026-10-04 - Block 3 (copilot and app)

**Built:**
- Access control (sql/11), with roles FFU_COORDINATOR (clinics C1 and C2, full detail) and FFU_ANALYST (all clinics, masked). The secure views SEC.LOOPS_V and SEC.REPORTS_V check the primary role with CURRENT_ROLE(); IS_ROLE_IN_SESSION widened access through secondary roles, so it was replaced. Tested: the coordinator sees 312 loops in C1/C2; the analyst sees 611 loops with hashed IDs, *** quotes, age bands and 0 reports.
- Copilot layer (sql/12):
  - APP.RULE_TEXT (R1-R7, paraphrased);
  - Cortex Search APP.REPORT_SEARCH over reports and rules;
  - view APP.LOOP_EXPLANATION, with UDF APP.EXPLAIN_PRIORITY and tool procedure APP.EXPLAIN_PRIORITY_TOOL;
  - APP.DRAFT_LETTER, APP.APPROVE_DRAFT and APP.APPROVALS;
  - APP.VERIFY_QUOTE;
  - semantic view APP.LOOPS_SV over SEC.LOOPS_V.
- Cortex Agent APP.FFU_AGENT (gent/FFU_AGENT.agent.yaml, gent/create_agent.sql) with 4 tools: analyst, search, explain_priority and draft_letter. cortex agent-studio agent-write could not take multi-line YAML from PowerShell, so the agent was created with CREATE AGENT FROM SPECIFICATION from the same spec file.
- APP.ASK_AGENT wraps DATA_AGENT_RUN for the app (sql/13).
- Streamlit FFU.APP.FFU_APP (container runtime, SYSTEM_COMPUTE_POOL_CPU) with these pages: Worklist, Patient loop timeline, Copilot chat, Alerts and Results.

**Tests:**
- Agent "who is first": rank 1 of 211 (L-R00334-0), with the score breakdown, verified quote, rules R3/R7 and communication status.
- "Closed only by outside claims": 49 (matches the AMBER count).
- Letter draft is logged as PENDING_CLINICIAN_APPROVAL.

**Bundled skills used:** agent-studio (agent spec templates), developing-with-streamlit-in-snowflake (deploy manifest, container runtime).

**App URL:** https://app.snowflake.com/JVHFISR/pb73401/#/streamlit-apps/FFU.APP.FFU_APP

## 2026-10-04 - Block 4 (proof and CoCo)

**Set B (trap reports):**
- 36 cases (38 findings) cover every trap in the brief plus extras: cm sizes, PET/CT claim, low-dose CT claim, unrelated follow-up CT, addendum that cancels, never-smoker woman, TB.
- Labels were written first (`eval/setB/01_labels.sql`, exported to `eval/setB/setB_labels.csv` for review), text by claude-sonnet-4-5, extraction by claude-haiku-4-5.
- Result: 38/38 status, 0 false greens; size, tier, action, pathway and quotes each 30/30.
- Caveat: the labels were written by the builder, not an independent tester.

**Set A (real text):** 120 Indiana University reports sampled with fixed seed 2026 from 340 candidates. Loaded and extracted; the text stays in `data/openi/` (git-ignored). A blank labelling sheet and guide are ready; metrics were pending hand labels at this point (scored later; see the Set A section and the README).

**Baselines** (`eval/02_baselines.sql`, `EVAL.BASELINE_SUMMARY`): SYSTEM vs KEYWORD vs AI_ONLY, with Wilson 95% CIs and a false-green rate over loops that should not be green.
- Set C: system 694/700 with 0 false greens; keyword 61.4% with 94 false greens; AI-only 60.4% with 13 false greens.
- Set B: system 36/36; keyword 18/36; AI-only 21/36.

**Official run:** `official-v2-block4` from the DEMO_RESET(TRUE) state.

**Cost** (METERING_HISTORY, whole day so far): 2.422 AI credits over 1890 AI-processed reports, so at most 1.28 AI credits per 1,000 reports. Warehouse 2.071, agent 0.636, app container 0.298 credits.

**Latency:** 822-report batch in 17.2 s (about 21 ms per report in parallel); a single report takes about 3.5 s.

**Failure cases (3):**
1. A schema error on R00519 and RA9 means no loop is opened. The new `CORE.EXTRACTION_ERRORS` review queue shows these in the app.
2. Different wording (mass-like opacity vs nodule) means AI_FILTER fails to confirm, so the loop stays RED as needs review.
3. Priority saturates at 3110 for long-overdue tier-1 loops; the tie-break is days overdue.

**Hooks:** `.cortex/settings.json`.
- PreToolUse (`.cortex/hooks/pretooluse.ps1`) blocks SSN- and Aadhaar-like numbers, dropping secure views or policies, and destructive DDL on RAW, KEY, AI and SEC (override: FFU_ALLOW_DESTRUCTIVE=1). `tests/hook_tests.ps1`: 12/12 pass.
- SessionEnd appends to `docs/coco-log.md`.

**App:**
- Page renamed to Patient 360.
- "View as analyst" toggle using restricted caller's rights (`st.connection('snowflake-callers-rights')`), with caller grants limited to FFU.SEC.LOOPS_V and the warehouse. It uses the viewer's DEFAULT role, so masking only shows for a user whose default role is FFU_ANALYST.
- Extraction-error queue on the Worklist.
- Eval patients (Sets A and B) sit in clinic EVAL and are kept off the worklist, alerts and outside requests.

## 2026-10-04 - Extras (in order)

1. **Outside-report PDF (done).** Stage `APP.OUTSIDE_DOCS` (SSE, directory table), `CORE.INGEST_OUTSIDE_PDF` (AI_PARSE_DOCUMENT LAYOUT, cached in `AI.PARSED_DOCS`), and a synthetic PDF `demo/inbox_outside/RDEMO002_*.pdf`. Rehearsal: AMBER, then 575 chars parsed, then GREEN, and the next check opens. `followup-intake` handles .pdf, and DEMO_RESET clears the parse cache.
2. **Notebook eval harness (done).** `eval/eval_harness.ipynb` (generated by `eval/make_notebook.py`), uploaded to Workspace: https://app.snowflake.com/jvhfisr/pb73401/#/workspaces/ws/USER%24/PUBLIC/DEFAULT%24/eval_harness.ipynb (not executed in Snowflake from here).
3. **Marketplace check (10 min, done; mounted later by the owner, see the Marketplace context section).** `Synthetic Healthcare Data - Clinical and Claims` (Snowflake Virtual Hands-On Labs, GZSTZL7M0Q6): free (is_monetized false), STANDARD terms, regions ALL, ready for import, Synthea-based, with PATIENTS, ENCOUNTERS, CLAIMS, PAYERS and PROVIDERS in SYNTHEA.SILVER. Getting it requires accepting Marketplace terms, so it waits for the owner's OK. If added, it would be the payer's claims backdrop only.
4. **ROI calculator page (done).** Every input is editable and shows its source (Nodule Net 37% and 74%, East Alabama 39% to 68% and about $9,000 a month, and a 31% finding rate, later relabelled as an assumption). The CT volume and price per exam are labelled ASSUMPTION. The achieved rate defaults to this project's SIMULATED 78.8%. Headless smoke test: 19/19.


## 2026-10-04 - Block 5 (packaging, started 17:43 IST)
- README rewritten: architecture diagram, results table, CoCo skills table, features, runbook, known limits, roadmap.
- New: `docs/DATASETS.md` (every dataset with its licence; Set A text never committed), `docs/DECK_OUTLINE.md` (10 slides, each headed by its rubric line, including the skills-workflow slide).
- `docs/DEMO_SCRIPT.md` updated: PDF step, Patient 360, final numbers, recording checklist.

## 2026-10-04 - Set A scored, app polish, judge login
- **Set A scoring** (`eval/setA/02_score.sql`; labels in `eval/setA/setA_labels.csv`, uid + 4 label columns only).
  - Blind, frozen in `EVAL.SETA_SUMMARY_BLIND`: system 91.7% (recall 17/24), AI-only 92.5% (24/24, 9 false alarms), keyword 90.8% (13/24).
  - Rule gap found: real X-rays describe masses and mediastinal contours that extraction typed as OTHER with a CT recommendation. Fix: on an X-ray, any non-negated finding with a CT/PET/biopsy recommendation opens a loop.
  - After the fix (no longer blind): system 95.0%, recall 21/24, precision 0.875. Sets B and C unchanged (36/36; 694/700, 0 false greens).
- **Priority** spread: elapsed up to 900, context up to 50, tier step 1000; `tests/priority_scale.sql` passes (2950 < 3000). Days overdue is blank for AMBER.
- **App:** Patient 360 dropdown (rank 1 default) with sections and a vertical timeline; Results leads with the comparison charts (false greens in red), official runs only, all runs in an expander, quotes to one decimal; Letters rename. Light theme (`app/.streamlit/config.toml`), status pills, friendly worklist with row click to Patient 360, KPI cards, Demo controls expander. Smoke test 20/20 plus a row-click jump check. Rollback tag `pre-ui-polish`.
- **Judge login** (`sql/15_judge_access.sql`, no password in any file):
  - role FFU_JUDGE (usage on FFU_APP_WH, FFU, the APP/SEC schemas, the app and the agent; SELECT on SEC.LOOPS_V, which is masked for judges);
  - user JUDGE_RUZEN (default role FFU_JUDGE, MUST_CHANGE_PASSWORD FALSE) with the user-level policy FFU.SEC.JUDGE_AUTH_POLICY (MFA_ENROLLMENT OPTIONAL);
  - credit guard: the app and the judge run on FFU_APP_WH, capped by FFU_APP_RM at 5 credits/day (suspend immediately).
  - Tested by logging in as JUDGE_RUZEN: role FFU_JUDGE, app visible, masked rows only; raw tables and CREATE are denied.

## Marketplace context and ROI source fix

- **Marketplace listing mounted** by the owner as SYNTHETIC_HEALTHCARE_DATA_CLINICAL_AND_CLAIMS. One read-only secure view, FFU.APP.MKT_IMAGING_VOLUME (sql/16_marketplace_context.sql), counts imaging studies by modality. It is shown as a context chart on the Results page and granted to FFU_ANALYST and FFU_JUDGE (judge query tested). The pipeline, rules, eval and demo are unchanged.
- **ROI default:** the 31% actionable-finding rate is now labelled 'ASSUMPTION, editable'. The Gould 2015 citation was removed because it was not checked against the paper. Smoke test 20/20; app redeployed.
