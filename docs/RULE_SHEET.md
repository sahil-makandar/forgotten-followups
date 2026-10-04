# Rule sheet (version 1) - for clinician review and sign-off

These rules are implemented as plain SQL in `sql/07_rules.sql`. AI only extracts facts, quotes the source line and explains. AI never decides a status. The guidelines are paraphrased in our own words. This is not a diagnostic tool, and it never overrides the radiologist.

## 1. Incidental lung nodule on CT (Fleischner Society 2017)
Source: MacMahon H et al., Radiology 2017. https://pubs.rsna.org/doi/full/10.1148/radiol.2017161659

- **Size** = average of the long and short axis, rounded to the nearest mm. A 9 x 7 mm nodule counts as 8 mm. Part-solid nodules are judged by their solid part.
- **Solid, under 6 mm:** no routine follow-up.
- **Solid, 6 to 8 mm:** CT at 6 to 12 months.
- **Solid, over 8 mm:** CT at about 3 months, PET/CT or tissue sampling. **Tier 1.**
- **Part-solid, 6 mm or more:** CT at 3 to 6 months. **Tier 1** if the solid part is 6 mm or more.
- **Ground-glass, 6 mm or more:** CT at 6 to 12 months. **Tier 3.**
- **What closes the loop:** CT chest (CPT 71250, 71260, 71270), PET/CT (78815) or biopsy (32405), done after the index report, AND the new report discusses the nodule (checked by AI_FILTER).
- **Low-dose screening CT (71271)** closes the loop only on the lung screening pathway.

## 2. Chest X-ray that says "recommend CT" (radiologist's recommendation)
- Action: CT chest within 1 month, unless the report states another interval.
- **Tier 1** if the wording is "suspicious" or "mass"; otherwise tier 2.
- Closes with the same CT codes as above.

## 3. Abdominal aortic aneurysm (SVS 2018 practice guidelines)
Source: Chaikof EL et al., J Vasc Surg 2018;67:2-77.
- **5.5 cm or more (men), or 5.0 cm or more (women):** vascular surgery referral within 1 month. **Tier 1.**
- **Otherwise, surveillance ultrasound:** about every 6 months at 5.0 to 5.4 cm, about every 12 months at 4.0 to 4.9 cm (tier 2), and about every 3 years at 3.0 to 3.9 cm (tier 3).
- **What closes the loop:** aorta ultrasound (76775, 76770), CT abdomen (74177, 74178) or CTA (75635). A referral loop closes with a consult (99242 to 99245, 99203 to 99205).
- Surveillance continues: closing one loop opens the next check-up.

## 4. Thyroid nodule seen on CT (ACR 2015 white paper)
Source: Hoang JK et al., J Am Coll Radiol 2015;12:143-150. https://www.acr.org/Clinical-Resources/Clinical-Tools-and-Reference/Incidental-Findings

- **1.5 cm or more (age 35+):** thyroid ultrasound within 3 months. **Tier 2.**
- **1.0 cm or more (under 35):** thyroid ultrasound within 3 months. **Tier 2.**
- **Any size with suspicious features** (abnormal lymph nodes, local invasion, PET avidity): thyroid ultrasound within 3 months. **Tier 1.**
- **Under the threshold and not suspicious:** no follow-up.
- **What closes the loop:** thyroid ultrasound (CPT 76536).
- **What does not close the loop:** neck CT (CPT 70491).
- Closure codes: `THYROID_ULTRASOUND` / `76536` (closes), `THYROID_ULTRASOUND` / `70491` (does not close).

Added by guideline-rule-compiler on 2026-10-04, pending clinician sign-off.

## 5. Pathway routing (lung nodules; Fleischner exclusions)
Patients with known cancer go to **ONCOLOGY_SURVEILLANCE**. Patients who are immunosuppressed or under 35 go to **CLINICIAN_REVIEW**. Patients enrolled in screening go to **LUNG_SCREENING** (Lung-RADS). These patients are listed with the reason and are never silently dropped.

## 6. Loop states
| State | Meaning |
| --- | --- |
| OPEN | Not due yet |
| RED | Past the due date with no matching test |
| AMBER | A payer claim shows the right test at another hospital, but we have no report yet. An outside-report request is created. |
| GREEN | A hospital report or note exists AND AI_FILTER confirms it discusses the original finding |
| CANCELLED | Requires a written reason plus clinician sign-off |
| REROUTED | Moved to another pathway, with the reason shown |

- **The wrong test never closes a loop.** A chest X-ray (71045, 71046) never closes a CT loop; the reason is shown.
- **The radiologist's stated interval sets the due date.** If it differs from the guideline, a QA flag is raised; we never override the radiologist.
- Communication (clinician acknowledged, patient notified) is tracked separately from completion.

## 7. Priority (not "risk")
- Score = tier points (tier 1: 300, tier 2: 200, tier 3: 100), plus time points (share of the due window elapsed x 50, capped at 100), plus context points (age 65 or over +5; current smoker +5, former +3).
- A TB history is shown as context only and never raises priority.
- Subsolid nodules in never-smoker women are never downgraded (Bai C et al., Asia consensus 2016, https://pubmed.ncbi.nlm.nih.gov/26923625).

Clinician sign-off: ____________________  Date: __________
