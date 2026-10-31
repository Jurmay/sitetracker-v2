# -*- coding: utf-8 -*-
"""
Cross-tenant RLS verification test for SiteTracker v2.

Run AFTER seed.py. Logs in as each seeded user (using their own anon-key
session, NOT the service role key - this is the whole point, since the
service role bypasses RLS entirely and would prove nothing) and asserts:

  1. Each user can see their OWN company/project's data.
  2. Each user can NEVER see the OTHER company's data, in any table.
  3. Role-appropriate restrictions hold within their own project
     (e.g. Site Coordinator cannot see another coordinator's locked
     financial detail, Viewer without grant cannot see boq_items).

This requires SUPABASE_ANON_KEY (the public anon key, not service role)
since we are testing as authenticated end users, not as an admin.

Usage:
    export SUPABASE_URL="https://xxxx.supabase.co"
    export SUPABASE_ANON_KEY="..."
    python3 test_rls.py
"""

import os
import sys
import httpx
from supabase import create_client, Client

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
TEST_PASSWORD = "Seed-Test-Pass-2026!"

if not SUPABASE_URL or not SUPABASE_ANON_KEY:
    print("ERROR: set SUPABASE_URL and SUPABASE_ANON_KEY environment variables first.")
    sys.exit(1)

PASS = []
FAIL = []


def check(label, condition):
    if condition:
        PASS.append(label)
        print(f"  PASS  {label}")
    else:
        FAIL.append(label)
        print(f"  FAIL  {label}")


def login_as(email: str) -> Client:
    client = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    client.auth.sign_in_with_password({"email": email, "password": TEST_PASSWORD})
    return client


def get_project_id(client: Client, company_slug: str) -> str:
    """Fetch a project_id this user can see, matching the company slug's demo project name."""
    res = client.table("projects").select("id,name").execute()
    for row in res.data:
        if company_slug.lower() in row["name"].lower():
            return row["id"]
    return None


def run_cross_tenant_checks(slug: str, other_slug: str, role: str):
    email = f"{slug}.{role}@seedtest.local"
    print(f"\n--- Testing as {email} ---")
    client = login_as(email)

    own_project_id = get_project_id(client, slug)
    check(f"{role}@{slug}: can see own project", own_project_id is not None)

    # NOTE (fixed after first run): 'projects' has no project_id column - its
    # own primary key is 'id'. 'boq_items' has no direct project_id column
    # either - it only reaches its project indirectly via section_id ->
    # boq_sections.project_id. Both were incorrectly included in the original
    # flat project_id check below; handled separately further down instead.
    tables_to_check = [
        "boq_sections", "advance_requisitions",
        "advance_settlements", "progress_reports", "master_roll_entries",
        "labourers", "subcontracts", "fund_receipts", "fund_requisitions",
        "ledger_heads", "leave_periods", "zones",
        "purchase_orders", "goods_receipts",
    ]

    for table in tables_to_check:
        try:
            res = client.table(table).select("project_id").execute()
            leaked = [r for r in res.data if r.get("project_id") and r["project_id"] != own_project_id]
            check(f"{role}@{slug}: zero leaked rows in '{table}'", len(leaked) == 0)
        except Exception as e:
            # A clean permission error is fine; only a successful leak is a failure
            print(f"    ({table} raised: {e})")

    # projects: check by its own primary key 'id', not a project_id column
    try:
        res = client.table("projects").select("id").execute()
        leaked = [r for r in res.data if r["id"] != own_project_id]
        check(f"{role}@{slug}: zero leaked rows in 'projects'", len(leaked) == 0)
    except Exception as e:
        print(f"    (projects raised: {e})")

    # boq_items: reach project via section_id -> boq_sections.project_id, joined client-side
    try:
        sections_res = client.table("boq_sections").select("id,project_id").execute()
        own_section_ids = {s["id"] for s in sections_res.data if s["project_id"] == own_project_id}
        items_res = client.table("boq_items").select("id,section_id").execute()
        leaked = [r for r in items_res.data if r["section_id"] not in own_section_ids]
        check(f"{role}@{slug}: zero leaked rows in 'boq_items'", len(leaked) == 0)
    except Exception as e:
        print(f"    (boq_items raised: {e})")


