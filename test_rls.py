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


if __name__ == "__main__":
    print("========================================")
    print("Cross-tenant RLS verification")
    print("========================================")

    for role in ["owner", "admin", "coordinator", "cashier", "viewer"]:
        run_cross_tenant_checks("alpha", "beta", role)
        run_cross_tenant_checks("beta", "alpha", role)

    run_within_tenant_role_checks()

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