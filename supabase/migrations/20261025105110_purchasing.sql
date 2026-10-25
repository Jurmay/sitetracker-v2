-- =====================================================================
-- Purchasing: suppliers, purchase orders, and goods received on site.
--
--   suppliers            company-wide list (Admins/Owners add them)
--   purchase_orders      per project, numbered PO-0001.. automatically;
--                        draft -> issued -> partially_received -> received,
--                        or cancelled (only before anything is received)
--   purchase_order_lines what was ordered; optionally linked to a BOQ item;
--                        editable only while the PO is a draft
--   goods_receipts       a delivery on site (date, delivery note, vehicle)
--   goods_receipt_lines  accepted / rejected quantity per PO line;
--                        append-only, can't exceed the ordered quantity
--
-- PO status after issue is kept in step with receipts by trigger.
-- PO amounts are commitments, not "actual cost": spend still comes from
-- settled advances, so materials bought through advances aren't counted
-- twice.
--
-- Who can do what (RLS):
--   see a project's POs/receipts: Owner, Admin, Cashier, Site Coordinator,
--                                 Viewer with the financial grant
--   create/issue/cancel POs:      Owner, Admin
--   record deliveries:            Site Coordinator, Owner, Admin
-- fn_create_purchase_order / fn_record_goods_receipt write a header and
-- its lines in one transaction; they run as the caller, so RLS applies.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
CREATE TABLE public.suppliers (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) > 0),
  contact_person text,
  phone text,
  email text,
  tpn text,  -- Bhutan taxpayer number
  address text,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  UNIQUE (company_id, name)
);

CREATE TABLE public.purchase_orders (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id),
  po_number text NOT NULL,
  status text DEFAULT 'draft' NOT NULL
    CHECK (status = ANY (ARRAY['draft', 'issued', 'partially_received', 'received', 'cancelled'])),
  order_date date DEFAULT CURRENT_DATE NOT NULL,
  expected_date date,
  delivery_address text,
  notes text,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  issued_by uuid REFERENCES public.profiles(id),
  issued_at timestamp with time zone,
  cancelled_by uuid REFERENCES public.profiles(id),
  cancelled_at timestamp with time zone,
  cancel_reason text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  UNIQUE (project_id, po_number),
  CHECK (expected_date IS NULL OR expected_date >= order_date)
);

CREATE TABLE public.purchase_order_lines (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  po_id uuid NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  line_no integer NOT NULL,
  boq_item_id uuid REFERENCES public.boq_items(id),
  description text NOT NULL CHECK (length(btrim(description)) > 0),
  unit text NOT NULL,
  quantity numeric(14,3) NOT NULL CHECK (quantity > 0),
  rate numeric(14,2) NOT NULL CHECK (rate >= 0),
  amount numeric(14,2) GENERATED ALWAYS AS (round(quantity * rate, 2)) STORED,
  UNIQUE (po_id, line_no)
);