def run_within_tenant_role_checks():
    print("\n--- Within-tenant role restriction checks (Alpha only) ---")

    # Viewer without financial grant should NOT see boq_items at all
    viewer = login_as("alpha.viewer@seedtest.local")
    res = viewer.table("boq_items").select("id").execute()
    check("alpha.viewer (no grant): cannot see boq_items", len(res.data) == 0)

    # Site Coordinator should see their own master_roll_entries
    coord = login_as("alpha.coordinator@seedtest.local")
    res = coord.table("master_roll_entries").select("id").execute()
    check("alpha.coordinator: can see own master_roll_entries", len(res.data) > 0)

    # Site Coordinator should NOT be able to verify their own advance requisition
    # (i.e. should not be able to insert a 'verified' action - only cashier can).
    # Create a FRESH pending requisition for this check specifically, rather than
    # reusing seed.py's advance (which is already pushed to 'disbursed' - testing
    # against that would fail for the wrong reason: bad status, not bad permission).
    boq_res = coord.table("boq_items").select("id").limit(1).execute()
    proj_id = get_project_id(coord, "alpha")
    if boq_res.data and proj_id:
        # FIX (caught on first run): this insert was missing requested_by,
        # which ar_insert_self's RLS policy requires to equal auth.uid().
        # Without it, requested_by was null, and "null = auth.uid()" is
        # null (not true) in SQL, so RLS correctly denied the insert - this
        # was a bug in this test script, not in the schema/policy itself.
        coord_user_id = coord.auth.get_user().user.id
        fresh_adv = coord.table("advance_requisitions").insert({
            "project_id": proj_id,
            "requested_by": coord_user_id,
            "advance_category": "work_tied",
            "boq_item_id": boq_res.data[0]["id"],
            "amount": 1000,
            "justification": "RLS test - self-verify attempt",
        }).execute()
        if fresh_adv.data:
            fresh_adv_id = fresh_adv.data[0]["id"]
            try:
                coord.table("advance_requisition_actions").insert({
                    "requisition_id": fresh_adv_id, "action_type": "verified",
                }).execute()
                check("alpha.coordinator: blocked from self-verifying an advance", False)
            except Exception:
                check("alpha.coordinator: blocked from self-verifying an advance", True)
        else:
            check("alpha.coordinator: blocked from self-verifying an advance (could not create test row)", False)

    # Cashier should see ALL advance requisitions in their project, not just ones
    # they personally touched - this is the specific SVL bug pattern check.
    cashier = login_as("alpha.cashier@seedtest.local")
    res = cashier.table("advance_requisitions").select("id").execute()
    check("alpha.cashier: can see all advance requisitions in project (not just own)", len(res.data) >= 1)


# The reporting views run with their owner's rights, so table RLS doesn't
# protect them - each view filters by project membership itself (migration
# 20261024122329). These checks catch a view that loses that filter.
VIEWS_WITH_PROJECT_ID = [
    "v_evm_by_project", "v_evm_by_boq_item", "v_cashbook_running_balance",
    "v_progress_effective", "v_subcontract_balances", "v_schedule_by_boq_item",
    "v_purchase_orders", "v_purchase_order_lines",
]
ALL_VIEWS = VIEWS_WITH_PROJECT_ID + ["v_actual_cost_by_boq_item", "v_portfolio_summary"]


def run_view_checks(slug: str, role: str):
    email = f"{slug}.{role}@seedtest.local"
    print(f"\n--- View checks as {email} ---")
    client = login_as(email)
    own_project_id = get_project_id(client, slug)

    for view in VIEWS_WITH_PROJECT_ID:
        res = client.table(view).select("project_id").execute()
        leaked = [r for r in res.data if r["project_id"] != own_project_id]
        check(f"{role}@{slug}: zero leaked rows in '{view}'", len(leaked) == 0)

    try:
        res = client.table("v_progress_effective").update({"status": "certified"}).eq(
            "project_id", own_project_id).execute()
        check(f"{role}@{slug}: cannot write through v_progress_effective", len(res.data) == 0)
    except Exception:
        check(f"{role}@{slug}: cannot write through v_progress_effective", True)


