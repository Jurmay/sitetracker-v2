-- =====================================================================
-- Retention release: claiming back the retention the client deducted
-- from running bills, usually in parts (e.g. half on completion, the
-- rest at the end of the defects liability period).
--
--   client_retention_releases  RR-01, RR-02.. per project;
--                              claimed -> received, or cancelled
--
-- Retention held = retention on certified or paid bills. A claim can
-- never be more than what is still held and not already claimed.
-- Recording it as received is what takes it off "retention held".
--
-- Who can do what (RLS):
--   see:                 as client bills (Owner, Admin, Cashier, Viewer with grant)
--   claim, cancel:       Owner, Admin
--   record as received:  Owner, Admin, Cashier
-- =====================================================================

CREATE TABLE public.client_retention_releases (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  release_no integer NOT NULL,
  status text DEFAULT 'claimed' NOT NULL CHECK (status = ANY (ARRAY['claimed', 'received', 'cancelled'])),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  claim_date date DEFAULT CURRENT_DATE NOT NULL,
  stage text,  -- e.g. "Half on completion", "End of defects liability period"
  notes text,
  received_date date,
  received_reference text,  -- cheque / transfer number
  received_by uuid REFERENCES public.profiles(id),
  received_at timestamp with time zone,
  cancelled_by uuid REFERENCES public.profiles(id),
  cancelled_at timestamp with time zone,
  cancel_reason text,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  UNIQUE (project_id, release_no)
);
CREATE INDEX idx_retention_releases_project ON public.client_retention_releases USING btree (project_id, release_no);


-- What the client still holds, and what can still be claimed.
CREATE FUNCTION public.fn_retention_position(p_project_id uuid)
 RETURNS TABLE (withheld numeric, claimed_open numeric, released numeric, held numeric, available numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  with w as (select coalesce(sum(retention_amount), 0) as v from client_bills
              where project_id = p_project_id and status = ANY (ARRAY['certified', 'paid'])),
       r as (select coalesce(sum(amount) filter (where status = 'claimed'), 0) as claimed,
                    coalesce(sum(amount) filter (where status = 'received'), 0) as received
               from client_retention_releases where project_id = p_project_id)
  select w.v, r.claimed, r.received, w.v - r.received, w.v - r.received - r.claimed
    from w, r
   where fn_can_view_billing(p_project_id);
$function$;


CREATE FUNCTION public.fn_retention_release_before_insert()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_available numeric;
begin
  -- Permission first, so nobody outside the project learns anything from the rules below.
  if not fn_can_manage_billing(new.project_id) then
    raise exception 'new row violates row-level security policy for table "client_retention_releases"' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('retention_release:' || new.project_id::text));

  select available into v_available from fn_retention_position(new.project_id);
  if new.amount > coalesce(v_available, 0) then
    raise exception 'Only % of retention is still held and not already claimed', coalesce(v_available, 0);
  end if;
  if new.claim_date > current_date then
    raise exception 'The claim date cannot be in the future';
  end if;

  select coalesce(max(release_no), 0) + 1 into new.release_no
    from client_retention_releases where project_id = new.project_id;
  new.status := 'claimed';
  new.received_date := null; new.received_reference := null; new.received_by := null; new.received_at := null;
  new.cancelled_by := null; new.cancelled_at := null; new.cancel_reason := null;
  return new;
end;
$function$;

