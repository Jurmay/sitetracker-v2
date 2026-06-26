# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.schemas.master_roll import (
    LabourerOut, LabourerCreate, MasterRollEntryOut, MasterRollEntryCreate,
)

router = APIRouter()


@router.get("/labourers", response_model=List[LabourerOut])
def search_labourers(project_id: str, q: str = "", user: CurrentUser = Depends(get_current_user)):
    """
    Powers the 'search/select a returning worker' flow from the Phase 7
    mobile design - a coordinator types a name or ID number to find
    someone already registered, rather than re-entering photo+ID every day.
    """
    query = user.client.table("labourers").select("*").eq("project_id", project_id)
    if q:
        # Search both name and id_number - a coordinator on a noisy site
        # is just as likely to look someone up by their ID card as by name.
        query = query.or_(f"name.ilike.%{q}%,id_number.ilike.%{q}%")
    result = query.execute()
    return result.data


@router.post("/labourers", response_model=LabourerOut)
def register_labourer(payload: LabourerCreate, user: CurrentUser = Depends(get_current_user)):
    """
    One-time capture for a first-time worker. photo_url is expected to
    already be a Supabase Storage URL by this point - the actual upload
    (with the client-side auto-compression from the Document Management
    module) happens via a separate storage upload call before this is hit.
    """
    data = payload.model_dump(mode="json", exclude_none=True)
    data["created_by"] = user.id
    result = user.client.table("labourers").insert(data).execute()
    if not result.data:
        raise HTTPException(
            status_code=403,
            detail="Not permitted to register a labourer on this project.",
        )
    return result.data[0]


@router.get("/entries", response_model=List[MasterRollEntryOut])
def list_entries(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = (
        user.client.table("master_roll_entries")
        .select("*")
        .eq("project_id", project_id)
        .order("date", desc=True)
        .execute()
    )
    return result.data


@router.post("/entries", response_model=MasterRollEntryOut)
def submit_master_roll(payload: MasterRollEntryCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Submits a full day's master roll: the entry row, plus one attendance
    row per labourer (or none, if is_no_work_day). This is a multi-step
    sequence rather than a single insert - the Supabase Python client
    talks to PostgREST per-call, not a single multi-statement DB
    transaction, so a failure partway through (e.g. entry created but
    one attendance row rejected by RLS) can leave a partial entry.

    We mitigate this by validating everything we can client-side first
    (the schema's model_validator) and by relying on the unique
    constraint on (project_id, coordinator_id, date) - a failed retry
    after a partial success will hit that constraint on the entry insert
    rather than silently duplicating the day. A genuinely partial
    attendance set (entry exists, some rows missing) is still possible
    on a failure mid-loop; the route returns enough detail for the
    client to detect this and prompt a retry/resume rather than silently
    reporting success.
    """
    entry_data = {
        "project_id": str(payload.project_id),
        "coordinator_id": user.id,
        "date": str(payload.date),
        "is_no_work_day": payload.is_no_work_day,
        "no_work_remarks": payload.no_work_remarks,
    }
    entry_result = user.client.table("master_roll_entries").insert(entry_data).execute()
    if not entry_result.data:
        raise HTTPException(
            status_code=403,
            detail="Not permitted to submit a master roll entry for this project/date "
                   "(check you are an active Site Coordinator and an entry for this date "
                   "does not already exist).",
        )
    entry = entry_result.data[0]

    if not payload.is_no_work_day:
        attendance_rows = [
            {"entry_id": entry["id"], "labourer_id": str(row.labourer_id), "present": row.present}
            for row in payload.attendance
        ]
        attendance_result = (
            user.client.table("master_roll_attendance").insert(attendance_rows).execute()
        )
        if not attendance_result.data or len(attendance_result.data) != len(attendance_rows):
            raise HTTPException(
                status_code=207,  # Multi-Status: entry succeeded, attendance partially/fully failed
                detail=(
                    f"Master roll entry {entry['id']} was created, but one or more attendance "
                    "rows failed to save. Re-submit the missing workers for this same date "
                    "rather than creating a new entry."
                ),
            )

    return entry
