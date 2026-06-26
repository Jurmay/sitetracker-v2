# -*- coding: utf-8 -*-
"""
Thin wrapper around Resend for transactional email. Kept deliberately
small - if Resend is ever swapped out (e.g. for Supabase's built-in SMTP,
the other option considered in Phase 9), only this file should need to
change, not every caller.
"""
import base64
import resend

from app.core.config import get_settings

settings = get_settings()
resend.api_key = settings.resend_api_key


def send_email_with_pdf_attachment(
    *,
    to: str,
    subject: str,
    body_text: str,
    pdf_bytes: bytes,
    pdf_filename: str,
) -> dict:
    """
    Sends a transactional email with a single PDF attachment.
    Returns Resend's response dict (contains the message id) for logging.
    Raises whatever exception the resend SDK raises on failure - the
    caller is responsible for deciding whether a failed send should
    block the broader operation (it should NOT block fund requisition
    approval itself; see the calling endpoint's error handling).
    """
    if not settings.resend_api_key:
        raise RuntimeError(
            "RESEND_API_KEY is not configured. Set it in the environment before "
            "approving fund requisitions, or accounts_email_sent_at will never be set."
        )

    encoded_pdf = base64.b64encode(pdf_bytes).decode("utf-8")

    params: resend.Emails.SendParams = {
        "from": settings.accounts_email_from,
        "to": [to],
        "subject": subject,
        "text": body_text,
        "attachments": [
            {
                "filename": pdf_filename,
                "content": encoded_pdf,
            }
        ],
    }
    return resend.Emails.send(params)
