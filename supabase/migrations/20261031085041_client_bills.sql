-- =====================================================================
-- Client running bills (RA bills): what the contractor bills the client
-- for work done, and what the client pays.
--
--   project_settings      + client name/address and billing terms:
--                           retention %, optional retention limit (% of
--                           contract value), TDS %, mobilisation advance
--                           and the % of each bill that recovers it
--   client_bills          RA-01, RA-02.. per project;
--                           draft -> submitted -> certified -> paid,
--                           or cancelled (a submitted bill only)
--   client_bill_lines     quantity billed this time per BOQ item, at the
--                           BOQ rate (after variations); total billed can
--                           never exceed the BOQ quantity (after variations)
--   client_bill_deductions other deductions typed in (LD, material
--                           recovery, ...)
--   client_bill_payments  money received against a certified bill;
--                           append-only, can't exceed the certified amount
--
-- Amounts follow the lines while a bill is a draft and are fixed when it
-- is submitted: gross = sum of lines; retention, TDS and advance
-- recovery from the project's terms; net = gross - deductions. BOQ rates
-- already include GST (e-GP rule), so no GST line is added.
-- Only the latest bill can be recalled to draft or cancelled, so earlier
-- bills' "previous quantity" never changes under a later bill.
--
-- Who can do what (RLS):
--   see bills:            Owner, Admin, Cashier, Viewer with the financial grant
--   create/edit/submit/
--   certify/cancel:       Owner, Admin
--   record payments:      Owner, Admin, Cashier
-- =====================================================================


-- ---------------------------------------------------------------------
-- Billing terms (one set per project)
-- ---------------------------------------------------------------------
ALTER TABLE public.project_settings
  ADD COLUMN client_name text,
  ADD COLUMN client_address text,
  ADD COLUMN retention_pct numeric(5,2) DEFAULT 10 NOT NULL CHECK (retention_pct BETWEEN 0 AND 100),
  ADD COLUMN retention_limit_pct numeric(5,2) CHECK (retention_limit_pct IS NULL OR retention_limit_pct BETWEEN 0 AND 100),
  ADD COLUMN tds_pct numeric(5,2) DEFAULT 2 NOT NULL CHECK (tds_pct BETWEEN 0 AND 100),
  ADD COLUMN mobilisation_advance numeric(14,2) DEFAULT 0 NOT NULL CHECK (mobilisation_advance >= 0),
  ADD COLUMN advance_recovery_pct numeric(5,2) DEFAULT 0 NOT NULL CHECK (advance_recovery_pct BETWEEN 0 AND 100);


-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
CREATE TABLE public.client_bills (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  bill_no integer NOT NULL,
  status text DEFAULT 'draft' NOT NULL
    CHECK (status = ANY (ARRAY['draft', 'submitted', 'certified', 'paid', 'cancelled'])),
  bill_date date DEFAULT CURRENT_DATE NOT NULL,
  period_to date DEFAULT CURRENT_DATE NOT NULL,  -- work measured up to this date
  is_final boolean DEFAULT false NOT NULL,       -- final bill recovers all advance still outstanding
  notes text,
  -- follow the lines while draft, fixed once submitted
  gross_amount numeric(14,2) DEFAULT 0 NOT NULL,
  retention_amount numeric(14,2) DEFAULT 0 NOT NULL,
  tds_amount numeric(14,2) DEFAULT 0 NOT NULL,
  advance_recovery numeric(14,2) DEFAULT 0 NOT NULL,
  other_deductions numeric(14,2) DEFAULT 0 NOT NULL,
  net_amount numeric(14,2) DEFAULT 0 NOT NULL,
  retention_pct numeric(5,2),
  tds_pct numeric(5,2),
  advance_recovery_pct numeric(5,2),
  -- the client's certificate
  certified_amount numeric(14,2),
  certified_date date,
  certificate_ref text,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  submitted_by uuid REFERENCES public.profiles(id),
  submitted_at timestamp with time zone,
  certified_by uuid REFERENCES public.profiles(id),
  certified_at timestamp with time zone,
  cancelled_by uuid REFERENCES public.profiles(id),
  cancelled_at timestamp with time zone,
  cancel_reason text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  UNIQUE (project_id, bill_no)
);

