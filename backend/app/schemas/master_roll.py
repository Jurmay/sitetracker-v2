# -*- coding: utf-8 -*-
from datetime import date, datetime
from typing import Optional, List
from uuid import UUID
from pydantic import BaseModel, Field, model_validator


class LabourerOut(BaseModel):
    id: UUID
    project_id: UUID
    name: str
    photo_url: str
    id_number: str
    labour_type: str  # 'contract' | 'daily_wage'
    labour_category_id: Optional[UUID] = None
    contracted_rate: Optional[float] = None


class LabourerCreate(BaseModel):
    """
    Registration of a new labourer. Per the Phase 7 redesign, photo_url
    and id_number are mandatory for EVERY labourer regardless of type -
    there is no anonymous/headcount-only path. The check constraint in
    migration 002 enforces this at the database level too, so even a
    bypassed or buggy client cannot create an incomplete record.
    """
    project_id: UUID
    name: str
    photo_url: str = Field(min_length=1)
    id_number: str = Field(min_length=1)
    labour_type: str
    labour_category_id: Optional[UUID] = None
    contracted_rate: Optional[float] = None

    @model_validator(mode="after")
    def check_type_consistency(self):
        if self.labour_type == "daily_wage" and self.labour_category_id is None:
            raise ValueError("daily_wage labourers must have a labour_category_id.")
        if self.labour_type == "contract" and self.contracted_rate is None:
            raise ValueError("contract labourers must have a contracted_rate.")
        return self


class MasterRollEntryOut(BaseModel):
    id: UUID
    project_id: UUID
    coordinator_id: UUID
    date: date
    is_no_work_day: bool
    no_work_remarks: Optional[str] = None
    is_late_entry: bool


class AttendanceRow(BaseModel):
    labourer_id: UUID
    present: bool = True


class MasterRollEntryCreate(BaseModel):
    """
    Single submission covering the whole day: either a list of present/
    absent labourers, OR a no-work-day flag with mandatory remarks -
    mirroring the mobile form designed in Phase 7. The API enforces the
    same either/or rule the database check constraint enforces, so the
    client gets a clear 422 rather than a vague database error.
    """
    project_id: UUID
    date: date
    is_no_work_day: bool = False
    no_work_remarks: Optional[str] = None
    attendance: List[AttendanceRow] = []

    @model_validator(mode="after")
    def check_no_work_or_attendance(self):
        if self.is_no_work_day:
            if not self.no_work_remarks or not self.no_work_remarks.strip():
                raise ValueError("no_work_remarks is required when is_no_work_day is true.")
        else:
            if not self.attendance:
                raise ValueError("At least one attendance row is required unless is_no_work_day is true.")
        return self
