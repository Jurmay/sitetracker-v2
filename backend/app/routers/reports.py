# -*- coding: utf-8 -*-
from fastapi import APIRouter, Depends, HTTPException, Response
from typing import Optional

from app.core.deps import get_current_user, CurrentUser
from app.services.report_registry import REPORT_REGISTRY, NEEDS_DATE_RANGE, REPORT_TITLES
from app.services.report_pdf import generate_tabular_report_pdf
from app.services.report_csv import generate_tabular_report_csv

router = APIRouter()


def _check_granted(user: CurrentUser, project_id: str, report_key: str):
    """
    Re-checks the user's own grant before running the report query, on
    top of whatever RLS already restricts at the table level. This
    matters because some report queries join across tables where RLS
    alone wouldn't necessarily produce "nothing" for an ungranted user
    (e.g. a Site Coordinator's own progress_reports rows are visible to
    them regardless of report grants) - the grant check is what
    actually enforces "you may use the *report* feature for this key",
    distinct from "you may see the underlying rows" at all.
    """
    result = (
        user.client.table("user_report_permissions")
        .select("granted, report_definitions!inner(key)")
        .eq("project_id", project_id)
        .eq("user_id", user.id)
        .eq("report_definitions.key", report_key)
        .execute()
    )
    if not result.data or not result.data[0]["granted"]:
        raise HTTPException(status_code=403, detail=f"You are not granted access to the '{report_key}' report.")


def _run_report(user: CurrentUser, project_id: str, report_key: str, date_from: Optional[str], date_to: Optional[str]):
    if report_key not in REPORT_REGISTRY:
        raise HTTPException(
            status_code=404,
            detail=f"'{report_key}' is not yet implemented as a downloadable report.",
        )
    _check_granted(user, project_id, report_key)

    fn = REPORT_REGISTRY[report_key]
    if report_key in NEEDS_DATE_RANGE:
        if not date_from or not date_to:
            raise HTTPException(status_code=422, detail="date_from and date_to are required for this report.")
        columns, rows = fn(user.client, project_id, date_from, date_to)
    else:
        columns, rows = fn(user.client, project_id)
    return columns, rows


@router.get("/{report_key}/data")
def get_report_data(
    report_key: str, project_id: str,
    date_from: Optional[str] = None, date_to: Optional[str] = None,
    user: CurrentUser = Depends(get_current_user),
):
    """JSON shape, for the frontend to render an on-screen preview table before download."""
    columns, rows = _run_report(user, project_id, report_key, date_from, date_to)
    return {"title": REPORT_TITLES.get(report_key, report_key), "columns": columns, "rows": rows}


@router.get("/{report_key}/pdf")
def get_report_pdf(
    report_key: str, project_id: str,
    date_from: Optional[str] = None, date_to: Optional[str] = None,
    user: CurrentUser = Depends(get_current_user),
):
    columns, rows = _run_report(user, project_id, report_key, date_from, date_to)

    project = user.client.table("projects").select("name, companies(name)").eq("id", project_id).execute()
    if not project.data:
        raise HTTPException(status_code=404, detail="Project not found.")
    project_name = project.data[0]["name"]
    company_name = (project.data[0].get("companies") or {}).get("name", "")

    pdf_bytes = generate_tabular_report_pdf(
        report_title=REPORT_TITLES.get(report_key, report_key),
        project_name=project_name,
        company_name=company_name,
        generated_by_name=user.email,
        columns=columns,
        rows=rows,
        landscape_mode=len(columns) > 5,
    )
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{report_key}.pdf"'},
    )


@router.get("/{report_key}/csv")
def get_report_csv(
    report_key: str, project_id: str,
    date_from: Optional[str] = None, date_to: Optional[str] = None,
    user: CurrentUser = Depends(get_current_user),
):
    columns, rows = _run_report(user, project_id, report_key, date_from, date_to)
    csv_text = generate_tabular_report_csv(columns=columns, rows=rows)
    return Response(
        content=csv_text,
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{report_key}.csv"'},
    )
