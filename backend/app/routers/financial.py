# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException
from typing import List
from postgrest.exceptions import APIError

from app.core.deps import get_current_user, CurrentUser
from app.core.db_helpers import safe_execute
from app.schemas.financial import (
    SubcontractOut, SubcontractCreate, SubcontractBalanceOut,
    AdvanceRequisitionOut, AdvanceRequisitionCreate, RequisitionActionCreate,
    AdvanceSettlementOut, AdvanceSettlementCreate, SettlementActionCreate,
    CashbookOut, FundRequisitionOut, FundRequisitionCreate,
)

router = APIRouter()


# ----------------------------------------------------------------
# Subcontracts
# ----------------------------------------------------------------

@router.get("/subcontracts", response_model=List[SubcontractOut])
def list_subcontracts(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = user.client.table("subcontracts").select("*").eq("project_id", project_id).execute()
    return result.data


@router.post("/subcontracts", response_model=SubcontractOut)
def create_subcontract(payload: SubcontractCreate, user: CurrentUser = Depends(get_current_user)):
    data = payload.model_dump(mode="json")
    data["created_by"] = user.id
    result = safe_execute(
        user.client.table("subcontracts").insert(data),
        on_denied="Not permitted to create a subcontract on this project.",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to create a subcontract on this project.")
    return result.data[0]


@router.get("/subcontracts/balances", response_model=List[SubcontractBalanceOut])
def get_subcontract_balances(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Reads v_subcontract_balances (migration 003) - drawn vs earned vs
    net, computed live from settled advances + progress measurements.
    This is the Labour Advance Ledger view from Phase 3/8.
    """
    result = (
        user.client.table("v_subcontract_balances")
        .select("*")
        .eq("project_id", project_id)
        .execute()
    )
    return result.data


# ----------------------------------------------------------------
# Advance requisitions
# ----------------------------------------------------------------

@router.get("/advances", response_model=List[AdvanceRequisitionOut])
def list_advances(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Returns whatever this user's role is entitled to see, per RLS.
    Cashier/Admin/Company Owner see ALL requisitions in the project here
    (not just their own) - this is the exact thing test_rls.py checks for,
    and it's RLS doing the work, not a role check in this function.
    """
    result = user.client.table("advance_requisitions").select("*").eq("project_id", project_id).execute()
    return result.data


@router.post("/advances", response_model=AdvanceRequisitionOut)
def create_advance(payload: AdvanceRequisitionCreate, user: CurrentUser = Depends(get_current_user)):
    data = payload.model_dump(mode="json", exclude_none=True)
    data["requested_by"] = user.id

    generic_msg = (
        "Could not submit advance requisition. You must be an active Site "
        "Coordinator on this project."
    )
    result = safe_execute(
        user.client.table("advance_requisitions").insert(data),
        on_denied=generic_msg,
    )
    if result.data:
        return result.data[0]

    # The insert was denied by the RLS policy. Work out WHICH of the three
    # locks is active so we can tell the coordinator exactly what to fix,
    # instead of a vague catch-all. These are the same functions the policy
    # itself calls (fn_is_*_locked), so the answer here matches the real
    # reason the insert failed.
    #
    # Each returns a single boolean. We surface the first active lock with
    # a concrete, actionable instruction. If somehow none report active
    # (e.g. a role/permission issue rather than a lock), fall back to the
    # generic message.
    def _lock_active(fn_name: str) -> bool:
        try:
            res = user.client.rpc(
                fn_name,
                {"p_coordinator_id": user.id, "p_project_id": data["project_id"]},
            ).execute()
            return bool(res.data)
        except Exception:
            # If the check itself fails, don't block the error path - just
            # treat it as "unknown" and let the generic message stand.
            return False

    if _lock_active("fn_is_master_roll_locked"):
        detail = (
            "Blocked: today's Master Roll has not been submitted. Submit "
            "today's Master Roll first, then raise this advance."
        )
    elif _lock_active("fn_is_progress_report_locked"):
        detail = (
            "Blocked: today's Progress Report has not been submitted. Submit "
            "today's Progress Report first, then raise this advance."
        )
    elif _lock_active("fn_is_settlement_locked"):
        detail = (
            "Blocked: you have an advance that is past its settlement grace "
            "period and not yet fully settled. Settle the overdue advance "
            "first, then raise this one."
        )
    else:
        detail = generic_msg

    raise HTTPException(status_code=403, detail=detail)


@router.post("/advances/{requisition_id}/verify")
def verify_advance(requisition_id: str, payload: RequisitionActionCreate, user: CurrentUser = Depends(get_current_user)):
    """Cashier only. First step: pending_verification -> pending_approval."""
    return _insert_requisition_action(requisition_id, "verified", payload.remarks, user)


@router.post("/advances/{requisition_id}/approve")
def approve_advance(requisition_id: str, payload: RequisitionActionCreate, user: CurrentUser = Depends(get_current_user)):
    """Admin/Company Owner only. Second step: pending_approval -> approved."""
    return _insert_requisition_action(requisition_id, "approved", payload.remarks, user)


@router.post("/advances/{requisition_id}/disburse")
def disburse_advance(requisition_id: str, payload: RequisitionActionCreate, user: CurrentUser = Depends(get_current_user)):
    """Cashier only. Final step: approved -> disbursed. Cash actually leaves here."""
    return _insert_requisition_action(requisition_id, "disbursed", payload.remarks, user)


@router.post("/advances/{requisition_id}/reject")
def reject_advance(requisition_id: str, payload: RequisitionActionCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Cashier (at verification stage) or Admin (at approval stage) - both
    have a reject policy, RLS sorts out which stage based on the
    requisition's current status (the trigger rejects an out-of-stage
    attempt regardless of who's asking).
    """
    if not payload.remarks or not payload.remarks.strip():
        raise HTTPException(status_code=422, detail="A remark is required when rejecting a requisition.")
    return _insert_requisition_action(requisition_id, "rejected", payload.remarks, user)


# ----------------------------------------------------------------
# Settlements
# ----------------------------------------------------------------

@router.get("/settlements")
def list_settlements(project_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Returns settlements with their review remarks folded in.

    advance_settlement_actions has no timestamp column, so we do not sort
    by recency - settlement review is a single-step, terminal action per
    settlement, so at most one verified/rejected action is expected. If
    both were somehow present, rejection is treated as authoritative
    since it is the more consequential state.
    """
    result = (
        user.client.table("advance_settlements")
        .select("*, advance_settlement_actions(action_type, remarks)")
        .eq("project_id", project_id)
        .execute()
    )

    settlements = []
    for row in result.data:
        actions = row.pop("advance_settlement_actions", []) or []

        rejected = next((a for a in actions if a.get("action_type") == "rejected"), None)
        verified = next((a for a in actions if a.get("action_type") == "verified"), None)

        row["rejection_reason"] = rejected["remarks"] if rejected and rejected.get("remarks") else None
        row["cashier_note"] = verified["remarks"] if verified and verified.get("remarks") else None

        settlements.append(row)

    return settlements


@router.post("/settlements", response_model=AdvanceSettlementOut)
def submit_settlement(payload: AdvanceSettlementCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Partial settlements allowed - this can be called multiple times
    against the same requisition_id until the running total matches the
    original advance amount. The database enforces (via
    trg_check_settlement_total, migration 003) that the sum of all
    non-rejected settlements against one requisition can never exceed
    the original advance amount.

    Two distinct failure modes are handled separately here:
      - RLS silently returns zero rows (no exception) -> 403, permission issue.
      - The trigger raises a genuine Postgres exception (over-settlement
        attempt) -> caught explicitly and surfaced as 400 with the
        trigger's own message, since that message already states the
        amounts involved clearly.
    """
    data = payload.model_dump(mode="json")
    data["submitted_by"] = user.id
    try:
        result = user.client.table("advance_settlements").insert(data).execute()
    except APIError as e:
        # Two genuinely different failure shapes share this except block,
        # both raised as exceptions by postgrest-py (neither comes back
        # as an empty .data): an RLS denial (code 42501, e.g. not the
        # original requester) is a permissions issue (403); the
        # over-settlement trigger raising its own exception is a business-
        # rule rejection (400) whose message is already specific and
        # worth showing as-is.
        if e.code == "42501":
            raise HTTPException(
                status_code=403,
                detail="Not permitted to submit a settlement for this requisition (must be the original requester).",
            )
        raise HTTPException(status_code=400, detail=f"Settlement rejected: {e.message}")

    if not result.data:
        raise HTTPException(
            status_code=403,
            detail="Not permitted to submit a settlement for this requisition (must be the original requester).",
        )
    return result.data[0]


@router.post("/settlements/{settlement_id}/verify")
def verify_settlement(settlement_id: str, payload: SettlementActionCreate, user: CurrentUser = Depends(get_current_user)):
    """
    Cashier only, single-step (no Admin approval), per Phase 1/3 design.
    This is the action that triggers Actual Cost to update (via
    v_actual_cost_by_boq_item reading settled-status settlements live -
    there is no separate "post to ledger" step to call here).
    """
    data = {"settlement_id": settlement_id, "action_by": user.id, "action_type": "verified"}
    result = safe_execute(
        user.client.table("advance_settlement_actions").insert(data),
        on_denied="Not permitted to verify this settlement.",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to verify this settlement.")
    return result.data[0]


@router.post("/settlements/{settlement_id}/reject")
def reject_settlement(settlement_id: str, payload: SettlementActionCreate, user: CurrentUser = Depends(get_current_user)):
    if not payload.remarks or not payload.remarks.strip():
        raise HTTPException(status_code=422, detail="A remark is required when rejecting a settlement.")
    data = {"settlement_id": settlement_id, "action_by": user.id, "action_type": "rejected", "remarks": payload.remarks}
    result = safe_execute(
        user.client.table("advance_settlement_actions").insert(data),
        on_denied="Not permitted to reject this settlement.",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to reject this settlement.")
    return result.data[0]


# ----------------------------------------------------------------
# Cashbook & Fund Requisitions
# ----------------------------------------------------------------

@router.get("/cashbook", response_model=CashbookOut)
def get_cashbook(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = (
        user.client.table("v_cashbook_running_balance")
        .select("*")
        .eq("project_id", project_id)
        .execute()
    )
    if not result.data:
        raise HTTPException(status_code=404, detail="No cashbook data visible for this project.")
    return result.data[0]


@router.get("/fund-requisitions", response_model=List[FundRequisitionOut])
def list_fund_requisitions(project_id: str, user: CurrentUser = Depends(get_current_user)):
    result = user.client.table("fund_requisitions").select("*").eq("project_id", project_id).execute()
    return result.data


@router.post("/fund-requisitions", response_model=FundRequisitionOut)
def create_fund_requisition(payload: FundRequisitionCreate, user: CurrentUser = Depends(get_current_user)):
    """Cashier only (RLS freq_insert_cashier)."""
    data = payload.model_dump(mode="json")
    data["requested_by"] = user.id
    result = safe_execute(
        user.client.table("fund_requisitions").insert(data),
        on_denied="Not permitted to raise a fund requisition (Cashier only).",
    )
    if not result.data:
        raise HTTPException(status_code=403, detail="Not permitted to raise a fund requisition (Cashier only).")
    return result.data[0]


@router.post("/fund-requisitions/{fund_requisition_id}/approve")
def approve_fund_requisition(fund_requisition_id: str, user: CurrentUser = Depends(get_current_user)):
    """
    Admin only (RLS freq_update_admin). Full Phase 3 workflow:
      1. Mark the fund_requisition 'approved'.
      2. Record the fund_receipts row (the actual cash-in event).
      3. Snapshot the cashbook + recent disbursements for the PDF.
      4. Generate the approval PDF.
      5. Email it to the project's configured accounts_department_email
         (skipped gracefully, with a clear note, if none is configured).
      6. Stamp accounts_email_sent_at so this is auditable later.

    Per Phase 3: the PDF is generated and sent ONLY after approval,
    never in a pending state - this function's whole structure exists
    to guarantee that ordering, not just to bundle convenience.

    A failed email send does NOT roll back the approval or the
    fund_receipts row - the money movement and the approval are real
    regardless of whether the notification succeeded. The failure is
    surfaced in the response so the caller knows to follow up manually,
    rather than silently swallowing it.

    Returns the approved fund_requisitions row, plus an optional
    '_email_warning' key if the Accounts email could not be sent (e.g.
    no accounts_department_email configured, or Resend failed). No
    strict response_model here deliberately, since FundRequisitionOut
    doesn't have a slot for that warning field and silently dropping it
    would hide exactly the information this endpoint needs to surface.
    """
    from datetime import datetime, timezone
    from app.services.fund_requisition_pdf import generate_fund_requisition_pdf
    from app.services.email import send_email_with_pdf_attachment

    # 1. Fetch the requisition + its project + company context.
    req_result = (
        user.client.table("fund_requisitions").select("*").eq("id", fund_requisition_id).execute()
    )
    if not req_result.data:
        raise HTTPException(status_code=404, detail="Fund requisition not found or not visible to you.")
    requisition = req_result.data[0]

    if requisition["status"] != "pending_approval":
        raise HTTPException(
            status_code=409,
            detail=f"Cannot approve a fund requisition in status '{requisition['status']}'.",
        )

    project_result = (
        user.client.table("projects").select("*, project_settings(accounts_department_email)")
        .eq("id", requisition["project_id"]).execute()
    )
    if not project_result.data:
        raise HTTPException(status_code=404, detail="Project not found.")
    project = project_result.data[0]

    company_result = user.client.table("companies").select("name, currency").eq("id", project["company_id"]).execute()
    company_name = company_result.data[0]["name"] if company_result.data else "Unknown Company"
    currency = company_result.data[0]["currency"] if company_result.data else "BTN"

    requester_result = user.client.table("profiles").select("name").eq("id", requisition["requested_by"]).execute()
    requester_name = requester_result.data[0]["name"] if requester_result.data else "Unknown"

    approver_result = user.client.table("profiles").select("name").eq("id", user.id).execute()
    approver_name = approver_result.data[0]["name"] if approver_result.data else "Unknown"

    # 2. Cashbook snapshot BEFORE the new fund receipt is recorded.
    cashbook_before_result = (
        user.client.table("v_cashbook_running_balance").select("*").eq("project_id", project["id"]).execute()
    )
    balance_before = cashbook_before_result.data[0]["current_balance"] if cashbook_before_result.data else 0
    total_received_before = cashbook_before_result.data[0]["total_fund_receipts"] if cashbook_before_result.data else 0

    # 3. Approve the requisition.
    now = datetime.now(timezone.utc)
    approve_result = safe_execute(
        user.client.table("fund_requisitions")
        .update({"status": "approved", "approved_by": user.id, "approved_at": now.isoformat()})
        .eq("id", fund_requisition_id),
        on_denied="Not permitted to approve this fund requisition.",
    )
    if not approve_result.data:
        raise HTTPException(status_code=403, detail="Not permitted to approve this fund requisition.")
    approved_requisition = approve_result.data[0]

    # 4. Record the actual fund_receipts row - this IS the cash-in event.
    receipt_result = user.client.table("fund_receipts").insert({
        "project_id": project["id"],
        "amount": requisition["amount"],
        "source": "head_office",
        "recorded_by": user.id,
    }).execute()
    receipt_id = receipt_result.data[0]["id"] if receipt_result.data else None
    if receipt_id:
        user.client.table("fund_requisitions").update({"fund_receipt_id": receipt_id}).eq("id", fund_requisition_id).execute()

    # 5. Recent disbursements for the PDF context.
    disbursements_result = (
        user.client.table("advance_requisitions")
        .select("amount, justification, created_at")
        .eq("project_id", project["id"])
        .eq("status", "disbursed")
        .order("created_at", desc=True)
        .limit(10)
        .execute()
    )
    recent_disbursements = [
        {"date": d["created_at"][:10], "description": d.get("justification", ""), "amount": d["amount"]}
        for d in disbursements_result.data
    ]

    # 6. Generate the PDF.
    pdf_bytes = generate_fund_requisition_pdf(
        project_name=project["name"],
        company_name=company_name,
        requested_by_name=requester_name,
        approved_by_name=approver_name,
        amount=requisition["amount"],
        currency=currency,
        reason=requisition["reason"],
        requested_at=datetime.fromisoformat(requisition["created_at"]),
        approved_at=now,
        cashbook_balance_before=balance_before,
        cashbook_balance_after=balance_before + requisition["amount"],
        total_fund_received_to_date=total_received_before + requisition["amount"],
        recent_disbursements=recent_disbursements,
    )

    # 7. Email to Accounts, if configured. Per-project, not company-wide (Phase 3 decision).
    accounts_email = None
    settings_blob = project.get("project_settings")
    if settings_blob:
        accounts_email = (settings_blob[0] if isinstance(settings_blob, list) else settings_blob).get("accounts_department_email")

    email_warning = None
    if not accounts_email:
        email_warning = (
            "No accounts_department_email configured for this project - the approval "
            "PDF was generated but NOT emailed. Set this in Project Configuration."
        )
    else:
        try:
            send_email_with_pdf_attachment(
                to=accounts_email,
                subject=f"Fund Requisition Approved - {project['name']} - {currency} {requisition['amount']:,.2f}",
                body_text=(
                    f"A fund requisition for {project['name']} has been approved by {approver_name}. "
                    f"See the attached PDF for full details."
                ),
                pdf_bytes=pdf_bytes,
                pdf_filename=f"fund_requisition_{fund_requisition_id}.pdf",
            )
            user.client.table("fund_requisitions").update(
                {"accounts_email_sent_at": datetime.now(timezone.utc).isoformat()}
            ).eq("id", fund_requisition_id).execute()
        except Exception as e:
            # Per the docstring above: do NOT roll back the approval/receipt for
            # a failed send. Surface it so the caller knows to follow up.
            email_warning = f"Approval succeeded but the Accounts email failed to send: {e}"

    response = dict(approved_requisition)
    if email_warning:
        response["_email_warning"] = email_warning
    return response


# ----------------------------------------------------------------
# KNOWN GAPS in this pass (flagged, not silently skipped):
#
# 1. No enforcement yet that sum(settled_amount) for a requisition
#    cannot exceed the original advance amount. Needs either a
#    check-on-insert query in this router or a database trigger.
#
# (Gap 2 - fund requisition PDF/email/fund_receipts - resolved:
#  see approve_fund_requisition above, plus app/services/
#  fund_requisition_pdf.py and app/services/email.py)
# ----------------------------------------------------------------
