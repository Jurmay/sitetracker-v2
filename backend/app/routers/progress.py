# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.schemas.progress import (
    ProgressReportOut, ProgressReportCreate, ProgressCorrectionOut, ProgressCorrectionCreate,
)

router = APIRouter()


@router.get("", response_model=List[ProgressReportOut])
def list_progress_reports(
    project_id: str,
    boq_item_id: str = None,
    user: CurrentUser = Depends(get_current_user),
):
    query = user.client.table("progress_reports").select("*").eq("project_id", project_id)
    if boq_item_id:
        query = query.eq("boq_item_id", boq_item_id)
    result = query.order("date", desc=True).execute()
    return result.data


@router.post("", response_model=ProgressReportOut)
def submit_progress_report(
    payload: ProgressReportCreate, user: CurrentUser = Depends(get_current_user)
):
    """
    Submits a measured-quantity entry. Per Phase 3, this counts as Earned
    Value immediately - no certification step. The non-reversal rule
    (cumulative effective quantity cannot decrease via a new Site
    Coordinator entry) and the coordinator-scope check
    (fn_coordinator_has_boq_access) are both enforced at the database
    level (a check constraint and an RLS policy respectively, not here),
    so this route stays a thin pass-through rather than re-implementing
    business rules that could drift from the database's own enforcement.
    """
    data = payload.model_dump(mode="json", exclude_none=True)
    data["coordinator_id"] = user.id
    result = user.client.table("progress_reports").insert(data).execute()
    if not result.data:
        raise HTTPException(
            status_code=403,
            detail=(
                "Could not submit progress report. This can mean: you are not assigned "
                "to this BOQ item's scope, the measured quantity is less than a previous "
                "cumulative entry, or you do not have Site Coordinator access on this project."
            ),
        )
    return result.data[0]


@router.post("/corrections", response_model=ProgressCorrectionOut)
def correct_progress_report(
    payload: ProgressCorrectionCreate, user: CurrentUser = Depends(get_current_user)
):
    """
    Admin/Company Owner only - enforced by RLS (pc_insert_admin /
    pc_insert_owner). This is final on submission; no second approval
    step, per the Phase 7 decision. original_quantity is read server-side
    from the live progress_reports row rather than trusted from the
    client, so the audit record always reflects what the value actually
    was at correction time.
    """
    original = (
        user.client.table("progress_reports")
        .select("measured_quantity")
        .eq("id", str(payload.progress_report_id))
        .execute()
    )
    if not original.data:
        raise HTTPException(
            status_code=404,
            detail="Progress report not found (or not visible to you).",
        )

    correction_data = {
        "progress_report_id": str(payload.progress_report_id),
        "original_quantity": original.data[0]["measured_quantity"],
        "corrected_quantity": payload.corrected_quantity,
        "reason": payload.reason,
        "corrected_by": user.id,
    }
    result = user.client.table("progress_corrections").insert(correction_data).execute()
    if not result.data:
        raise HTTPException(
            status_code=403,
            detail="Not permitted to correct progress reports on this project (Admin/Company Owner only).",
        )
    return result.data[0]
