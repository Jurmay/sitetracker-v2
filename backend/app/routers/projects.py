# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.core.db_helpers import execute_with_rules
from app.schemas.boq import ProjectOut, ProjectCreate, ProjectFromBoqCreate
from app.services.boq_import import parse_boq_xlsx, BoqImportError

MAX_BOQ_UPLOAD_BYTES = 5 * 1024 * 1024

router = APIRouter()


@router.get("", response_model=List[ProjectOut])
def list_my_projects(user: CurrentUser = Depends(get_current_user)):
    """
    Returns every project this user has active access to. RLS (migration 005,
    projects_select_member policy via fn_has_project_access) does the actual
    filtering - this endpoint does not need its own WHERE clause for tenancy,
    since the RLS-scoped client cannot see rows outside the user's access
    regardless of what query is run.
    """
    result = user.client.table("projects").select("*").execute()
    return result.data


@router.get("/can-create")
def can_create_project(user: CurrentUser = Depends(get_current_user)):
    """Whether this user may create projects (Company Owners only)."""
    result = user.client.rpc("fn_can_create_project", {}).execute()
    return {"allowed": bool(result.data)}


@router.post("/import-boq")
async def preview_boq_import(file: UploadFile = File(...), user: CurrentUser = Depends(get_current_user)):
    """
    Reads an uploaded BOQ spreadsheet (the tender dashboard's
    BOQ_Pricing.xlsx) and returns its sections, items, total and warnings
    for the owner to check. Nothing is saved; POST /from-boq creates the
    project from what they confirm.
    """
    data = await file.read(MAX_BOQ_UPLOAD_BYTES + 1)
    if len(data) > MAX_BOQ_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="That file is over 5 MB; a BOQ spreadsheet should be far smaller.")
    try:
        return parse_boq_xlsx(data)
    except BoqImportError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/from-boq", response_model=ProjectOut)
def create_project_from_boq(payload: ProjectFromBoqCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Creates the project, makes the caller its Company Owner, and loads the
    BOQ, in one transaction (fn_create_project_from_boq). Company Owners
    only; the project is always created in the caller's own company.
    """
    body = payload.model_dump(mode="json")
    result = execute_with_rules(
        user.client.rpc("fn_create_project_from_boq", {
            "p_name": body["name"],
            "p_sections": body["sections"],
            "p_location": body["location"],
            "p_start_date": body["start_date"],
            "p_target_end_date": body["target_end_date"],
            "p_tender_ref": body["tender_ref"],
        }),
        on_denied="Only a Company Owner can create projects.",
    )
    return user.client.table("projects").select("*").eq("id", result.data).execute().data[0]


@router.get("/{project_id}", response_model=ProjectOut)
def get_project(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = user.client.table("projects").select("*").eq("id", project_id).execute()
    if not result.data:
        # Could mean "doesn't exist" OR "exists but RLS hides it" - we deliberately
        # do not distinguish these to the caller, since revealing "it exists but
        # you can't see it" leaks information about other tenants' data.
        raise HTTPException(status_code=404, detail="Project not found.")
    return result.data[0]


@router.get("/{project_id}/my-role")
def get_my_role(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Returns the calling user's active role(s) on this project. Added
    during Financial-screens frontend work: there was no existing way
    for the frontend to know whether to show a Site Coordinator view,
    a Cashier view, an Admin view, etc. - a real gap, not present in
    any router until now.

    A user could theoretically hold more than one role on the same
    project (the schema's unique constraint is on (project_id, user_id,
    role), not (project_id, user_id) alone) - returns a list rather than
    assuming exactly one, so the frontend can handle that case rather
    than silently picking one role role arbitrarily.
    """
    result = (
        user.client.table("project_roles")
        .select("role")
        .eq("project_id", project_id)
        .eq("user_id", user.id)
        .eq("status", "active")
        .execute()
    )
    roles = [row["role"] for row in result.data]
    if not roles:
        raise HTTPException(status_code=404, detail="You have no active role on this project.")
    return {"roles": roles}
