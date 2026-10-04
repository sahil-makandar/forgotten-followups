# Set A labelling guide (real Indiana University chest X-ray reports)

**Your work file:** `data/openi/setA_labelling_sheet.csv`. It has the report text, is git-ignored, and must never be committed (licence CC BY-NC-ND 4.0).
**When done:** copy only the label columns into `eval/setA/setA_labels.csv`. That file has uids plus labels, no text, and is safe to commit.

Fill one row per report:
| Column | Values | Rule |
| --- | --- | --- |
| expect_loop | Y / N | Y if the report recommends a follow-up action (CT, repeat imaging, further evaluation) for a finding. N for negated findings ("no nodule"), benign or stable findings with no recommendation, and "no follow-up needed". |
| finding_type | CXR_RECOMMEND_CT / LUNG_NODULE / NONE | On a chest X-ray, any nodule or opacity with a recommendation counts as CXR_RECOMMEND_CT. Use NONE when expect_loop is N. |
| action | CT_CHEST / NONE | CT_CHEST when CT or further cross-sectional imaging is recommended. |
| hedged | Y / N | Y for "if clinically indicated", "could be considered" or similar. |
| notes | free text | Anything ambiguous. A clinician settles disagreements. |

Label from the report text only. Do not look at the app's output first, so the labels stay blind.
