# -*- coding: utf-8 -*-
"""
Generic CSV report generator - the "download as spreadsheet" counterpart
to report_pdf.py. CSV rather than true .xlsx: every spreadsheet app
(Excel, Sheets, LibreOffice) opens CSV natively, and the report data
here is plain tabular values with no formulas, multi-sheet structure,
or formatting that would justify the added complexity of a real .xlsx
writer library on the backend. If a future report genuinely needs
multi-sheet structure or in-cell formulas, that's a deliberate
escalation point, not a default to reach for now.
"""
import csv
import io


def generate_tabular_report_csv(*, columns: list[str], rows: list[list[str]]) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(columns)
    writer.writerows(rows)
    return buf.getvalue()
