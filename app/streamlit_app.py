"""Forgotten Follow-ups - care coordination app (Streamlit in Snowflake). All data is synthetic.

Pages: Worklist, Patient 360, Copilot chat, Alerts, Results, ROI calculator.
Every action calls the same stored procedures the CoCo skills and the Task use.
"""
import html
import json

import altair as alt
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

STATUS_COLOURS = {  # background, text
    "RED": ("#FDE2E1", "#B3261E"), "AMBER": ("#FFF1D6", "#8A5300"), "GREEN": ("#E3F5E6", "#1E7B34"),
    "OPEN": ("#ECEFF1", "#455A64"), "REROUTED": ("#EFE5FA", "#6A3FA0"), "CANCELLED": ("#ECEFF1", "#455A64"),
}
PAGES = ["Worklist", "Patient 360", "Copilot chat", "Alerts", "Results", "ROI calculator"]


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


def chip(status: str) -> str:
    """HTML pill for a loop status."""
    bg, fg = STATUS_COLOURS.get(status, ("#ECEFF1", "#455A64"))
    return (f"<span style='background:{bg};color:{fg};padding:2px 10px;border-radius:999px;"
            f"font-weight:600;font-size:0.8rem'>{html.escape(str(status))}</span>")


def style_status(df: pd.DataFrame, col: str = "Status"):
    """Colour the status column of a table as pills (background + text colour)."""
    def cell(v):
        bg, fg = STATUS_COLOURS.get(v, ("", ""))
        return f"background-color: {bg}; color: {fg}; font-weight: 600; border-radius: 12px" if bg else ""
    return df.style.map(cell, subset=[col]) if col in df.columns else df


def highlight(text: str, quote: str) -> str:
    """Report text as safe HTML, with the evidence quote marked."""
    safe = html.escape(text if isinstance(text, str) else "")
    if isinstance(quote, str) and quote:  # NaN (no loop on this report) is a float, not a quote
        sq = html.escape(quote)
        if sq in safe:
            safe = safe.replace(sq, f"<mark style='background:#FFE58F;padding:0 2px'>{sq}</mark>")
    return f"<div style='white-space:pre-wrap;font-family:monospace;font-size:0.85rem'>{safe}</div>"


def kpi(col, label: str, value, caption: str, colour: str | None = None):
    with col.container(border=True):
        st.caption(label)
        st.markdown(f"<div style='font-size:2rem;font-weight:700;color:{colour or 'inherit'}'>{value}</div>", unsafe_allow_html=True)
        st.caption(caption)


# ---------- navigation (a worklist row click jumps to Patient 360) ----------
if "_goto_patient" in st.session_state:
    st.session_state["patient"] = st.session_state.pop("_goto_patient")
    st.session_state["page"] = "Patient 360"

st.sidebar.title("Forgotten Follow-ups")
st.sidebar.caption("Every recommended follow-up, tracked to done - with the source line as proof.")
page = st.sidebar.radio("Page", PAGES, key="page")
st.sidebar.caption("Built on Snowflake. Synthetic data only. Not a diagnostic tool.")
with st.sidebar.expander("Demo controls"):
    st.markdown(f"**Demo date:** {sim_date()}")
    new_date = st.date_input("Move demo clock to", value=pd.to_datetime(sim_date()))
    if st.button("Move clock and run overdue alert", width="stretch"):
        with st.spinner("Moving clock, refreshing loops, firing alert..."):
            run("CALL FFU.CTRL.ADVANCE_CLOCK(?, 'ALL')", [str(new_date)])
        st.rerun()
    if st.button("Refresh (process new reports)", width="stretch"):
        with st.spinner("Extracting new reports and refreshing loops..."):
            run("CALL FFU.CORE.PROCESS_NEW_REPORTS()")
        st.rerun()


