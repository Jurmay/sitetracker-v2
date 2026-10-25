# -*- coding: utf-8 -*-
"""
Purchase order PDF, to send to the supplier. Drafts and cancelled POs
are clearly marked so they can't be mistaken for a live order.
"""
import io
from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

BHUTAN_TIME = timezone(timedelta(hours=6), "BTT")  # no daylight saving

STATUS_BANNER = {
    "draft": ("DRAFT - NOT AN ORDER", "#B62F1C"),
    "cancelled": ("CANCELLED", "#B62F1C"),
}


def _money(value) -> str:
    return f"{float(value or 0):,.2f}"


def _qty(value) -> str:
    return f"{float(value or 0):,.3f}".rstrip("0").rstrip(".")


def _date(value) -> str:
    if not value:
        return "-"
    return datetime.fromisoformat(str(value)[:10]).strftime("%d %b %Y")


def generate_purchase_order_pdf(
    *,
    order: dict,
    lines: list[dict],
    supplier: dict,
    company_name: str,
    project_name: str,
    project_location: str | None,
    currency: str,
    issued_by_name: str | None,
) -> bytes:
    buf = io.BytesIO()
    styles = getSampleStyleSheet()
    body = ParagraphStyle(name="Body9", parent=styles["BodyText"], fontSize=9, leading=12)
    small = ParagraphStyle(name="Small", parent=body, fontSize=8, textColor=colors.HexColor("#666666"))
    title = ParagraphStyle(name="POTitle", parent=styles["Heading1"], fontSize=18, spaceAfter=2)
    label = ParagraphStyle(name="Label", parent=body, fontName="Helvetica-Bold")

    story = []
    story.append(Paragraph(escape(company_name), ParagraphStyle(name="Co", parent=body, fontSize=11, fontName="Helvetica-Bold")))
    story.append(Paragraph(f"PURCHASE ORDER {escape(order['po_number'])}", title))
    banner = STATUS_BANNER.get(order["status"])
    if banner:
        story.append(Paragraph(banner[0], ParagraphStyle(name="Banner", parent=body, fontSize=12,
                                                         fontName="Helvetica-Bold", textColor=colors.HexColor(banner[1]))))
    story.append(Spacer(1, 6 * mm))

    def block(lines_):
        return Paragraph("<br/>".join(escape(str(x)) for x in lines_ if x), body)

    supplier_block = block([
        supplier.get("name"),
        supplier.get("contact_person") and f"Attn: {supplier['contact_person']}",
        supplier.get("address"),
        supplier.get("phone") and f"Phone: {supplier['phone']}",
        supplier.get("email") and f"Email: {supplier['email']}",
        supplier.get("tpn") and f"TPN: {supplier['tpn']}",
    ])
    order_block = block([
        f"Order date: {_date(order['order_date'])}",
        f"Deliver by: {_date(order.get('expected_date'))}",
        f"Project: {project_name}",
        f"Deliver to: {order.get('delivery_address') or project_location or project_name}",
    ])
    header = Table(
        [[Paragraph("Supplier", label), Paragraph("Order", label)], [supplier_block, order_block]],
        colWidths=[90 * mm, 90 * mm],
    )
    header.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LINEBELOW", (0, 0), (-1, 0), 0.5, colors.HexColor("#999999")),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    story.append(header)
    story.append(Spacer(1, 6 * mm))

    rows = [["#", "Description", "Unit", "Qty", f"Rate ({currency})", f"Amount ({currency})"]]
    for ln in lines:
        desc = escape(ln["description"])
        if ln.get("boq_description"):
            desc += f"<br/><font size=7 color='#666666'>BOQ: {escape(ln['boq_description'])}</font>"
        rows.append([str(ln["line_no"]), Paragraph(desc, body), ln["unit"], _qty(ln["ordered_qty"]),
                     _money(ln["rate"]), _money(ln["amount"])])
    total = sum(float(ln["amount"] or 0) for ln in lines)
    rows.append(["", Paragraph("<b>Total</b>", body), "", "", "", _money(total)])

    table = Table(rows, colWidths=[8 * mm, 78 * mm, 16 * mm, 20 * mm, 26 * mm, 32 * mm], repeatRows=1)
    table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EDE7DC")),
        ("GRID", (0, 0), (-1, -2), 0.4, colors.HexColor("#BBBBBB")),
        ("LINEABOVE", (0, -1), (-1, -1), 1, colors.black),
        ("FONTNAME", (-1, -1), (-1, -1), "Helvetica-Bold"),
        ("ALIGN", (3, 0), (-1, -1), "RIGHT"),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story.append(table)

    if order.get("notes"):
        story.append(Spacer(1, 5 * mm))
        story.append(Paragraph("Notes", label))
        story.append(Paragraph(escape(order["notes"]).replace("\n", "<br/>"), body))

    story.append(Spacer(1, 14 * mm))
    if order["status"] == "cancelled":
        story.append(Paragraph(f"Cancelled: {escape(order.get('cancel_reason') or '')}", body))
    elif order.get("issued_at"):
        story.append(Paragraph(
            f"Issued by {escape(issued_by_name or '-')} on {_date(order['issued_at'])}", body))
    story.append(Spacer(1, 12 * mm))
    story.append(Paragraph("_______________________________<br/>Authorised signature", body))
    story.append(Spacer(1, 6 * mm))
    story.append(Paragraph(
        f"Please quote {escape(order['po_number'])} on your delivery note and invoice. "
        f"Generated {datetime.now(BHUTAN_TIME).strftime('%Y-%m-%d %H:%M BTT')}.", small))

    SimpleDocTemplate(buf, pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm,
                      topMargin=15 * mm, bottomMargin=15 * mm,
                      title=f"Purchase order {order['po_number']}").build(story)
    return buf.getvalue()
