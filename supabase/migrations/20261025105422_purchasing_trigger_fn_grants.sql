-- Trigger functions only run as triggers; nobody needs to call them directly.
REVOKE ALL ON FUNCTION public.fn_po_before_insert(), public.fn_po_before_update(),
  public.fn_po_line_before_write(), public.fn_goods_receipt_before_insert(),
  public.fn_receipt_line_before_insert(), public.fn_receipt_line_after_insert()
  FROM PUBLIC, anon, authenticated;
