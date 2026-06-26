# -*- coding: utf-8 -*-
from datetime import date, datetime
from typing import Optional
from uuid import UUID
from pydantic import BaseModel, Field, model_validator


class SubcontractOut(BaseModel):
    id: UUID
    project_id: UUID
    boq_item_id: UUID
    team_lead_name: str
    agreed_rate: float
    status: str


class SubcontractCreate(BaseModel):
    project_id: UUID
    boq_item_id: UUID
    team_lead_name: str
    agreed_rate: float = Field(ge=0)


class SubcontractBalanceOut(BaseModel):
    """Maps to v_subcontract_balances - drawn vs earned vs net."""
    subcontract_id: UUID
    project_id: UUID
    team_lead_name: str
    status: str
    total_drawn: float
    total_earned: float
    net_position: float


class AdvanceRequisitionOut(BaseModel):
    id: UUID
    project_id: UUID
    requested_by: UUID
    advance_category: str  # 'work_tied' | 'subcontract' | 'overhead'
    boq_item_id: Optional[UUID] = None
    subcontract_id: Optional[UUID] = None
    ledger_head_id: Optional[UUID] = None
    amount: float
    justification: str
    status: str


class AdvanceRequisitionCreate(BaseModel):
    """
    Mirrors the type-dependent form designed in Phase 7: the category
    selected determines which link field is required. The check
    constraint in migration 003 enforces the same rule at the database
    level as a backstop, but validating here first gives the client a
    clean 422 with a specific message instead of an opaque DB error.
    """
    project_id: UUID
    advance_category: str
    boq_item_id: Optional[UUID] = None
    subcontract_id: Optional[UUID] = None
    ledger_head_id: Optional[UUID] = None
    amount: float = Field(gt=0)
    justification: str = Field(min_length=1)

    @model_validator(mode="after")
    def check_category_shape(self):
        if self.advance_category == "work_tied":
            if not self.boq_item_id or self.subcontract_id:
                raise ValueError("work_tied advances require boq_item_id and must not set subcontract_id.")
        elif self.advance_category == "subcontract":
            if not self.subcontract_id or self.boq_item_id:
                raise ValueError("subcontract advances require subcontract_id and must not set boq_item_id.")
        elif self.advance_category == "overhead":
            if self.boq_item_id or self.subcontract_id:
                raise ValueError("overhead advances must not set boq_item_id or subcontract_id.")
        else:
            raise ValueError("advance_category must be one of: work_tied, subcontract, overhead.")
        return self


class RequisitionActionCreate(BaseModel):
    """
    action_type is intentionally NOT free-form here per role - each role
    has its own dedicated endpoint (verify/approve/reject/disburse) below,
    so the action_type is set server-side, not supplied by the caller.
    This avoids a Cashier being able to even ATTEMPT an 'approved' action
    from the API shape itself, on top of the RLS-level rejection that
    would also catch it.
    """
    remarks: Optional[str] = None


class AdvanceSettlementOut(BaseModel):
    id: UUID
    requisition_id: UUID
    project_id: UUID
    submitted_by: UUID
    settled_amount: float
    status: str


class AdvanceSettlementCreate(BaseModel):
    requisition_id: UUID
    project_id: UUID
    settled_amount: float = Field(gt=0)


class SettlementActionCreate(BaseModel):
    remarks: Optional[str] = None


class CashbookOut(BaseModel):
    """Maps to v_cashbook_running_balance."""
    project_id: UUID
    total_fund_receipts: float
    total_disbursed: float
    current_balance: float
    balance_pct_of_fund: float


class FundRequisitionOut(BaseModel):
    id: UUID
    project_id: UUID
    requested_by: UUID
    amount: float
    reason: str
    status: str
    approved_by: Optional[UUID] = None


class FundRequisitionCreate(BaseModel):
    project_id: UUID
    amount: float = Field(gt=0)
    reason: str = Field(min_length=1)
