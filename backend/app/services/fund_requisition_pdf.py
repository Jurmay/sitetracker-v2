# -*- coding: utf-8 -*-
"""
Generates the Fund Requisition approval PDF described in Phase 3:
amount, reason, cashbook snapshot at time of request, recent
disbursement activity, and Admin's approval signature/timestamp.

This PDF is only ever generated for an ALREADY-APPROVED fund
requisition - there is no "pending" variant, per the Phase 3 decision
to avoid Accounts ever receiving a document for money that might not
actually move. The caller (the approval endpoint) is responsible for
only invoking this after the status is genuinely 'approved'.
"""
import io
from datetime import datetime, timezone

from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle


def generate_fund_requisition_pdf(
    *,
    project_name: str,
    company_name: str,
    requested_by_name: str,
    approved_by_name: str,
    amount: float,
    currency: str,
    reason: str,
    requested_at: datetime,
    approved_at: datetime,
    cashbook_balance_before: float,
    cashbook_balance_after: float,
    total_fund_received_to_date: float,
    recent_disbursements: list[dict],  # [{date, description, amount}, ...] most recent first
) -> bytes:
    """Returns the rendered PDF as raw bytes, ready to attach to an email or save to disk."""

    buf = io.BytesIO()
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name="TitleCustom", parent=styles["Heading1"], fontSize=16, spaceAfter=4))
    styles.add(ParagraphStyle(name="SubtitleCustom", parent=styles["BodyText"], fontSize=10, textColor=colors.HexColor("#555555")))
    styles.add(ParagraphStyle(name="SectionHeading", parent=styles["Heading2"], fontSize=12, spaceBefore=14, spaceAfter=6))
    styles.add(ParagraphStyle(name="Body10", parent=styles["BodyText"], fontSize=10, leading=14))
    styles.add(ParagraphStyle(name="ApprovedStamp", parent=styles["BodyText"], fontSize=11,
                               textColor=colors.HexColor("#1a7a3c"), fontName="Helvetica-Bold"))

    story = []
    story.append(Paragraph("Fund Requisition &mdash; APPROVED", styles["TitleCustom"]))
    story.append(Paragraph(f"{company_name} &mdash; {project_name}", styles["SubtitleCustom"]))
    story.append(Spacer(1, 4))
    story.append(Paragraph(
        f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        ParagraphStyle(name="Tiny", parent=styles["Body10"], fontSize=8, textColor=colors.HexColor("#888888")),
    ))
    story.append(Spacer(1, 14))

    story.append(Paragraph("APPROVED", styles["ApprovedStamp"]))
    story.append(Spacer(1, 8))

    details_rows = [
        ["Requested by", requested_by_name],
        ["Requested at", requested_at.strftime("%Y-%m-%d %H:%M")],
        ["Approved by", approved_by_name],
        ["Approved at", approved_at.strftime("%Y-%m-%d %H:%M")],
        ["Amount", f"{currency} {amount:,.2f}"],
        ["Reason", reason],
    ]
    details_table = Table(
        [[Paragraph(f"<b>{k}</b>", styles["Body10"]), Paragraph(v, styles["Body10"])] for k, v in details_rows],
        colWidths=[1.6 * inch, 4.8 * inch],
    )
    details_table.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#D3D1C7")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#F2F1ED")),
    ]))
    story.append(details_table)

    story.append(Paragraph("Cashbook position", styles["SectionHeading"]))
    cashbook_rows = [
        ["Balance before this requisition", f"{currency} {cashbook_balance_before:,.2f}"],
        ["Balance after (once fund is received)", f"{currency} {cashbook_balance_after:,.2f}"],
        ["Total fund received to date (project lifetime)", f"{currency} {total_fund_received_to_date:,.2f}"],
    ]
    cashbook_table = Table(cashbook_rows, colWidths=[3.6 * inch, 2.8 * inch])
    cashbook_table.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#D3D1C7")),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("ROWBACKGROUNDS", (0, 0), (-1, -1), [colors.white, colors.HexColor("#F7F7F5")]),
    ]))
    story.append(cashbook_table)

    story.append(Paragraph("Recent disbursement activity", styles["SectionHeading"]))
    if recent_disbursements:
        disb_header = ["Date", "Description", "Amount"]
        disb_rows = [disb_header] + [
            [d["date"], d.get("description", ""), f"{currency} {d['amount']:,.2f}"]
            for d in recent_disbursements[:10]
        ]
        disb_table = Table(disb_rows, colWidths=[1.2 * inch, 3.8 * inch, 1.4 * inch], repeatRows=1)
        disb_table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#3C3489")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#D3D1C7")),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F7F7F5")]),
            ("LEFTPADDING", (0, 0), (-1, -1), 6),
            ("TOPPADDING", (0, 0), (-1, -1), 5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ("FONTSIZE", (0, 0), (-1, -1), 9),
        ]))
        story.append(disb_table)
    else:
        story.append(Paragraph("No disbursements recorded yet for this project.", styles["Body10"]))

    story.append(Spacer(1, 16))
    story.append(Paragraph(
        "This document was generated automatically upon approval and reflects the "
        "cashbook position at the time of approval. It is provided to the Accounts "
        "department as a record of an approved fund transfer.",
        ParagraphStyle(name="Footnote", parent=styles["Body10"], fontSize=8, textColor=colors.HexColor("#888888")),
    ))

    doc = SimpleDocTemplate(
        buf, pagesize=letter,
        leftMargin=0.75 * inch, rightMargin=0.75 * inch,
        topMargin=0.75 * inch, bottomMargin=0.75 * inch,
        title=f"Fund Requisition Approved - {project_name}",
    )
    doc.build(story)
    return buf.getvalue()
