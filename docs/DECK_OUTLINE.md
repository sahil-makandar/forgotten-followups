# Deck outline (10 slides)

Each slide is headed by the rubric line it serves: Real-World Relevance 30, Technical Execution 40, Solution Completeness 30. All numbers come from `eval/metrics.json`. Simulated numbers are labelled SIMULATED on the slide.

**1. Title - Forgotten Follow-ups** *(Real-World Relevance)*
- "When a scan says repeat in 6 months, we make sure it happens, and prove every step with the source line."
- Track 4: Patient and Member 360 and Clinical Document Copilot. Built on Snowflake.
- Visual: a red, amber and green loop icon.

**2. The problem** *(Real-World Relevance)*
- A reported lawsuit (alleged): an 8 mm nodule, a "follow-up CT 6-12 months" never communicated, then stage 4A cancer about 3 years later.
- Only 37% of recommended nodule follow-ups were completed (Nodule Net, 2022); 74% after tracking.
- The gap: hospital trackers can't see follow-ups done at another hospital, and payer claims can.

**3. Users and buyer** *(Real-World Relevance)*
- Buyer: hospital quality and radiology leadership (patient safety, malpractice risk, leaked downstream revenue).
- Data partner: the payer's care-management team, often in an India GCC. It shares one table of "follow-up done elsewhere" events. The payer never sees report text, and the hospital never gets the full claims history.
- ROI page: findings, recovered follow-ups and revenue. Every default is editable and sourced.

**4. Architecture** *(Technical Execution)*
- The two-account Mermaid diagram from the README: payer share, then Dynamic Tables, the agent and the app.
- AI extracts and quotes; plain SQL decides; AI_FILTER confirms; the wrong test never closes a loop.

**5. CoCo CLI skills: the product workflow** *(Technical Execution)*
- Diagram: `followup-intake`, then `loop-auditor`, then `guideline-rule-compiler`, then `demo-reset`, each pointing at the stored procedure it calls (`PROCESS_NEW_REPORTS`, `AUDIT_LOOP`, `EXTRA_RULES` DT + tests + `RUN_EVAL`, `DEMO_RESET`).
- One code path: the skills, the Task and the app buttons call the same procedures.
- Hooks: PreToolUse PHI and destructive-DDL guard (12/12 tests); SessionEnd log.
- Bundled skills used: agent-studio, Streamlit in Snowflake, notebooks, marketplace-search.

**6. Demo: red, amber, green** *(Solution Completeness)*
- Screenshots in order:
  1. intake output (tier 1, verified quote, patient not told);
  2. clock +4 months, then the alert;
  3. payer claim, then AMBER; the decoy chest X-ray stays RED with the reason;
  4. outside PDF read by AI_PARSE_DOCUMENT, then GREEN, then the next check opens.

**7. Copilot and Patient 360** *(Solution Completeness)*
- "Why is this patient first?" gets a cited answer: rank, score breakdown, verified report line, rule ID.
- The letter draft is pending clinician approval and logged.
- Access control: secure views on the hospital side and masking/row access policies on the payer side. Analyst view: hashed IDs, masked quotes.

**8. Live extension: thyroid in one sentence** *(Technical Execution)*
- The compiler writes the SQL rule, stops for approval, then runs 7 tests written before the rule existed (all PASS) and re-runs the eval with no regression.

**9. Results** *(Technical Execution)*
- Table: Set C 99.1% with 0 false greens vs keyword 61.4% (94 false greens) vs AI-only 60.4% (13); Set B 36/36 vs 18/36 vs 21/36; Set A (real) blind 17/24 loops at 91.7%, 21/24 at 95.0% after one rule fix made after seeing Set A.
- Cost per 1,000 reports: at most about 1.3 AI credits. Latency: about 21 ms per report in a batch.
- SIMULATED: completion 35.9% (hospital only), then 50.9% with the payer share, then 78.8% with recall.
- 3 honest failure cases (one line each).

**10. Limits, roadmap, ask** *(Solution Completeness)*
- Limits: synthetic data; Set B labels drafted by the build agent, then reviewed by team member Rojina Mallick (38 of 38 agreed; not a radiologist, rule sheet still needs radiologist sign-off); Set A rule fix after seeing results; trial account; owner's-rights app.
- Roadmap: deeper use of the Marketplace clinical and claims listing (mounted; context chart today), Native App, Snowflake Intelligence, ABDM for Indian hospitals, Hindi letter.
- Close: "0 false greens - nobody is told they're done when they aren't."
