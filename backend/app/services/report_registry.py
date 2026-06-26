# -*- coding: utf-8 -*-
"""
Maps each report_definitions.key (migration 004) to the columns/rows it
actually produces. Four of the fifteen seeded report keys are KPI cards
already served by /api/dashboard/evm, not downloadable tables - they
are deliberately excluded here rather than faked with a one-row table.

daily/weekly/monthly progress reports are unified into one query
parameterized by date range, rather than three near-identical copies -
the frontend supplies the range; "daily" is just a single-day range.

Each entry returns (columns: list[str], rows: list[list[str]]) - all
values pre-formatted as display strings, since formatting rules differ
per column and are easier to get right once here than to push into a
generic formatter.
"""


def _progress_report(user_client, project_id, date_from, date_to):
    result = (
        user_client.table("progress_reports")
        .select("date, measured_quantity, notes, boq_items(description, unit), profiles(name)")
        .eq("project_id", project_id)
        .gte("date", date_from)
        .lte("date", date_to)
        .order("date")
        .execute()
    )
    columns = ["Date", "Work item", "Measured quantity", "Unit", "Coordinator", "Notes"]
    rows = []
    for r in result.data:
        boq = r.get("boq_items") or {}
        profile = r.get("profiles") or {}
        rows.append([
            str(r["date"]), boq.get("description", ""), f"{r['measured_quantity']:,.2f}",
            boq.get("unit", ""), profile.get("name", ""), r.get("notes") or "",
        ])
    return columns, rows


def _boq_completion(user_client, project_id):
    result = user_client.table("v_evm_by_boq_item").select("*").eq("project_id", project_id).execute()
    columns = ["Work item", "Budgeted quantity", "Measured quantity", "% of estimate", "Rate", "Budgeted cost"]
    rows = []
    for r in result.data:
        pct = (r["cumulative_measured_quantity"] / r["budgeted_quantity"] * 100) if r["budgeted_quantity"] else 0
        rows.append([
            r["description"], f"{r['budgeted_quantity']:,.2f}", f"{r['cumulative_measured_quantity']:,.2f}",
            f"{pct:.1f}%", f"{r['rate']:,.2f}", f"{r['original_budgeted_cost']:,.2f}",
        ])
    return columns, rows


def _master_roll_report(user_client, project_id, date_from, date_to):
    result = (
        user_client.table("master_roll_entries")
        .select("date, is_no_work_day, no_work_remarks, profiles(name), master_roll_attendance(present, labourers(name, id_number))")
        .eq("project_id", project_id)
        .gte("date", date_from)
        .lte("date", date_to)
        .order("date")
        .execute()
    )
    columns = ["Date", "Coordinator", "Worker", "ID number", "Present", "Notes"]
    rows = []
    for entry in result.data:
        coordinator = (entry.get("profiles") or {}).get("name", "")
        if entry.get("is_no_work_day"):
            rows.append([str(entry["date"]), coordinator, "", "", "", entry.get("no_work_remarks") or "No work day"])
            continue
        for att in entry.get("master_roll_attendance", []):
            labourer = att.get("labourers") or {}
            rows.append([
                str(entry["date"]), coordinator, labourer.get("name", ""),
                labourer.get("id_number", ""), "Yes" if att.get("present") else "No", "",
            ])
    return columns, rows


def _advance_register(user_client, project_id):
    result = (
        user_client.table("advance_requisitions")
        .select("created_at, advance_category, amount, justification, status, profiles(name)")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
    )
    columns = ["Date", "Requested by", "Category", "Amount", "Justification", "Status"]
    rows = [
        [
            str(r["created_at"])[:10], (r.get("profiles") or {}).get("name", ""), r["advance_category"],
            f"{r['amount']:,.2f}", r["justification"], r["status"],
        ]
        for r in result.data
    ]
    return columns, rows


def _settlement_register(user_client, project_id):
    result = (
        user_client.table("advance_settlements")
        .select("created_at, settled_amount, status, profiles(name), advance_requisitions(justification, amount)")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
    )
    columns = ["Date", "Submitted by", "Against advance", "Advance amount", "Settled amount", "Status"]
    rows = []
    for r in result.data:
        adv = r.get("advance_requisitions") or {}
        rows.append([
            str(r["created_at"])[:10], (r.get("profiles") or {}).get("name", ""), adv.get("justification", ""),
            f"{adv.get('amount', 0):,.2f}", f"{r['settled_amount']:,.2f}", r["status"],
        ])
    return columns, rows


