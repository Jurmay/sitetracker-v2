-- =====================================================================
-- Close two holes found on 2026-10-24.
--
-- 1. The six reporting views run with their owner's rights, so the RLS
--    policies on the tables underneath never applied. Anyone with the
--    public anon key could read every company's cashbook balance and
--    BOQ costs, and v_progress_effective (a single-table view, so
--    auto-updatable) let them UPDATE any progress report.
--
--    Fix: each view now only returns rows for projects the caller is an
--    active member of, and views are read-only for API roles. Members
--    see exactly the same numbers as before, so dashboards and reports
--    don't change.
--
-- 2. Any signed-in user of any company could list and read every
--    settlement receipt, and upload into any project's folder.
--
--    Fix: receipts are scoped by project (paths are "<project_id>/...").
--    The bucket itself is made private in a follow-up migration, once
--    the frontend uses signed URLs instead of public links.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Views: members-only rows, no writes
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_progress_effective AS
 SELECT id AS progress_report_id,
    project_id,
    boq_item_id,
    subcontract_id,
    coordinator_id,
    date,
    COALESCE(( SELECT pc.corrected_quantity
           FROM progress_corrections pc
          WHERE pc.progress_report_id = pr.id
          ORDER BY pc.corrected_at DESC
         LIMIT 1), measured_quantity) AS effective_quantity,
    status
   FROM progress_reports pr
  WHERE fn_has_project_access(pr.project_id);

CREATE OR REPLACE VIEW public.v_actual_cost_by_boq_item AS
 SELECT ar.boq_item_id,
    sum(s.settled_amount) AS actual_cost
   FROM advance_settlements s
     JOIN advance_requisitions ar ON ar.id = s.requisition_id
  WHERE s.status = 'settled'::text AND ar.advance_category = 'work_tied'::text AND ar.boq_item_id IS NOT NULL
    AND fn_has_project_access(ar.project_id)
  GROUP BY ar.boq_item_id;

CREATE OR REPLACE VIEW public.v_subcontract_balances AS
 SELECT sc.id AS subcontract_id,
    sc.project_id,
    sc.team_lead_name,
    sc.status,
    COALESCE(drawn.total_drawn, 0::numeric) AS total_drawn,
    COALESCE(earned.total_earned, 0::numeric) AS total_earned,
    COALESCE(earned.total_earned, 0::numeric) - COALESCE(drawn.total_drawn, 0::numeric) AS net_position
   FROM subcontracts sc
     LEFT JOIN ( SELECT ar.subcontract_id,
            sum(ar.amount) AS total_drawn
           FROM advance_requisitions ar
          WHERE ar.status = 'disbursed'::text AND ar.advance_category = 'subcontract'::text
          GROUP BY ar.subcontract_id) drawn ON drawn.subcontract_id = sc.id
     LEFT JOIN ( SELECT pe.subcontract_id,
            sum(pe.effective_quantity * sc2.agreed_rate) AS total_earned
           FROM v_progress_effective pe
             JOIN subcontracts sc2 ON sc2.id = pe.subcontract_id
          WHERE pe.subcontract_id IS NOT NULL
          GROUP BY pe.subcontract_id, sc2.agreed_rate) earned ON earned.subcontract_id = sc.id
  WHERE fn_has_project_access(sc.project_id);

CREATE OR REPLACE VIEW public.v_cashbook_running_balance AS
 SELECT p.id AS project_id,
    COALESCE(fr.total_received, 0::numeric) AS total_fund_receipts,
    COALESCE(disb.total_disbursed, 0::numeric) AS total_disbursed,
    COALESCE(fr.total_received, 0::numeric) - COALESCE(disb.total_disbursed, 0::numeric) AS current_balance,
        CASE
            WHEN COALESCE(fr.total_received, 0::numeric) > 0::numeric THEN round(100.0 * (COALESCE(fr.total_received, 0::numeric) - COALESCE(disb.total_disbursed, 0::numeric)) / fr.total_received, 2)
            ELSE 0::numeric
        END AS balance_pct_of_fund
   FROM projects p
     LEFT JOIN ( SELECT fund_receipts.project_id,
            sum(fund_receipts.amount) AS total_received
           FROM fund_receipts
          GROUP BY fund_receipts.project_id) fr ON fr.project_id = p.id
     LEFT JOIN ( SELECT advance_requisitions.project_id,
            sum(advance_requisitions.amount) AS total_disbursed
           FROM advance_requisitions
          WHERE advance_requisitions.status = 'disbursed'::text
          GROUP BY advance_requisitions.project_id) disb ON disb.project_id = p.id
  WHERE fn_has_project_access(p.id);

