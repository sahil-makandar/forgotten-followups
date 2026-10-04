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
