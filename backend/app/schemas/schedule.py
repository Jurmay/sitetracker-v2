# -*- coding: utf-8 -*-
from datetime import date
from typing import Optional
from uuid import UUID
from pydantic import BaseModel, model_validator


class ScheduleItemOut(BaseModel):
    """Maps to v_schedule_by_boq_item - one row per BOQ item."""
    boq_item_id: UUID
    project_id: UUID
    section_id: UUID
    section_name: str
    section_sort: int
    description: str
    unit: str
    quantity: float
    done_qty: float
    pct_complete: float
    planned_start: Optional[date] = None
    planned_end: Optional[date] = None
    pct_expected: Optional[float] = None
    actual_start: Optional[date] = None
    actual_finish: Optional[date] = None
    last_progress_date: Optional[date] = None
    forecast_finish: Optional[date] = None
    schedule_status: str  # done | unscheduled | overdue | not_started | late_start | behind | on_track
    delay_days: Optional[int] = None


class PlannedDatesUpdate(BaseModel):
    """Both dates set, or both cleared (item becomes unscheduled)."""
    planned_start: Optional[date] = None
    planned_end: Optional[date] = None

    @model_validator(mode="after")
    def check_dates(self):
        if (self.planned_start is None) != (self.planned_end is None):
            raise ValueError("Set both planned start and planned end, or clear both.")
        if self.planned_start and self.planned_end <= self.planned_start:
            raise ValueError("Planned end must be after planned start.")
        return self
