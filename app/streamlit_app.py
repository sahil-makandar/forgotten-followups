"""Forgotten Follow-ups - care coordination app (Streamlit in Snowflake). All data is synthetic.

Pages: Worklist, Patient loop timeline, Copilot chat, Alerts, Results.
Every action calls the same stored procedures the CoCo skills and the Task use.
"""
import json
import os

import pandas as pd
import streamlit as st

st.set_page_config(page_title="Forgotten Follow-ups", layout="wide")

conn = st.connection("snowflake")  # SiS supplies the connection; passing connection_name here crashes the app

# Restricted caller's rights connection (container runtime only). Must be created at the top of the script:
# the caller token is valid for two minutes from session start. It runs as the VIEWER's default role and can only
# read FFU.SEC.LOOPS_V (caller grants in sql/13_app_access.sql). None when unavailable (for example local runs).
try:
    caller_conn = st.connection("snowflake-callers-rights")
except Exception:  # noqa: BLE001 - any failure means the feature is unavailable here
    caller_conn = None

STATUS_ICON = {"RED": ":red[RED]", "AMBER": ":orange[AMBER]", "GREEN": ":green[GREEN]",
               "OPEN": ":blue[OPEN]", "REROUTED": ":violet[REROUTED]", "CANCELLED": ":gray[CANCELLED]"}


def q(sql: str, params=None, ttl=0) -> pd.DataFrame:
    """Run a parameterised query; column names are lower-cased for easy access.

    CALL results come back in JSON result format, which conn.query() (Arrow fetch) cannot read
    ("NotSupportedError: Unknown error"), so procedure calls go through a plain cursor.
    """
    if sql.lstrip().upper().startswith("CALL"):
        cur = conn.cursor()
        try:
            cur.execute(sql, params)
            df = pd.DataFrame(cur.fetchall(), columns=[d[0] for d in cur.description])
        finally:
            cur.close()
    else:
        df = conn.query(sql, params=params, ttl=ttl)
    df.columns = [c.lower() for c in df.columns]
    return df


def run(sql: str, params=None) -> pd.DataFrame:
    """Run a statement that changes state (never cached)."""
    return q(sql, params, ttl=0)


def sim_date() -> str:
    return str(q("SELECT MAX(sim_date) AS d FROM FFU.CTRL.SIM_DATE")["d"].iloc[0])


# ---------- sidebar: demo clock and refresh ----------
st.sidebar.title("Forgotten Follow-ups")
st.sidebar.caption("Built on Snowflake. Synthetic data only. Not a diagnostic tool.")
page = st.sidebar.radio("Page", ["Worklist", "Patient 360", "Copilot chat", "Alerts", "Results"])
st.sidebar.divider()
st.sidebar.markdown(f"**Demo date:** {sim_date()}")
new_date = st.sidebar.date_input("Move demo clock to", value=pd.to_datetime(sim_date()))
if st.sidebar.button("Move clock and run overdue alert", use_container_width=True):
    with st.spinner("Moving clock, refreshing loops, firing alert..."):
        run("CALL FFU.CTRL.ADVANCE_CLOCK(?, 'ALL')", [str(new_date)])
    st.rerun()
if st.sidebar.button("Refresh (process new reports)", use_container_width=True):
    with st.spinner("Extracting new reports and refreshing loops..."):
        run("CALL FFU.CORE.PROCESS_NEW_REPORTS()")
    st.rerun()


