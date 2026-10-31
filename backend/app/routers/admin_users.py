# -*- coding: utf-8 -*-
"""
People on a project: list, add, invite, change roles, switch roles off,
resend invites, password reset emails, and the activity log.

Every change to project_roles goes through the CALLER's own RLS-scoped
client, so the database rules (migration 20261030000000) apply to it:
same company only, only an Owner can grant or remove the Owner role,
every project keeps an active Owner. The service-role client (which
bypasses RLS) is used only for what Supabase Auth itself requires: the
invite email, the reset email, creating the new person's profile, and
undoing a half-finished invite.

Lookups by email go through the caller's client too, so they only ever
find people in the caller's own company.
"""
import os
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr, Field

from app.core.deps import get_current_user, CurrentUser, get_service_db
from app.core.db_helpers import execute_with_rules

router = APIRouter()

VALID_ROLES = {"company_owner", "admin", "site_coordinator", "cashier", "viewer"}
MANAGERS_ONLY = "Only an Admin or Company Owner can manage people on this project."


def _require_admin_or_owner(user: CurrentUser, project_id: str):
    """The caller's own role, read through their own RLS-scoped client."""
    result = user.client.rpc("fn_can_manage_people", {"p_project_id": project_id}).execute()
    if not result.data:
        raise HTTPException(status_code=403, detail=MANAGERS_ONLY)


def _is_owner(user: CurrentUser, project_id: str) -> bool:
    return bool(user.client.rpc("fn_is_company_owner_of_project", {"p_project_id": project_id}).execute().data)


def _check_role(user: CurrentUser, project_id: str, role: str):
    if role not in VALID_ROLES:
        raise HTTPException(status_code=422, detail=f"Invalid role. Must be one of: {', '.join(sorted(VALID_ROLES))}")
    if role == "company_owner" and not _is_owner(user, project_id):
        raise HTTPException(status_code=403, detail="Only a Company Owner can make someone a Company Owner.")


def _company_profile(user: CurrentUser, email: str) -> Optional[dict]:
    """A profile in the caller's own company (RLS: profiles_select_same_company)."""
    # Case-insensitive exact match: escape LIKE wildcards ("_" is common in emails).
    pattern = email.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    found = user.client.table("profiles").select("id, name, email").ilike("email", pattern).execute().data
    return found[0] if found else None


def _app_url(request: Request) -> Optional[str]:
    """Where invite and reset links should land: the app the request came from, if it's an allowed origin."""
    origin = request.headers.get("origin")
    allowed = [o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o.strip() and o.strip() != "*"]
    if origin and (origin in allowed or not allowed):
        return origin
    return allowed[0] if allowed else None


def _set_role(user: CurrentUser, project_id: str, user_id: str, role: str, active: bool) -> dict:
    """Adds or re-enables (active) or switches off a role, as the caller."""
    existing = (
        user.client.table("project_roles").select("id, status")
        .eq("project_id", project_id).eq("user_id", user_id).eq("role", role).execute().data
    )
    status = "active" if active else "disabled"
    if existing:
        result = execute_with_rules(
            user.client.table("project_roles").update({"status": status, "assigned_by": user.id}).eq("id", existing[0]["id"]),
            on_denied=MANAGERS_ONLY,
        )
    elif active:
        result = execute_with_rules(
            user.client.table("project_roles").insert({
                "project_id": project_id, "user_id": user_id, "role": role,
                "status": "active", "assigned_by": user.id,
            }),
            on_denied=MANAGERS_ONLY,
        )
    else:
        raise HTTPException(status_code=404, detail="That person doesn't have this role on the project.")
    if not result.data:
        raise HTTPException(status_code=403, detail=MANAGERS_ONLY)
    return result.data[0]


# ----------------------------------------------------------------
# People list
# ----------------------------------------------------------------

