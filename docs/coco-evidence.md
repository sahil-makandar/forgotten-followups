# CoCo evidence

How Snowflake CoCo (Cortex Code) was used to plan, build and run this project. Everything listed here is in the repo; session ids are CoCo conversation ids from the build machine.

## Plan files (`.cortex/plans/`)

| File | Created | What it is |
| --- | --- | --- |
| [`plan_2026-10-04_0435.md`](../.cortex/plans/plan_2026-10-04_0435.md) | 2026-10-04 04:35 UTC, main build session `ab2f5d1e` | The approved build plan (PLAN_SPEC for Track 4), written in plan mode before any code. The working copy is [docs/PLAN_SPEC.md](PLAN_SPEC.md). |

This is the only plan file; later work was done as approved blocks inside the same session (see [BUILD_LOG.md](BUILD_LOG.md)).

## The 4 project skills (`.cortex/skills/`)

Each skill calls fixed stored procedures, so the skill, the Task and the app buttons share one code path. One real call each, taken from the CoCo sessions that ran them:

| Skill | Real call | What happened |
| --- | --- | --- |
| [`followup-intake`](../.cortex/skills/followup-intake/SKILL.md) | Session `a9fa29cf` (2026-10-04): intake of `demo/inbox`, which runs `CALL FFU.CORE.INGEST_REPORT(...)` per file, then `CALL FFU.CORE.PROCESS_NEW_REPORTS();` | P09901 opened as tier 1, status OPEN, quote verified, "patient not told" flagged (BUILD_LOG, Block 2b rehearsal). |
| [`loop-auditor`](../.cortex/skills/loop-auditor/SKILL.md) | Session `a9fa29cf`: `CALL FFU.CORE.AUDIT_LOOP('P09901');` | First audit found a MISMATCH (app RED, recomputed AMBER) because the Dynamic Table was stale; after refresh the verdict was MATCH, loop `L-RDEMO001-0` AMBER via the payer claim. |
| [`guideline-rule-compiler`](../.cortex/skills/guideline-rule-compiler/SKILL.md) | Session `96bd340d` (2026-10-04): "Add thyroid nodule follow-up per the ACR incidental thyroid rule", which runs `CALL FFU.EVAL.RUN_EVAL('before-<rule>');`, installs `sql/rules/thyroid.sql`, runs `tests/thyroid/02_check.sql`, then `CALL FFU.EVAL.RUN_EVAL('after-<rule>');` | Rule written, stopped for approval, tests 7/7 PASS, eval 690/700 before and after with 0 false greens (no regression). |
| [`demo-reset`](../.cortex/skills/demo-reset/SKILL.md) | Session `f21f5e72` (2026-10-04): `CALL FFU.CTRL.DEMO_RESET(TRUE);`, payer `EDEMO%` cleanup, then `CALL FFU.CTRL.DEMO_STATE();` | All 7 checks PASS (sim_date 2026-10-04, 0 demo reports, 0 hero alerts, 0 outside requests, 1 decoy loop, 0 demo claims, 0 thyroid loops). |

## The 2 hooks (`.cortex/settings.json`)

| Hook | Script | Test result |
| --- | --- | --- |
| PreToolUse | [`.cortex/hooks/pretooluse.ps1`](../.cortex/hooks/pretooluse.ps1): blocks SSN- and Aadhaar-like numbers, dropping secure views or policies, and destructive DDL on RAW, KEY, AI and SEC | `tests/hook_tests.ps1`: **12/12 PASS** (re-run 2026-10-05) |
| SessionEnd | [`.cortex/hooks/sessionend.ps1`](../.cortex/hooks/sessionend.ps1): appends one line per session to [coco-log.md](coco-log.md), never blocks | Run against a temporary folder with a sample event (2026-10-05): exit 0, created the log and appended one session line |

## Key fixes CoCo made during the build (from [BUILD_LOG.md](BUILD_LOG.md))

- **Change tracking:** turned on CHANGE_TRACKING on the payer table so hospital-side Dynamic Tables and Streams could read the share.
- **No secrets in SQL:** removed SSN-like literals from `sql/payer/02_payer_events.sql`; values are generated at runtime with HASH.
- **Extension slot:** `CORE.EXTRA_RULES` became a Dynamic Table, because a Dynamic Table cannot read a view that wraps another Dynamic Table.
- **Access control:** replaced `IS_ROLE_IN_SESSION` with `CURRENT_ROLE()` in the secure views, because secondary roles made every user look like ACCOUNTADMIN.
- **Explain tool:** fixed a UDF parameter name that shadowed a column, and a UDF subquery that could not run inside LISTAGG.
- **Secure view semantics:** `days_overdue` counts RED loops only; `closed_by_outside_claim_only` means status AMBER.
- **Agent creation:** `cortex agent-studio agent-write` could not take multi-line YAML from PowerShell, so the agent is created with `CREATE AGENT ... FROM SPECIFICATION` from the same spec file.
- **Silent drops:** reports that fail the extraction JSON schema now land in the `CORE.EXTRACTION_ERRORS` review queue shown in the app.
- **Eval isolation:** Set A and Set B patients moved to clinic EVAL, off the worklist, alerts and outside requests.
- **Set A rule gap:** real X-rays described masses typed as OTHER with a CT recommendation; on an X-ray, a non-negated finding with a CT, PET or biopsy recommendation now opens a loop. Made after seeing Set A (blind 17/24, after 21/24).
- **Priority scale:** rescaled so tier bands never overlap (`tests/priority_scale.sql`: 2950 < 3000).
- **Judge access:** role FFU_JUDGE and a credit-capped app warehouse (FFU_APP_RM, 5 credits/day), with no password in any file.