# ---------- Worklist ----------
if page == "Worklist":
    st.header("Ranked worklist")
    st.caption("Red (overdue) and amber (done elsewhere, outside report needed). Most dangerous tier first, then priority, then days overdue. "
               "Click a row to open the patient.")
    wl = q("""SELECT rank, patient_id, finding_type, COALESCE(avg_mm || ' mm', aorta_cm || ' cm') AS size, tier, status,
                     days_overdue::INT AS days_overdue, ROUND(priority:score::FLOAT)::INT AS priority, clinician_acked, patient_notified, status_reason
              FROM FFU.CORE.WORKLIST ORDER BY rank LIMIT 300""")
    k1, k2, k3, k4 = st.columns(4)
    kpi(k1, "On worklist", len(wl), "Red and amber loops needing action")
    kpi(k2, "Red (overdue)", int((wl["status"] == "RED").sum()), "Due date passed, no correct test", "#B3261E")
    kpi(k3, "Amber (outside claim)", int((wl["status"] == "AMBER").sum()), "Done elsewhere, report requested", "#8A5300")
    kpi(k4, "Patient not told", int((~wl["patient_notified"].astype(bool)).sum()), "No notification on record", "#B3261E")
    f1, f2 = st.columns(2)
    types = f1.multiselect("Finding type", sorted(wl["finding_type"].unique()))
    tiers = f2.multiselect("Tier", sorted(wl["tier"].unique()))
    mask = pd.Series(True, index=wl.index)  # start from "keep all" so no filter selected keeps every row
    if types:
        mask &= wl["finding_type"].isin(types)
    if tiers:
        mask &= wl["tier"].isin(tiers)
    view = wl[mask].rename(columns={
        "rank": "Rank", "patient_id": "Patient", "finding_type": "Finding", "size": "Size", "tier": "Tier", "status": "Status",
        "days_overdue": "Days overdue", "priority": "Priority", "clinician_acked": "Clinician acked",
        "patient_notified": "Patient told", "status_reason": "Why"}).reset_index(drop=True)
    # Whole days; blank (not "None") for amber loops, which are not overdue.
    view["Days overdue"] = view["Days overdue"].map(lambda v: "" if pd.isna(v) else str(int(v)))
    event = st.dataframe(style_status(view), hide_index=True, width="stretch", on_select="rerun", selection_mode="single-row",
                         row_height=56, key="worklist",
                         column_config={"Priority": st.column_config.NumberColumn(format="%d"),
                                        "Days overdue": st.column_config.TextColumn(),
                                        "Why": st.column_config.TextColumn(width="large")})
    rows = event.selection.rows if event and hasattr(event, "selection") else []
    if rows:
        st.session_state["_goto_patient"] = view.loc[rows[0], "Patient"]
        st.rerun()

    # View as analyst: same loops through the role-aware secure view, read with the viewer's own role.
    st.divider()
    if st.toggle("View as analyst (masked, via caller's rights)"):
        if caller_conn is None:
            st.info("Caller's rights are only available when the app runs in Snowflake (container runtime).")
        else:
            role = caller_conn.query("SELECT CURRENT_ROLE() AS r", ttl=0).iloc[0, 0]
            st.caption(f"Reading FFU.SEC.LOOPS_V as your default role **{role}**. "
                       "Analyst and judge roles see hashed patient IDs and masked quotes; coordinators see only their clinics; admins see all.")
            masked = caller_conn.query("""SELECT patient_id AS "Patient", clinic_id AS "Clinic", finding_type AS "Finding", tier AS "Tier",
                                                 status AS "Status", days_overdue AS "Days overdue", age_band AS "Age band", quote AS "Quote",
                                                 status_reason AS "Why"
                                          FROM FFU.SEC.LOOPS_V WHERE status IN ('RED','AMBER') ORDER BY tier, priority_score DESC LIMIT 100""", ttl=0)
            st.dataframe(style_status(masked), hide_index=True, width="stretch")

    errs = q("SELECT report_id, patient_id, report_date, modality, error FROM FFU.CORE.EXTRACTION_ERRORS WHERE set_name NOT IN ('A','B')")
    if not errs.empty:
        st.warning(f"{len(errs)} report(s) could not be read by AI extraction and need a person to review them (never dropped silently).")
        st.dataframe(errs, hide_index=True, width="stretch")