def run_portfolio_checks(slug: str, role: str):
    """The all-sites owner dashboard: owners and admins see their own sites only;
    every other role sees nothing."""
    client = login_as(f"{slug}.{role}@seedtest.local")
    own_project_id = get_project_id(client, slug)
    rows = client.table("v_portfolio_summary").select("project_id").execute().data
    if role in ("owner", "admin"):
        check(f"{role}@{slug}: portfolio shows exactly own site",
              [r["project_id"] for r in rows] == [own_project_id])
    else:
        check(f"{role}@{slug}: portfolio is empty for this role", len(rows) == 0)


def run_schedule_checks():
    """Schedule follows boq_items visibility, and only admins/owners set planned dates."""
    print("\n--- Schedule ---")
    viewer = login_as("alpha.viewer@seedtest.local")
    rows = viewer.table("v_schedule_by_boq_item").select("boq_item_id").execute().data
    check("alpha.viewer (no grant): schedule is empty", len(rows) == 0)

    admin = login_as("alpha.admin@seedtest.local")
    rows = admin.table("v_schedule_by_boq_item").select("boq_item_id,schedule_status,pct_complete").execute().data
    check("alpha.admin: sees the seeded BOQ item on the schedule", len(rows) >= 1)
    item_id = rows[0]["boq_item_id"] if rows else None
    check("alpha.admin: Brickwork is 24% done (120 of 500)", bool(rows) and float(rows[0]["pct_complete"]) == 24.0)

    if item_id:
        coord = login_as("alpha.coordinator@seedtest.local")
        res = coord.table("boq_items").update({"planned_end": "2099-01-01"}).eq("id", item_id).execute()
        check("alpha.coordinator: cannot change planned dates", len(res.data) == 0)

        beta_admin = login_as("beta.admin@seedtest.local")
        res = beta_admin.table("boq_items").update({"planned_end": "2099-01-01"}).eq("id", item_id).execute()
        check("beta.admin: cannot change alpha's planned dates", len(res.data) == 0)

        res = admin.table("boq_items").update({"planned_end": "2099-01-01"}).eq("id", item_id).execute()
        check("alpha.admin: can change planned dates", len(res.data) == 1)


def _raises(fn, needle=""):
    try:
        fn()
        return False
    except Exception as e:
        return needle.lower() in str(e).lower()


