# -*- coding: utf-8 -*-
from datetime import date, datetime
from typing import List, Optional
from uuid import UUID
from pydantic import BaseModel, Field


class BillingTerms(BaseModel):
    """The billing columns of project_settings."""
    client_name: Optional[str] = None
    client_address: Optional[str] = None
    retention_pct: float = Field(ge=0, le=100)
    retention_limit_pct: Optional[float] = Field(default=None, ge=0, le=100)  # cap, % of contract value
    tds_pct: float = Field(ge=0, le=100)
    mobilisation_advance: float = Field(ge=0)
    advance_recovery_pct: float = Field(ge=0, le=100)


class ClientBillCreate(BaseModel):
    project_id: UUID
    period_to: Optional[date] = None  # work measured up to; defaults to today
    bill_date: Optional[date] = None
    prefill: bool = True  # fill quantities from measured, not yet billed work


class ClientBillUpdate(BaseModel):
    """Draft bills only (enforced by trigger)."""
    bill_date: Optional[date] = None
    period_to: Optional[date] = None
    is_final: Optional[bool] = None
    notes: Optional[str] = None


class ClientBillOut(BaseModel):
    """Maps to v_client_bills."""
    bill_id: UUID
    project_id: UUID
    bill_no: int
    bill_ref: str
    status: str  # draft | submitted | certified | paid | cancelled
    bill_date: date
    period_to: date
    is_final: bool
    notes: Optional[str] = None
    gross_amount: float
    retention_amount: float
    tds_amount: float
    advance_recovery: float
    other_deductions: float
    net_amount: float
    retention_pct: Optional[float] = None
    tds_pct: Optional[float] = None
    advance_recovery_pct: Optional[float] = None
    certified_amount: Optional[float] = None
    certified_date: Optional[date] = None
    certificate_ref: Optional[str] = None
    submitted_at: Optional[datetime] = None
    certified_at: Optional[datetime] = None
    cancelled_at: Optional[datetime] = None
    cancel_reason: Optional[str] = None
    paid_amount: float
    balance_due: Optional[float] = None
    payment_count: int
    last_payment_date: Optional[date] = None


class BillSheetRow(BaseModel):
    """One BOQ item on the bill abstract (fn_client_bill_sheet)."""
    boq_item_id: UUID
    section_name: str
    section_order: Optional[int] = None
    description: str
    unit: str
    boq_quantity: float
    rate: float
    previous_quantity: float
    this_quantity: float
    cumulative_quantity: float
    measured_quantity: float
    previous_amount: float
    this_amount: float
    cumulative_amount: float


class DeductionIn(BaseModel):
    description: str = Field(min_length=1)
    amount: float = Field(gt=0)


class DeductionOut(BaseModel):
    id: UUID
    description: str
    amount: float


class PaymentIn(BaseModel):
    amount: float = Field(gt=0)
    received_date: Optional[date] = None  # defaults to today (Bhutan time)
    reference: Optional[str] = None  # cheque / transfer number
    notes: Optional[str] = None


class PaymentOut(BaseModel):
    id: UUID
    received_date: date
    amount: float
    reference: Optional[str] = None
    notes: Optional[str] = None
    recorded_by_name: Optional[str] = None


class ClientBillDetailOut(BaseModel):
    bill: ClientBillOut
    sheet: List[BillSheetRow]
    deductions: List[DeductionOut]
    payments: List[PaymentOut]


class BillLineIn(BaseModel):
    boq_item_id: UUID
    quantity: float = Field(ge=0)  # 0 removes the item from the bill


class BillLinesIn(BaseModel):
    lines: List[BillLineIn] = Field(min_length=1)


class CertifyIn(BaseModel):
    certified_amount: float = Field(gt=0)
    certified_date: Optional[date] = None
    certificate_ref: Optional[str] = None


class CancelBillIn(BaseModel):
    reason: str = Field(min_length=1)


class RetentionPosition(BaseModel):
    """fn_retention_position: retention on certified/paid bills, and what has been claimed back."""
    withheld: float      # deducted on certified or paid bills
    claimed_open: float  # claimed, not yet received
    released: float      # received back
    held: float          # withheld - released
    available: float     # can still be claimed


class RetentionReleaseOut(BaseModel):
    id: UUID
    release_no: int
    release_ref: str
    status: str  # claimed | received | cancelled
    amount: float
    claim_date: date
    stage: Optional[str] = None
    notes: Optional[str] = None
    received_date: Optional[date] = None
    received_reference: Optional[str] = None
    cancel_reason: Optional[str] = None


class RetentionOut(BaseModel):
    position: RetentionPosition
    releases: List[RetentionReleaseOut]


class RetentionClaimIn(BaseModel):
    project_id: UUID
    amount: float = Field(gt=0)
    claim_date: Optional[date] = None
    stage: Optional[str] = None  # e.g. "Half on completion"
    notes: Optional[str] = None


class RetentionReceivedIn(BaseModel):
    received_date: Optional[date] = None
    reference: Optional[str] = None
