# -*- coding: utf-8 -*-
"""
Suppliers, purchase orders and goods received on site.

All business rules live in the database (migration 20261025105110):
RLS decides who may see/create/issue/receive, and triggers enforce PO
numbering, draft-only line edits, issue/cancel transitions, and that
deliveries never exceed the ordered quantity. These routes just pass
requests through as the signed-in user and turn database refusals into
clean HTTP errors.
"""
from fastapi import APIRouter, Depends, HTTPException, Response
from typing import List
from postgrest.exceptions import APIError

from app.core.deps import get_current_user, CurrentUser
from app.schemas.purchasing import (
    SupplierOut, SupplierCreate, PurchaseOrderCreate, PurchaseOrderOut, PurchaseOrderLineOut,
    PurchaseOrderDetailOut, CancelPurchaseOrder, GoodsReceiptCreate,
)
from app.services.purchase_order_pdf import generate_purchase_order_pdf

router = APIRouter()


def _run(query, *, on_denied: str):
    """
    Like safe_execute, but a rule raised by a trigger or function
    (P0001, e.g. "Receiving 81 bag would exceed the 200 bag ordered")
    or a constraint violation (23xxx) is the user's mistake, so it comes
    back as a 400 carrying the database's own message.
    """
    try:
        return query.execute()
    except APIError as e:
        if e.code == "42501":
            raise HTTPException(status_code=403, detail=on_denied)
        if e.code == "P0001" or (e.code or "").startswith("23"):
            raise HTTPException(status_code=400, detail=e.message)
        raise HTTPException(status_code=500, detail=f"Database error: {e.message}")