def run_purchasing_checks():
    """Suppliers, POs and deliveries: who can do what, and the delivery limits."""
    print("\n--- Purchasing ---")
    admin = login_as("alpha.admin@seedtest.local")
    coord = login_as("alpha.coordinator@seedtest.local")
    project_id = get_project_id(admin, "alpha")

    for slug in ["alpha", "beta"]:
        other = "beta" if slug == "alpha" else "alpha"
        client = login_as(f"{slug}.admin@seedtest.local")
        names = [s["name"] for s in client.table("suppliers").select("name").execute().data]
        check(f"{slug}.admin: sees no supplier of {other}", all(other.lower() not in n.lower() for n in names))

    viewer = login_as("alpha.viewer@seedtest.local")
    check("alpha.viewer (no grant): sees no purchase orders",
          len(viewer.table("v_purchase_orders").select("po_id").execute().data) == 0)
    check("alpha.cashier: sees the purchase order",
          len(login_as("alpha.cashier@seedtest.local").table("v_purchase_orders").select("po_id").execute().data) == 1)

    po = coord.table("v_purchase_orders").select("po_id,status").execute().data
    check("alpha.coordinator: sees the issued purchase order", len(po) == 1 and po[0]["status"] == "issued")
    po_id = po[0]["po_id"] if po else None
    line = coord.table("v_purchase_order_lines").select("po_line_id").eq("po_id", po_id).execute().data if po_id else []
    line_id = line[0]["po_line_id"] if line else None
    supplier_id = admin.table("suppliers").select("id").execute().data[0]["id"]

    check("alpha.coordinator: cannot create a purchase order", _raises(lambda: coord.rpc("fn_create_purchase_order", {
        "p_project_id": project_id, "p_supplier_id": supplier_id,
        "p_lines": [{"description": "x", "unit": "u", "quantity": 1, "rate": 1}]}).execute()))
    res = coord.table("purchase_orders").update({"status": "cancelled"}).eq("id", po_id).execute()
    check("alpha.coordinator: cannot cancel a purchase order", len(res.data) == 0)

    beta_admin = login_as("beta.admin@seedtest.local")
    beta_project = get_project_id(beta_admin, "beta")
    check("beta.admin: cannot order from alpha's supplier", _raises(lambda: beta_admin.rpc("fn_create_purchase_order", {
        "p_project_id": beta_project, "p_supplier_id": supplier_id,
        "p_lines": [{"description": "x", "unit": "u", "quantity": 1, "rate": 1}]}).execute(), "supplier list"))
    check("beta.admin: cannot record a delivery on alpha's PO", _raises(lambda: beta_admin.rpc("fn_record_goods_receipt", {
        "p_po_id": po_id, "p_lines": [{"po_line_id": line_id, "quantity_received": 1}]}).execute(), "not found"))

    coord.rpc("fn_record_goods_receipt", {
        "p_po_id": po_id, "p_delivery_note_no": "DN-1",
        "p_lines": [{"po_line_id": line_id, "quantity_received": 120, "quantity_rejected": 5}]}).execute()
    status = coord.table("v_purchase_orders").select("status,pct_received").eq("po_id", po_id).execute().data[0]
    check("alpha.coordinator: delivery of 120/200 -> partially_received, 60%",
          status["status"] == "partially_received" and float(status["pct_received"]) == 60.0)
    check("alpha.coordinator: delivering more than ordered is refused", _raises(lambda: coord.rpc("fn_record_goods_receipt", {
        "p_po_id": po_id, "p_lines": [{"po_line_id": line_id, "quantity_received": 81}]}).execute(), "exceed"))
    check("alpha.admin: cannot cancel once goods are received", _raises(
        lambda: admin.table("purchase_orders").update({"status": "cancelled"}).eq("id", po_id).execute(), "cannot go from"))

    new_po = admin.rpc("fn_create_purchase_order", {
        "p_project_id": project_id, "p_supplier_id": supplier_id,
        "p_lines": [{"description": "Sand", "unit": "cum", "quantity": 10, "rate": 1800}]}).execute().data
    numbered = admin.table("purchase_orders").select("po_number,status").eq("id", new_po).execute().data[0]
    check("alpha.admin: new PO is a draft numbered PO-0002",
          numbered["po_number"] == "PO-0002" and numbered["status"] == "draft")
    admin.table("purchase_orders").update({"status": "issued"}).eq("id", new_po).execute()
    check("alpha.admin: lines are locked once the PO is issued", _raises(
        lambda: admin.table("purchase_order_lines").update({"quantity": 99}).eq("po_id", new_po).execute(), "draft"))


def run_project_creation_checks():
    """Only a Company Owner creates projects (from a won tender's BOQ), always in their own company."""
    print("\n--- Creating a project from a BOQ ---")
    boq = [{"name": "BOQ 01", "items": [
        {"description": "Excavation", "unit": "cum", "quantity": 100, "rate": 127.42},
        {"description": "OHS measures", "unit": "LS", "quantity": 1, "rate": 0}]}]
    args = {"p_name": "Imported tender job", "p_sections": boq, "p_tender_ref": "NIT-TEST-1"}

    owner = login_as("alpha.owner@seedtest.local")
    check("alpha.owner: may create projects", owner.rpc("fn_can_create_project", {}).execute().data is True)
    new_id = owner.rpc("fn_create_project_from_boq", args).execute().data
    project = owner.table("projects").select("name,total_budget,tender_ref").eq("id", new_id).execute().data
    check("alpha.owner: new project has budget = BOQ total and the NIT",
          len(project) == 1 and float(project[0]["total_budget"]) == 12742.0 and project[0]["tender_ref"] == "NIT-TEST-1")
    items = owner.table("v_schedule_by_boq_item").select("boq_item_id").eq("project_id", new_id).execute().data
    check("alpha.owner: both BOQ lines are on the new project's schedule", len(items) == 2)

    for who in ["alpha.admin", "alpha.coordinator", "alpha.cashier", "alpha.viewer"]:
        client = login_as(f"{who}@seedtest.local")
        check(f"{who}: cannot create projects", _raises(lambda: client.rpc("fn_create_project_from_boq", args).execute()))
        check(f"{who}: does not see the new project",
              len(client.table("projects").select("id").eq("id", new_id).execute().data) == 0)

    beta_owner = login_as("beta.owner@seedtest.local")
    check("beta.owner: does not see alpha's new project",
          len(beta_owner.table("projects").select("id").eq("id", new_id).execute().data) == 0
          and len(beta_owner.table("boq_sections").select("id").eq("project_id", new_id).execute().data) == 0)

    anon = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    check("anon: cannot create projects", _raises(lambda: anon.rpc("fn_create_project_from_boq", args).execute()))