# ---------- Patient 360 ----------
elif page == "Patient 360":
    st.header("Patient 360")
    pts = q("""SELECT s.patient_id, MIN(w.rank) AS best_rank
               FROM FFU.CORE.LOOP_STATUS s LEFT JOIN FFU.CORE.WORKLIST w ON w.patient_id = s.patient_id
               WHERE s.clinic_id <> 'EVAL' GROUP BY 1 ORDER BY best_rank NULLS LAST, 1""")
    options = pts["patient_id"].tolist()
    if st.session_state.get("patient") not in options and options:
        st.session_state["patient"] = options[0]  # default: worklist rank 1
    pid = st.selectbox("Patient (patients with follow-up loops, worklist rank 1 first)", options, key="patient")

    p = q("SELECT age, sex, smoking, known_cancer, immunosuppressed, screening_enrolled, tb_history, clinic_id FROM FFU.RAW.PATIENTS WHERE patient_id = ?", [pid])
    loops = q("SELECT * FROM FFU.CORE.LOOP_CARD WHERE patient_id = ? ORDER BY priority_score DESC", [pid])

    with st.container(border=True):
        st.subheader("Patient details")
        if not p.empty:
            r = p.iloc[0]
            flags = [n for n, v in [("known cancer", r["known_cancer"]), ("immunosuppressed", r["immunosuppressed"]),
                                    ("screening programme", r["screening_enrolled"]), ("TB history", r["tb_history"])] if v]
            c = st.columns(4)
            c[0].metric("Patient", pid)
            c[1].metric("Age / sex", f"{r['age']} / {r['sex']}")
            c[2].metric("Smoking", str(r["smoking"]).title())
            c[3].metric("Clinic", r["clinic_id"])
            st.caption("History flags: " + (", ".join(flags) if flags else "none"))

    st.subheader("Follow-up loops")
    if loops.empty:
        st.info("No follow-up loops for this patient.")
    for _, l in loops.iterrows():
        with st.container(border=True):
            st.markdown(f"**{html.escape(l['loop_id'])}** - {html.escape(str(l['finding_type']))} {html.escape(str(l['size']))} &nbsp; {chip(l['status'])}",
                        unsafe_allow_html=True)
            st.markdown(f"**Why:** {l['status_reason']}  \n**Due by:** {l['due_end']}  \n"
                        f"**Tier {l['tier']}**, priority **{l['priority_score']:.1f}** = {l['priority_breakdown']}  \n"
                        f"**Clinician acknowledged:** {l['clinician_acked']} - **Patient told:** {l['patient_notified']}")
            if l["qa_flag"]:
                st.warning(f"QA note for the radiologist (we never override): {l['qa_flag']}")
            if st.button("Audit this loop (recompute from raw rows)", key=f"audit-{l['loop_id']}"):
                a = q("CALL FFU.CORE.AUDIT_LOOP(?)", [l["loop_id"]])
                for _, ar in a.iterrows():
                    (st.success if ar["match"] else st.error)(
                        f"{'MATCH' if ar['match'] else 'MISMATCH'}: app says {ar['app_status']}, raw rows say {ar['audit_status']}")
                    st.caption(f"Rule: {ar['rule']}")
                    st.caption(f"Evidence: {ar['evidence']}")

    st.subheader("Timeline")
    tl = q("""
        SELECT report_date AS d, 'Report ' || report_id || ' (' || modality || ', ' || facility || ')' AS event, 'Hospital record' AS source, 'report' AS kind
          FROM FFU.RAW.REPORTS WHERE patient_id = ?
        UNION ALL SELECT ack_date, 'Clinician acknowledged ' || report_id, 'Hospital record', 'comm' FROM FFU.RAW.ACKS WHERE patient_id = ?
        UNION ALL SELECT notified_date, 'Patient notified by ' || channel, 'Hospital record', 'comm' FROM FFU.RAW.NOTIFICATIONS WHERE patient_id = ?
        UNION ALL SELECT order_date, 'Order CPT ' || cpt || ' (' || status || ')', 'Hospital record', 'order' FROM FFU.RAW.ORDERS WHERE patient_id = ?
        UNION ALL SELECT service_date, 'Claim ' || event_id || ': CPT ' || cpt || ' ' || cpt_desc || ' at ' || facility, 'Payer share', 'claim'
          FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS WHERE patient_id = ?
        UNION ALL SELECT requested_at::DATE, 'Outside report requested (' || claim || ')', 'App', 'request' FROM FFU.APP.OUTSIDE_REPORT_REQUESTS WHERE patient_id = ?
        UNION ALL SELECT next_due, 'Next surveillance check due', 'Rule', 'next' FROM FFU.CORE.NEXT_CHECKS WHERE patient_id = ?
        ORDER BY 1""", [pid] * 7)
    dot = {"report": "#0074D6", "comm": "#1E7B34", "order": "#455A64", "claim": "#8A5300", "request": "#8A5300", "next": "#6A3FA0"}
    items = "".join(
        f"<div style='display:flex;gap:12px;align-items:flex-start;margin:0 0 10px 0'>"
        f"<div style='min-width:92px;color:#546E7A;font-size:0.85rem'>{html.escape(str(r['d']))}</div>"
        f"<div style='width:12px;height:12px;border-radius:50%;background:{dot.get(r['kind'], '#455A64')};margin-top:4px'></div>"
        f"<div><div>{html.escape(str(r['event']))}</div><div style='color:#78909C;font-size:0.8rem'>{html.escape(str(r['source']))}</div></div></div>"
        for _, r in tl.iterrows())
    st.markdown(f"<div style='border-left:2px solid #CFD8DC;padding-left:12px'>{items or 'No events.'}</div>", unsafe_allow_html=True)

    st.subheader("Reports")
    rpts = q("""SELECT r.report_id, r.report_date, r.modality, r.facility, r.text,
                       (SELECT ANY_VALUE(quote) FROM FFU.CORE.LOOP_STATUS s WHERE s.report_id = r.report_id) AS quote
                FROM FFU.RAW.REPORTS r WHERE r.patient_id = ? ORDER BY r.report_date""", [pid])
    for _, r in rpts.iterrows():
        with st.expander(f"{r['report_id']} - {r['report_date']} - {r['modality']} - {r['facility']}", expanded=len(rpts) == 1):
            st.markdown(highlight(r["text"], r["quote"]), unsafe_allow_html=True)
            if isinstance(r["quote"], str) and r["quote"]:
                st.caption("Highlighted: the evidence quote used for the loop (checked word for word against this text).")

    c1, c2 = st.columns(2)
    with c1:
        st.subheader("Orders")
        st.dataframe(q("SELECT order_id, order_date, cpt, status FROM FFU.RAW.ORDERS WHERE patient_id = ? ORDER BY order_date", [pid]),
                     hide_index=True, width="stretch")
        st.subheader("Notifications and acknowledgements")
        st.dataframe(q("""SELECT notified_date AS event_date, 'Patient notified (' || channel || ')' AS event, report_id FROM FFU.RAW.NOTIFICATIONS WHERE patient_id = ?
                          UNION ALL SELECT ack_date, 'Clinician acknowledged (' || clinician_id || ')', report_id FROM FFU.RAW.ACKS WHERE patient_id = ?
                          ORDER BY 1""", [pid, pid]), hide_index=True, width="stretch")
    with c2:
        st.subheader("Payer claims (Secure Data Share)")
        st.dataframe(q("""SELECT event_id, service_date, cpt, cpt_desc, facility FROM PAYER_SHARE.SHARED.FOLLOWUP_EVENTS_FROM_CLAIMS
                          WHERE patient_id = ? ORDER BY service_date""", [pid]), hide_index=True, width="stretch")
        st.subheader("Letters and approvals")
        st.dataframe(q("""SELECT a.kind, a.status, a.created_at, a.approved_by, a.approved_at, a.loop_id FROM FFU.APP.APPROVALS a
                          JOIN FFU.CORE.LOOP_STATUS s ON s.loop_id = a.loop_id WHERE s.patient_id = ? ORDER BY a.created_at DESC""", [pid]),
                     hide_index=True, width="stretch")


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
        if col.button(ex, width="stretch"):
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
    st.subheader("Letters (drafts and approvals)")
    drafts = q("SELECT draft_id, loop_id, kind, status, created_at, approved_by, draft FROM FFU.APP.APPROVALS ORDER BY created_at DESC LIMIT 20")
    for _, d in drafts.iterrows():
        label = f"{d['kind']} for {d['loop_id']} - {d['status']}" + (f" by {d['approved_by']}" if d["approved_by"] else "")
        with st.expander(label):
            st.text(d["draft"])
            if d["status"] == "PENDING_CLINICIAN_APPROVAL":
                # Own form and key per draft: the approver name only ever comes from this box, never from the chat.
                with st.form(key=f"approve-{d['draft_id']}", clear_on_submit=True):
                    who = st.text_input("Clinician name (approver)", key=f"approver-{d['draft_id']}").strip()
                    if st.form_submit_button("Approve (logged)"):
                        asked = {m["content"].strip() for m in st.session_state.chat if m["role"] == "user"}
                        if not who or who in asked or len(who) > 80:
                            st.error("Enter the approving clinician's name.")
                        else:
                            run("CALL FFU.APP.APPROVE_DRAFT(?, ?)", [d["draft_id"], who])
                            st.rerun()


