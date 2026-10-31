# -*- coding: utf-8 -*-
"""
Running account (RA) bill PDF, to submit to the client: the abstract of
work done per BOQ item (previous / this bill / up to date) and the
amount payable after retention, TDS, advance recovery and other
deductions. Drafts and cancelled bills are clearly marked.
"""
import io
from datetime import datetime
from itertools import groupby
from xml.sax.saxutils import escape

from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

from app.services.purchase_order_pdf import BHUTAN_TIME, _money, _qty, _date

STATUS_BANNER = {
    "draft": ("DRAFT - NOT SUBMITTED", "#B62F1C"),
    "cancelled": ("CANCELLED", "#B62F1C"),
}


def _pct(value) -> str:
    return f"{float(value or 0):g}%"


def generate_client_bill_pdf(
    *,
    bill: dict,
    sheet: list[dict],
    deductions: list[dict],
    company_name: str,
    project_name: str,
    project_location: str | None,
    tender_ref: str | None,
    currency: str,
    client_name: str | None,
    client_address: str | None,
) -> bytes:
    buf = io.BytesIO()
    styles = getSampleStyleSheet()
    body = ParagraphStyle(name="Body8", parent=styles["BodyText"], fontSize=8, leading=10)
    info = ParagraphStyle(name="Info9", parent=body, fontSize=9, leading=12)
    small = ParagraphStyle(name="Small", parent=body, fontSize=7, textColor=colors.HexColor("#666666"))
    title = ParagraphStyle(name="BillTitle", parent=styles["Heading1"], fontSize=16, spaceAfter=2)
    label = ParagraphStyle(name="Label", parent=info, fontName="Helvetica-Bold")

    story = []
    story.append(Paragraph(escape(company_name), ParagraphStyle(name="Co", parent=info, fontSize=11, fontName="Helvetica-Bold")))
    final = " (FINAL)" if bill.get("is_final") else ""
    story.append(Paragraph(f"RUNNING ACCOUNT BILL {escape(bill['bill_ref'])}{final}", title))
    banner = STATUS_BANNER.get(bill["status"])
    if banner:
        story.append(Paragraph(banner[0], ParagraphStyle(name="Banner", parent=info, fontSize=12,
                                                         fontName="Helvetica-Bold", textColor=colors.HexColor(banner[1]))))
    story.append(Spacer(1, 4 * mm))

    def block(lines_):
        return Paragraph("<br/>".join(escape(str(x)) for x in lines_ if x), info)

    header = Table(
        [[Paragraph("Client", label), Paragraph("Work", label), Paragraph("Bill", label)],
         [block([client_name or "-", client_address]),
          block([project_name, project_location, tender_ref and f"Tender / contract: {tender_ref}"]),
          block([f"Bill date: {_date(bill['bill_date'])}",
                 f"Work measured up to: {_date(bill['period_to'])}",
                 bill.get("certificate_ref") and f"Client certificate: {bill['certificate_ref']}"])]],
        colWidths=[85 * mm, 105 * mm, 77 * mm],
    )
    header.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LINEBELOW", (0, 0), (-1, 0), 0.5, colors.HexColor("#999999")),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    story.append(header)
    story.append(Spacer(1, 5 * mm))

    # Abstract: only items with work billed up to date.
    billed = [r for r in sheet if float(r["cumulative_quantity"] or 0) > 0]
    rows = [
        ["#", "Description", "Unit", "BOQ qty", f"Rate ({currency})",
         "Quantity", "", "", f"Amount ({currency})", "", ""],
        ["", "", "", "", "", "Previous", "This bill", "Up to date", "Previous", "This bill", "Up to date"],
    ]
    section_rows = []
    n = 0
    for section, items in groupby(billed, key=lambda r: r["section_name"]):
        section_rows.append(len(rows))
        rows.append(["", Paragraph(f"<b>{escape(section)}</b>", body), "", "", "", "", "", "", "", "", ""])
        for r in items:
            n += 1
            rows.append([str(n), Paragraph(escape(r["description"]), body), r["unit"], _qty(r["boq_quantity"]),
                         _money(r["rate"]), _qty(r["previous_quantity"]), _qty(r["this_quantity"]),
                         _qty(r["cumulative_quantity"]), _money(r["previous_amount"]), _money(r["this_amount"]),
                         _money(r["cumulative_amount"])])
    rows.append(["", Paragraph("<b>Value of work</b>", body), "", "", "", "", "", "",
                 _money(sum(float(r["previous_amount"] or 0) for r in billed)),
                 _money(bill["gross_amount"]),
                 _money(sum(float(r["cumulative_amount"] or 0) for r in billed))])

    table = Table(rows, colWidths=[7 * mm, 88 * mm, 13 * mm, 17 * mm, 20 * mm, 17 * mm, 17 * mm, 17 * mm,
                                   24 * mm, 24 * mm, 24 * mm], repeatRows=2)
    style = [
        ("FONTNAME", (0, 0), (-1, 1), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 8),
        ("BACKGROUND", (0, 0), (-1, 1), colors.HexColor("#EDE7DC")),
        ("SPAN", (5, 0), (7, 0)), ("SPAN", (8, 0), (10, 0)),
        *[("SPAN", (c, 0), (c, 1)) for c in range(5)],
        ("VALIGN", (0, 0), (4, 1), "MIDDLE"),
        ("ALIGN", (5, 0), (-1, 0), "CENTER"),
        ("GRID", (0, 0), (-1, -2), 0.4, colors.HexColor("#BBBBBB")),
        ("LINEABOVE", (0, -1), (-1, -1), 1, colors.black),
        ("FONTNAME", (8, -1), (-1, -1), "Helvetica-Bold"),
        ("ALIGN", (3, 1), (-1, -1), "RIGHT"),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]
    for i in section_rows:
        style += [("SPAN", (1, i), (-1, i)), ("BACKGROUND", (0, i), (-1, i), colors.HexColor("#F6F3EE"))]
    table.setStyle(TableStyle(style))
    story.append(table)
    story.append(Spacer(1, 5 * mm))

    # Amount payable on this bill.
    pay = [["Gross value of work this bill", _money(bill["gross_amount"])]]
    if float(bill["retention_amount"] or 0):
        pay.append([f"Less retention @ {_pct(bill.get('retention_pct'))}", f"({_money(bill['retention_amount'])})"])
    if float(bill["tds_amount"] or 0):
        pay.append([f"Less tax deducted at source @ {_pct(bill.get('tds_pct'))}", f"({_money(bill['tds_amount'])})"])
    if float(bill["advance_recovery"] or 0):
        pay.append(["Less recovery of mobilisation advance", f"({_money(bill['advance_recovery'])})"])
    for d in deductions:
        pay.append([f"Less {d['description']}", f"({_money(d['amount'])})"])
    pay.append([f"Net amount payable ({currency})", _money(bill["net_amount"])])
    if bill.get("certified_amount") is not None and bill["status"] in ("certified", "paid"):
        pay.append([f"Certified by client on {_date(bill.get('certified_date'))}", _money(bill["certified_amount"])])
    summary = Table([[Paragraph(escape(a), info), b] for a, b in pay], colWidths=[110 * mm, 35 * mm], hAlign="RIGHT")
    net_row = len(pay) - (2 if bill.get("certified_amount") is not None and bill["status"] in ("certified", "paid") else 1)
    summary.setStyle(TableStyle([
        ("ALIGN", (1, 0), (1, -1), "RIGHT"),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("LINEABOVE", (0, net_row), (-1, net_row), 1, colors.black),
        ("FONTNAME", (1, net_row), (1, net_row), "Helvetica-Bold"),
    ]))
    story.append(KeepTogether([summary]))

    if bill.get("notes"):
        story.append(Spacer(1, 4 * mm))
        story.append(Paragraph("Notes", label))
        story.append(Paragraph(escape(bill["notes"]).replace("\n", "<br/>"), info))
    if bill["status"] == "cancelled":
        story.append(Spacer(1, 4 * mm))
        story.append(Paragraph(f"Cancelled: {escape(bill.get('cancel_reason') or '')}", info))

    story.append(Spacer(1, 14 * mm))
    signs = Table([["_________________________", "_________________________", "_________________________"],
                   ["Contractor", "Measured & checked (Site Engineer)", "Certified for payment"]],
                  colWidths=[89 * mm, 89 * mm, 89 * mm])
    signs.setStyle(TableStyle([("FONTSIZE", (0, 0), (-1, -1), 9), ("ALIGN", (0, 0), (-1, -1), "CENTER")]))
    story.append(KeepTogether([signs]))
    story.append(Spacer(1, 5 * mm))
    story.append(Paragraph(
        f"Rates as per the accepted BOQ (inclusive of taxes). "
        f"Generated {datetime.now(BHUTAN_TIME).strftime('%Y-%m-%d %H:%M BTT')}.", small))

    SimpleDocTemplate(buf, pagesize=landscape(A4), leftMargin=12 * mm, rightMargin=12 * mm,
                      topMargin=12 * mm, bottomMargin=12 * mm,
                      title=f"Running account bill {bill['bill_ref']}").build(story)
    return buf.getvalue()


