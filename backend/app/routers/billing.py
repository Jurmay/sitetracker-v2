# -*- coding: utf-8 -*-
"""
Client running bills (RA bills) and the payments received against them.

All business rules live in the database (migration 20261025200000):
RLS decides who may see/create/certify/record payments, and triggers
enforce RA numbering, BOQ rates, the BOQ quantity limit, draft-only
edits, the amounts (retention, TDS, advance recovery) and the payment
limit. These routes pass requests through as the signed-in user and
turn database refusals into clean HTTP errors.
"""
from fastapi import APIRouter, Depends, HTTPException, Response
from typing import List

from app.core.deps import get_current_user, CurrentUser
from app.core.db_helpers import execute_with_rules as _run
from app.schemas.billing import (
    BillingTerms, ClientBillCreate, ClientBillUpdate, ClientBillOut, ClientBillDetailOut,
    BillLinesIn, DeductionIn, DeductionOut, PaymentIn, CertifyIn, CancelBillIn,
    RetentionOut, RetentionClaimIn, RetentionReceivedIn,
)
from app.services.client_bill_pdf import generate_client_bill_pdf, generate_retention_claim_pdf

router = APIRouter()

TERMS_COLUMNS = ("client_name, client_address, retention_pct, retention_limit_pct, tds_pct, "
                 "mobilisation_advance, advance_recovery_pct")
MANAGERS_ONLY = "Only an Admin or Company Owner can manage client bills on this project."


