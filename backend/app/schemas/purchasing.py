# -*- coding: utf-8 -*-
from datetime import date, datetime
from typing import List, Optional
from uuid import UUID
from pydantic import BaseModel, Field, EmailStr


class SupplierOut(BaseModel):
    id: UUID
    company_id: UUID
    name: str
    contact_person: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    tpn: Optional[str] = None
    address: Optional[str] = None


class SupplierCreate(BaseModel):
    name: str = Field(min_length=1)
    contact_person: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[EmailStr] = None
    tpn: Optional[str] = None  # Bhutan taxpayer number
    address: Optional[str] = None


class PurchaseOrderLineIn(BaseModel):
    description: str = Field(min_length=1)
    unit: str = Field(min_length=1)
    quantity: float = Field(gt=0)
    rate: float = Field(ge=0)
    boq_item_id: Optional[UUID] = None


class PurchaseOrderCreate(BaseModel):
    project_id: UUID
    supplier_id: UUID
    expected_date: Optional[date] = None
    delivery_address: Optional[str] = None
    notes: Optional[str] = None
    lines: List[PurchaseOrderLineIn] = Field(min_length=1)


class PurchaseOrderOut(BaseModel):
    """Maps to v_purchase_orders."""
    po_id: UUID
    project_id: UUID
    po_number: str
    status: str  # draft | issued | partially_received | received | cancelled
    order_date: date
    expected_date: Optional[date] = None
    delivery_address: Optional[str] = None
    notes: Optional[str] = None
    supplier_id: UUID
    supplier_name: str
    supplier_phone: Optional[str] = None
    issued_at: Optional[datetime] = None
    cancelled_at: Optional[datetime] = None
    cancel_reason: Optional[str] = None
    line_count: int
    total_amount: float
    received_amount: float
    pct_received: float
    receipt_count: int
    last_received_date: Optional[date] = None
    delivery_overdue: bool


class PurchaseOrderLineOut(BaseModel):
    """Maps to v_purchase_order_lines."""
    po_line_id: UUID
    po_id: UUID
    line_no: int
    boq_item_id: Optional[UUID] = None
    boq_description: Optional[str] = None
    description: str
    unit: str
    ordered_qty: float
    rate: float
    amount: float
    received_qty: float
    rejected_qty: float
    pending_qty: float
    received_amount: float


class GoodsReceiptLineOut(BaseModel):
    po_line_id: UUID
    quantity_received: float
    quantity_rejected: float
    remarks: Optional[str] = None


class GoodsReceiptOut(BaseModel):
    id: UUID
    received_date: date
    delivery_note_no: Optional[str] = None
    vehicle_no: Optional[str] = None
    notes: Optional[str] = None
    received_by_name: Optional[str] = None
    lines: List[GoodsReceiptLineOut]


class PurchaseOrderDetailOut(BaseModel):
    order: PurchaseOrderOut
    lines: List[PurchaseOrderLineOut]
    receipts: List[GoodsReceiptOut]


class CancelPurchaseOrder(BaseModel):
    reason: str = Field(min_length=1)


class GoodsReceiptLineIn(BaseModel):
    po_line_id: UUID
    quantity_received: float = Field(default=0, ge=0)  # accepted
    quantity_rejected: float = Field(default=0, ge=0)
    remarks: Optional[str] = None


class GoodsReceiptCreate(BaseModel):
    received_date: Optional[date] = None  # defaults to today (Bhutan time) in the database
    delivery_note_no: Optional[str] = None
    vehicle_no: Optional[str] = None
    notes: Optional[str] = None
    lines: List[GoodsReceiptLineIn] = Field(min_length=1)
