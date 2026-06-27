# -*- coding: utf-8 -*-
"""
Generic tabular report PDF generator. Deliberately generic rather than
one bespoke generator per report (15 of them per report_definitions,
migration 004) - every report in that list reduces to the same shape:
a title, some context lines, and a table of rows. Visual style mirrors
fund_requisition_pdf.py (the one hand-styled, visually-verified document
this app has produced so far), so reports look like they belong to the
same product rather than introducing a second, divergent style.
"""
import io
from datetime import datetime, timezone

from reportlab.lib.pagesizes import letter, landscape
from reportlab.lib.units import inch
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle


def generate_tabular_report_pdf(
    *,
    report_title: str,
    project_name: str,
    company_name: str,
    generated_by_name: str,
    columns: list[str],
    rows: list[list[str]],
    landscape_mode: bool = False,
) -> bytes:
    """
    columns: header labels, in display order.
    rows: each inner list must have the same length as columns; all
    values are pre-formatted strings by the caller (currency symbols,
    date formatting, etc.) - this function does no formatting of its
    own, since formatting rules differ per report (e.g. a quantity
    column vs. a currency column) and are the caller's responsibility.
    """
    buf = io.BytesIO()
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name="TitleCustom", parent=styles["Heading1"], fontSize=16, spaceAfter=4))
    styles.add(ParagraphStyle(name="SubtitleCustom", parent=styles["BodyText"], fontSize=10, textColor=colors.HexColor("#555555")))
    styles.add(ParagraphStyle(name="Tiny", parent=styles["BodyText"], fontSize=8, textColor=colors.HexColor("#888888")))
    styles.add(ParagraphStyle(name="Footnote", parent=styles["BodyText"], fontSize=8, textColor=colors.HexColor("#888888")))

    story = []
    story.append(Paragraph(report_title, styles["TitleCustom"]))
    story.append(Paragraph(f"{company_name} &mdash; {project_name}", styles["SubtitleCustom"]))
    story.append(Paragraph(
        f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by {generated_by_name}",
        styles["Tiny"],
    ))
    story.append(Spacer(1, 14))

    if rows:
        table_data = [columns] + rows
        available_width = (10.0 if landscape_mode else 7.0) * inch
        col_width = available_width / len(columns)
        table = Table(table_data, colWidths=[col_width] * len(columns), repeatRows=1)
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#3C3489")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#D3D1C7")),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F7F7F5")]),
            ("LEFTPADDING", (0, 0), (-1, -1), 6),
            ("TOPPADDING", (0, 0), (-1, -1), 5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ("FONTSIZE", (0, 0), (-1, -1), 8),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ]))
        story.append(table)
    else:
        story.append(Paragraph("No data available for this report.", styles["SubtitleCustom"]))

    story.append(Spacer(1, 16))
    story.append(Paragraph(
        "This report reflects data visible to the generating user at the time of "
        "generation, subject to that user's role and report permissions.",
        styles["Footnote"],
    ))

    page_size = landscape(letter) if landscape_mode else letter
    doc = SimpleDocTemplate(
        buf, pagesize=page_size,
        leftMargin=0.6 * inch, rightMargin=0.6 * inch,
        topMargin=0.75 * inch, bottomMargin=0.75 * inch,
        title=f"{report_title} - {project_name}",
    )
    doc.build(story)
    return buf.getvalue()
