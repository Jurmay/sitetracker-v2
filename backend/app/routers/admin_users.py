# -*- coding: utf-8 -*-
"""
Admin user management: assign a role to an existing profile, or invite
a brand-new user by email (which creates their Supabase Auth account
server-side, since client-side code never holds the service role key).

CRITICAL SAFETY NOTE: every endpoint here re-checks the CALLER's own
role via their own RLS-scoped client BEFORE touching the service-role
client for anything. The service role bypasses RLS entirely - without
this explicit re-check, ANY authenticated caller could hit this router
and grant themselves Admin on an arbitrary project. The check here is
the only thing standing between "authenticated user" and "can create
users/grant roles" for this router - RLS on project_roles does NOT
protect these endpoints, since the service-role client ignores RLS.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, EmailStr

from app.core.deps import get_current_user, CurrentUser, get_service_db

router = APIRouter()

VALID_ROLES = {"company_owner", "admin", "site_coordinator", "cashier", "viewer"}


def _require_admin_or_owner(user: CurrentUser, project_id: str):
    """
    Re-checks the caller's own role via THEIR OWN RLS-scoped client
    (not the service client) - this query can only ever return rows
    the caller is genuinely allowed to see, so its result is trustworthy
    proof of the caller's real role, unlike trusting a client-supplied
    role field.
    """
    result = (
        user.client.table("project_roles")
        .select("role")
        .eq("project_id", project_id)
        .eq("user_id", user.id)
        .eq("status", "active")
        .in_("role", ["admin", "company_owner"])
        .execute()
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Only an Admin or Company Owner can manage users on this project.")


class AssignRolePayload(BaseModel):
    project_id: str
    email: EmailStr
    role: str


class InviteUserPayload(BaseModel):
    project_id: str
    email: EmailStr
    name: str
    role: str


class ResetPasswordPayload(BaseModel):
    project_id: str
    email: EmailStr


@router.post("/assign-role")
def assign_role(payload: AssignRolePayload, user: CurrentUser = Depends(get_current_user)):
    """
    Grants a role to a user who ALREADY has a profile (an existing
    Supabase Auth account). Looked up by email since that's what an
    Admin would realistically have on hand, not a raw user_id.
    """
    if payload.role not in VALID_ROLES:
        raise HTTPException(status_code=422, detail=f"Invalid role. Must be one of: {', '.join(sorted(VALID_ROLES))}")
    _require_admin_or_owner(user, payload.project_id)

    service_db = get_service_db()
    profile = service_db.table("profiles").select("id").eq("email", payload.email).execute()
    if not profile.data:
        raise HTTPException(
            status_code=404,
            detail=f"No existing account found for {payload.email}. Use 'Invite new user' instead.",
        )

    target_user_id = profile.data[0]["id"]
    result = (
        service_db.table("project_roles")
        .upsert(
            {
                "project_id": payload.project_id,
                "user_id": target_user_id,
                "role": payload.role,
                "status": "active",
                "assigned_by": user.id,
            },
            on_conflict="project_id,user_id,role",
        )
        .execute()
    )
    return result.data[0] if result.data else {"status": "assigned"}


@router.post("/invite")
def invite_user(payload: InviteUserPayload, user: CurrentUser = Depends(get_current_user)):
    """
    Creates a brand-new Supabase Auth user and immediately assigns them
    the given role. Uses the Admin API's invite flow (rather than
    create_user with a random password) so the new person receives a
    real email to set their own password.
    """
    if payload.role not in VALID_ROLES:
        raise HTTPException(status_code=422, detail=f"Invalid role. Must be one of: {', '.join(sorted(VALID_ROLES))}")
    _require_admin_or_owner(user, payload.project_id)

    service_db = get_service_db()

    existing = service_db.table("profiles").select("id").eq("email", payload.email).execute()
    if existing.data:
        raise HTTPException(
            status_code=409,
            detail=f"{payload.email} already has an account. Use 'Assign role' instead.",
        )

    try:
        invite_response = service_db.auth.admin.invite_user_by_email(
            payload.email, {"data": {"name": payload.name}}
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Failed to send invite email: {e}")

    new_user_id = invite_response.user.id

    company = service_db.table("projects").select("company_id").eq("id", payload.project_id).execute()
    if not company.data:
        raise HTTPException(status_code=404, detail="Project not found.")

    service_db.table("profiles").insert({
        "id": new_user_id,
        "company_id": company.data[0]["company_id"],
        "name": payload.name,
        "email": payload.email,
    }).execute()

    result = (
        service_db.table("project_roles")
        .insert({
            "project_id": payload.project_id,
            "user_id": new_user_id,
            "role": payload.role,
            "status": "active",
            "assigned_by": user.id,
        })
        .execute()
    )
    return result.data[0] if result.data else {"status": "invited"}


@router.post("/reset-password")
def reset_password(payload: ResetPasswordPayload, user: CurrentUser = Depends(get_current_user)):
    """
    Triggers Supabase's own password-recovery email for an EXISTING
    user - the same flow as clicking "Send password recovery" in the
    Supabase Studio dashboard. Deliberately does NOT set a password
    directly: an admin choosing (and knowing) another person's password
    is worse practice than letting that person set their own via a
    time-limited link, and this way there's no plaintext password ever
    passed through this API or shown in this UI.

    project_id is required only to prove the caller is an admin/owner
    ON THAT PROJECT - it is not otherwise used, since password reset is
    a property of the Supabase Auth account, not of any one project.
    """
    _require_admin_or_owner(user, payload.project_id)

    service_db = get_service_db()

    profile = service_db.table("profiles").select("id").eq("email", payload.email).execute()
    if not profile.data:
        raise HTTPException(
            status_code=404,
            detail=f"No existing account found for {payload.email}. Use 'Invite new user' instead.",
        )

    try:
        service_db.auth.reset_password_for_email(payload.email)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Failed to send reset email: {e}")

    return {"status": "reset_email_sent", "email": payload.email}
