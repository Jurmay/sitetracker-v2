# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.schemas.schedule import ScheduleItemOut

router = APIRouter()


@router.get("", response_model=List[ScheduleItemOut])
def get_schedule(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Planned vs actual for every BOQ item the caller can see. The view is
    security_invoker, so boq_items RLS decides the rows: a Viewer without
    the financial grant gets an empty list, a coordinator in split mode
    only their sections/zones.
    """
    result = (
        user.client.table("v_schedule_by_boq_item")
        .select("*")
        .eq("project_id", project_id)
        .order("section_sort")
        .order("section_name")
        .order("planned_start", nullsfirst=False)
        .order("description")
        .execute()
    )
    return result.data