# ---------- Worklist ----------
if page == "Worklist":
    st.header("Ranked worklist")
    st.caption("Red (overdue) and amber (done elsewhere, outside report needed). Most dangerous tier first, then priority score, then days overdue.")
    wl = q("""SELECT rank, loop_id, patient_id, clinic_id, finding_type,
                     COALESCE(avg_mm || ' mm', aorta_cm || ' cm') AS size, tier, status, days_overdue,
                     priority:score::FLOAT AS priority, clinician_acked, patient_notified, status_reason
              FROM FFU.CORE.WORKLIST ORDER BY rank LIMIT 300""")
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("On worklist", len(wl))
    c2.metric("Red (overdue)", int((wl["status"] == "RED").sum()))
    c3.metric("Amber (outside claim)", int((wl["status"] == "AMBER").sum()))
    c4.metric("Patient not told", int((~wl["patient_notified"].astype(bool)).sum()))
    f1, f2 = st.columns(2)
    types = f1.multiselect("Finding type", sorted(wl["finding_type"].unique()))
    tiers = f2.multiselect("Tier", sorted(wl["tier"].unique()))
    mask = pd.Series(True, index=wl.index)  # start from "keep all" so no filter selected keeps every row
    if types:
        mask &= wl["finding_type"].isin(types)
    if tiers:
        mask &= wl["tier"].isin(tiers)
    view = wl[mask]
    st.dataframe(view, hide_index=True, use_container_width=True,
                 column_config={"priority": st.column_config.NumberColumn(format="%.1f")})

    # View as analyst: same loops through the role-aware secure view, read with the viewer's own role.
    st.divider()
    if st.toggle("View as analyst (masked, via caller's rights)"):
        if caller_conn is None:
            st.info("Caller's rights are only available when the app runs in Snowflake (container runtime).")
        else:
            role = caller_conn.query("SELECT CURRENT_ROLE() AS r", ttl=0).iloc[0, 0]
            st.caption(f"Reading FFU.SEC.LOOPS_V as your default role **{role}**. "
                       "FFU_ANALYST sees hashed patient IDs and masked quotes; coordinators see only their clinics; admins see all.")
            masked = caller_conn.query("""SELECT loop_id, patient_id, clinic_id, finding_type, tier, status, days_overdue,
                                                 age_band, quote, status_reason
                                          FROM FFU.SEC.LOOPS_V WHERE status IN ('RED','AMBER') ORDER BY tier, priority_score DESC LIMIT 100""", ttl=0)
            st.dataframe(masked, hide_index=True, use_container_width=True)

    errs = q("SELECT report_id, patient_id, report_date, modality, error FROM FFU.CORE.EXTRACTION_ERRORS WHERE set_name NOT IN ('A','B')")
    if not errs.empty:
        st.warning(f"{len(errs)} report(s) could not be read by AI extraction and need a person to review them (never dropped silently).")
        st.dataframe(errs, hide_index=True, use_container_width=True)


# ---------- Patient loop timeline ----------
elif page == "Patient 360":
    st.header("Patient 360")
    pid = st.text_input("Patient ID", value="P09901").strip()
    loops = q("SELECT * FROM FFU.CORE.LOOP_CARD WHERE patient_id = ? ORDER BY priority_score DESC", [pid])
    if loops.empty:
        st.info("No follow-up loops for this patient.")
    for _, l in loops.iterrows():
        with st.container(border=True):
            st.subheader(f"{l['loop_id']} - {l['finding_type']} {l['size']} - {STATUS_ICON.get(l['status'], l['status'])}")
            st.markdown(f"**Tier {l['tier']}**, priority **{l['priority_score']:.1f}** = {l['priority_breakdown']}")
            st.markdown(f"**Status:** {l['status_reason']}  \n**Due by:** {l['due_end']}  \n"
                        f"**Clinician acknowledged:** {l['clinician_acked']} - **Patient notified:** {l['patient_notified']}")
            if l["qa_flag"]:
                st.warning(f"QA note for the radiologist (we never override): {l['qa_flag']}")
            # Original report with the evidence quote highlighted.
            rpt = q("SELECT report_id, report_date, facility, text FROM FFU.RAW.REPORTS WHERE report_id = ?", [l["report_id"]])
            if not rpt.empty:
                text, quote = rpt["text"].iloc[0], l["quote"] or ""
                shown = text.replace(quote, f"**:orange-background[{quote}]**") if quote and quote in text else text
                with st.expander(f"Report {rpt['report_id'].iloc[0]} ({rpt['report_date'].iloc[0]}) - quote verified: {l['quote_verified']}"):
                    st.markdown(shown.replace("\n", "  \n"))
            if st.button("Audit this loop (recompute from raw rows)", key=f"audit-{l['loop_id']}"):
                a = q("CALL FFU.CORE.AUDIT_LOOP(?)", [l["loop_id"]])
                for _, r in a.iterrows():
                    (st.success if r["match"] else st.error)(
                        f"{'MATCH' if r['match'] else 'MISMATCH'}: app says {r['app_status']}, raw rows say {r['audit_status']}")
                    st.caption(f"Rule: {r['rule']}")
                    st.caption(f"Evidence: {r['evidence']}")
    st.subheader("Timeline")
    tl = q("""
        SELECT report_date AS event_date, 'Report ' || report_id || ' (' || modality || ', ' || facility || ')' AS event, 'hospital record' AS source
          FROM FFU.RAW.REPORTS WHERE patient_id = ?
        UNION ALL SELECT ack_date, 'Clinician acknowledged ' || report_id, 'hospital record' FROM FFU.RAW.ACKS WHERE patient_id = ?
        UNION ALL SELECT notified_date, 'Patient notified by ' || channel, 'hospital record' FROM FFU.RAW.NOTIFICATIONS WHERE patient_id = ?
        UNION ALL SELECT order_date, 'Order ' || cpt || ' ' || status, 'hospital record' FROM FFU.RAW.ORDERS WHERE patient_id = ?
        UNION ALL SELECT service_date, 'Claim ' || event_id || ': CPT ' || cpt || ' ' || cpt_desc || ' at ' || facility, 'payer share'
          FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS WHERE patient_id = ?
        UNION ALL SELECT requested_at::DATE, 'Outside report requested (' || claim || ')', 'app' FROM FFU.APP.OUTSIDE_REPORT_REQUESTS WHERE patient_id = ?
        UNION ALL SELECT d.next_due, 'Next surveillance check due', 'rule' FROM FFU.CORE.NEXT_CHECKS d WHERE patient_id = ?
        ORDER BY 1""", [pid] * 7)
    st.dataframe(tl, hide_index=True, use_container_width=True)