def _get_order(user: CurrentUser, po_id: str) -> dict:
    result = user.client.table("v_purchase_orders").select("*").eq("po_id", po_id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Purchase order not found.")
    return result.data[0]


# ----------------------------------------------------------------
# Suppliers (company-wide)
# ----------------------------------------------------------------

@router.get("/suppliers", response_model=List[SupplierOut])
def list_suppliers(user: CurrentUser = Depends(get_current_user)):
    """RLS limits this to the caller's own company."""
    return user.client.table("suppliers").select("*").order("name").execute().data


@router.post("/suppliers", response_model=SupplierOut)
def create_supplier(payload: SupplierCreate, user: CurrentUser = Depends(get_current_user)):
    """Admins/Company Owners only (suppliers_insert policy)."""
    profile = user.client.table("profiles").select("company_id").eq("id", user.id).execute()
    if not profile.data:
        raise HTTPException(status_code=403, detail="No profile found for your account.")
    data = {**payload.model_dump(mode="json"), "company_id": profile.data[0]["company_id"], "created_by": user.id}
    result = _run(user.client.table("suppliers").insert(data),
                  on_denied="Only an Admin or Company Owner can add suppliers.")
    return result.data[0]


# ----------------------------------------------------------------
# Purchase orders
# ----------------------------------------------------------------

@router.get("/orders", response_model=List[PurchaseOrderOut])
def list_orders(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = (
        user.client.table("v_purchase_orders").select("*").eq("project_id", project_id)
        .order("order_date", desc=True).order("po_number", desc=True).execute()
    )
    return result.data


@router.post("/orders", response_model=PurchaseOrderOut)
def create_order(payload: PurchaseOrderCreate, user: CurrentUser = Depends(get_current_user)):
    """Creates a draft PO and its lines in one transaction (fn_create_purchase_order)."""
    body = payload.model_dump(mode="json")
    result = _run(
        user.client.rpc("fn_create_purchase_order", {
            "p_project_id": body["project_id"],
            "p_supplier_id": body["supplier_id"],
            "p_lines": body["lines"],
            "p_expected_date": body["expected_date"],
            "p_delivery_address": body["delivery_address"],
            "p_notes": body["notes"],
        }),
        on_denied="Only an Admin or Company Owner can create purchase orders on this project.",
    )
    return _get_order(user, result.data)


@router.get("/orders/{po_id}", response_model=PurchaseOrderDetailOut)
def get_order(po_id: str, user: CurrentUser = Depends(get_current_user)):
    order = _get_order(user, po_id)
    lines = (
        user.client.table("v_purchase_order_lines").select("*").eq("po_id", po_id).order("line_no").execute().data
    )
    receipts = (
        user.client.table("goods_receipts")
        .select("id, received_date, delivery_note_no, vehicle_no, notes, profiles(name), "
                "goods_receipt_lines(po_line_id, quantity_received, quantity_rejected, remarks)")
        .eq("po_id", po_id).order("received_date").order("created_at").execute().data
    )
    return {
        "order": order,
        "lines": lines,
        "receipts": [
            {**r, "received_by_name": (r.get("profiles") or {}).get("name"), "lines": r["goods_receipt_lines"]}
            for r in receipts
        ],
    }


@router.post("/orders/{po_id}/issue", response_model=PurchaseOrderOut)
def issue_order(po_id: str, user: CurrentUser = Depends(get_current_user)):
    result = _run(
        user.client.table("purchase_orders").update({"status": "issued"}).eq("id", po_id),
        on_denied="Only an Admin or Company Owner can issue purchase orders.",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Only an Admin or Company Owner can issue purchase orders.")
    return _get_order(user, po_id)


@router.post("/orders/{po_id}/cancel", response_model=PurchaseOrderOut)
def cancel_order(po_id: str, payload: CancelPurchaseOrder, user: CurrentUser = Depends(get_current_user)):
    """Only before anything has been received (enforced by trigger)."""
    result = _run(
        user.client.table("purchase_orders")
        .update({"status": "cancelled", "cancel_reason": payload.reason}).eq("id", po_id),
        on_denied="Only an Admin or Company Owner can cancel purchase orders.",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Only an Admin or Company Owner can cancel purchase orders.")
    return _get_order(user, po_id)


@router.post("/orders/{po_id}/receipts", response_model=PurchaseOrderOut)
def record_receipt(po_id: str, payload: GoodsReceiptCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Records a delivery on site (fn_record_goods_receipt). Site Coordinators,
    Admins and Owners. The PO's status follows automatically.
    """
    body = payload.model_dump(mode="json")
    _run(
        user.client.rpc("fn_record_goods_receipt", {
            "p_po_id": po_id,
            "p_lines": body["lines"],
            "p_received_date": body["received_date"],
            "p_delivery_note_no": body["delivery_note_no"],
            "p_vehicle_no": body["vehicle_no"],
            "p_notes": body["notes"],
        }),
        on_denied="You are not permitted to record deliveries on this project.",
    )
    return _get_order(user, po_id)


@router.get("/orders/{po_id}/pdf")
def get_order_pdf(po_id: str, user: CurrentUser = Depends(get_current_user)):
    order = _get_order(user, po_id)
    lines = (
        user.client.table("v_purchase_order_lines").select("*").eq("po_id", po_id).order("line_no").execute().data
    )
    supplier = user.client.table("suppliers").select("*").eq("id", order["supplier_id"]).execute().data
    project = (
        user.client.table("projects").select("name, location, currency, companies(name)")
        .eq("id", order["project_id"]).execute().data
    )
    issued_by = user.client.table("purchase_orders").select("profiles!purchase_orders_issued_by_fkey(name)") \
        .eq("id", po_id).execute().data

    pdf_bytes = generate_purchase_order_pdf(
        order=order,
        lines=lines,
        supplier=supplier[0] if supplier else {"name": order["supplier_name"]},
        company_name=((project[0].get("companies") or {}).get("name", "")) if project else "",
        project_name=project[0]["name"] if project else "",
        project_location=project[0].get("location") if project else None,
        currency=project[0].get("currency", "BTN") if project else "BTN",
        issued_by_name=((issued_by[0].get("profiles") or {}).get("name")) if issued_by else None,
    )
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{order["po_number"]}.pdf"'},
    )