def _cashbook_report(user_client, project_id):
    # BUG (caught via the same class of error as the ledger_report fix
    # below): fund_receipts' timestamp column is received_at, not
    # created_at like every other table this module queries - assumed
    # from pattern-matching the other tables rather than checking this
    # specific one's actual schema.
    result = (
        user_client.table("fund_receipts")
        .select("received_at, amount, source, profiles(name)")
        .eq("project_id", project_id)
        .order("received_at", desc=True)
        .execute()
    )
    columns = ["Date", "Type", "Source / Description", "Recorded by", "Amount"]
    rows = [
        [
            str(r["received_at"])[:10], "Receipt", r.get("source") or "",
            (r.get("profiles") or {}).get("name", ""), f"{r['amount']:,.2f}",
        ]
        for r in result.data
    ]
    return columns, rows


def _labour_advance_ledger(user_client, project_id):
    result = (
        user_client.table("advance_requisitions")
        .select("created_at, amount, status, subcontracts(team_lead_name)")
        .eq("project_id", project_id)
        .eq("advance_category", "subcontract")
        .order("created_at", desc=True)
        .execute()
    )
    columns = ["Date", "Subcontract team", "Amount drawn", "Status"]
    rows = [
        [
            str(r["created_at"])[:10], (r.get("subcontracts") or {}).get("team_lead_name", ""),
            f"{r['amount']:,.2f}", r["status"],
        ]
        for r in result.data
    ]
    return columns, rows


# Maps report_definitions.key -> a callable producing (columns, rows).
# Date-range reports take date_from/date_to as positional args after
# project_id; others only take project_id. NEEDS_DATE_RANGE tells the
# endpoint (and the frontend) which is which, rather than guessing from
# the function signature.
def _labour_productivity_report(user_client, project_id, date_from, date_to):
    """
    Honest scope note: the schema attributes measured quantity to a BOQ
    item per day (progress_reports), not to individual workers - there
    is no data linking "worker X produced Y quantity" at the per-person
    level (master_roll_attendance only records presence/absence, not
    output). This report is therefore necessarily team-level: workers
    present that day vs. total quantity measured that day, project-wide -
    not a per-worker breakdown, since faking individual attribution from
    data that doesn't support it would be actively misleading rather
    than just incomplete.
    """
    attendance_result = (
        user_client.table("master_roll_entries")
        .select("date, master_roll_attendance(present)")
        .eq("project_id", project_id)
        .gte("date", date_from)
        .lte("date", date_to)
        .execute()
    )
    workers_by_date = {}
    for entry in attendance_result.data:
        present_count = sum(1 for a in entry.get("master_roll_attendance", []) if a.get("present"))
        workers_by_date[entry["date"]] = workers_by_date.get(entry["date"], 0) + present_count

    progress_result = (
        user_client.table("v_progress_effective")
        .select("date, effective_quantity")
        .eq("project_id", project_id)
        .gte("date", date_from)
        .lte("date", date_to)
        .execute()
    )
    quantity_by_date = {}
    for r in progress_result.data:
        quantity_by_date[r["date"]] = quantity_by_date.get(r["date"], 0) + r["effective_quantity"]

    all_dates = sorted(set(workers_by_date) | set(quantity_by_date))
    columns = ["Date", "Workers present", "Total measured quantity (all items)", "Output per worker"]
    rows = []
    for d in all_dates:
        workers = workers_by_date.get(d, 0)
        quantity = quantity_by_date.get(d, 0)
        ratio = f"{(quantity / workers):.2f}" if workers else "N/A (no attendance recorded)"
        rows.append([str(d), str(workers), f"{quantity:,.2f}", ratio])
    return columns, rows