def run_offline_resend_checks():
    """A progress report sent twice from a phone (same client_ref) is stored once."""
    print("\n--- Resent offline submissions ---")
    import uuid
    coord = login_as("alpha.coordinator@seedtest.local")
    project_id = get_project_id(coord, "alpha")
    item = coord.table("boq_items").select("id").limit(1).execute().data[0]["id"]
    ref = str(uuid.uuid4())
    row = {"project_id": project_id, "boq_item_id": item, "coordinator_id": coord.auth.get_user().user.id,
           "date": "2026-10-25", "measured_quantity": 130, "client_ref": ref}
    coord.table("progress_reports").insert(row).execute()
    check("alpha.coordinator: the same submission can't be stored twice",
          _raises(lambda: coord.table("progress_reports").insert(row).execute(), "client_ref"))
    check("alpha.coordinator: exactly one report with that client_ref",
          len(coord.table("progress_reports").select("id").eq("client_ref", ref).execute().data) == 1)


def run_billing_checks():
    """Client running bills: who can bill, certify and record payments, and the money rules."""
    print("\n--- Client running bills ---")
    admin = login_as("alpha.admin@seedtest.local")
    cashier = login_as("alpha.cashier@seedtest.local")
    coord = login_as("alpha.coordinator@seedtest.local")
    viewer = login_as("alpha.viewer@seedtest.local")
    beta_admin = login_as("beta.admin@seedtest.local")
    project_id = get_project_id(admin, "alpha")

    check("alpha.coordinator: cannot start a bill", _raises(
        lambda: coord.rpc("fn_create_client_bill", {"p_project_id": project_id}).execute()))
    check("alpha.cashier: cannot start a bill", _raises(
        lambda: cashier.rpc("fn_create_client_bill", {"p_project_id": project_id}).execute()))
    check("beta.admin: cannot bill on alpha's project", _raises(
        lambda: beta_admin.rpc("fn_create_client_bill", {"p_project_id": project_id}).execute()))

    bill_id = admin.rpc("fn_create_client_bill", {"p_project_id": project_id}).execute().data
    bill = admin.table("v_client_bills").select("*").eq("bill_id", bill_id).execute().data[0]
    gross = float(bill["gross_amount"])
    check("alpha.admin: RA-01 prefilled from measured brickwork, draft",
          bill["bill_ref"] == "RA-01" and bill["status"] == "draft" and gross > 0)
    check("alpha.admin: default terms applied (retention 10%, TDS 2%)",
          float(bill["retention_amount"]) == round(gross * 0.10, 2) and float(bill["tds_amount"]) == round(gross * 0.02, 2)
          and float(bill["net_amount"]) == round(gross * 0.88, 2))
    check("alpha.admin: billing beyond the BOQ quantity is refused", _raises(
        lambda: admin.table("client_bill_lines").update({"quantity": 501}).eq("bill_id", bill_id).execute(),
        "more than the boq quantity"))

    admin.table("client_bills").update({"status": "submitted"}).eq("id", bill_id).execute()
    check("alpha.admin: lines are locked once submitted", _raises(
        lambda: admin.table("client_bill_lines").update({"quantity": 1}).eq("bill_id", bill_id).execute(), "draft"))
    check("alpha.cashier: cannot certify a bill",
          len(cashier.table("client_bills").update({"status": "certified", "certified_amount": 1})
              .eq("id", bill_id).execute().data) == 0)
    admin.table("client_bills").update({"status": "certified", "certified_amount": float(bill["net_amount"])}) \
        .eq("id", bill_id).execute()

    check("beta.admin: cannot record a payment on alpha's bill", _raises(
        lambda: beta_admin.table("client_bill_payments").insert({
            "bill_id": bill_id, "project_id": project_id, "amount": 1,
            "recorded_by": beta_admin.auth.get_user().user.id}).execute()))
    me = cashier.auth.get_user().user.id
    check("alpha.cashier: paying more than certified is refused", _raises(
        lambda: cashier.table("client_bill_payments").insert({
            "bill_id": bill_id, "project_id": project_id, "amount": float(bill["net_amount"]) + 1,
            "recorded_by": me}).execute(), "more than the certified"))
    cashier.table("client_bill_payments").insert({
        "bill_id": bill_id, "project_id": project_id, "amount": float(bill["net_amount"]), "recorded_by": me}).execute()
    paid = cashier.table("v_client_bills").select("status,balance_due").eq("bill_id", bill_id).execute().data[0]
    check("alpha.cashier: full payment marks the bill paid", paid["status"] == "paid" and float(paid["balance_due"]) == 0)

    check("alpha.coordinator: sees no bills", len(coord.table("v_client_bills").select("bill_id").execute().data) == 0)
    check("alpha.viewer (no grant): sees no bills", len(viewer.table("v_client_bills").select("bill_id").execute().data) == 0)
    check("beta.admin: sees no alpha bills or payments",
          len(beta_admin.table("client_bills").select("id").execute().data) == 0
          and len(beta_admin.table("client_bill_payments").select("id").execute().data) == 0)
    row = admin.table("v_portfolio_summary").select("client_billed,client_received,client_receivable") \
        .eq("project_id", project_id).execute().data[0]
    check("alpha.admin: all-sites dashboard shows billed and received",
          float(row["client_billed"]) == gross and float(row["client_received"]) == float(bill["net_amount"])
          and float(row["client_receivable"]) == 0)


