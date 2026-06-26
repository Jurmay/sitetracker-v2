# -*- coding: utf-8 -*-
"""
Seed script for SiteTracker v2 RLS testing.

Builds TWO separate fake companies (Alpha Construction, Beta Builders),
each with a full project, full role set, and enough real transactional
data (advances, settlements, progress, master roll) to exercise actual
workflows - not just empty tables.

The entire point of having two companies is to test the cross-tenant
boundary directly: after seeding, a user from Alpha must NEVER be able
to see a single row belonging to Beta, and vice versa.

Usage:
    export SUPABASE_URL="https://xxxx.supabase.co"
    export SUPABASE_SERVICE_ROLE_KEY="..."
    python3 seed.py

Idempotent: safe to re-run. Checks for existing auth users by email
before creating, and uses fixed, readable slugs for everything else
so re-running doesn't create duplicate companies/projects.
"""

import os
import sys
from datetime import date, timedelta
from supabase import create_client, Client

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
    print("ERROR: set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY environment variables first.")
    sys.exit(1)

sb: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

TEST_PASSWORD = "Seed-Test-Pass-2026!"  # test-only credential, not for real use


def get_or_create_auth_user(email: str, name: str) -> str:
    """Returns the auth user's UUID, creating it via the admin API if needed.
    Paginates through list_users() since it returns results in pages and
    a naive single-call lookup would silently miss users once the project
    has more auth users than one page holds, risking duplicate creation."""
    page = 1
    while True:
        batch = sb.auth.admin.list_users(page=page, per_page=200)
        if not batch:
            break
        for u in batch:
            if u.email == email:
                return u.id
        if len(batch) < 200:
            break
        page += 1

    created = sb.auth.admin.create_user({
        "email": email,
        "password": TEST_PASSWORD,
        "email_confirm": True,
        "user_metadata": {"name": name},
    })
    return created.user.id


def upsert_row(table: str, match: dict, data: dict) -> dict:
    """Find a row matching `match`; insert with `data` if absent. Returns the row."""
    q = sb.table(table).select("*")
    for k, v in match.items():
        q = q.eq(k, v)
    existing = q.execute().data
    if existing:
        return existing[0]
    full = {**match, **data}
    result = sb.table(table).insert(full).execute()
    return result.data[0]