@router.get("/members")
def list_members(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """Everyone in the company, their roles on this project, invite status and last sign-in."""
    result = execute_with_rules(
        user.client.rpc("fn_project_members", {"p_project_id": project_id}), on_denied=MANAGERS_ONLY,
    )
    return {"members": result.data, "can_grant_owner": _is_owner(user, project_id)}


class AssignRolePayload(BaseModel):
    project_id: str
    email: EmailStr
    role: str


class RoleStatusPayload(BaseModel):
    project_id: str
    user_id: str
    role: str
    active: bool


@router.post("/assign-role")
def assign_role(payload: AssignRolePayload, user: CurrentUser = Depends(get_current_user)):
    """Gives (or gives back) a role to someone who already has an account in this company."""
    _require_admin_or_owner(user, payload.project_id)
    _check_role(user, payload.project_id, payload.role)
    profile = _company_profile(user, payload.email)
    if not profile:
        raise HTTPException(
            status_code=404,
            detail=f"No one in your company has an account with {payload.email}. Use 'Invite a new person' instead.",
        )
    return _set_role(user, payload.project_id, profile["id"], payload.role, True)


@router.post("/role-status")
def set_role_status(payload: RoleStatusPayload, user: CurrentUser = Depends(get_current_user)):
    """Switches one of a person's roles on or off. Off removes that access; the history is kept."""
    _require_admin_or_owner(user, payload.project_id)
    _check_role(user, payload.project_id, payload.role)
    if not payload.active and payload.user_id == user.id and payload.role in ("admin", "company_owner"):
        raise HTTPException(status_code=400, detail="You can't remove your own Admin or Owner access. Ask another Owner.")
    return _set_role(user, payload.project_id, payload.user_id, payload.role, payload.active)


# ----------------------------------------------------------------
# Invites and password reset emails
# ----------------------------------------------------------------

class InviteUserPayload(BaseModel):
    project_id: str
    email: EmailStr
    name: str = Field(min_length=1)
    role: str


class MemberPayload(BaseModel):
    project_id: str
    user_id: str


class ResetPasswordPayload(BaseModel):
    project_id: str
    email: EmailStr


@router.post("/invite")
def invite_user(payload: InviteUserPayload, request: Request, user: CurrentUser = Depends(get_current_user)):
    """
    Creates the person's account, profile and role, and emails them a link
    to set their password. All or nothing: if any step after the account is
    created fails, the account is removed again so the invite can be retried.
    """
    _require_admin_or_owner(user, payload.project_id)
    _check_role(user, payload.project_id, payload.role)
    if _company_profile(user, payload.email):
        raise HTTPException(status_code=409, detail=f"{payload.email} already has an account. Use 'Add someone from your company' instead.")

    project = user.client.table("projects").select("company_id").eq("id", payload.project_id).execute().data
    if not project:
        raise HTTPException(status_code=404, detail="Project not found.")

    service_db = get_service_db()
    options = {"data": {"name": payload.name.strip()}}
    if _app_url(request):
        options["redirect_to"] = _app_url(request)
    try:
        invited = service_db.auth.admin.invite_user_by_email(str(payload.email), options)
    except Exception as e:
        if "already" in str(e).lower():
            raise HTTPException(status_code=409, detail=f"{payload.email} can't be invited: it is already registered with SiteTracker.")
        raise HTTPException(status_code=502, detail=f"Could not send the invite email: {e}")
    new_user_id = invited.user.id

    try:
        service_db.table("profiles").insert({
            "id": new_user_id, "company_id": project[0]["company_id"],
            "name": payload.name.strip(), "email": str(payload.email),
        }).execute()
        role = _set_role(user, payload.project_id, new_user_id, payload.role, True)
    except Exception as e:
        try:
            service_db.auth.admin.delete_user(new_user_id)  # profile and roles go with it
        except Exception:
            pass
        if isinstance(e, HTTPException):
            raise
        raise HTTPException(status_code=500, detail=f"The invite could not be completed and was undone: {e}")
    return {"status": "invited", "user_id": new_user_id, "role": role}


@router.post("/resend-invite")
def resend_invite(payload: MemberPayload, request: Request, user: CurrentUser = Depends(get_current_user)):
    """Sends the set-your-password email again to someone who has never signed in."""
    _require_admin_or_owner(user, payload.project_id)
    members = user.client.rpc("fn_project_members", {"p_project_id": payload.project_id}).execute().data
    member = next((m for m in members if m["user_id"] == payload.user_id), None)
    if not member:
        raise HTTPException(status_code=404, detail="That person is not in your company.")
    if not member["invite_pending"]:
        raise HTTPException(status_code=409, detail="They have already signed in. Use 'Send password reset' instead.")

    service_db = get_service_db()
    redirect = _app_url(request)
    try:
        service_db.auth.admin.invite_user_by_email(member["email"], {"redirect_to": redirect} if redirect else None)
    except Exception:
        # Supabase won't re-invite some unconfirmed accounts; a recovery link also lets them set a password.
        try:
            service_db.auth.reset_password_for_email(member["email"], {"redirect_to": redirect} if redirect else None)
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"Could not resend the invite: {e}")
    return {"status": "invite_resent", "email": member["email"]}


@router.post("/reset-password")
def reset_password(payload: ResetPasswordPayload, request: Request, user: CurrentUser = Depends(get_current_user)):
    """
    Emails a time-limited link to set a new password. The admin never sets
    or sees the password. Only for people in the admin's own company.
    """
    _require_admin_or_owner(user, payload.project_id)
    profile = _company_profile(user, payload.email)
    if not profile:
        raise HTTPException(status_code=404, detail=f"No one in your company has an account with {payload.email}.")
    redirect = _app_url(request)
    try:
        get_service_db().auth.reset_password_for_email(profile["email"], {"redirect_to": redirect} if redirect else None)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Could not send the reset email: {e}")
    return {"status": "reset_email_sent", "email": profile["email"]}


# ----------------------------------------------------------------
# Lookup (report permissions) and activity
# ----------------------------------------------------------------

class LookupPayload(BaseModel):
    project_id: str
    email: EmailStr


@router.post("/lookup")
def lookup_user(payload: LookupPayload, user: CurrentUser = Depends(get_current_user)):
    """A person in the caller's company and their active roles on this project."""
    _require_admin_or_owner(user, payload.project_id)
    profile = _company_profile(user, payload.email)
    if not profile:
        raise HTTPException(status_code=404, detail=f"No one in your company has an account with {payload.email}.")
    roles = [
        r["role"] for r in user.client.table("project_roles").select("role")
        .eq("project_id", payload.project_id).eq("user_id", profile["id"]).eq("status", "active").execute().data
    ]
    if not roles:
        raise HTTPException(status_code=404, detail=f"{payload.email} has no active role on this project. Give them a role first.")
    return {"user_id": profile["id"], "name": profile["name"], "email": profile["email"], "roles": roles}


@router.get("/activity")
def list_activity(project_id: str, limit: int = 100, user: CurrentUser = Depends(get_current_user)):
    """Recent changes on the project (from the audit log), newest first, with who made them."""
    result = execute_with_rules(
        user.client.rpc("fn_project_activity", {"p_project_id": project_id, "p_limit": limit}), on_denied=MANAGERS_ONLY,
    )
    return result.data