def _get_bill(user: CurrentUser, bill_id: str) -> dict:
    result = user.client.table("v_client_bills").select("*").eq("bill_id", bill_id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Bill not found.")
    return result.data[0]


def _update_bill(user: CurrentUser, bill_id: str, changes: dict) -> dict:
    result = _run(user.client.table("client_bills").update(changes).eq("id", bill_id), on_denied=MANAGERS_ONLY)
    if not result.data:
        raise HTTPException(status_code=403, detail=MANAGERS_ONLY)
    return _get_bill(user, bill_id)


# ----------------------------------------------------------------
# Billing terms (per project)
# ----------------------------------------------------------------

@router.get("/terms", response_model=BillingTerms)
def get_terms(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = user.client.table("project_settings").select(TERMS_COLUMNS).eq("project_id", project_id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Project not found.")
    return result.data[0]


@router.put("/terms", response_model=BillingTerms)
def set_terms(project_id: str, payload: BillingTerms, user: CurrentUser = Depends(get_current_user)):
    """Admins/Owners. Applies to draft and future bills; submitted bills keep their amounts."""
    result = _run(
        user.client.table("project_settings").update(payload.model_dump(mode="json")).eq("project_id", project_id),
        on_denied=MANAGERS_ONLY,
    )
    if not result.data:
        raise HTTPException(status_code=403, detail=MANAGERS_ONLY)
    return get_terms(project_id, user)


# ----------------------------------------------------------------
# Bills
# ----------------------------------------------------------------

@router.get("/bills", response_model=List[ClientBillOut])
def list_bills(project_id: str, user: CurrentUser = Depends(get_current_user)):
    return (
        user.client.table("v_client_bills").select("*").eq("project_id", project_id)
        .order("bill_no", desc=True).execute().data
    )


@router.post("/bills", response_model=ClientBillOut)
def create_bill(payload: ClientBillCreate, user: CurrentUser = Depends(get_current_user)):
    """Starts the next RA bill as a draft, optionally filled from measured work (fn_create_client_bill)."""
    body = payload.model_dump(mode="json")
    result = _run(
        user.client.rpc("fn_create_client_bill", {
            "p_project_id": body["project_id"],
            "p_period_to": body["period_to"],
            "p_bill_date": body["bill_date"],
            "p_prefill": body["prefill"],
        }),
        on_denied=MANAGERS_ONLY,
    )
    return _get_bill(user, result.data)


@router.get("/bills/{bill_id}", response_model=ClientBillDetailOut)
def get_bill(bill_id: str, user: CurrentUser = Depends(get_current_user)):
    bill = _get_bill(user, bill_id)
    sheet = user.client.rpc("fn_client_bill_sheet", {"p_bill_id": bill_id}).execute().data
    deductions = (
        user.client.table("client_bill_deductions").select("id, description, amount")
        .eq("bill_id", bill_id).order("created_at").execute().data
    )
    payments = (
        user.client.table("client_bill_payments")
        .select("id, received_date, amount, reference, notes, profiles(name)")
        .eq("bill_id", bill_id).order("received_date").order("created_at").execute().data
    )
    return {
        "bill": bill,
        "sheet": sheet,
        "deductions": deductions,
        "payments": [{**p, "recorded_by_name": (p.get("profiles") or {}).get("name")} for p in payments],
    }


@router.patch("/bills/{bill_id}", response_model=ClientBillOut)
def update_bill(bill_id: str, payload: ClientBillUpdate, user: CurrentUser = Depends(get_current_user)):
    """Dates, final-bill flag and notes; drafts only (enforced by trigger)."""
    changes = payload.model_dump(mode="json", exclude_unset=True)
    if not changes:
        return _get_bill(user, bill_id)
    return _update_bill(user, bill_id, changes)


@router.delete("/bills/{bill_id}", status_code=204)
def delete_bill(bill_id: str, user: CurrentUser = Depends(get_current_user)):
    """Drafts only (client_bills_delete_draft policy)."""
    bill = _get_bill(user, bill_id)
    if bill["status"] != "draft":
        raise HTTPException(status_code=400, detail="Only a draft bill can be deleted; cancel a submitted bill instead.")
    result = _run(user.client.table("client_bills").delete().eq("id", bill_id), on_denied=MANAGERS_ONLY)
    if not result.data:
        raise HTTPException(status_code=403, detail=MANAGERS_ONLY)
    return Response(status_code=204)


@router.put("/bills/{bill_id}/lines", response_model=ClientBillOut)
def set_lines(bill_id: str, payload: BillLinesIn, user: CurrentUser = Depends(get_current_user)):
    """Sets quantities this bill per BOQ item (0 removes it). Rates always come from the BOQ."""
    _run(
        user.client.rpc("fn_set_client_bill_lines", {
            "p_bill_id": bill_id, "p_lines": payload.model_dump(mode="json")["lines"],
        }),
        on_denied=MANAGERS_ONLY,
    )
    return _get_bill(user, bill_id)


@router.post("/bills/{bill_id}/deductions", response_model=ClientBillOut)
def add_deduction(bill_id: str, payload: DeductionIn, user: CurrentUser = Depends(get_current_user)):
    _run(
        user.client.table("client_bill_deductions").insert({
            "bill_id": bill_id, "description": payload.description, "amount": payload.amount,
            "created_by": user.id,
        }),
        on_denied=MANAGERS_ONLY,
    )
    return _get_bill(user, bill_id)


@router.delete("/bills/{bill_id}/deductions/{deduction_id}", response_model=ClientBillOut)
def remove_deduction(bill_id: str, deduction_id: str, user: CurrentUser = Depends(get_current_user)):
    result = _run(
        user.client.table("client_bill_deductions").delete().eq("id", deduction_id).eq("bill_id", bill_id),
        on_denied=MANAGERS_ONLY,
    )
    if not result.data:
        raise HTTPException(status_code=403, detail=MANAGERS_ONLY)
    return _get_bill(user, bill_id)


@router.post("/bills/{bill_id}/submit", response_model=ClientBillOut)
def submit_bill(bill_id: str, user: CurrentUser = Depends(get_current_user)):
    """Fixes the bill's quantities and amounts."""
    return _update_bill(user, bill_id, {"status": "submitted"})


@router.post("/bills/{bill_id}/recall", response_model=ClientBillOut)
def recall_bill(bill_id: str, user: CurrentUser = Depends(get_current_user)):
    """Back to draft for corrections; latest bill only, before it is certified."""
    return _update_bill(user, bill_id, {"status": "draft"})


@router.post("/bills/{bill_id}/certify", response_model=ClientBillOut)
def certify_bill(bill_id: str, payload: CertifyIn, user: CurrentUser = Depends(get_current_user)):
    """Records the client's certificate: the amount they will pay."""
    return _update_bill(user, bill_id, {"status": "certified", **payload.model_dump(mode="json", exclude_none=True)})


@router.post("/bills/{bill_id}/cancel", response_model=ClientBillOut)
def cancel_bill(bill_id: str, payload: CancelBillIn, user: CurrentUser = Depends(get_current_user)):
    """A submitted (not yet certified) bill; latest bill only."""
    return _update_bill(user, bill_id, {"status": "cancelled", "cancel_reason": payload.reason})


@router.post("/bills/{bill_id}/payments", response_model=ClientBillOut)
def record_payment(bill_id: str, payload: PaymentIn, user: CurrentUser = Depends(get_current_user)):
    """Admins, Owners and Cashiers. The bill becomes 'paid' once the certified amount is received."""
    bill = _get_bill(user, bill_id)
    _run(
        user.client.table("client_bill_payments").insert({
            "bill_id": bill_id, "project_id": bill["project_id"], "recorded_by": user.id,
            **payload.model_dump(mode="json", exclude_none=True),
        }),
        on_denied="Only an Admin, Company Owner or Cashier can record payments on this project.",
    )
    return _get_bill(user, bill_id)


@router.get("/bills/{bill_id}/pdf")
def get_bill_pdf(bill_id: str, user: CurrentUser = Depends(get_current_user)):
    bill = _get_bill(user, bill_id)
    sheet = user.client.rpc("fn_client_bill_sheet", {"p_bill_id": bill_id}).execute().data
    deductions = (
        user.client.table("client_bill_deductions").select("description, amount")
        .eq("bill_id", bill_id).order("created_at").execute().data
    )
    project = (
        user.client.table("projects").select("name, location, currency, tender_ref, companies(name)")
        .eq("id", bill["project_id"]).execute().data
    )
    terms = (
        user.client.table("project_settings").select("client_name, client_address")
        .eq("project_id", bill["project_id"]).execute().data
    )
    p = project[0] if project else {}
    pdf_bytes = generate_client_bill_pdf(
        bill=bill,
        sheet=sheet,
        deductions=deductions,
        company_name=(p.get("companies") or {}).get("name", ""),
        project_name=p.get("name", ""),
        project_location=p.get("location"),
        tender_ref=p.get("tender_ref"),
        currency=p.get("currency") or "BTN",
        client_name=(terms[0].get("client_name") if terms else None),
        client_address=(terms[0].get("client_address") if terms else None),
    )
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{bill["bill_ref"]}.pdf"'},
    )


# ----------------------------------------------------------------
# Retention release (claiming back retention the client holds)
# ----------------------------------------------------------------

RELEASE_COLUMNS = ("id, release_no, status, amount, claim_date, stage, notes, received_date, "
                   "received_reference, cancel_reason, project_id")


def _release_row(r: dict) -> dict:
    return {**r, "release_ref": f"RR-{int(r['release_no']):02d}"}


def _get_release(user: CurrentUser, release_id: str) -> dict:
    found = user.client.table("client_retention_releases").select(RELEASE_COLUMNS).eq("id", release_id).execute().data
    if not found:
        raise HTTPException(status_code=404, detail="Retention claim not found.")
    return _release_row(found[0])


@router.get("/retention", response_model=RetentionOut)
def get_retention(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """What the client holds, what can still be claimed, and the claims so far."""
    position = user.client.rpc("fn_retention_position", {"p_project_id": project_id}).execute().data
    if not position:
        raise HTTPException(status_code=404, detail="Project not found, or you can't see its client bills.")
    releases = (
        user.client.table("client_retention_releases").select(RELEASE_COLUMNS)
        .eq("project_id", project_id).order("release_no", desc=True).execute().data
    )
    return {"position": position[0], "releases": [_release_row(r) for r in releases]}


@router.post("/retention", response_model=RetentionOut)
def claim_retention(payload: RetentionClaimIn, user: CurrentUser = Depends(get_current_user)):
    """Admins/Owners. Never more than is still held and not already claimed (enforced by trigger)."""
    body = payload.model_dump(mode="json", exclude_none=True)
    _run(user.client.table("client_retention_releases").insert({**body, "created_by": user.id}), on_denied=MANAGERS_ONLY)
    return get_retention(body["project_id"], user)


@router.post("/retention/{release_id}/received", response_model=RetentionOut)
def retention_received(release_id: str, payload: RetentionReceivedIn, user: CurrentUser = Depends(get_current_user)):
    """Admins, Owners and Cashiers: the client has paid the retention back."""
    release = _get_release(user, release_id)
    changes = {"status": "received", "received_reference": (payload.reference or "").strip() or None}
    if payload.received_date:
        changes["received_date"] = payload.received_date.isoformat()
    result = _run(
        user.client.table("client_retention_releases").update(changes).eq("id", release_id),
        on_denied="Only an Admin, Company Owner or Cashier can record retention as received.",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Only an Admin, Company Owner or Cashier can record retention as received.")
    return get_retention(release["project_id"], user)


@router.post("/retention/{release_id}/cancel", response_model=RetentionOut)
def cancel_retention(release_id: str, payload: CancelBillIn, user: CurrentUser = Depends(get_current_user)):
    """Admins/Owners, while the claim is open. The amount can be claimed again."""
    release = _get_release(user, release_id)
    _run(
        user.client.table("client_retention_releases")
        .update({"status": "cancelled", "cancel_reason": payload.reason.strip()}).eq("id", release_id),
        on_denied=MANAGERS_ONLY,
    )
    return get_retention(release["project_id"], user)


@router.get("/retention/{release_id}/pdf")
def get_retention_pdf(release_id: str, user: CurrentUser = Depends(get_current_user)):
    """The claim letter: the bills retention was deducted from, and the amount claimed."""
    release = _get_release(user, release_id)
    project_id = release["project_id"]
    retention = get_retention(project_id, user)
    bills = (
        user.client.table("v_client_bills")
        .select("bill_ref, bill_date, certified_date, gross_amount, retention_amount, status")
        .eq("project_id", project_id).in_("status", ["certified", "paid"]).order("bill_no").execute().data
    )
    project = (
        user.client.table("projects").select("name, location, currency, tender_ref, companies(name)")
        .eq("id", project_id).execute().data
    )
    terms = user.client.table("project_settings").select("client_name, client_address").eq("project_id", project_id).execute().data
    p = project[0] if project else {}
    pdf_bytes = generate_retention_claim_pdf(
        release=release,
        bills=bills,
        earlier=[r for r in retention["releases"] if r["release_no"] < release["release_no"] and r["status"] != "cancelled"],
        company_name=(p.get("companies") or {}).get("name", ""),
        project_name=p.get("name", ""),
        project_location=p.get("location"),
        tender_ref=p.get("tender_ref"),
        currency=p.get("currency") or "BTN",
        client_name=(terms[0].get("client_name") if terms else None),
        client_address=(terms[0].get("client_address") if terms else None),
    )
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{release["release_ref"]}.pdf"'},
    )
