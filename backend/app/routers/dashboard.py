# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.core.db_helpers import safe_execute
from app.schemas.dashboard import (
    ProjectEvmOut, BoqItemEvmOut, ReportPermissionOut, ReportPermissionUpdate,
)

router = APIRouter()


@router.get("/evm", response_model=ProjectEvmOut)
def get_project_evm(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    The headline numbers for the Admin/Company Owner dashboard's KPI
    cards and the S-curve chart (Phase 5). Reads v_evm_by_project
    (migration 006) - RLS on the underlying boq_items/progress_reports/
    advance_settlements tables governs what actually gets summed for
    this user, so a Viewer without financial grant would see this
    rolled-up view reflect only what they're otherwise allowed to see
    (in practice: for MVP, Viewer access to boq_items is all-or-nothing
    per the Phase 11 RLS decision, so an ungranted Viewer hitting this
    endpoint gets an empty/zeroed result, not an error - see note below).
    """
    result = user.client.table("v_evm_by_project").select("*").eq("project_id", project_id).execute()
    if not result.data:
        # Empty result here is ambiguous: either no BOQ items exist yet
        # for this project, OR this user's RLS-visible BOQ items are
        # empty (e.g. ungranted Viewer). We return zeroed EVM rather
        # than a 404, since "no visible financial data" and "no data"
        # should look the same to a Viewer without grant - a 404 here
        # would itself leak the fact that financial data exists but is
        # hidden, which is exactly the kind of information leak Phase 1's
        # evenhandedness/permission design tries to avoid.
        return {
            "project_id": project_id,
            "total_planned_value": 0, "total_earned_value": 0, "total_actual_cost": 0,
            "cost_variance": 0, "schedule_variance": 0, "total_budgeted_cost": 0,
            "physical_progress_pct": 0, "financial_progress_pct": 0,
            "items_exceeding_boq_estimate": 0,
        }
    return result.data[0]


@router.get("/evm/items", response_model=List[BoqItemEvmOut])
def get_boq_item_evm(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """Per-item EVM detail, for dashboard drill-down into a specific BOQ line."""
    result = (
        user.client.table("v_evm_by_boq_item")
        .select("*")
        .eq("project_id", project_id)
        .execute()
    )
    return result.data


@router.get("/permissions", response_model=List[ReportPermissionOut])
def get_my_report_permissions(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Returns the calling user's own visibility grid (which reports/KPI
    cards they're allowed to see), so the frontend can decide which
    dashboard cards and report-download buttons to render. RLS
    (urp_select_self) restricts this to the caller's own rows even
    though the query doesn't explicitly filter by user_id - Admin/Owner
    calling this for THEIR OWN permissions works the same way; viewing
    another user's grid is a separate endpoint below.
    """
    result = (
        user.client.table("user_report_permissions")
        .select("granted, report_definitions(key, name, category)")
        .eq("project_id", project_id)
        .execute()
    )
    return [
        {
            "report_key": row["report_definitions"]["key"],
            "report_name": row["report_definitions"]["name"],
            "category": row["report_definitions"]["category"],
            "granted": row["granted"],
        }
        for row in result.data
    ]


@router.get("/permissions/{target_user_id}", response_model=List[ReportPermissionOut])
def get_user_report_permissions(
    project_id: str, target_user_id: str, user: CurrentUser = Depends(get_current_user)
):
    """
    Admin/Company Owner viewing or editing ANOTHER user's permission
    grid (the Phase 3 checkbox-grid feature). RLS (urp_select_admin /
    urp_select_owner) restricts this to Admin/Owner - a non-admin
    calling this for someone else's user_id gets an empty result, which
    we translate to 403 here since, unlike the EVM endpoint above, there
    is no Viewer-facing reason to hide this distinction for this route.
    """
    result = (
        user.client.table("user_report_permissions")
        .select("granted, report_definitions(key, name, category)")
        .eq("project_id", project_id)
        .eq("user_id", target_user_id)
        .execute()
    )
    if not result.data:
        raise HTTPException(
            status_code=403,
            detail="Not permitted to view this user's report permissions, or no permissions exist yet.",
        )
    return [
        {
            "report_key": row["report_definitions"]["key"],
            "report_name": row["report_definitions"]["name"],
            "category": row["report_definitions"]["category"],
            "granted": row["granted"],
        }
        for row in result.data
    ]


@router.put("/permissions")
def update_report_permission(
    project_id: str, payload: ReportPermissionUpdate, user: CurrentUser = Depends(get_current_user)
):
    """
    Admin/Company Owner only (RLS urp_write_admin / urp_write_owner).
    Looks up the report_definition by its stable key (not its uuid -
    keys are what the frontend/this API surface naturally, since they're
    human-readable and stable across environments, unlike a generated id).
    """
    report_def = (
        user.client.table("report_definitions")
        .select("id")
        .eq("key", payload.report_definition_key)
        .execute()
    )
    if not report_def.data:
        raise HTTPException(status_code=404, detail=f"Unknown report key: {payload.report_definition_key}")

    result = safe_execute(
        user.client.table("user_report_permissions")
        .update({"granted": payload.granted, "granted_by": user.id})
        .eq("project_id", project_id)
        .eq("user_id", str(payload.user_id))
        .eq("report_definition_id", report_def.data[0]["id"]),
        on_denied="Not permitted to change this user's report permissions on this project.",
    )
    if not result.data:
        raise HTTPException(
            status_code=403,
            detail="Not permitted to change this user's report permissions on this project.",
        )
    return result.data[0]
