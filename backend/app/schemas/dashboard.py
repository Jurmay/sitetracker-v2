# -*- coding: utf-8 -*-
from datetime import date
from typing import List, Optional
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


class PortfolioProjectOut(BaseModel):
    """Maps to v_portfolio_summary - one row per site for the owner dashboard."""
    project_id: UUID
    name: str
    location: Optional[str] = None
    status: str
    target_end_date: Optional[date] = None
    total_budgeted_cost: float
    planned_value: float
    earned_value: float
    actual_cost: float
    cost_variance: float
    schedule_variance: float
    physical_progress_pct: float
    financial_progress_pct: float
    items_exceeding_boq_estimate: int
    total_fund_receipts: float
    total_disbursed: float
    cash_balance: float
    cash_balance_pct: float
    cash_replenishment_threshold_pct: float
    cash_low: bool
    advances_pending_verification: int
    advances_pending_approval: int
    advances_awaiting_disbursement: int
    settlements_pending_verification: int
    fund_requisitions_pending: int
    advances_outstanding_amount: float
    settlements_overdue: int
    coordinators_on_duty: int
    master_roll_submitted_today: int
    progress_submitted_today: int
    coordinators_missing_today: List[str]
    last_progress_date: Optional[date] = None


class ReportPermissionOut(BaseModel):
    report_key: str
    report_name: str
    category: str
    granted: bool


class ReportPermissionUpdate(BaseModel):
    user_id: UUID
    report_definition_key: str
    granted: bool
