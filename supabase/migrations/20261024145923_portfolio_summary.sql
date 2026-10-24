-- =====================================================================
-- Owner dashboard across all sites: one row per project with progress,
-- cost, cash, pending approvals, overdue settlements and today's
-- submissions.
--
-- Like the other reporting views it runs with its owner's rights, so it
-- filters rows itself: only a project's company owner or admin sees it.
-- "Today" is the database's current_date, the same day the escalation
-- checks and advance locks use.
-- =====================================================================

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
    lp.last_progress_date
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
  WHERE fn_is_company_owner_of_project(p.id) OR fn_has_project_role(p.id, 'admin'::text);

REVOKE ALL ON public.v_portfolio_summary FROM anon, authenticated;
GRANT SELECT ON public.v_portfolio_summary TO authenticated;