# ---------- Alerts ----------
elif page == "Alerts":
    st.header("Alerts")
    st.caption("Fired by the overdue Alert when a tier-1 loop goes red. Outside-report requests are created for amber loops.")
    st.subheader("Overdue alerts")
    st.dataframe(q("SELECT fired_at, sim_date, patient_id, loop_id, tier, message FROM FFU.APP.ALERTS ORDER BY fired_at DESC LIMIT 200"),
                 hide_index=True, width="stretch")
    st.subheader("Outside-report requests")
    st.dataframe(q("SELECT requested_at, patient_id, loop_id, claim, status FROM FFU.APP.OUTSIDE_REPORT_REQUESTS ORDER BY requested_at DESC LIMIT 200"),
                 hide_index=True, width="stretch")


# ---------- Results ----------
elif page == "Results":
    st.header("Results")
    st.caption("Ours vs a keyword rule vs AI alone. Set C: synthetic, hidden answer key. Set B: trap reports, labels written first. "
               "Set A: 120 real chest X-ray reports, hand-labelled (loop detection). Official Set C runs come only from the reset demo state.")
    comp = q("""
        SELECT set_name, method, n, correct, accuracy, false_greens, NULL::FLOAT AS recall FROM FFU.EVAL.BASELINE_SUMMARY
        UNION ALL SELECT 'A', method, n, correct, accuracy, fp, recall FROM FFU.EVAL.SETA_SUMMARY
        ORDER BY set_name, method""")
    comp["method"] = comp["method"].map({"SYSTEM": "Ours", "KEYWORD": "Keyword rule", "AI_ONLY": "AI only"}).fillna(comp["method"])
    comp["set"] = comp["set_name"].map({"A": "Set A (real, n=120)", "B": "Set B (traps, n=36)", "C": "Set C (synthetic)"})
    order = ["Ours", "Keyword rule", "AI only"]
    acc = alt.Chart(comp).mark_bar().encode(
        x=alt.X("method:N", sort=order, title=None), y=alt.Y("accuracy:Q", title="Accuracy", scale=alt.Scale(domain=[0, 1]), axis=alt.Axis(format="%")),
        color=alt.Color("method:N", sort=order, scale=alt.Scale(domain=order, range=["#0074D6", "#90A4AE", "#B0BEC5"]), legend=None),
        column=alt.Column("set:N", title=None), tooltip=["set", "method", "correct", "n", alt.Tooltip("accuracy:Q", format=".1%")]
    ).properties(width=170, height=220, title="Accuracy")
    fg = comp[comp["set_name"].isin(["B", "C"])]
    fgc = alt.Chart(fg).mark_bar(color="#D32F2F").encode(
        x=alt.X("method:N", sort=order, title=None), y=alt.Y("false_greens:Q", title="False greens (lower is safer)"),
        column=alt.Column("set:N", title=None), tooltip=["set", "method", "false_greens"]
    ).properties(width=170, height=220, title="False greens (wrongly marked done)")
    st.altair_chart(acc)
    st.altair_chart(fgc)
    table = comp.assign(**{"Accuracy": comp["accuracy"].map(lambda v: f"{v:.1%}"),
                           "Recall (Set A)": comp["recall"].map(lambda v: "" if pd.isna(v) else f"{v:.1%}")})
    st.dataframe(table[["set", "method", "correct", "n", "Accuracy", "false_greens", "Recall (Set A)"]].rename(
        columns={"set": "Set", "method": "Method", "correct": "Correct", "n": "N", "false_greens": "False greens / false alarms"}),
        hide_index=True, width="stretch")
    st.caption("Set A counts false alarms (loops opened that the label says are not needed); a false green cannot happen there because real reports have no follow-up events.")

    runs = q("""SELECT run_at, label, official, state_note, n, correct, accuracy, false_green, false_green_upper95,
                       missed_loops, quote_verified_rate FROM FFU.EVAL.RUNS ORDER BY run_at DESC LIMIT 50""")
    off = runs[runs["official"] == True]  # noqa: E712
    st.subheader("Latest official Set C run")
    if not off.empty:
        r = off.iloc[0]
        c1, c2, c3, c4 = st.columns(4)
        kpi(c1, "Loop-status accuracy", f"{r['accuracy']:.1%}", f"{r['correct']} of {r['n']} index reports")
        kpi(c2, "False greens", f"{int(r['false_green'])} of {r['n']}", f"95% upper bound {r['false_green_upper95']:.1%}",
            "#1E7B34" if int(r["false_green"]) == 0 else "#B3261E")
        kpi(c3, "Quotes verified", f"{r['quote_verified_rate'] * 100:.1f}%", "Word for word against the source")
        kpi(c4, "Missed loops", int(r["missed_loops"]), "Shown in the extraction review queue")
        st.dataframe(off, hide_index=True, width="stretch")
    with st.expander("All eval runs (including unofficial)"):
        st.dataframe(runs, hide_index=True, width="stretch")
    st.subheader("Loop status mix")
    st.bar_chart(q("SELECT status, COUNT(*) AS loops FROM FFU.CORE.LOOP_STATUS GROUP BY 1 ORDER BY 1"), x="status", y="loops")

    st.subheader("Payer-side context: imaging volume (Marketplace)")
    st.caption("From the Snowflake Marketplace listing 'Synthetic Healthcare Data - Clinical and Claims' (synthetic population). "
               "Context only: not used by the pipeline or the eval.")
    try:
        mkt = q("SELECT modality_description AS modality, studies, patients FROM FFU.APP.MKT_IMAGING_VOLUME ORDER BY studies DESC", ttl=3600)
        st.altair_chart(alt.Chart(mkt).mark_bar(color="#0074D6").encode(
            x=alt.X("studies:Q", title="Imaging studies"), y=alt.Y("modality:N", sort="-x", title=None),
            tooltip=["modality", "studies", "patients"]).properties(height=180))
    except Exception:
        st.info("Marketplace context view is not available in this account.")