CREATE TABLE public.client_bill_lines (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  bill_id uuid NOT NULL REFERENCES public.client_bills(id) ON DELETE CASCADE,
  boq_item_id uuid NOT NULL REFERENCES public.boq_items(id),
  quantity numeric(14,3) NOT NULL CHECK (quantity >= 0),
  rate numeric(14,2) NOT NULL CHECK (rate >= 0),  -- set from the BOQ (after variations), not by the caller
  amount numeric(14,2) GENERATED ALWAYS AS (round(quantity * rate, 2)) STORED,
  UNIQUE (bill_id, boq_item_id)
);

CREATE TABLE public.client_bill_deductions (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  bill_id uuid NOT NULL REFERENCES public.client_bills(id) ON DELETE CASCADE,
  description text NOT NULL CHECK (length(btrim(description)) > 0),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.client_bill_payments (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  bill_id uuid NOT NULL REFERENCES public.client_bills(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  received_date date DEFAULT CURRENT_DATE NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  reference text,  -- cheque / transfer number
  notes text,
  recorded_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- One draft at a time per project, so bills are always finished in order.
CREATE UNIQUE INDEX uq_client_bills_one_draft ON public.client_bills USING btree (project_id) WHERE status = 'draft';
CREATE INDEX idx_client_bills_project ON public.client_bills USING btree (project_id, bill_no);
CREATE INDEX idx_client_bill_lines_bill ON public.client_bill_lines USING btree (bill_id);
CREATE INDEX idx_client_bill_lines_item ON public.client_bill_lines USING btree (boq_item_id);
CREATE INDEX idx_client_bill_deductions_bill ON public.client_bill_deductions USING btree (bill_id);
CREATE INDEX idx_client_bill_payments_bill ON public.client_bill_payments USING btree (bill_id);
CREATE INDEX idx_client_bill_payments_project ON public.client_bill_payments USING btree (project_id, received_date);


-- ---------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------
CREATE FUNCTION public.fn_can_view_billing(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_is_company_owner_of_project(p_project_id)
      or fn_has_project_role(p_project_id, 'admin')
      or fn_has_project_role(p_project_id, 'cashier')
      or (fn_has_project_role(p_project_id, 'viewer') and fn_viewer_has_financial_grant(p_project_id));
$function$;

CREATE FUNCTION public.fn_can_manage_billing(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_is_company_owner_of_project(p_project_id) or fn_has_project_role(p_project_id, 'admin');
$function$;

CREATE FUNCTION public.fn_can_record_client_payment(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_can_manage_billing(p_project_id) or fn_has_project_role(p_project_id, 'cashier');
$function$;

-- BOQ quantity and rate after variations.
CREATE FUNCTION public.fn_boq_effective_qty_rate(p_boq_item_id uuid, OUT quantity numeric, OUT rate numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select bi.quantity + coalesce(sum(v.qty_delta), 0), bi.rate + coalesce(sum(v.rate_delta), 0)
    from boq_items bi left join boq_variations v on v.boq_item_id = bi.id
   where bi.id = p_boq_item_id
   group by bi.id, bi.quantity, bi.rate;
$function$;

-- A bill's amounts from its lines, deductions and the project's terms.
CREATE FUNCTION public.fn_client_bill_amounts(p_bill_id uuid, p_is_final boolean)
 RETURNS TABLE (gross numeric, retention numeric, tds numeric, advance numeric, other numeric, net numeric,
                retention_pct numeric, tds_pct numeric, advance_recovery_pct numeric)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_project uuid;
  v_bill_no integer;
  ps record;
  v_contract numeric;
  v_prev_retention numeric;
  v_prev_advance numeric;
  v_advance_left numeric;
begin
  select b.project_id, b.bill_no into v_project, v_bill_no from client_bills b where b.id = p_bill_id;
  select * into ps from project_settings s where s.project_id = v_project;

  select coalesce(sum(l.amount), 0) into gross from client_bill_lines l where l.bill_id = p_bill_id;
  select coalesce(sum(d.amount), 0) into other from client_bill_deductions d where d.bill_id = p_bill_id;
  select coalesce(sum(b.retention_amount), 0), coalesce(sum(b.advance_recovery), 0)
    into v_prev_retention, v_prev_advance
    from client_bills b
   where b.project_id = v_project and b.bill_no < v_bill_no and b.status <> 'cancelled';

  retention_pct := ps.retention_pct;
  tds_pct := ps.tds_pct;
  advance_recovery_pct := ps.advance_recovery_pct;

  retention := round(gross * ps.retention_pct / 100, 2);
  if ps.retention_limit_pct is not null then
    select coalesce(sum(fn_boq_effective_budget(bi.id)), 0) into v_contract
      from boq_items bi join boq_sections bs on bs.id = bi.section_id
     where bs.project_id = v_project;
    retention := least(retention, greatest(round(v_contract * ps.retention_limit_pct / 100, 2) - v_prev_retention, 0));
  end if;

  tds := round(gross * ps.tds_pct / 100, 2);

  v_advance_left := greatest(ps.mobilisation_advance - v_prev_advance, 0);
  advance := case when p_is_final then v_advance_left
                  else least(round(gross * ps.advance_recovery_pct / 100, 2), v_advance_left) end;

  net := gross - retention - tds - advance - other;
  return next;
end;
$function$;

CREATE FUNCTION public.fn_client_bill_paid(p_bill_id uuid)
 RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select coalesce(sum(amount), 0) from client_bill_payments where bill_id = p_bill_id;
$function$;

-- True when a later, non-cancelled bill exists (so this one is not the latest).
CREATE FUNCTION public.fn_client_bill_has_later(p_project_id uuid, p_bill_no integer)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select exists (select 1 from client_bills
                  where project_id = p_project_id and bill_no > p_bill_no and status <> 'cancelled');
$function$;


-- ---------------------------------------------------------------------
-- Rules (triggers)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.fn_client_bill_before_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_draft integer;
  v_last_period date;
begin
  -- Permission first, so nobody outside the project learns anything from the rules below.
  if not fn_can_manage_billing(new.project_id) then
    raise exception 'new row violates row-level security policy for table "client_bills"' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('client_bill:' || new.project_id::text));

  select bill_no into v_draft from client_bills where project_id = new.project_id and status = 'draft';
  if v_draft is not null then
    raise exception 'RA-% is still a draft; submit or delete it before starting a new bill', lpad(v_draft::text, 2, '0');
  end if;

  select max(period_to) into v_last_period
    from client_bills where project_id = new.project_id and status <> 'cancelled';
  if v_last_period is not null and new.period_to < v_last_period then
    raise exception 'The bill period must end on or after the previous bill''s (%)', v_last_period;
  end if;

  select coalesce(max(bill_no), 0) + 1 into new.bill_no from client_bills where project_id = new.project_id;

  -- Every bill starts as an empty draft; amounts follow its lines.
  new.status := 'draft';
  new.gross_amount := 0; new.retention_amount := 0; new.tds_amount := 0;
  new.advance_recovery := 0; new.other_deductions := 0; new.net_amount := 0;
  new.retention_pct := null; new.tds_pct := null; new.advance_recovery_pct := null;
  new.certified_amount := null; new.certified_date := null; new.certificate_ref := null;
  new.submitted_by := null; new.submitted_at := null;
  new.certified_by := null; new.certified_at := null;
  new.cancelled_by := null; new.cancelled_at := null; new.cancel_reason := null;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_client_bill_before_update()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  a record;
  v_last_period date;
begin
  if new.project_id <> old.project_id or new.bill_no <> old.bill_no or new.created_by <> old.created_by then
    raise exception 'Project, bill number and creator of a bill cannot be changed';
  end if;

  -- Draft (staying a draft, being submitted, or recalled to draft): amounts follow the lines.
  if new.status = 'draft' or (old.status = 'draft' and new.status = 'submitted') then
    if old.status = 'draft' and new.period_to <> old.period_to then
      select max(period_to) into v_last_period from client_bills
       where project_id = new.project_id and bill_no < new.bill_no and status <> 'cancelled';
      if v_last_period is not null and new.period_to < v_last_period then
        raise exception 'The bill period must end on or after the previous bill''s (%)', v_last_period;
      end if;
    end if;
    if old.status = 'submitted' and new.status = 'draft' then
      if fn_client_bill_has_later(new.project_id, new.bill_no) then
        raise exception 'Only the latest bill can be recalled to draft';
      end if;
    elsif old.status <> 'draft' then
      raise exception 'A bill cannot go from % to %', old.status, new.status;
    end if;
    new.submitted_by := null; new.submitted_at := null;
    new.cancelled_by := null; new.cancelled_at := null; new.cancel_reason := null;

    select * into a from fn_client_bill_amounts(new.id, new.is_final);
    new.gross_amount := a.gross; new.retention_amount := a.retention; new.tds_amount := a.tds;
    new.advance_recovery := a.advance; new.other_deductions := a.other; new.net_amount := a.net;
    new.retention_pct := a.retention_pct; new.tds_pct := a.tds_pct; new.advance_recovery_pct := a.advance_recovery_pct;
    new.certified_amount := null; new.certified_date := null; new.certificate_ref := null;

    if new.status = 'submitted' then
      if a.gross <= 0 then
        raise exception 'Add at least one item with a quantity before submitting the bill';
      end if;
      if a.net < 0 then
        raise exception 'Deductions (%) are more than the bill value (%)', a.gross - a.net, a.gross;
      end if;
      new.submitted_by := auth.uid();
      new.submitted_at := now();
    end if;
    return new;
  end if;

  -- Everything below: the bill is no longer a draft, so its contents are fixed.
  if (new.bill_date, new.period_to, new.is_final, new.notes, new.gross_amount, new.retention_amount,
      new.tds_amount, new.advance_recovery, new.other_deductions, new.net_amount)
     is distinct from
     (old.bill_date, old.period_to, old.is_final, old.notes, old.gross_amount, old.retention_amount,
      old.tds_amount, old.advance_recovery, old.other_deductions, old.net_amount) then
    raise exception 'A submitted bill cannot be changed; recall it to draft first';
  end if;

  if new.status = old.status then
    if (new.certified_amount, new.certified_date, new.certificate_ref)
       is distinct from (old.certified_amount, old.certified_date, old.certificate_ref) then
      raise exception 'The certificate details cannot be changed once recorded';
    end if;
    return new;
  end if;

  if old.status = 'submitted' and new.status = 'certified' then
    if new.certified_amount is null or new.certified_amount <= 0 then
      raise exception 'Enter the amount the client certified';
    end if;
    if new.certified_amount > old.gross_amount then
      raise exception 'The certified amount (%) is more than the bill value (%)', new.certified_amount, old.gross_amount;
    end if;
    new.certified_date := coalesce(new.certified_date, current_date);
    if new.certified_date > current_date then
      raise exception 'The certificate date cannot be in the future';
    end if;
    if new.certified_date < old.bill_date then
      raise exception 'The certificate date is before the bill date (%)', old.bill_date;
    end if;
    new.certified_by := auth.uid();
    new.certified_at := now();
  elsif old.status = 'submitted' and new.status = 'cancelled' then
    if fn_client_bill_has_later(new.project_id, new.bill_no) then
      raise exception 'Only the latest bill can be cancelled';
    end if;
    if coalesce(btrim(new.cancel_reason), '') = '' then
      raise exception 'Give a reason for cancelling the bill';
    end if;
    new.certified_amount := null; new.certified_date := null; new.certificate_ref := null;
    new.cancelled_by := auth.uid();
    new.cancelled_at := now();
  elsif (old.status = 'certified' and new.status = 'paid'
         and fn_client_bill_paid(new.id) >= old.certified_amount)
     or (old.status = 'paid' and new.status = 'certified'
         and fn_client_bill_paid(new.id) < old.certified_amount) then
    -- kept in step with payments by fn_client_payment_after_insert
    if (new.certified_amount, new.certified_date, new.certificate_ref)
       is distinct from (old.certified_amount, old.certified_date, old.certificate_ref) then
      raise exception 'The certificate details cannot be changed once recorded';
    end if;
  else
    raise exception 'A bill cannot go from % to %', old.status, new.status;
  end if;
  return new;
end;
$function$;

-- Lines and deductions can only change while the bill is a draft.
CREATE FUNCTION public.fn_client_bill_line_before_write()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_status text;
  v_project uuid;
  v_eff record;
  v_billed numeric;
  v_unit text;
begin
  if tg_op = 'DELETE' then
    select status into v_status from client_bills where id = old.bill_id;
    if v_status is not null and v_status <> 'draft' then
      raise exception 'Items can only be changed while the bill is a draft';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and (new.bill_id <> old.bill_id or new.boq_item_id <> old.boq_item_id) then
    raise exception 'A bill line cannot be moved to another bill or BOQ item';
  end if;

  select status, project_id into v_status, v_project from client_bills where id = new.bill_id for update;
  if v_project is null or not fn_can_manage_billing(v_project) then
    raise exception 'new row violates row-level security policy for table "client_bill_lines"' using errcode = '42501';
  end if;
  if v_status <> 'draft' then
    raise exception 'Items can only be changed while the bill is a draft';
  end if;
  if not exists (
    select 1 from boq_items bi join boq_sections bs on bs.id = bi.section_id
    where bi.id = new.boq_item_id and bs.project_id = v_project
  ) then
    raise exception 'That BOQ item is not in this project';
  end if;

  select * into v_eff from fn_boq_effective_qty_rate(new.boq_item_id);
  new.rate := v_eff.rate;

  select coalesce(sum(l.quantity), 0) into v_billed
    from client_bill_lines l join client_bills b on b.id = l.bill_id
   where l.boq_item_id = new.boq_item_id and b.status <> 'cancelled' and b.id <> new.bill_id;
  if v_billed + new.quantity > v_eff.quantity then
    select unit into v_unit from boq_items where id = new.boq_item_id;
    raise exception 'Billing % % would bring the total billed to % %, more than the BOQ quantity of % % (record a variation first)',
      new.quantity, v_unit, v_billed + new.quantity, v_unit, v_eff.quantity, v_unit;
  end if;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_client_bill_deduction_before_write()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_status text;
  v_project uuid;
begin
  if tg_op = 'UPDATE' and new.bill_id <> old.bill_id then
    raise exception 'A deduction cannot be moved to another bill';
  end if;
  select status, project_id into v_status, v_project from client_bills
   where id = case when tg_op = 'DELETE' then old.bill_id else new.bill_id end;
  if tg_op <> 'DELETE' and (v_project is null or not fn_can_manage_billing(v_project)) then
    raise exception 'new row violates row-level security policy for table "client_bill_deductions"' using errcode = '42501';
  end if;
  if v_status is not null and v_status <> 'draft' then
    raise exception 'Deductions can only be changed while the bill is a draft';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$function$;

-- After any change to a draft's lines or deductions, refresh its amounts
-- (the bill's update trigger recalculates them).
CREATE FUNCTION public.fn_client_bill_child_after_write()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
begin
  update client_bills set gross_amount = gross_amount
   where id = case when tg_op = 'DELETE' then old.bill_id else new.bill_id end and status = 'draft';
  return null;
end;
$function$;

CREATE FUNCTION public.fn_client_payment_before_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  b record;
  v_paid numeric;
begin
  -- Serialise payments per bill so two at once can't both pass the limit.
  select * into b from client_bills where id = new.bill_id for update;
  if b.id is null or not fn_can_record_client_payment(b.project_id) then
    raise exception 'new row violates row-level security policy for table "client_bill_payments"' using errcode = '42501';
  end if;
  if b.status not in ('certified', 'paid') then
    raise exception 'Payments can only be recorded against a certified bill (this one is %)', b.status;
  end if;
  if new.received_date > current_date then
    raise exception 'The payment date cannot be in the future';
  end if;
  if new.received_date < b.certified_date then
    raise exception 'The payment date is before the certificate date (%)', b.certified_date;
  end if;
  v_paid := fn_client_bill_paid(b.id);
  if v_paid + new.amount > b.certified_amount then
    raise exception 'This would bring payments to %, more than the certified % (% already received)',
      v_paid + new.amount, b.certified_amount, v_paid;
  end if;
  new.project_id := b.project_id;  -- always the bill's project, whatever the caller sent
  return new;
end;
$function$;

CREATE FUNCTION public.fn_client_payment_after_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
begin
  update client_bills
     set status = case when fn_client_bill_paid(id) >= certified_amount then 'paid' else 'certified' end
   where id = new.bill_id
     and status <> case when fn_client_bill_paid(id) >= certified_amount then 'paid' else 'certified' end;
  return null;
end;
$function$;

CREATE TRIGGER trg_client_bill_before_insert BEFORE INSERT ON public.client_bills FOR EACH ROW EXECUTE FUNCTION fn_client_bill_before_insert();
CREATE TRIGGER trg_client_bill_before_update BEFORE UPDATE ON public.client_bills FOR EACH ROW EXECUTE FUNCTION fn_client_bill_before_update();
CREATE TRIGGER trg_client_bill_line_before_write BEFORE INSERT OR UPDATE OR DELETE ON public.client_bill_lines FOR EACH ROW EXECUTE FUNCTION fn_client_bill_line_before_write();
CREATE TRIGGER trg_client_bill_line_after_write AFTER INSERT OR UPDATE OR DELETE ON public.client_bill_lines FOR EACH ROW EXECUTE FUNCTION fn_client_bill_child_after_write();
CREATE TRIGGER trg_client_bill_deduction_before_write BEFORE INSERT OR UPDATE OR DELETE ON public.client_bill_deductions FOR EACH ROW EXECUTE FUNCTION fn_client_bill_deduction_before_write();
CREATE TRIGGER trg_client_bill_deduction_after_write AFTER INSERT OR UPDATE OR DELETE ON public.client_bill_deductions FOR EACH ROW EXECUTE FUNCTION fn_client_bill_child_after_write();
CREATE TRIGGER trg_client_payment_before_insert BEFORE INSERT ON public.client_bill_payments FOR EACH ROW EXECUTE FUNCTION fn_client_payment_before_insert();
CREATE TRIGGER trg_client_payment_after_insert AFTER INSERT ON public.client_bill_payments FOR EACH ROW EXECUTE FUNCTION fn_client_payment_after_insert();

CREATE TRIGGER trg_audit_client_bills AFTER INSERT OR DELETE OR UPDATE ON public.client_bills FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_client_bill_lines AFTER INSERT OR DELETE OR UPDATE ON public.client_bill_lines FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_client_bill_deductions AFTER INSERT OR DELETE OR UPDATE ON public.client_bill_deductions FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_client_bill_payments AFTER INSERT OR DELETE OR UPDATE ON public.client_bill_payments FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();


-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
ALTER TABLE public.client_bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_bill_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_bill_deductions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_bill_payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY client_bills_select ON public.client_bills FOR SELECT TO authenticated
  USING (fn_can_view_billing(project_id));
CREATE POLICY client_bills_insert ON public.client_bills FOR INSERT TO authenticated
  WITH CHECK (fn_can_manage_billing(project_id) AND created_by = auth.uid());
CREATE POLICY client_bills_update ON public.client_bills FOR UPDATE TO authenticated
  USING (fn_can_manage_billing(project_id)) WITH CHECK (fn_can_manage_billing(project_id));
CREATE POLICY client_bills_delete_draft ON public.client_bills FOR DELETE TO authenticated
  USING (fn_can_manage_billing(project_id) AND status = 'draft');

CREATE POLICY client_bill_lines_select ON public.client_bill_lines FOR SELECT TO authenticated
  USING (fn_can_view_billing((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_lines.bill_id)));
CREATE POLICY client_bill_lines_write ON public.client_bill_lines FOR ALL TO authenticated
  USING (fn_can_manage_billing((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_lines.bill_id)))
  WITH CHECK (fn_can_manage_billing((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_lines.bill_id)));

CREATE POLICY client_bill_deductions_select ON public.client_bill_deductions FOR SELECT TO authenticated
  USING (fn_can_view_billing((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_deductions.bill_id)));
CREATE POLICY client_bill_deductions_write ON public.client_bill_deductions FOR ALL TO authenticated
  USING (fn_can_manage_billing((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_deductions.bill_id)))
  WITH CHECK (fn_can_manage_billing((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_deductions.bill_id))
              AND created_by = auth.uid());

CREATE POLICY client_bill_payments_select ON public.client_bill_payments FOR SELECT TO authenticated
  USING (fn_can_view_billing(project_id));
CREATE POLICY client_bill_payments_insert ON public.client_bill_payments FOR INSERT TO authenticated
  WITH CHECK (recorded_by = auth.uid()
              AND fn_can_record_client_payment((SELECT b.project_id FROM client_bills b WHERE b.id = client_bill_payments.bill_id)));


-- ---------------------------------------------------------------------
-- One-call writes and reads (run as the caller, so the policies apply)
-- ---------------------------------------------------------------------
-- Starts the next RA bill. With p_prefill, each BOQ item gets the
-- quantity measured on site up to p_period_to that hasn't been billed
-- yet (never more than the BOQ quantity left); edit it before submitting.
CREATE FUNCTION public.fn_create_client_bill(
  p_project_id uuid, p_period_to date DEFAULT NULL, p_bill_date date DEFAULT NULL, p_prefill boolean DEFAULT true)
 RETURNS uuid LANGUAGE plpgsql SET search_path = public
AS $function$
declare
  v_id uuid;
  v_period date := coalesce(p_period_to, current_date);
begin
  insert into client_bills (project_id, bill_date, period_to, created_by)
  values (p_project_id, coalesce(p_bill_date, current_date), v_period, auth.uid())
  returning id into v_id;

  if p_prefill then
    insert into client_bill_lines (bill_id, boq_item_id, quantity, rate)
    select v_id, x.boq_item_id, x.qty, 0
      from (
        select m.boq_item_id,
               least(m.measured, eff.quantity) - coalesce(bl.billed, 0) as qty
          from (select pe.boq_item_id, sum(pe.effective_quantity) as measured
                  from v_progress_effective pe
                 where pe.project_id = p_project_id and pe.date <= v_period
                 group by pe.boq_item_id) m
          cross join lateral fn_boq_effective_qty_rate(m.boq_item_id) eff
          left join lateral (select sum(l.quantity) as billed
                               from client_bill_lines l join client_bills b on b.id = l.bill_id
                              where l.boq_item_id = m.boq_item_id and b.status <> 'cancelled' and b.id <> v_id) bl on true
      ) x
     where x.qty > 0;
  end if;

  return v_id;
end;
$function$;

-- Sets a draft's quantities in one step: [{"boq_item_id", "quantity"}, ...];
-- quantity 0 removes the item from the bill.
CREATE FUNCTION public.fn_set_client_bill_lines(p_bill_id uuid, p_lines jsonb)
 RETURNS void LANGUAGE plpgsql SET search_path = public
AS $function$
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Send the items to bill';
  end if;

  delete from client_bill_lines l
   using jsonb_array_elements(p_lines) e
   where l.bill_id = p_bill_id and l.boq_item_id = (e->>'boq_item_id')::uuid
     and coalesce((e->>'quantity')::numeric, 0) = 0;

  insert into client_bill_lines (bill_id, boq_item_id, quantity, rate)
  select p_bill_id, (e->>'boq_item_id')::uuid, (e->>'quantity')::numeric, 0
    from jsonb_array_elements(p_lines) e
   where coalesce((e->>'quantity')::numeric, 0) <> 0
  on conflict (bill_id, boq_item_id) do update set quantity = excluded.quantity;
end;
$function$;

-- The bill as an abstract: every BOQ item of the project with quantity
-- billed before this bill, this bill and to date, and what was measured
-- on site up to the bill's period end.
CREATE FUNCTION public.fn_client_bill_sheet(p_bill_id uuid)
 RETURNS TABLE (boq_item_id uuid, section_name text, section_order integer, description text, unit text,
                boq_quantity numeric, rate numeric, previous_quantity numeric, this_quantity numeric,
                cumulative_quantity numeric, measured_quantity numeric,
                previous_amount numeric, this_amount numeric, cumulative_amount numeric)
 LANGUAGE sql STABLE SET search_path = public
AS $function$
  with b as (select id, project_id, bill_no, period_to from client_bills where id = p_bill_id)
  select bi.id, bs.name, bs.sort_order, bi.description, bi.unit,
         eff.quantity,
         coalesce(cur.rate, eff.rate),
         coalesce(prev.qty, 0),
         coalesce(cur.quantity, 0),
         coalesce(prev.qty, 0) + coalesce(cur.quantity, 0),
         coalesce(ms.qty, 0),
         coalesce(prev.amount, 0),
         coalesce(cur.amount, 0),
         coalesce(prev.amount, 0) + coalesce(cur.amount, 0)
    from b
    join boq_sections bs on bs.project_id = b.project_id
    join boq_items bi on bi.section_id = bs.id
    cross join lateral fn_boq_effective_qty_rate(bi.id) eff
    left join client_bill_lines cur on cur.bill_id = b.id and cur.boq_item_id = bi.id
    left join lateral (select sum(l.quantity) as qty, sum(l.amount) as amount
                         from client_bill_lines l join client_bills pb on pb.id = l.bill_id
                        where l.boq_item_id = bi.id and pb.project_id = b.project_id
                          and pb.bill_no < b.bill_no and pb.status <> 'cancelled') prev on true
    left join lateral (select sum(pe.effective_quantity) as qty
                         from v_progress_effective pe
                        where pe.boq_item_id = bi.id and pe.date <= b.period_to) ms on true
   order by bs.sort_order nulls last, bs.name, bi.created_at, bi.description;
$function$;

CREATE VIEW public.v_client_bills WITH (security_invoker = true) AS
 SELECT b.id AS bill_id,
    b.project_id,
    b.bill_no,
    'RA-' || lpad(b.bill_no::text, 2, '0') AS bill_ref,
    b.status,
    b.bill_date,
    b.period_to,
    b.is_final,
    b.notes,
    b.gross_amount,
    b.retention_amount,
    b.tds_amount,
    b.advance_recovery,
    b.other_deductions,
    b.net_amount,
    b.retention_pct,
    b.tds_pct,
    b.advance_recovery_pct,
    b.certified_amount,
    b.certified_date,
    b.certificate_ref,
    b.submitted_at,
    b.certified_at,
    b.cancelled_at,
    b.cancel_reason,
    COALESCE(p.paid, 0::numeric) AS paid_amount,
    CASE WHEN b.status = ANY (ARRAY['certified'::text, 'paid'::text])
         THEN b.certified_amount - COALESCE(p.paid, 0::numeric) END AS balance_due,
    COALESCE(p.payment_count, 0::bigint) AS payment_count,
    p.last_payment_date,
    b.created_at
   FROM client_bills b
     LEFT JOIN LATERAL ( SELECT sum(cp.amount) AS paid, count(*) AS payment_count, max(cp.received_date) AS last_payment_date
           FROM client_bill_payments cp
          WHERE cp.bill_id = b.id) p ON true;


-- ---------------------------------------------------------------------
-- Grants: signed-in users only; RLS decides the rows
-- ---------------------------------------------------------------------
REVOKE ALL ON public.client_bills, public.client_bill_lines, public.client_bill_deductions,
  public.client_bill_payments, public.v_client_bills FROM anon;
REVOKE ALL ON public.v_client_bills FROM authenticated;
GRANT SELECT ON public.v_client_bills TO authenticated;
-- Payments are append-only.
REVOKE UPDATE, DELETE, TRUNCATE ON public.client_bill_payments FROM authenticated;

REVOKE ALL ON FUNCTION public.fn_can_view_billing(uuid), public.fn_can_manage_billing(uuid),
  public.fn_can_record_client_payment(uuid), public.fn_boq_effective_qty_rate(uuid),
  public.fn_create_client_bill(uuid, date, date, boolean), public.fn_client_bill_sheet(uuid),
  public.fn_set_client_bill_lines(uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_can_view_billing(uuid), public.fn_can_manage_billing(uuid),
  public.fn_can_record_client_payment(uuid), public.fn_boq_effective_qty_rate(uuid),
  public.fn_create_client_bill(uuid, date, date, boolean), public.fn_client_bill_sheet(uuid),
  public.fn_set_client_bill_lines(uuid, jsonb)
  TO authenticated;
-- Internal: only the triggers use these.
REVOKE ALL ON FUNCTION public.fn_client_bill_amounts(uuid, boolean), public.fn_client_bill_paid(uuid),
  public.fn_client_bill_has_later(uuid, integer),
  public.fn_client_bill_before_insert(), public.fn_client_bill_before_update(),
  public.fn_client_bill_line_before_write(), public.fn_client_bill_deduction_before_write(),
  public.fn_client_bill_child_after_write(), public.fn_client_payment_before_insert(),
  public.fn_client_payment_after_insert()
  FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- All-sites dashboard: billed to the client, certified, received,
-- still to come (receivable), retention held, bills awaiting the
-- client's certificate. (New columns at the end.)
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
    pu.deliveries_overdue AS po_deliveries_overdue,
    cbl.billed AS client_billed,
    cbl.certified AS client_certified,
    cbl.received AS client_received,
    cbl.certified - cbl.received AS client_receivable,
    cbl.retention_held AS client_retention_held,
    cbl.awaiting_certification AS client_bills_awaiting_certification
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
     LEFT JOIN LATERAL ( SELECT
            COALESCE(sum(b.gross_amount) FILTER (WHERE b.status = ANY (ARRAY['submitted'::text, 'certified'::text, 'paid'::text])), 0::numeric) AS billed,
            COALESCE(sum(b.certified_amount) FILTER (WHERE b.status = ANY (ARRAY['certified'::text, 'paid'::text])), 0::numeric) AS certified,
            COALESCE(( SELECT sum(cp.amount) FROM client_bill_payments cp WHERE cp.project_id = p.id), 0::numeric) AS received,
            COALESCE(sum(b.retention_amount) FILTER (WHERE b.status = ANY (ARRAY['submitted'::text, 'certified'::text, 'paid'::text])), 0::numeric) AS retention_held,
            count(*) FILTER (WHERE b.status = 'submitted'::text) AS awaiting_certification
           FROM client_bills b
          WHERE b.project_id = p.id) cbl ON true
  WHERE fn_is_company_owner_of_project(p.id) OR fn_has_project_role(p.id, 'admin'::text);
