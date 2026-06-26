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


@router.post("", response_model=ProjectOut)
def create_project(payload: ProjectCreate, user: CurrentUser = Depends(get_current_user)):
    """
    RLS (projects_insert_owner policy) requires the caller to be a
    company_owner of the target company - a non-owner's insert attempt
    is rejected by Postgres itself, not just hidden by application logic.
    """
    result = user.client.table("projects").insert(payload.model_dump(mode="json")).execute()
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to create a project for this company.")
    return result.data[0]
