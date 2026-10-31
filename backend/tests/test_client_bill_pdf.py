# -*- coding: utf-8 -*-
"""The RA bill PDF builds for drafts, certified and final bills."""
import io
import unittest

from app.services.client_bill_pdf import generate_client_bill_pdf

BILL = {
    "bill_ref": "RA-02", "status": "certified", "is_final": False,
    "bill_date": "2026-10-25", "period_to": "2026-10-24",
    "gross_amount": 13500, "retention_amount": 1350, "tds_amount": 270, "advance_recovery": 1350,
    "other_deductions": 1000, "net_amount": 9530, "retention_pct": 10, "tds_pct": 2,
    "certified_amount": 9500, "certified_date": "2026-10-25", "certificate_ref": "MB-12/7",
    "notes": "Up to slab level", "cancel_reason": None,
}
SHEET = [
    {"section_name": "BOQ 02: Ch 6.4 km", "description": "P&L Random Rubble Masonry <1:4>", "unit": "Cu.m",
     "boq_quantity": 145.32, "rate": 4101.59, "previous_quantity": 20, "this_quantity": 3.29,
     "cumulative_quantity": 23.29, "previous_amount": 82031.8, "this_amount": 13494.23, "cumulative_amount": 95526.03},
    {"section_name": "BOQ 02: Ch 6.4 km", "description": "Not started", "unit": "m",
     "boq_quantity": 10, "rate": 1, "previous_quantity": 0, "this_quantity": 0,
     "cumulative_quantity": 0, "previous_amount": 0, "this_amount": 0, "cumulative_amount": 0},
]


def _pdf(**overrides):
    args = dict(bill=BILL, sheet=SHEET, deductions=[{"description": "Liquidated damages", "amount": 1000}],
                company_name="Sherza & Co", project_name="Amochu restoration", project_location="Phuentsholing",
                tender_ref="DoST/ROP/2026-2027/Mtc-12/615", currency="BTN",
                client_name="Regional Office DoST", client_address="Phuentsholing")
    args.update(overrides)
    return generate_client_bill_pdf(**args)


def _text(pdf: bytes) -> str:
    from pypdf import PdfReader
    return "\n".join(p.extract_text() for p in PdfReader(io.BytesIO(pdf)).pages)


class ClientBillPdfTest(unittest.TestCase):
    def test_certified_bill(self):
        pdf = _pdf()
        self.assertTrue(pdf.startswith(b"%PDF"))
        text = _text(pdf)
        self.assertIn("RUNNING ACCOUNT BILL RA-02", text)
        for expected in ("Liquidated damages", "9,530.00", "Certified by client", "MB-12/7", "95,526.03"):
            self.assertIn(expected, text)
        self.assertNotIn("Not started", text)  # only items with work billed are listed

    def test_draft_and_final_marked(self):
        text = _text(_pdf(bill={**BILL, "status": "draft", "is_final": True, "certified_amount": None}))
        self.assertIn("DRAFT - NOT SUBMITTED", text)
        self.assertIn("(FINAL)", text)
        self.assertNotIn("Certified by client", text)

    def test_no_client_details(self):
        self.assertTrue(_pdf(client_name=None, client_address=None, deductions=[], tender_ref=None).startswith(b"%PDF"))



class RetentionClaimPdfTest(unittest.TestCase):
    def test_claim_letter(self):
        from app.services.client_bill_pdf import generate_retention_claim_pdf
        pdf = generate_retention_claim_pdf(
            release={"release_ref": "RR-02", "release_no": 2, "status": "claimed", "amount": 3600,
                     "claim_date": "2026-10-31", "stage": "End of defects liability period", "notes": None},
            bills=[{"bill_ref": "RA-01", "bill_date": "2026-10-25", "certified_date": "2026-10-26",
                    "gross_amount": 72000, "retention_amount": 7200}],
            earlier=[{"release_ref": "RR-01", "release_no": 1, "status": "received", "amount": 3600,
                      "claim_date": "2026-10-28", "received_date": "2026-10-30"}],
            company_name="Sherza & Co", project_name="Amochu restoration", project_location="Phuentsholing",
            tender_ref="DoST/ROP/2026-2027/Mtc-12/615", currency="BTN",
            client_name="Regional Office DoST", client_address=None,
        )
        text = _text(pdf)
        self.assertIn("CLAIM FOR RELEASE OF RETENTION RR-02", text)
        for expected in ("7,200.00", "RR-01 released", "(3,600.00)", "Retention still held", "End of defects liability period"):
            self.assertIn(expected, text)


if __name__ == "__main__":
    unittest.main()