CREATE TABLE public.goods_receipts (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  po_id uuid NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  received_date date DEFAULT CURRENT_DATE NOT NULL,
  delivery_note_no text,
  vehicle_no text,
  notes text,
  received_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.goods_receipt_lines (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  receipt_id uuid NOT NULL REFERENCES public.goods_receipts(id) ON DELETE CASCADE,
  po_line_id uuid NOT NULL REFERENCES public.purchase_order_lines(id),
  quantity_received numeric(14,3) NOT NULL CHECK (quantity_received >= 0),  -- accepted
  quantity_rejected numeric(14,3) DEFAULT 0 NOT NULL CHECK (quantity_rejected >= 0),
  remarks text,
  CHECK (quantity_received + quantity_rejected > 0),
  UNIQUE (receipt_id, po_line_id)
);

CREATE INDEX idx_suppliers_company ON public.suppliers USING btree (company_id);
CREATE INDEX idx_purchase_orders_project ON public.purchase_orders USING btree (project_id, status);
CREATE INDEX idx_purchase_orders_supplier ON public.purchase_orders USING btree (supplier_id);
CREATE INDEX idx_po_lines_po ON public.purchase_order_lines USING btree (po_id);
CREATE INDEX idx_po_lines_boq_item ON public.purchase_order_lines USING btree (boq_item_id);
CREATE INDEX idx_goods_receipts_po ON public.goods_receipts USING btree (po_id);
CREATE INDEX idx_goods_receipts_project ON public.goods_receipts USING btree (project_id, received_date);
CREATE INDEX idx_receipt_lines_receipt ON public.goods_receipt_lines USING btree (receipt_id);
CREATE INDEX idx_receipt_lines_po_line ON public.goods_receipt_lines USING btree (po_line_id);


-- ---------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------
CREATE FUNCTION public.fn_can_view_purchasing(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_is_company_owner_of_project(p_project_id)
      or fn_has_project_role(p_project_id, 'admin')
      or fn_has_project_role(p_project_id, 'cashier')
      or fn_has_project_role(p_project_id, 'site_coordinator')
      or (fn_has_project_role(p_project_id, 'viewer') and fn_viewer_has_financial_grant(p_project_id));
$function$;

CREATE FUNCTION public.fn_can_manage_purchasing(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_is_company_owner_of_project(p_project_id) or fn_has_project_role(p_project_id, 'admin');
$function$;

CREATE FUNCTION public.fn_can_receive_goods(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_can_manage_purchasing(p_project_id) or fn_has_project_role(p_project_id, 'site_coordinator');
$function$;

-- Admin or Owner on at least one active project of this company.
CREATE FUNCTION public.fn_is_company_manager(p_company_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select p_company_id = fn_my_company_id() and exists (
    select 1 from project_roles r join projects p on p.id = r.project_id
    where p.company_id = p_company_id and r.user_id = auth.uid()
      and r.status = 'active' and r.role in ('admin', 'company_owner')
  );
$function$;

-- What a PO's status should be from what has been received so far.
CREATE FUNCTION public.fn_po_receipt_status(p_po_id uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select case
    when coalesce(sum(r.received), 0) = 0 then 'issued'
    when bool_and(r.received >= l.quantity) then 'received'
    else 'partially_received'
  end
  from purchase_order_lines l
  cross join lateral (
    select coalesce(sum(g.quantity_received), 0) as received
    from goods_receipt_lines g where g.po_line_id = l.id
  ) r
  where l.po_id = p_po_id;
$function$;


-- ---------------------------------------------------------------------
-- Rules (triggers)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.fn_po_before_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
begin
  if not exists (
    select 1 from suppliers s join projects p on p.company_id = s.company_id
    where s.id = new.supplier_id and p.id = new.project_id
  ) then
    raise exception 'That supplier is not on your company''s supplier list';
  end if;

  if new.po_number is null or btrim(new.po_number) = '' then
    perform pg_advisory_xact_lock(hashtext('po_number:' || new.project_id::text));
    select 'PO-' || lpad((coalesce(max(substring(po_number from 4)::integer), 0) + 1)::text, 4, '0')
      into new.po_number
      from purchase_orders
     where project_id = new.project_id and po_number ~ '^PO-[0-9]+$';
  end if;

  -- Every PO starts as a draft; issuing is a separate, checked step.
  new.status := 'draft';
  new.issued_by := null; new.issued_at := null;
  new.cancelled_by := null; new.cancelled_at := null;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_po_before_update()
 RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $function$
begin
  if new.project_id <> old.project_id or new.po_number <> old.po_number or new.created_by <> old.created_by then
    raise exception 'Project, PO number and creator of a purchase order cannot be changed';
  end if;
  if old.status <> 'draft' and (new.supplier_id <> old.supplier_id or new.order_date <> old.order_date) then
    raise exception 'Supplier and order date are fixed once the PO is issued';
  end if;
  if new.supplier_id <> old.supplier_id and not exists (
    select 1 from suppliers s join projects p on p.company_id = s.company_id
    where s.id = new.supplier_id and p.id = new.project_id
  ) then
    raise exception 'That supplier is not on your company''s supplier list';
  end if;

  if new.status = old.status then
    return new;
  end if;

  if old.status = 'draft' and new.status = 'issued' then
    if not exists (select 1 from purchase_order_lines where po_id = new.id) then
      raise exception 'Add at least one line before issuing the purchase order';
    end if;
    new.issued_by := auth.uid();
    new.issued_at := now();
  elsif new.status = 'cancelled' and old.status in ('draft', 'issued') then
    if exists (select 1 from goods_receipts where po_id = new.id) then
      raise exception 'Goods have already been received against this purchase order, so it cannot be cancelled';
    end if;
    new.cancelled_by := auth.uid();
    new.cancelled_at := now();
  elsif old.status in ('issued', 'partially_received', 'received')
        and new.status in ('issued', 'partially_received', 'received')
        and new.status = fn_po_receipt_status(new.id) then
    null;  -- kept in step with deliveries by fn_receipt_line_after_insert
  else
    raise exception 'A purchase order cannot go from % to %', old.status, new.status;
  end if;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_po_line_before_write()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_status text;
  v_project uuid;
begin
  if tg_op = 'DELETE' then
    select status into v_status from purchase_orders where id = old.po_id;
    if v_status is not null and v_status <> 'draft' then
      raise exception 'Lines can only be changed while the purchase order is a draft';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and new.po_id <> old.po_id then
    raise exception 'A line cannot be moved to another purchase order';
  end if;

  select status, project_id into v_status, v_project from purchase_orders where id = new.po_id;
  if v_status <> 'draft' then
    raise exception 'Lines can only be changed while the purchase order is a draft';
  end if;
  if new.boq_item_id is not null and not exists (
    select 1 from boq_items bi join boq_sections bs on bs.id = bi.section_id
    where bi.id = new.boq_item_id and bs.project_id = v_project
  ) then
    raise exception 'That BOQ item is not in this project';
  end if;
  if new.line_no is null then
    select coalesce(max(line_no), 0) + 1 into new.line_no from purchase_order_lines where po_id = new.po_id;
  end if;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_goods_receipt_before_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_project uuid;
  v_status text;
  v_order_date date;
begin
  select project_id, status, order_date into v_project, v_status, v_order_date
    from purchase_orders where id = new.po_id;
  if v_project is null then
    raise exception 'Purchase order not found';
  end if;
  if v_status not in ('issued', 'partially_received') then
    raise exception 'Deliveries can only be recorded against an issued purchase order (this one is %)', v_status;
  end if;
  if new.received_date > current_date then
    raise exception 'The received date cannot be in the future';
  end if;
  if new.received_date < v_order_date then
    raise exception 'The received date is before the order date (%)', v_order_date;
  end if;
  new.project_id := v_project;  -- always the PO's project, whatever the caller sent
  return new;
end;
$function$;

CREATE FUNCTION public.fn_receipt_line_before_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_po uuid;
  v_line_po uuid;
  v_ordered numeric;
  v_already numeric;
  v_unit text;
begin
  select po_id into v_po from goods_receipts where id = new.receipt_id;
  -- Serialise deliveries per PO so two at once can't both pass the limit.
  perform 1 from purchase_orders where id = v_po for update;

  select po_id, quantity, unit into v_line_po, v_ordered, v_unit
    from purchase_order_lines where id = new.po_line_id;
  if v_line_po is distinct from v_po then
    raise exception 'That line is not on this purchase order';
  end if;

  select coalesce(sum(quantity_received), 0) into v_already
    from goods_receipt_lines where po_line_id = new.po_line_id;
  if v_already + new.quantity_received > v_ordered then
    raise exception 'Receiving % % would exceed the % % ordered (% already received)',
      new.quantity_received, v_unit, v_ordered, v_unit, v_already;
  end if;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_receipt_line_after_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_po uuid;
  v_status text;
begin
  select po_id into v_po from goods_receipts where id = new.receipt_id;
  v_status := fn_po_receipt_status(v_po);
  update purchase_orders set status = v_status where id = v_po and status <> v_status;
  return null;
end;
$function$;

CREATE TRIGGER trg_po_before_insert BEFORE INSERT ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION fn_po_before_insert();
CREATE TRIGGER trg_po_before_update BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION fn_po_before_update();
CREATE TRIGGER trg_po_line_before_write BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_order_lines FOR EACH ROW EXECUTE FUNCTION fn_po_line_before_write();
CREATE TRIGGER trg_goods_receipt_before_insert BEFORE INSERT ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION fn_goods_receipt_before_insert();
CREATE TRIGGER trg_receipt_line_before_insert BEFORE INSERT ON public.goods_receipt_lines FOR EACH ROW EXECUTE FUNCTION fn_receipt_line_before_insert();
CREATE TRIGGER trg_receipt_line_after_insert AFTER INSERT ON public.goods_receipt_lines FOR EACH ROW EXECUTE FUNCTION fn_receipt_line_after_insert();

CREATE TRIGGER trg_audit_suppliers AFTER INSERT OR DELETE OR UPDATE ON public.suppliers FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_purchase_orders AFTER INSERT OR DELETE OR UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_purchase_order_lines AFTER INSERT OR DELETE OR UPDATE ON public.purchase_order_lines FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_goods_receipts AFTER INSERT OR DELETE OR UPDATE ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_goods_receipt_lines AFTER INSERT OR DELETE OR UPDATE ON public.goods_receipt_lines FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();


-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY suppliers_select ON public.suppliers FOR SELECT TO authenticated
  USING (company_id = fn_my_company_id());
CREATE POLICY suppliers_insert ON public.suppliers FOR INSERT TO authenticated
  WITH CHECK (fn_is_company_manager(company_id) AND created_by = auth.uid());
CREATE POLICY suppliers_update ON public.suppliers FOR UPDATE TO authenticated
  USING (fn_is_company_manager(company_id)) WITH CHECK (fn_is_company_manager(company_id));

CREATE POLICY po_select ON public.purchase_orders FOR SELECT TO authenticated
  USING (fn_can_view_purchasing(project_id));
CREATE POLICY po_insert ON public.purchase_orders FOR INSERT TO authenticated
  WITH CHECK (fn_can_manage_purchasing(project_id) AND created_by = auth.uid());
CREATE POLICY po_update ON public.purchase_orders FOR UPDATE TO authenticated
  USING (fn_can_manage_purchasing(project_id)) WITH CHECK (fn_can_manage_purchasing(project_id));
CREATE POLICY po_delete_draft ON public.purchase_orders FOR DELETE TO authenticated
  USING (fn_can_manage_purchasing(project_id) AND status = 'draft');

CREATE POLICY po_lines_select ON public.purchase_order_lines FOR SELECT TO authenticated
  USING (fn_can_view_purchasing((SELECT po.project_id FROM purchase_orders po WHERE po.id = purchase_order_lines.po_id)));
CREATE POLICY po_lines_write ON public.purchase_order_lines FOR ALL TO authenticated
  USING (fn_can_manage_purchasing((SELECT po.project_id FROM purchase_orders po WHERE po.id = purchase_order_lines.po_id)))
  WITH CHECK (fn_can_manage_purchasing((SELECT po.project_id FROM purchase_orders po WHERE po.id = purchase_order_lines.po_id)));

CREATE POLICY receipts_select ON public.goods_receipts FOR SELECT TO authenticated
  USING (fn_can_view_purchasing(project_id));
CREATE POLICY receipts_insert ON public.goods_receipts FOR INSERT TO authenticated
  WITH CHECK (received_by = auth.uid() AND fn_can_receive_goods(project_id));

CREATE POLICY receipt_lines_select ON public.goods_receipt_lines FOR SELECT TO authenticated
  USING (fn_can_view_purchasing((SELECT r.project_id FROM goods_receipts r WHERE r.id = goods_receipt_lines.receipt_id)));
CREATE POLICY receipt_lines_insert ON public.goods_receipt_lines FOR INSERT TO authenticated
  WITH CHECK ((SELECT r.received_by FROM goods_receipts r WHERE r.id = goods_receipt_lines.receipt_id) = auth.uid());


-- ---------------------------------------------------------------------
-- One-call writes (run as the caller, so the policies above apply)
-- ---------------------------------------------------------------------
-- p_lines: [{"description", "unit", "quantity", "rate", "boq_item_id"?}, ...]
CREATE FUNCTION public.fn_create_purchase_order(
  p_project_id uuid, p_supplier_id uuid, p_lines jsonb,
  p_expected_date date DEFAULT NULL, p_delivery_address text DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SET search_path = public
AS $function$
declare
  v_id uuid;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase order needs at least one line';
  end if;

  insert into purchase_orders (project_id, supplier_id, expected_date, delivery_address, notes, created_by)
  values (p_project_id, p_supplier_id, p_expected_date, p_delivery_address, p_notes, auth.uid())
  returning id into v_id;

  insert into purchase_order_lines (po_id, line_no, boq_item_id, description, unit, quantity, rate)
  select v_id, l.ord, nullif(l.e->>'boq_item_id', '')::uuid, l.e->>'description', l.e->>'unit',
         (l.e->>'quantity')::numeric, (l.e->>'rate')::numeric
    from jsonb_array_elements(p_lines) with ordinality as l(e, ord);

  return v_id;
end;
$function$;

-- p_lines: [{"po_line_id", "quantity_received", "quantity_rejected"?, "remarks"?}, ...]
-- Lines with nothing received or rejected are skipped.
CREATE FUNCTION public.fn_record_goods_receipt(
  p_po_id uuid, p_lines jsonb,
  p_received_date date DEFAULT NULL, p_delivery_note_no text DEFAULT NULL,
  p_vehicle_no text DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SET search_path = public
AS $function$
declare
  v_id uuid;
  v_count integer;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Enter what was received';
  end if;

  insert into goods_receipts (po_id, project_id, received_date, delivery_note_no, vehicle_no, notes, received_by)
  select p_po_id, po.project_id, coalesce(p_received_date, current_date), p_delivery_note_no, p_vehicle_no, p_notes, auth.uid()
    from purchase_orders po where po.id = p_po_id
  returning id into v_id;
  if v_id is null then
    raise exception 'Purchase order not found';
  end if;

  insert into goods_receipt_lines (receipt_id, po_line_id, quantity_received, quantity_rejected, remarks)
  select v_id, (l->>'po_line_id')::uuid,
         coalesce((l->>'quantity_received')::numeric, 0), coalesce((l->>'quantity_rejected')::numeric, 0),
         nullif(btrim(l->>'remarks'), '')
    from jsonb_array_elements(p_lines) as l
   where coalesce((l->>'quantity_received')::numeric, 0) + coalesce((l->>'quantity_rejected')::numeric, 0) > 0;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'Enter a received or rejected quantity for at least one line';
  end if;

  return v_id;
end;
$function$;


-- ---------------------------------------------------------------------
-- Read views (run as the caller, so the policies above apply)
-- ---------------------------------------------------------------------
CREATE VIEW public.v_purchase_order_lines WITH (security_invoker = true) AS
 SELECT l.id AS po_line_id,
    l.po_id,
    po.project_id,
    l.line_no,
    l.boq_item_id,
    bi.description AS boq_description,
    l.description,
    l.unit,
    l.quantity AS ordered_qty,
    l.rate,
    l.amount,
    COALESCE(r.received, 0::numeric) AS received_qty,
    COALESCE(r.rejected, 0::numeric) AS rejected_qty,
    GREATEST(l.quantity - COALESCE(r.received, 0::numeric), 0::numeric) AS pending_qty,
    round(COALESCE(r.received, 0::numeric) * l.rate, 2) AS received_amount
   FROM purchase_order_lines l
     JOIN purchase_orders po ON po.id = l.po_id
     LEFT JOIN boq_items bi ON bi.id = l.boq_item_id
     LEFT JOIN LATERAL ( SELECT sum(g.quantity_received) AS received, sum(g.quantity_rejected) AS rejected
           FROM goods_receipt_lines g
          WHERE g.po_line_id = l.id) r ON true;

CREATE VIEW public.v_purchase_orders WITH (security_invoker = true) AS
 SELECT po.id AS po_id,
    po.project_id,
    po.po_number,
    po.status,
    po.order_date,
    po.expected_date,
    po.delivery_address,
    po.notes,
    po.supplier_id,
    s.name AS supplier_name,
    s.phone AS supplier_phone,
    po.issued_at,
    po.cancelled_at,
    po.cancel_reason,
    t.line_count,
    t.total_amount,
    t.received_amount,
    CASE WHEN t.total_amount > 0::numeric THEN round(100.0 * t.received_amount / t.total_amount, 1) ELSE 0::numeric END AS pct_received,
    rc.receipt_count,
    rc.last_received_date,
    (po.status = ANY (ARRAY['issued'::text, 'partially_received'::text]) AND po.expected_date < CURRENT_DATE) AS delivery_overdue
   FROM purchase_orders po
     JOIN suppliers s ON s.id = po.supplier_id
     LEFT JOIN LATERAL ( SELECT count(*) AS line_count,
            COALESCE(sum(vl.amount), 0::numeric) AS total_amount,
            COALESCE(sum(vl.received_amount), 0::numeric) AS received_amount
           FROM v_purchase_order_lines vl
          WHERE vl.po_id = po.id) t ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS receipt_count, max(g.received_date) AS last_received_date
           FROM goods_receipts g
          WHERE g.po_id = po.id) rc ON true;


-- ---------------------------------------------------------------------
-- Grants: signed-in users only; RLS decides the rows
-- ---------------------------------------------------------------------
REVOKE ALL ON public.suppliers, public.purchase_orders, public.purchase_order_lines,
  public.goods_receipts, public.goods_receipt_lines,
  public.v_purchase_order_lines, public.v_purchase_orders FROM anon;
REVOKE ALL ON public.v_purchase_order_lines, public.v_purchase_orders FROM authenticated;
GRANT SELECT ON public.v_purchase_order_lines, public.v_purchase_orders TO authenticated;

REVOKE ALL ON FUNCTION public.fn_can_view_purchasing(uuid), public.fn_can_manage_purchasing(uuid),
  public.fn_can_receive_goods(uuid), public.fn_is_company_manager(uuid), public.fn_po_receipt_status(uuid),
  public.fn_create_purchase_order(uuid, uuid, jsonb, date, text, text),
  public.fn_record_goods_receipt(uuid, jsonb, date, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_can_view_purchasing(uuid), public.fn_can_manage_purchasing(uuid),
  public.fn_can_receive_goods(uuid), public.fn_is_company_manager(uuid), public.fn_po_receipt_status(uuid),
  public.fn_create_purchase_order(uuid, uuid, jsonb, date, text, text),
  public.fn_record_goods_receipt(uuid, jsonb, date, text, text, text)
  TO authenticated;


-- ---------------------------------------------------------------------
-- All-sites dashboard: value still to be delivered on issued POs, and
-- POs past their expected delivery date. (New columns at the end.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_portfolio_summary AS
 SELECT p.id AS project_id,
    p.company_id,
    p.name,
    p.location,
    p.status,
    p.target_end_date,
    COALESCE(e.total_budgeted_cost, 0::numeric) AS total_budgeted_cost,
    COALESCE(e.total_planned_value, 0::numeric) AS planned_value,
    COALESCE(e.total_earned_value, 0::numeric) AS earned_value,
    COALESCE(e.total_actual_cost, 0::numeric) AS actual_cost,
    COALESCE(e.cost_variance, 0::numeric) AS cost_variance,
    COALESCE(e.schedule_variance, 0::numeric) AS schedule_variance,
    COALESCE(e.physical_progress_pct, 0::numeric) AS physical_progress_pct,
    COALESCE(e.financial_progress_pct, 0::numeric) AS financial_progress_pct,
    COALESCE(e.items_exceeding_boq_estimate, 0::bigint) AS items_exceeding_boq_estimate,
    COALESCE(cb.total_fund_receipts, 0::numeric) AS total_fund_receipts,
    COALESCE(cb.total_disbursed, 0::numeric) AS total_disbursed,
    COALESCE(cb.current_balance, 0::numeric) AS cash_balance,
    COALESCE(cb.balance_pct_of_fund, 0::numeric) AS cash_balance_pct,
    ps.cash_replenishment_threshold_pct,
    (COALESCE(cb.total_fund_receipts, 0::numeric) > 0::numeric
      AND COALESCE(cb.balance_pct_of_fund, 0::numeric) < ps.cash_replenishment_threshold_pct) AS cash_low,
    adv.pending_verification AS advances_pending_verification,
    adv.pending_approval AS advances_pending_approval,
    adv.awaiting_disbursement AS advances_awaiting_disbursement,
    st.pending AS settlements_pending_verification,
    fq.pending AS fund_requisitions_pending,
    os.outstanding_amount AS advances_outstanding_amount,
    os.overdue_count AS settlements_overdue,
    co.on_duty AS coordinators_on_duty,
    co.master_roll_done AS master_roll_submitted_today,
    co.progress_done AS progress_submitted_today,
    co.missing_names AS coordinators_missing_today,
    lp.last_progress_date,
    sc.late AS schedule_items_late,
    sc.unscheduled AS schedule_items_unscheduled,
    pu.open_value AS po_open_value,
    pu.deliveries_overdue AS po_deliveries_overdue
   FROM projects p
     JOIN project_settings ps ON ps.project_id = p.id
     LEFT JOIN v_evm_by_project e ON e.project_id = p.id
     LEFT JOIN v_cashbook_running_balance cb ON cb.project_id = p.id
     LEFT JOIN LATERAL ( SELECT
            count(*) FILTER (WHERE ar.status = 'pending_verification'::text) AS pending_verification,
            count(*) FILTER (WHERE ar.status = 'pending_approval'::text) AS pending_approval,
            count(*) FILTER (WHERE ar.status = 'approved'::text) AS awaiting_disbursement
           FROM advance_requisitions ar
          WHERE ar.project_id = p.id) adv ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS pending
           FROM advance_settlements s
          WHERE s.project_id = p.id AND s.status = 'pending_verification'::text) st ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS pending
           FROM fund_requisitions f
          WHERE f.project_id = p.id AND f.status = 'pending_approval'::text) fq ON true
     LEFT JOIN LATERAL ( SELECT
            COALESCE(sum(d.amount - d.settled), 0::numeric) AS outstanding_amount,
            count(*) FILTER (WHERE d.disbursed_at + make_interval(days => ps.settlement_grace_days) <= now()) AS overdue_count
           FROM ( SELECT ar.amount,
                    ( SELECT COALESCE(sum(s.settled_amount), 0::numeric)
                           FROM advance_settlements s
                          WHERE s.requisition_id = ar.id AND s.status = ANY (ARRAY['pending_verification'::text, 'settled'::text])) AS settled,
                    ( SELECT max(ara.action_at)
                           FROM advance_requisition_actions ara
                          WHERE ara.requisition_id = ar.id AND ara.action_type = 'disbursed'::text) AS disbursed_at
                   FROM advance_requisitions ar
                  WHERE ar.project_id = p.id AND ar.status = 'disbursed'::text) d
          WHERE d.settled < d.amount) os ON true
     LEFT JOIN LATERAL ( SELECT
            count(*) AS on_duty,
            count(*) FILTER (WHERE c.mr) AS master_roll_done,
            count(*) FILTER (WHERE c.pr) AS progress_done,
            COALESCE(array_agg(c.name ORDER BY c.name) FILTER (WHERE NOT (c.mr AND c.pr)), '{}'::text[]) AS missing_names
           FROM ( SELECT prof.name,
                    (EXISTS ( SELECT 1 FROM master_roll_entries m
                          WHERE m.project_id = p.id AND m.coordinator_id = r.user_id AND m.date = CURRENT_DATE)) AS mr,
                    (EXISTS ( SELECT 1 FROM progress_reports pr
                          WHERE pr.project_id = p.id AND pr.coordinator_id = r.user_id AND pr.date = CURRENT_DATE)) AS pr
                   FROM project_roles r
                     JOIN profiles prof ON prof.id = r.user_id
                  WHERE r.project_id = p.id AND r.role = 'site_coordinator'::text AND r.status = 'active'::text
                    AND NOT fn_is_on_leave(r.user_id, p.id, CURRENT_DATE)) c) co ON true
     LEFT JOIN LATERAL ( SELECT max(pr.date) AS last_progress_date
           FROM progress_reports pr
          WHERE pr.project_id = p.id) lp ON true
     LEFT JOIN LATERAL ( SELECT
            count(*) FILTER (WHERE s.schedule_status = ANY (ARRAY['behind'::text, 'late_start'::text, 'overdue'::text])) AS late,
            count(*) FILTER (WHERE s.schedule_status = 'unscheduled'::text) AS unscheduled
           FROM v_schedule_by_boq_item s
          WHERE s.project_id = p.id) sc ON true
     LEFT JOIN LATERAL ( SELECT
            COALESCE(sum(( SELECT sum(GREATEST(l.quantity - COALESCE(( SELECT sum(g.quantity_received)
                           FROM goods_receipt_lines g
                          WHERE g.po_line_id = l.id), 0::numeric), 0::numeric) * l.rate)
                   FROM purchase_order_lines l
                  WHERE l.po_id = po.id)) FILTER (WHERE po.status = ANY (ARRAY['issued'::text, 'partially_received'::text])), 0::numeric) AS open_value,
            count(*) FILTER (WHERE po.status = ANY (ARRAY['issued'::text, 'partially_received'::text]) AND po.expected_date < CURRENT_DATE) AS deliveries_overdue
           FROM purchase_orders po
          WHERE po.project_id = p.id) pu ON true
  WHERE fn_is_company_owner_of_project(p.id) OR fn_has_project_role(p.id, 'admin'::text);