def _ledger_report(user_client, project_id):
    """
    Combines fund receipts, advances, and settlements into one
    chronological feed - per its name, "Ledger Report (combined)".
    """
    rows = []

    receipts = (
        user_client.table("fund_receipts")
        .select("received_at, amount, source")
        .eq("project_id", project_id)
        .execute()
    )
    for r in receipts.data:
        rows.append([str(r["received_at"])[:10], "Fund receipt", r.get("source") or "", f"+{r['amount']:,.2f}"])

    advances = (
        user_client.table("advance_requisitions")
        .select("created_at, justification, amount, status")
        .eq("project_id", project_id)
        .execute()
    )
    for a in advances.data:
        sign = "-" if a["status"] == "disbursed" else "(pending)"
        rows.append([str(a["created_at"])[:10], "Advance", a["justification"], f"{sign}{a['amount']:,.2f}"])

    settlements = (
        user_client.table("advance_settlements")
        .select("created_at, settled_amount, status, advance_requisitions(justification)")
        .eq("project_id", project_id)
        .execute()
    )
    for s in settlements.data:
        desc = (s.get("advance_requisitions") or {}).get("justification", "")
        rows.append([str(s["created_at"])[:10], "Settlement", f"Settling: {desc}", f"{s['settled_amount']:,.2f}"])

    rows.sort(key=lambda r: r[0])
    columns = ["Date", "Type", "Description", "Amount"]
    return columns, rows


def _project_financial_report(user_client, project_id):
    """
    A SUMMARY, not a transaction list - one labeled metric per row,
    pulling from the EVM view (migration 006) and cashbook. Framed as
    a 2-column "Metric / Value" table so the existing generic table
    renderer (frontend + report_pdf.py) still applies without needing
    a separate, second rendering path just for this one report.
    """
    evm_result = user_client.table("v_evm_by_project").select("*").eq("project_id", project_id).execute()
    evm = evm_result.data[0] if evm_result.data else {}

    receipts = user_client.table("fund_receipts").select("amount").eq("project_id", project_id).execute()
    total_received = sum(r["amount"] for r in receipts.data)

    disbursed = (
        user_client.table("advance_requisitions")
        .select("amount")
        .eq("project_id", project_id)
        .eq("status", "disbursed")
        .execute()
    )
    total_disbursed = sum(a["amount"] for a in disbursed.data)
    cash_balance = total_received - total_disbursed

    columns = ["Metric", "Value"]
    rows = [
        ["Total budgeted cost", f"{evm.get('total_budgeted_cost', 0):,.2f}"],
        ["Planned value (to date)", f"{evm.get('total_planned_value', 0):,.2f}"],
        ["Earned value (to date)", f"{evm.get('total_earned_value', 0):,.2f}"],
        ["Actual cost (to date)", f"{evm.get('total_actual_cost', 0):,.2f}"],
        ["Cost variance", f"{evm.get('cost_variance', 0):,.2f}"],
        ["Schedule variance", f"{evm.get('schedule_variance', 0):,.2f}"],
        ["Physical progress", f"{evm.get('physical_progress_pct', 0):.1f}%"],
        ["Financial progress", f"{evm.get('financial_progress_pct', 0):.1f}%"],
        ["Total fund received", f"{total_received:,.2f}"],
        ["Total disbursed", f"{total_disbursed:,.2f}"],
        ["Current cash balance", f"{cash_balance:,.2f}"],
    ]
    return columns, rows


REPORT_REGISTRY = {
    "daily_progress_report": _progress_report,
    "weekly_progress_report": _progress_report,
    "monthly_progress_report": _progress_report,
    "boq_completion": _boq_completion,
    "master_roll_report": _master_roll_report,
    "advance_register": _advance_register,
    "settlement_register": _settlement_register,
    "cashbook_report": _cashbook_report,
    "labour_advance_ledger": _labour_advance_ledger,
    "labour_productivity_report": _labour_productivity_report,
    "ledger_report": _ledger_report,
    "project_financial_report": _project_financial_report,
}

NEEDS_DATE_RANGE = {
    "daily_progress_report", "weekly_progress_report", "monthly_progress_report",
    "master_roll_report", "labour_productivity_report",
}

REPORT_TITLES = {
    "daily_progress_report": "Daily Progress Report",
    "weekly_progress_report": "Weekly Progress Report",
    "monthly_progress_report": "Monthly Progress Report",
    "boq_completion": "BOQ Completion Report",
    "master_roll_report": "Master Roll Report",
    "advance_register": "Advance Register",
    "settlement_register": "Settlement Register",
    "cashbook_report": "Cashbook Report",
    "labour_advance_ledger": "Labour Advance Ledger",
    "labour_productivity_report": "Labour Productivity Report",
    "ledger_report": "Ledger Report (Combined)",
    "project_financial_report": "Project Financial Report",
}
