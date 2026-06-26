# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.schemas.boq import BOQSectionOut, BOQSectionCreate, BOQItemOut, BOQItemCreate, BOQVariationCreate

router = APIRouter()


@router.get("/sections", response_model=List[BOQSectionOut])
def list_sections(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = (
        user.client.table("boq_sections")
        .select("*")
        .eq("project_id", project_id)
        .order("sort_order")
        .execute()
    )
    return result.data


@router.post("/sections", response_model=BOQSectionOut)
def create_section(payload: BOQSectionCreate, user: CurrentUser = Depends(get_current_user)):
    """
    RLS (boq_sections_write_admin / boq_sections_write_owner) restricts
    this to Admin/Company Owner, same pattern as create_item below.
    """
    result = user.client.table("boq_sections").insert(
        payload.model_dump(mode="json")
    ).execute()
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to add BOQ sections to this project.")
    return result.data[0]


@router.get("/items", response_model=List[BOQItemOut])
def list_items(section_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    No manual scope-filtering here for Site Coordinators - that's
    intentional. RLS policy boq_items_select_coordinator already
    restricts which rows a coordinator can see via
    fn_coordinator_has_boq_access(). Re-implementing that filter here
    in Python would create two sources of truth that could drift apart;
    the database is the single source of truth for this rule.
    """
    result = user.client.table("boq_items").select("*").eq("section_id", section_id).execute()
    return result.data


@router.post("/items", response_model=BOQItemOut)
def create_item(payload: BOQItemCreate, user: CurrentUser = Depends(get_current_user)):
    """
    RLS (boq_items_write_admin / boq_items_write_owner) restricts this
    to Admin/Company Owner - a Site Coordinator attempting this gets a
    clean rejection from Postgres, not a 200 with hidden data.
    Note: budgeted_cost is NOT in the insert payload - it's a generated
    column (quantity * rate), computed by Postgres itself, never sent
    by the client.
    """
    result = user.client.table("boq_items").insert(
        payload.model_dump(mode="json", exclude_none=True)
    ).execute()
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to add BOQ items to this project.")
    return result.data[0]


@router.post("/variations")
def create_variation(payload: BOQVariationCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Append-only by design (migration 005 deliberately omits an update/delete
    policy on boq_variations) - this endpoint only ever inserts, and there
    is intentionally no corresponding PUT/DELETE route.
    """
    result = user.client.table("boq_variations").insert(
        {**payload.model_dump(mode="json"), "created_by": user.id}
    ).execute()
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to record a variation on this BOQ item.")
    return result.data[0]