CREATE FUNCTION public.fn_retention_release_before_update()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
begin
  if (new.project_id, new.release_no, new.amount, new.claim_date, new.stage, new.created_by)
     is distinct from (old.project_id, old.release_no, old.amount, old.claim_date, old.stage, old.created_by) then
    raise exception 'A retention claim cannot be changed; cancel it and make a new one';
  end if;
  if new.status = old.status then
    if (new.received_date, new.received_reference, new.cancel_reason)
       is distinct from (old.received_date, old.received_reference, old.cancel_reason) then
      raise exception 'This retention claim is already %', old.status;
    end if;
    return new;
  end if;

  if old.status = 'claimed' and new.status = 'received' then
    if not fn_can_record_client_payment(new.project_id) then
      raise exception 'Only an Admin, Owner or Cashier can record retention as received' using errcode = '42501';
    end if;
    new.received_date := coalesce(new.received_date, current_date);
    if new.received_date > current_date then
      raise exception 'The received date cannot be in the future';
    end if;
    if new.received_date < old.claim_date then
      raise exception 'The received date is before the claim date (%)', old.claim_date;
    end if;
    new.received_by := auth.uid();
    new.received_at := now();
  elsif old.status = 'claimed' and new.status = 'cancelled' then
    if not fn_can_manage_billing(new.project_id) then
      raise exception 'Only an Admin or Owner can cancel a retention claim' using errcode = '42501';
    end if;
    if coalesce(btrim(new.cancel_reason), '') = '' then
      raise exception 'Give a reason for cancelling the claim';
    end if;
    new.cancelled_by := auth.uid();
    new.cancelled_at := now();
  else
    raise exception 'A retention claim cannot go from % to %', old.status, new.status;
  end if;
  return new;
end;
$function$;

CREATE TRIGGER trg_retention_release_before_insert BEFORE INSERT ON public.client_retention_releases
  FOR EACH ROW EXECUTE FUNCTION fn_retention_release_before_insert();
CREATE TRIGGER trg_retention_release_before_update BEFORE UPDATE ON public.client_retention_releases
  FOR EACH ROW EXECUTE FUNCTION fn_retention_release_before_update();
CREATE TRIGGER trg_audit_client_retention_releases AFTER INSERT OR DELETE OR UPDATE ON public.client_retention_releases
  FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();

ALTER TABLE public.client_retention_releases ENABLE ROW LEVEL SECURITY;
CREATE POLICY retention_releases_select ON public.client_retention_releases FOR SELECT TO authenticated
  USING (fn_can_view_billing(project_id));
CREATE POLICY retention_releases_insert ON public.client_retention_releases FOR INSERT TO authenticated
  WITH CHECK (fn_can_manage_billing(project_id) AND created_by = auth.uid());
CREATE POLICY retention_releases_update ON public.client_retention_releases FOR UPDATE TO authenticated
  USING (fn_can_record_client_payment(project_id)) WITH CHECK (fn_can_record_client_payment(project_id));

REVOKE ALL ON public.client_retention_releases FROM anon;
REVOKE DELETE, TRUNCATE ON public.client_retention_releases FROM authenticated;
REVOKE ALL ON FUNCTION public.fn_retention_position(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_retention_position(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.fn_retention_release_before_insert(), public.fn_retention_release_before_update()
  FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- All-sites dashboard: retention held now means retention on certified
-- or paid bills that hasn't been received back; received and receivable
-- include retention claims. (Same columns as before.)
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
    cbl.received + rr.received AS client_received,
    cbl.certified - cbl.received + rr.claimed AS client_receivable,
    cbl.retention_held - rr.received AS client_retention_held,
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
            COALESCE(sum(b.retention_amount) FILTER (WHERE b.status = ANY (ARRAY['certified'::text, 'paid'::text])), 0::numeric) AS retention_held,
            count(*) FILTER (WHERE b.status = 'submitted'::text) AS awaiting_certification
           FROM client_bills b
          WHERE b.project_id = p.id) cbl ON true
     LEFT JOIN LATERAL ( SELECT
            COALESCE(sum(r.amount) FILTER (WHERE r.status = 'received'::text), 0::numeric) AS received,
            COALESCE(sum(r.amount) FILTER (WHERE r.status = 'claimed'::text), 0::numeric) AS claimed
           FROM client_retention_releases r
          WHERE r.project_id = p.id) rr ON true
  WHERE fn_is_company_owner_of_project(p.id) OR fn_has_project_role(p.id, 'admin'::text);
