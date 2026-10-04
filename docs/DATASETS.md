# Datasets and licences

| Dataset | What | Where it lives | Licence / status | Committed to repo? |
| --- | --- | --- | --- | --- |
| **Set C synthetic cohort** | 2,000 patients and a hidden answer key of 700 findings, generated in Snowflake with SQL (`sql/02`). Reports are written by AI_COMPLETE (claude-haiku-4-5) from the key (`sql/03`). Orders, notifications and acks come from `sql/04`. | `FFU.RAW.*`, `FFU.KEY.ANSWER_KEY` | Original work of this project (repo licence) | Generation scripts only (data is re-created by running them) |
| **Payer claims-derived events** | 73 synthetic follow-up events (CPT codes, dates, facility) derived from the answer key; demo and Set B claims | `PAYER_DB.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS` (payer account), shared to the hospital | Original work; synthetic | Scripts only (`sql/payer/`, `demo/payer_claims.sql`, `eval/setB/03_payer_claims.sql`). The synthetic SSN-like column is generated at runtime with HASH. |
| **Set B trap reports** | 36 cases (38 findings). Labels are written first (`eval/setB/01_labels.sql`, `setB_labels.csv`); text by claude-sonnet-4-5 | `FFU.EVAL.SETB_LABELS`, `RAW.REPORTS` (set B) | Original work; synthetic | Labels and scripts: yes |
| **Demo inputs** | 2 demo patients, a hero CT report, an outside report (text + synthetic PDF), and a decoy seed report | `demo/`, `sql/10_demo_seed.sql` | Original work; synthetic | Yes |
| **Thyroid test cases** | 6 synthetic CT reports with expected outcomes | `tests/thyroid/` | Original work; synthetic | Yes |
| **Set A: Indiana University chest X-ray reports (Open-i)** | 120 real de-identified reports sampled from 340 candidates (seed 2026), out of 3,851 | Local `data/openi/` (git-ignored) and `FFU.EVAL.SETA_RAW` in the hospital account | **CC BY-NC-ND 4.0** (per the mirrors: https://huggingface.co/datasets/ykumards/open-i, https://www.kaggle.com/datasets/raddar/chest-xrays-indiana-university) | **No text, ever.** Only `eval/setA/setA_uids.txt`, our labels (`setA_labels.csv`) and metrics |
| **Guideline rules** | Paraphrased in our own words: Fleischner 2017, ACR 2015 incidental thyroid, SVS 2018 AAA, Asia consensus 2016 | `docs/RULE_SHEET.md`, `FFU.APP.RULE_TEXT` | Paraphrase with citations; no tables copied | Yes |
| **Marketplace: Synthetic Healthcare Data - Clinical and Claims** (GZSTZL7M0Q6, Snowflake Virtual Hands-On Labs) | Synthea-based clinical and claims data | Not mounted | Free, standard listing terms; checked and available in Azure Central India | No (roadmap) |

**Rules followed:** synthetic or de-identified data only; no proprietary or employer data; no PHI. A PreToolUse hook blocks SSN- and Aadhaar-like strings.