CREATE OR REPLACE VIEW public.v_evm_by_boq_item AS
 SELECT bi.id AS boq_item_id,
    bs.project_id,
    bi.description,
    bi.quantity AS budgeted_quantity,
    bi.rate,
    bi.budgeted_cost AS original_budgeted_cost,
    fn_boq_effective_budget(bi.id) AS effective_budgeted_cost,
        CASE
            WHEN bi.planned_start IS NULL OR bi.planned_end IS NULL OR bi.planned_end <= bi.planned_start THEN 0::numeric
            ELSE fn_boq_effective_budget(bi.id) * GREATEST(0::numeric, LEAST(1::numeric, (CURRENT_DATE - bi.planned_start)::numeric / (bi.planned_end - bi.planned_start)::numeric))
        END AS planned_value,
    COALESCE(( SELECT sum(pe.effective_quantity) * bi.rate
           FROM v_progress_effective pe
          WHERE pe.boq_item_id = bi.id), 0::numeric) AS earned_value,
    COALESCE(( SELECT v_actual_cost_by_boq_item.actual_cost
           FROM v_actual_cost_by_boq_item
          WHERE v_actual_cost_by_boq_item.boq_item_id = bi.id), 0::numeric) AS actual_cost,
    COALESCE(( SELECT sum(pe.effective_quantity) AS sum
           FROM v_progress_effective pe
          WHERE pe.boq_item_id = bi.id), 0::numeric) AS cumulative_measured_quantity
   FROM boq_items bi
     JOIN boq_sections bs ON bs.id = bi.section_id
  WHERE fn_has_project_access(bs.project_id);

-- v_evm_by_project only reads v_evm_by_boq_item, which is now filtered.

-- Views are for reading only; nothing in the app writes through them.
REVOKE ALL ON public.v_progress_effective, public.v_actual_cost_by_boq_item,
  public.v_subcontract_balances, public.v_cashbook_running_balance,
  public.v_evm_by_boq_item, public.v_evm_by_project
  FROM anon, authenticated;
GRANT SELECT ON public.v_progress_effective, public.v_actual_cost_by_boq_item,
  public.v_subcontract_balances, public.v_cashbook_running_balance,
  public.v_evm_by_boq_item, public.v_evm_by_project
  TO authenticated;


-- ---------------------------------------------------------------------
-- 2. Settlement receipts: scoped to the project in the path
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "authenticated read receipts" ON storage.objects;
DROP POLICY IF EXISTS "authenticated upload receipts" ON storage.objects;

-- Same audience as fn_can_view_document() for 'advance_settlement':
-- owner, admin, cashier, viewers with the cashbook grant, and the
-- coordinator who uploaded the receipt.
CREATE POLICY settlement_receipts_select ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
  USING (((bucket_id = 'settlement-receipts'::text) AND (
    fn_is_company_owner_of_project(fn_storage_path_project_id(name))
    OR fn_has_project_role(fn_storage_path_project_id(name), 'admin'::text)
    OR fn_has_project_role(fn_storage_path_project_id(name), 'cashier'::text)
    OR (fn_has_project_role(fn_storage_path_project_id(name), 'viewer'::text) AND fn_viewer_has_financial_grant(fn_storage_path_project_id(name)))
    OR (owner_id = (auth.uid())::text)
  )));

-- Only site coordinators submit settlements, into their own project.
CREATE POLICY settlement_receipts_insert ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((bucket_id = 'settlement-receipts'::text) AND fn_has_project_role(fn_storage_path_project_id(name), 'site_coordinator'::text)));