# ---------- ROI calculator ----------
elif page == "ROI calculator":
    st.header("ROI calculator")
    st.caption("Every input is editable. Sources are shown next to each default; values marked ASSUMPTION are not "
               "from a publication and should be replaced with your own numbers. Outputs are estimates, not results.")
    sim = q("SELECT with_recall_completion_simulated AS sim FROM FFU.EVAL.SIMULATED_IMPACT")
    sim_rate = float(sim["sim"].iloc[0]) if not sim.empty else 0.74
    c1, c2 = st.columns(2)
    cts = c1.number_input("Chest CTs per year", min_value=0, value=20000, step=1000,
                          help="ASSUMPTION: example volume for a mid-size hospital. Replace with your own.")
    rate = c1.number_input("Share of chest CTs with an actionable finding (%)", 0.0, 100.0, 31.0, 1.0,
                           help="ASSUMPTION, editable: example rate, not from a verified source. Replace with your own audit figure.") / 100
    base = c2.number_input("Baseline completion of recommended follow-up (%)", 0.0, 100.0, 37.0, 1.0,
                           help="Nodule Net, Respiratory Medicine 2022: 442 of 1,202 (37%) completed before a tracking programme.") / 100
    achieved = c2.number_input("Achieved completion with tracking (%)", 0.0, 100.0, round(sim_rate * 100, 1), 1.0,
                               help="Default = this project's SIMULATED rate on synthetic data. Published reference: Nodule Net 74% after tracking; "
                                    "East Alabama Medical Center 39% to 68%.") / 100
    price = st.number_input("Average reimbursement per completed follow-up exam (USD)", min_value=0, value=250, step=25,
                            help="ASSUMPTION: replace with your payer mix. Reference point: East Alabama Medical Center reported "
                                 "about $9,000 a month in added revenue after adopting tracking (HCInnovation Group).")
    findings = cts * rate
    recovered = max(findings * (achieved - base), 0)
    m1, m2, m3 = st.columns(3)
    kpi(m1, "Actionable findings per year", f"{findings:,.0f}", "CTs x finding rate")
    kpi(m2, "Follow-ups recovered per year", f"{recovered:,.0f}", "Patients no longer lost", "#1E7B34")
    kpi(m3, "Estimated recovered revenue per year", f"${recovered * price:,.0f}", "Recovered x reimbursement")
    st.caption(f"Recovered = findings x (achieved - baseline) = {findings:,.0f} x ({achieved:.0%} - {base:.0%}). "
               "Staff time: East Alabama reported tracking work fell from about 5 hours a week to 15 minutes.")
