# -*- coding: utf-8 -*-
from typing import Optional
from uuid import UUID
from pydantic import BaseModel


class ProjectEvmOut(BaseModel):
    """Maps to v_evm_by_project - the headline dashboard numbers."""
    project_id: UUID
    total_planned_value: float
    total_earned_value: float
    total_actual_cost: float
    cost_variance: float
    schedule_variance: float
    total_budgeted_cost: float
    physical_progress_pct: float
    financial_progress_pct: float
    items_exceeding_boq_estimate: int


class BoqItemEvmOut(BaseModel):
    """Maps to v_evm_by_boq_item - per-item detail for drill-down."""
    boq_item_id: UUID
    project_id: UUID
    description: str
    budgeted_quantity: float
    rate: float
    original_budgeted_cost: float
    effective_budgeted_cost: float
    planned_value: float
    earned_value: float
    actual_cost: float
    cumulative_measured_quantity: float


class ReportPermissionOut(BaseModel):
    report_key: str
    report_name: str
    category: str
    granted: bool


class ReportPermissionUpdate(BaseModel):
    user_id: UUID
    report_definition_key: str
    granted: bool