def generate_retention_claim_pdf(
    *,
    release: dict,
    bills: list[dict],
    earlier: list[dict],
    company_name: str,
    project_name: str,
    project_location: str | None,
    tender_ref: str | None,
    currency: str,
    client_name: str | None,
    client_address: str | None,
) -> bytes:
    """
    Claim for release of retention (RR-01, RR-02..): retention deducted on
    each certified bill, what was released before, and the amount claimed.
    """
    buf = io.BytesIO()
    styles = getSampleStyleSheet()
    body = ParagraphStyle(name="RBody", parent=styles["BodyText"], fontSize=10, leading=14)
    small = ParagraphStyle(name="RSmall", parent=body, fontSize=8, textColor=colors.HexColor("#666666"))
    title = ParagraphStyle(name="RTitle", parent=styles["Heading1"], fontSize=16, spaceAfter=2)
    label = ParagraphStyle(name="RLabel", parent=body, fontName="Helvetica-Bold")

    story = [
        Paragraph(escape(company_name), ParagraphStyle(name="RCo", parent=body, fontSize=11, fontName="Helvetica-Bold")),
        Paragraph(f"CLAIM FOR RELEASE OF RETENTION {escape(release['release_ref'])}", title),
    ]
    if release["status"] == "cancelled":
        story.append(Paragraph("CANCELLED", ParagraphStyle(name="RBan", parent=body, fontSize=12,
                                                           fontName="Helvetica-Bold", textColor=colors.HexColor("#B62F1C"))))
    story.append(Spacer(1, 5 * mm))

    def block(lines_):
        return Paragraph("<br/>".join(escape(str(x)) for x in lines_ if x), body)

    header = Table(
        [[Paragraph("To", label), Paragraph("Work", label)],
         [block([client_name or "-", client_address]),
          block([project_name, project_location, tender_ref and f"Tender / contract: {tender_ref}",
                 f"Date of claim: {_date(release['claim_date'])}", release.get("stage") and f"Stage: {release['stage']}"])]],
        colWidths=[85 * mm, 95 * mm],
    )
    header.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"),
                                ("LINEBELOW", (0, 0), (-1, 0), 0.5, colors.HexColor("#999999"))]))
    story += [header, Spacer(1, 6 * mm)]

    rows = [["Bill", "Certified on", f"Value of work ({currency})", f"Retention deducted ({currency})"]]
    for b in bills:
        rows.append([b["bill_ref"], _date(b.get("certified_date") or b.get("bill_date")),
                     _money(b["gross_amount"]), _money(b["retention_amount"])])
    withheld = sum(float(b["retention_amount"] or 0) for b in bills)
    rows.append([Paragraph("<b>Total retention deducted</b>", body), "", "", _money(withheld)])
    table = Table(rows, colWidths=[30 * mm, 35 * mm, 55 * mm, 60 * mm], repeatRows=1)
    table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"), ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EDE7DC")),
        ("GRID", (0, 0), (-1, -2), 0.4, colors.HexColor("#BBBBBB")),
        ("LINEABOVE", (0, -1), (-1, -1), 1, colors.black), ("SPAN", (0, -1), (2, -1)),
        ("FONTNAME", (-1, -1), (-1, -1), "Helvetica-Bold"),
        ("ALIGN", (2, 0), (-1, -1), "RIGHT"), ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story += [table, Spacer(1, 5 * mm)]

    released_before = sum(float(r["amount"]) for r in earlier)
    summary = [["Total retention deducted", _money(withheld)]]
    for r in earlier:
        word = "released" if r["status"] == "received" else "claimed"
        summary.append([f"Less {r['release_ref']} {word} on {_date(r.get('received_date') or r['claim_date'])}", f"({_money(r['amount'])})"])
    summary.append(["Retention still held", _money(withheld - released_before)])
    summary.append([f"Amount claimed now ({currency})", _money(release["amount"])])
    st = Table([[Paragraph(escape(a), body), b] for a, b in summary], colWidths=[120 * mm, 45 * mm], hAlign="RIGHT")
    st.setStyle(TableStyle([("ALIGN", (1, 0), (1, -1), "RIGHT"),
                            ("LINEABOVE", (0, -1), (-1, -1), 1, colors.black),
                            ("FONTNAME", (1, -1), (1, -1), "Helvetica-Bold")]))
    story.append(KeepTogether([st]))

    if release.get("notes"):
        story += [Spacer(1, 4 * mm), Paragraph(escape(release["notes"]).replace("\n", "<br/>"), body)]
    if release["status"] == "received":
        story += [Spacer(1, 4 * mm), Paragraph(
            f"Received on {_date(release.get('received_date'))}"
            + (f", reference {escape(release['received_reference'])}" if release.get("received_reference") else "") + ".", body)]
    if release["status"] == "cancelled":
        story += [Spacer(1, 4 * mm), Paragraph(f"Cancelled: {escape(release.get('cancel_reason') or '')}", body)]

    story += [Spacer(1, 16 * mm), Paragraph("_______________________________<br/>Contractor", body), Spacer(1, 6 * mm),
              Paragraph(f"Generated {datetime.now(BHUTAN_TIME).strftime('%Y-%m-%d %H:%M BTT')}.", small)]

    SimpleDocTemplate(buf, pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm, topMargin=15 * mm, bottomMargin=15 * mm,
                      title=f"Retention claim {release['release_ref']}").build(story)
    return buf.getvalue()