def seed_company(slug: str, company_name: str, currency: str):
    print(f"\n=== Seeding company: {company_name} ===")

    company = upsert_row("companies", {"name": company_name}, {"currency": currency})
    company_id = company["id"]
    print("Company ID:", company_id)

    # --- Users (one of each role) ---
    users = {}
    for role_key, label in [
        ("owner", "Company Owner"),
        ("admin", "Project Admin"),
        ("coordinator", "Site Coordinator"),
        ("cashier", "Cashier"),
        ("viewer", "Client Viewer"),
    ]:
        email = f"{slug}.{role_key}@seedtest.local"
        name = f"{company_name} {label}"
        auth_id = get_or_create_auth_user(email, name)
        upsert_row("profiles", {"id": auth_id}, {
            "company_id": company_id, "name": name, "email": email,
        })
        users[role_key] = auth_id
        print(f"  {label}: {email} -> {auth_id}")

    # --- Project ---
    project = upsert_row("projects", {"company_id": company_id, "name": f"{company_name} - Demo Project"}, {
        "location": "Test Site",
        "start_date": str(date.today() - timedelta(days=60)),
        "target_end_date": str(date.today() + timedelta(days=120)),
        "total_budget": 1_000_000,
        "currency": currency,
        "status": "active",
    })
    project_id = project["id"]
    print("Project ID:", project_id)

    # --- Roles ---
    for role_key, role_name in [
        ("owner", "company_owner"), ("admin", "admin"),
        ("coordinator", "site_coordinator"), ("cashier", "cashier"), ("viewer", "viewer"),
    ]:
        upsert_row("project_roles", {
            "project_id": project_id, "user_id": users[role_key], "role": role_name,
        }, {"status": "active", "assigned_by": users["owner"]})

    # --- BOQ ---
    section = upsert_row("boq_sections", {"project_id": project_id, "name": "Civil Works"}, {"sort_order": 1})
    boq_item = upsert_row("boq_items", {"section_id": section["id"], "description": "Brickwork"}, {
        "unit": "sqm", "quantity": 500, "rate": 450,
        "planned_start": str(date.today() - timedelta(days=30)),
        "planned_end": str(date.today() + timedelta(days=60)),
    })
    boq_item_id = boq_item["id"]

    # --- Ledger head ---
    ledger_head = upsert_row("ledger_heads", {"project_id": project_id, "name": "Material Purchase"}, {})

    # --- Fund receipt (so cashbook isn't stuck at zero) ---
    upsert_row("fund_receipts", {"project_id": project_id, "amount": 300_000, "source": "head_office"}, {
        "recorded_by": users["admin"],
    })

    # --- Labourer (with photo + ID, per the revised registry design) ---
    labourer = upsert_row("labourers", {"project_id": project_id, "name": f"{company_name} Test Mason"}, {
        "photo_url": "https://placehold.co/200x200?text=Worker",
        "id_number": f"{slug.upper()}-ID-0001",
        "labour_type": "contract",
        "contracted_rate": 800,
        "created_by": users["admin"],
    })

    # --- Master roll entry (today) ---
    mre = upsert_row("master_roll_entries", {
        "project_id": project_id, "coordinator_id": users["coordinator"], "date": str(date.today()),
    }, {"is_no_work_day": False})
    upsert_row("master_roll_attendance", {"entry_id": mre["id"], "labourer_id": labourer["id"]}, {"present": True})

    # --- Progress report ---
    upsert_row("progress_reports", {
        "project_id": project_id, "boq_item_id": boq_item_id,
        "coordinator_id": users["coordinator"], "date": str(date.today()),
    }, {"measured_quantity": 120})

    # --- Advance requisition: work-tied, through full lifecycle ---
    adv = upsert_row("advance_requisitions", {
        "project_id": project_id, "requested_by": users["coordinator"],
        "advance_category": "work_tied", "boq_item_id": boq_item_id,
    }, {
        "ledger_head_id": ledger_head["id"], "amount": 25_000,
        "justification": "Cement purchase for brickwork",
    })
    adv_id = adv["id"]

    # Only push through the workflow if it's still pending (idempotency guard)
    if adv["status"] == "pending_verification":
        sb.table("advance_requisition_actions").insert({
            "requisition_id": adv_id, "action_by": users["cashier"], "action_type": "verified",
        }).execute()
        sb.table("advance_requisition_actions").insert({
            "requisition_id": adv_id, "action_by": users["admin"], "action_type": "approved",
        }).execute()
        sb.table("advance_requisition_actions").insert({
            "requisition_id": adv_id, "action_by": users["cashier"], "action_type": "disbursed",
        }).execute()
        print("  Advance requisition pushed through full verify->approve->disburse workflow")

    # --- Settlement against that advance (partial) ---
    settlement = upsert_row("advance_settlements", {
        "requisition_id": adv_id, "project_id": project_id, "submitted_by": users["coordinator"],
    }, {"settled_amount": 18_000})
    if settlement["status"] == "pending_verification":
        sb.table("advance_settlement_actions").insert({
            "settlement_id": settlement["id"], "action_by": users["cashier"], "action_type": "verified",
        }).execute()
        print("  Settlement verified (partial, Nu 18,000 of Nu 25,000)")

    print(f"=== {company_name} seeding complete ===")
    return {
        "company_id": company_id,
        "project_id": project_id,
        "users": users,
        "boq_item_id": boq_item_id,
    }


if __name__ == "__main__":
    alpha = seed_company("alpha", "Alpha Construction Pvt Ltd", "BTN")
    beta = seed_company("beta", "Beta Builders Inc", "BTN")

    print("\n\n========================================")
    print("SEED COMPLETE - summary for RLS testing")
    print("========================================")
    print(f"Test password for all seeded users: {TEST_PASSWORD}")
    print("\nAlpha Construction:")
    for role, uid in alpha["users"].items():
        print(f"  {role}: alpha.{role}@seedtest.local  (uid: {uid})")
    print(f"  project_id: {alpha['project_id']}")
    print("\nBeta Builders:")
    for role, uid in beta["users"].items():
        print(f"  {role}: beta.{role}@seedtest.local  (uid: {uid})")
    print(f"  project_id: {beta['project_id']}")
    print("\nNext: log in as each Alpha user and confirm NONE of them can read")
    print("any row scoped to Beta's project_id, and vice versa.")