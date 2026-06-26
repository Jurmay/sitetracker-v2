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
    result = (
        user_client.table("fund_receipts")
        .select("created_at, amount, source, profiles(name)")
        .eq("project_id", project_id)
        .order("created_at", desc=True)
        .execute()
    )
    columns = ["Date", "Type", "Source / Description", "Recorded by", "Amount"]
    rows = [
        [
            str(r["created_at"])[:10], "Receipt", r.get("source") or "",
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
}

NEEDS_DATE_RANGE = {"daily_progress_report", "weekly_progress_report", "monthly_progress_report", "master_roll_report"}

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
}
