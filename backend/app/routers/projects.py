# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.schemas.boq import ProjectOut, ProjectCreate

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