def run_admin_people_checks():
    """Role changes: owner role guarded, same company only, last owner kept; People list for managers only."""
    print("\n--- Admin: people and roles ---")
    admin = login_as("alpha.admin@seedtest.local")
    owner = login_as("alpha.owner@seedtest.local")
    coord = login_as("alpha.coordinator@seedtest.local")
    beta_admin = login_as("beta.admin@seedtest.local")
    project_id = get_project_id(admin, "alpha")
    admin_id = admin.auth.get_user().user.id
    owner_id = owner.auth.get_user().user.id
    beta_id = beta_admin.auth.get_user().user.id

    check("alpha.admin: cannot make themselves Company Owner", _raises(
        lambda: admin.table("project_roles").insert({"project_id": project_id, "user_id": admin_id,
                                                     "role": "company_owner", "assigned_by": admin_id}).execute(),
        "only a company owner"))
    check("alpha.admin: cannot switch off the Company Owner", _raises(
        lambda: admin.table("project_roles").update({"status": "disabled"})
        .eq("project_id", project_id).eq("user_id", owner_id).eq("role", "company_owner").execute(),
        "only a company owner"))
    check("alpha.admin: cannot give beta's admin a role on alpha's project", _raises(
        lambda: admin.table("project_roles").insert({"project_id": project_id, "user_id": beta_id,
                                                     "role": "viewer", "assigned_by": admin_id}).execute(),
        "not part of this company"))
    check("alpha.owner: cannot switch off the last Company Owner (self)", _raises(
        lambda: owner.table("project_roles").update({"status": "disabled"})
        .eq("project_id", project_id).eq("user_id", owner_id).eq("role", "company_owner").execute(),
        "at least one active company owner"))

    people = admin.rpc("fn_project_members", {"p_project_id": project_id}).execute().data
    check("alpha.admin: People list shows alpha's people only",
          len(people) > 0 and all("beta" not in (p["email"] or "") for p in people))
    check("alpha.coordinator: cannot see the People list", _raises(
        lambda: coord.rpc("fn_project_members", {"p_project_id": project_id}).execute(), "only an admin"))
    check("beta.admin: cannot see alpha's People list or activity", _raises(
        lambda: beta_admin.rpc("fn_project_members", {"p_project_id": project_id}).execute(), "only an admin")
        and _raises(lambda: beta_admin.rpc("fn_project_activity", {"p_project_id": project_id}).execute(), "only an admin"))
    check("alpha.admin: can read the activity log",
          isinstance(admin.rpc("fn_project_activity", {"p_project_id": project_id, "p_limit": 5}).execute().data, list))


