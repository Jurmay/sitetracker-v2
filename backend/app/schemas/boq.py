# -*- coding: utf-8 -*-
from datetime import date, datetime
from typing import List, Optional
from uuid import UUID
from pydantic import BaseModel, Field


class ProjectOut(BaseModel):
    id: UUID
    company_id: UUID
    name: str
    location: Optional[str] = None
    start_date: Optional[date] = None
    target_end_date: Optional[date] = None
    total_budget: float
    currency: str
    status: str
    tender_ref: Optional[str] = None


class ProjectCreate(BaseModel):
    company_id: UUID
    name: str
    location: Optional[str] = None
    start_date: Optional[date] = None
    target_end_date: Optional[date] = None
    total_budget: float = 0
    currency: str = "BTN"


class BOQSectionOut(BaseModel):
    id: UUID
    project_id: UUID
    name: str
    sort_order: int


class BOQSectionCreate(BaseModel):
    project_id: UUID
    name: str
    sort_order: int = 0


class BOQItemOut(BaseModel):
    id: UUID
    section_id: UUID
    zone_id: Optional[UUID] = None
    description: str
    unit: str
    quantity: float
    rate: float
    budgeted_cost: float  # generated column, read-only
    planned_start: Optional[date] = None
    planned_end: Optional[date] = None


class BOQItemCreate(BaseModel):
    section_id: UUID
    zone_id: Optional[UUID] = None
    description: str
    unit: str
    quantity: float = Field(ge=0)
    rate: float = Field(ge=0)
    planned_start: Optional[date] = None
    planned_end: Optional[date] = None


class BOQVariationCreate(BaseModel):
    boq_item_id: UUID
    qty_delta: float = 0
    rate_delta: float = 0
    reason: str


class ImportedBoqItem(BaseModel):
    description: str = Field(min_length=1)
    unit: str = Field(min_length=1)
    quantity: float = Field(ge=0)
    rate: float = Field(ge=0)


class ImportedBoqSection(BaseModel):
    name: str = Field(min_length=1)
    items: List[ImportedBoqItem] = Field(min_length=1)


class ProjectFromBoqCreate(BaseModel):
    """A won tender's BOQ (as previewed from the uploaded file) plus project details."""
    name: str = Field(min_length=1)
    location: Optional[str] = None
    start_date: Optional[date] = None
    target_end_date: Optional[date] = None
    tender_ref: Optional[str] = None
    sections: List[ImportedBoqSection] = Field(min_length=1)