# ---------- Copilot chat ----------
elif page == "Copilot chat":
    st.header("Copilot")
    st.caption("Cortex Agent with a semantic view, Cortex Search and 2 tools (explain priority, draft letter). "
               "Every answer cites the report line, the record and the rule. Letters are drafts until a clinician approves them.")
    if "chat" not in st.session_state:
        st.session_state.chat = []
    for m in st.session_state.chat:
        with st.chat_message(m["role"]):
            st.markdown(m["content"])
    examples = ["Who is first on the worklist and why?", "Which lung nodules over 8 mm are overdue by more than 60 days?",
                "Which loops were closed only by outside claims?", "Draft the patient letter for L-RSEED902-0"]
    # Buttons (not pills): a sticky selection would re-run the agent on every rerun.
    pick = None
    for col, ex in zip(st.columns(len(examples)), examples):
        if col.button(ex, use_container_width=True):
            pick = ex
    prompt = st.chat_input("Ask about follow-ups") or pick
    if prompt:
        st.session_state.chat.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)
        with st.chat_message("assistant"), st.spinner("Thinking with the agent..."):
            res = q("CALL FFU.APP.ASK_AGENT(?)", [prompt])
            out = json.loads(res.iloc[0, 0]) if isinstance(res.iloc[0, 0], str) else res.iloc[0, 0]
            answer = out.get("answer") or "No answer returned."
            tools = ", ".join(out.get("tools") or [])
            st.markdown(answer)
            if tools:
                st.caption(f"Tools used: {tools}")
        st.session_state.chat.append({"role": "assistant", "content": answer})
    st.subheader("Drafts awaiting clinician approval")
    drafts = q("SELECT draft_id, loop_id, kind, status, created_at, draft FROM FFU.APP.APPROVALS ORDER BY created_at DESC LIMIT 20")
    for _, d in drafts.iterrows():
        with st.expander(f"{d['kind']} for {d['loop_id']} - {d['status']}"):
            st.text(d["draft"])
            if d["status"] == "PENDING_CLINICIAN_APPROVAL":
                who = st.text_input("Clinician name", key=f"who-{d['draft_id']}")
                if st.button("Approve (logged)", key=f"ok-{d['draft_id']}", disabled=not who):
                    run("CALL FFU.APP.APPROVE_DRAFT(?, ?)", [d["draft_id"], who])
                    st.rerun()


# ---------- Alerts ----------
elif page == "Alerts":
    st.header("Alerts")
    st.caption("Fired by the overdue Alert when a tier-1 loop goes red. Outside-report requests are created for amber loops.")
    st.subheader("Overdue alerts")
    st.dataframe(q("SELECT fired_at, sim_date, patient_id, loop_id, tier, message FROM FFU.APP.ALERTS ORDER BY fired_at DESC LIMIT 200"),
                 hide_index=True, use_container_width=True)
    st.subheader("Outside-report requests")
    st.dataframe(q("SELECT requested_at, patient_id, loop_id, claim, status FROM FFU.APP.OUTSIDE_REPORT_REQUESTS ORDER BY requested_at DESC LIMIT 200"),
                 hide_index=True, use_container_width=True)


# ---------- Results ----------
elif page == "Results":
    st.header("Results")
    st.caption("Official numbers come only from the DEMO_RESET(TRUE) state (see eval/metrics.json). Synthetic Set C.")
    runs = q("""SELECT run_at, label, official, state_note, n, correct, accuracy, false_green, false_green_upper95,
                       missed_loops, quote_verified_rate FROM FFU.EVAL.RUNS ORDER BY run_at DESC LIMIT 20""")
    off = runs[runs["official"] == True]  # noqa: E712
    if not off.empty:
        r = off.iloc[0]
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Loop-status accuracy", f"{r['accuracy']:.1%}", help=f"{r['correct']} of {r['n']} index reports")
        c2.metric("False greens", f"{int(r['false_green'])} of {r['n']}", help=f"95% upper bound {r['false_green_upper95']:.1%}")
        c3.metric("Quotes verified", f"{r['quote_verified_rate']:.0%}")
        c4.metric("Missed loops", int(r["missed_loops"]))
    st.dataframe(runs, hide_index=True, use_container_width=True)
    st.subheader("Loop status mix")
    st.bar_chart(q("SELECT status, COUNT(*) AS loops FROM FFU.CORE.LOOP_STATUS GROUP BY 1 ORDER BY 1"), x="status", y="loops")
