# Demo script (4 minutes)

The demo shows one end-to-end workflow, Input -> Processing -> Output, run through CoCo CLI with 3 custom skills. The deployed Streamlit app then shows the same results. All data is synthetic. The lawsuit is described as alleged, and the impact numbers are labelled simulated.

## Before every take (off camera)
1. In CoCo CLI, say: **"Reset the demo including extensions"**. This runs the `demo-reset` skill. Every checklist line must say PASS.
2. Run `SELECT 1;` to warm the warehouse, and open the Streamlit app in a browser tab (Worklist page).
3. Have `demo/payer_claims.sql` and `demo/fallback_thyroid_rule.sql` open in an editor tab, just in case.

## Script

| Time | Screen | What you do | What you say |
| --- | --- | --- | --- |
| 0:00-0:20 | Title slide | - | "In a lawsuit reported in 2026, a hospital allegedly found an 8 mm lung nodule, recommended a CT in 6 to 12 months, and never followed up. The patient was diagnosed with stage 4 cancer three years later. In one published study, only 37% of recommended lung nodule follow-ups were completed. Forgotten Follow-ups makes sure the next step happens, and proves every step with the source line." |
| 0:20-1:05 | CoCo CLI | Type: **"Run followup-intake on demo/inbox"** | **Input:** a new CT report for patient P09901. **Processing:** the skill lands the report and calls `PROCESS_NEW_REPORTS()`: AI extraction with a verbatim quote, plain-SQL Fleischner rules, routing and a Python priority UDF, then Dynamic Tables refresh. **Output:** "A 9 x 9 mm solid nodule, tier 1, CT due in 3 months. The quote is verified word for word. The patient has not been told." |
| 1:05-1:25 | CoCo CLI | Type: **"Move the demo clock to 2027-02-04 and run the overdue alert"** (`CALL FFU.CTRL.SET_SIM_DATE('2027-02-04'); EXECUTE ALERT FFU.APP.OVERDUE_ALERT;`) | "Four months later, nothing has happened. The loop is red, and the alert fires." |
| 1:25-2:15 | Terminal, then CoCo CLI | Run `snow sql -c payer -f demo/payer_claims.sql`. Then type: **"Audit patient P09901 and P09902 with loop-auditor"** | "The payer shares claims through Secure Data Sharing; no data is copied. P09901 had a CT chest at another hospital, so the loop is **amber**, and an outside-report request was filed. P09902 only had a chest X-ray. That is the wrong test, so the loop **stays red**, and the auditor says why. The auditor recomputes everything from raw rows, says MATCH, and cites the report line, the claim and the rule." |
| 2:15-2:35 | CoCo CLI | Type: **"Run followup-intake on demo/inbox_outside"**, then **"Audit P09901"** | "The outside report arrives. AI_FILTER confirms it discusses the right upper lobe nodule. The loop turns **green**, and the next surveillance check opens automatically." |
| 2:35-3:15 | CoCo CLI | Type: **"Use guideline-rule-compiler: add thyroid nodule follow-up per the ACR incidental thyroid rule: ultrasound if 1.5 cm or more, 1 cm or more under age 35, or any size with suspicious features"** | "Adding a new finding type takes one sentence. The skill writes a SQL rule, runs 7 tests written before the rule existed, and all of them pass. The evaluation re-runs: accuracy holds and false greens stay at 0." (Fallback if generation fails: `snow sql -c hospital -f demo/fallback_thyroid_rule.sql`; say "here is the reviewed version".) |
| 3:15-3:45 | Streamlit app | Worklist, then the P09901 timeline, then copilot chat: "Why is this patient first?" | "The same procedures drive the app. The ranked worklist, the patient timeline with the quote highlighted, and a cited answer. The copilot drafts the patient letter, and a clinician must approve it." |
| 3:45-4:00 | Results panel | - | "On 700 synthetic reports: 99% loop-status accuracy and 0 false greens. All quotes verified. Cost per 1,000 reports is shown. Completion goes from 37% to the simulated rate. Built on Snowflake." |

## Fallbacks
- If the alert is slow, show `SELECT * FROM FFU.APP.ALERTS` instead.
- If the share looks stale, run `ALTER DYNAMIC TABLE FFU.CORE.LOOP_STATUS REFRESH;`.
- If AI is slow, the extraction for the demo inbox can be run once before the take; `PROCESS_NEW_REPORTS()` reuses cached results.
- Keep a recorded backup of the full run.
