# -*- coding: utf-8 -*-
from datetime import date
from typing import Optional
from uuid import UUID
from pydantic import BaseModel, Field


class ProgressReportOut(BaseModel):
    id: UUID
    project_id: UUID
    boq_item_id: UUID
    subcontract_id: Optional[UUID] = None
    coordinator_id: UUID
    date: date
    measured_quantity: float
    notes: Optional[str] = None
    status: str


class ProgressReportCreate(BaseModel):
    project_id: UUID
    boq_item_id: UUID
    subcontract_id: Optional[UUID] = None  # set only if a subcontract team did this work
    date: date
    measured_quantity: float = Field(ge=0)
    notes: Optional[str] = None


class ProgressCorrectionOut(BaseModel):
    id: UUID
    progress_report_id: UUID
    original_quantity: float
    corrected_quantity: float
    reason: str
    corrected_by: UUID


class ProgressCorrectionCreate(BaseModel):
    """
    Admin-only path (RLS pc_insert_admin / pc_insert_owner enforces this -
    a Site Coordinator's attempt is rejected by Postgres). original_quantity
    is NOT supplied by the caller - the server reads it from the existing
    report, so a correction can never misrepresent what the original value
    actually was.
    """
    progress_report_id: UUID
    corrected_quantity: float = Field(ge=0)
    reason: str = Field(min_length=1)
