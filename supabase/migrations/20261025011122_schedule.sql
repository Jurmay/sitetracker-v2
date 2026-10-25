-- =====================================================================
-- Schedule: one row per BOQ item, built from data already entered.
--
-- Planned dates come from boq_items.planned_start/planned_end; actual
-- progress from progress reports (after corrections) via
-- v_progress_effective. For each item: % done vs % expected by today,
-- actual start, actual finish (the day cumulative quantity reached the
-- BOQ quantity, variations included), forecast finish at the average
-- pace so far, days late, and a status:
--   done | unscheduled | overdue | not_started | late_start | behind | on_track
-- "behind" means more than 10 percentage points under the expected %.
--
-- security_invoker: RLS on boq_items applies, so a Viewer without the
-- financial grant sees no rows and a coordinator only their scope.
-- Progress quantities come through v_progress_effective, which already
-- limits rows to project members.
--
-- v_portfolio_summary gains two columns at the end: late and
-- unscheduled item counts per site.
-- =====================================================================

CREATE OR REPLACE VIEW public.v_schedule_by_boq_item WITH (security_invoker = true) AS
 WITH item AS (
         SELECT bi.id,
            bs.project_id,
            bs.id AS section_id,
            bs.name AS section_name,
            bs.sort_order AS section_sort,
            bi.description,
            bi.unit,
            bi.quantity + COALESCE(( SELECT sum(v.qty_delta) FROM boq_variations v WHERE v.boq_item_id = bi.id), 0::numeric) AS quantity,
            bi.planned_start,
            bi.planned_end
           FROM boq_items bi
             JOIN boq_sections bs ON bs.id = bi.section_id
        ), daily AS (
         SELECT pe.boq_item_id, pe.date, sum(pe.effective_quantity) AS qty
           FROM v_progress_effective pe
          GROUP BY pe.boq_item_id, pe.date
        ), running AS (
         SELECT d.boq_item_id, d.date,
            sum(d.qty) OVER (PARTITION BY d.boq_item_id ORDER BY d.date) AS cum
           FROM daily d
        ), agg AS (
         SELECT i_1.id,
            COALESCE(max(r.cum), 0::numeric) AS done_qty,
            min(r.date) FILTER (WHERE r.cum > 0::numeric) AS actual_start,
            max(r.date) AS last_progress_date,
            min(r.date) FILTER (WHERE r.cum >= i_1.quantity AND i_1.quantity > 0::numeric) AS actual_finish
           FROM item i_1
             LEFT JOIN running r ON r.boq_item_id = i_1.id
          GROUP BY i_1.id
        ), calc AS (
         SELECT i_1.*, a.done_qty, a.actual_start, a.last_progress_date, a.actual_finish,
                CASE WHEN i_1.quantity > 0::numeric THEN round(100.0 * a.done_qty / i_1.quantity, 1) ELSE 0::numeric END AS pct_complete,
                CASE
                    WHEN i_1.planned_start IS NULL OR i_1.planned_end IS NULL OR i_1.planned_end <= i_1.planned_start THEN NULL::numeric
                    ELSE round(100.0 * GREATEST(0::numeric, LEAST(1::numeric, (CURRENT_DATE - i_1.planned_start)::numeric / (i_1.planned_end - i_1.planned_start)::numeric)), 1)
                END AS pct_expected,
                -- Finish date if work keeps its average pace since it started (capped at 10 years).
                CASE
                    WHEN a.actual_finish IS NULL AND a.actual_start IS NOT NULL AND a.done_qty > 0::numeric AND a.done_qty < i_1.quantity
                    THEN CURRENT_DATE + LEAST(3650::numeric, ceil((i_1.quantity - a.done_qty) / (a.done_qty / (CURRENT_DATE - a.actual_start + 1)::numeric)))::integer
                    ELSE NULL::date
                END AS forecast_finish
           FROM item i_1
             JOIN agg a ON a.id = i_1.id
        )
 SELECT id AS boq_item_id,
    project_id, section_id, section_name, section_sort, description, unit,
    quantity, done_qty, pct_complete,
    planned_start, planned_end, pct_expected,
    actual_start, actual_finish, last_progress_date, forecast_finish,
        CASE
            WHEN actual_finish IS NOT NULL THEN 'done'::text
            WHEN planned_start IS NULL OR planned_end IS NULL THEN 'unscheduled'::text
            WHEN CURRENT_DATE > planned_end THEN 'overdue'::text
            WHEN done_qty = 0::numeric AND CURRENT_DATE <= planned_start THEN 'not_started'::text
            WHEN done_qty = 0::numeric THEN 'late_start'::text
            WHEN pct_complete + 10::numeric < pct_expected THEN 'behind'::text
            ELSE 'on_track'::text
        END AS schedule_status,
        -- Days past planned_end: actual for finished items, forecast (or
        -- at least today) for unfinished ones. Negative = early.
        CASE
            WHEN planned_end IS NULL THEN NULL::integer
            WHEN actual_finish IS NOT NULL THEN actual_finish - planned_end
            WHEN forecast_finish IS NOT NULL THEN GREATEST(forecast_finish, CURRENT_DATE) - planned_end
            WHEN CURRENT_DATE > planned_end THEN CURRENT_DATE - planned_end
            ELSE NULL::integer
        END AS delay_days
   FROM calc;

REVOKE ALL ON public.v_schedule_by_boq_item FROM anon, authenticated;
GRANT SELECT ON public.v_schedule_by_boq_item TO authenticated;

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
    sc.unscheduled AS schedule_items_unscheduled
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
  WHERE fn_is_company_owner_of_project(p.id) OR fn_has_project_role(p.id, 'admin'::text);

