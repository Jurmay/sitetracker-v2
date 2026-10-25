# -*- coding: utf-8 -*-
"""Parser tests for the tender BOQ import (app/services/boq_import.py)."""
import io
import unittest

from openpyxl import Workbook

from app.services.boq_import import parse_boq_xlsx, BoqImportError

HEADER = ["Sl.", "Work", "Description", "Unit", "Qty", "Rate (Nu.)", "Amount (Nu.)", "BSR basis / note"]


def workbook(lines, title="BILL OF QUANTITIES: Bailey bridge at Bukay", gst="N", tail=()):
    """Same layout as the tender dashboard's BOQ_Pricing.xlsx."""
    wb = Workbook()
    ws = wb.active
    ws.title = "BOQ"
    ws.append([title])
    ws.append(["NIT DAS/Engg-12/2026-27/2133 · Bidder: DRUKAR Private Limited · Priced at BSR 2025 (PL column)"])
    ws.append([])
    ws.append(["GST registered? (Y/N)", gst])
    ws.append([])
    ws.append(HEADER)
    for i, line in enumerate(lines, start=7):
        ws.append(list(line) + [f"=ROUND(E{i}*F{i},2)", "note"])
    for row in tail:
        ws.append(row)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


class ParseBoqTest(unittest.TestCase):
    def test_reads_header_lines_sections_and_total(self):
        data = workbook([
            (1, "Work 1: Resurfacing of access road", "Granular sub-base", "Cu.m", 342.75, 2087.71),
            (2, "Work 1", "Wet mix macadam", "Cu.m", 228.5, 2793.98),
            (3, "Work 2: Roadside drain", "PCC 1:3:6", "Cu.m", 10, 5000),
        ], tail=[
            [None, None, "Sub-total (items 1-3)"],
            [4, None, "Bhutan GST 5% (only if registered)"],  # numbered like an item, must be skipped
            [None, None, "TOTAL BID PRICE (Nu.)"],
        ])
        r = parse_boq_xlsx(data)
        self.assertEqual(r["title"], "Bailey bridge at Bukay")
        self.assertEqual(r["tender_ref"], "DAS/Engg-12/2026-27/2133")
        self.assertEqual(r["bidder"], "DRUKAR Private Limited")
        self.assertFalse(r["gst_registered"])
        self.assertEqual([s["name"] for s in r["sections"]], ["Work 1: Resurfacing of access road", "Work 2: Roadside drain"])
        self.assertEqual([len(s["items"]) for s in r["sections"]], [2, 1])
        self.assertEqual(r["item_count"], 3)
        self.assertEqual(r["total"], round(342.75 * 2087.71, 2) + round(228.5 * 2793.98, 2) + 50000)
        self.assertEqual(r["warnings"], [])

    def test_missing_rates_import_as_zero_with_a_warning(self):
        r = parse_boq_xlsx(workbook([
            (1, "BOQ", "OHS measures", "LS", 1, None),
            (2, "BOQ", "Excavation", "cu.m", 100, "=F1*2"),  # formula never calculated
            (3, "BOQ", "Backfill", "cu.m", 50, 645.89),
        ]))
        self.assertEqual([i["rate"] for i in r["sections"][0]["items"]], [0, 0, 645.89])
        self.assertEqual(len(r["warnings"]), 2)
        self.assertIn("no rate yet", r["warnings"][0])

    def test_gst_registered_flag(self):
        self.assertTrue(parse_boq_xlsx(workbook([(1, "BOQ", "Item", "m", 1, 1)], gst="Y"))["gst_registered"])

    def test_empty_boq_is_explained(self):
        with self.assertRaisesRegex(BoqImportError, "no item lines"):
            parse_boq_xlsx(workbook([]))

    def test_not_a_boq(self):
        with self.assertRaisesRegex(BoqImportError, "isn't an Excel workbook"):
            parse_boq_xlsx(b"%PDF-1.4")
        wb = Workbook()
        wb.active.append(["Name", "Phone"])
        buf = io.BytesIO()
        wb.save(buf)
        with self.assertRaisesRegex(BoqImportError, "Couldn't find the BOQ table"):
            parse_boq_xlsx(buf.getvalue())


if __name__ == "__main__":
    unittest.main()