def run_anonymous_checks():
    print("\n--- Not logged in (public anon key only) ---")
    anon = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)

    for name in ["projects", "advance_requisitions", "fund_receipts", "suppliers", "purchase_orders",
                 "purchase_order_lines", "goods_receipts", "goods_receipt_lines", "client_bills",
                 "client_bill_lines", "client_bill_deductions", "client_bill_payments", "v_client_bills"] + ALL_VIEWS:
        try:
            res = anon.table(name).select("*").execute()
            check(f"anon: reads zero rows from '{name}'", len(res.data) == 0)
        except Exception:
            check(f"anon: reads zero rows from '{name}'", True)

    try:
        res = anon.table("v_progress_effective").update({"status": "certified"}).neq(
            "status", "x").execute()
        check("anon: cannot write through v_progress_effective", len(res.data) == 0)
    except Exception:
        check("anon: cannot write through v_progress_effective", True)


def run_receipt_checks():
    print("\n--- Settlement receipt storage ---")
    bucket = "settlement-receipts"
    alpha_project = get_project_id(login_as("alpha.admin@seedtest.local"), "alpha")
    path = f"{alpha_project}/seed-receipt.jpg"

    names = [f["name"] for f in login_as("alpha.cashier@seedtest.local").storage.from_(bucket).list(alpha_project)]
    check("alpha.cashier: can see own project's receipt", "seed-receipt.jpg" in names)

    for who in ["beta.owner", "beta.admin", "beta.cashier", "alpha.coordinator"]:
        client = login_as(f"{who}@seedtest.local")
        names = [f["name"] for f in client.storage.from_(bucket).list(alpha_project)]
        check(f"{who}: cannot list alpha's receipts", "seed-receipt.jpg" not in names)
        try:
            client.storage.from_(bucket).create_signed_url(path, 60)
            check(f"{who}: cannot open alpha's receipt", False)
        except Exception:
            check(f"{who}: cannot open alpha's receipt", True)

    anon = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    names = [f["name"] for f in anon.storage.from_(bucket).list(alpha_project)]
    check("anon: cannot list receipts", "seed-receipt.jpg" not in names)

    public = httpx.get(f"{SUPABASE_URL}/storage/v1/object/public/{bucket}/{path}")
    check("receipts bucket is private (public link refused)", public.status_code != 200)

    beta_coord = login_as("beta.coordinator@seedtest.local")
    try:
        beta_coord.storage.from_(bucket).upload(f"{alpha_project}/intruder.jpg", b"\xff\xd8\xff\xd9",
                                                {"content-type": "image/jpeg"})
        check("beta.coordinator: cannot upload into alpha's receipts", False)
    except Exception:
        check("beta.coordinator: cannot upload into alpha's receipts", True)


if __name__ == "__main__":
    print("========================================")
    print("Cross-tenant RLS verification")
    print("========================================")

    for role in ["owner", "admin", "coordinator", "cashier", "viewer"]:
        run_cross_tenant_checks("alpha", "beta", role)
        run_cross_tenant_checks("beta", "alpha", role)

    run_within_tenant_role_checks()

    for role in ["owner", "admin", "coordinator", "cashier", "viewer"]:
        run_view_checks("alpha", role)
        run_view_checks("beta", role)
        run_portfolio_checks("alpha", role)
        run_portfolio_checks("beta", role)

    run_schedule_checks()
    run_purchasing_checks()
    run_project_creation_checks()
    run_offline_resend_checks()
    run_billing_checks()
    run_admin_people_checks()
    run_anonymous_checks()
    run_receipt_checks()

    print("\n========================================")
    print(f"RESULTS: {len(PASS)} passed, {len(FAIL)} failed")
    print("========================================")
    if FAIL:
        print("\nFAILED CHECKS:")
        for f in FAIL:
            print(" -", f)
        sys.exit(1)
    else:
        print("\nAll checks passed.")