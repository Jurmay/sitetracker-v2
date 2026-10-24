-- CANARY ONLY: reopens the cashbook leak to prove CI catches it. Never merge.
CREATE OR REPLACE VIEW public.v_cashbook_running_balance AS
 SELECT p.id AS project_id, 0::numeric AS total_fund_receipts, 0::numeric AS total_disbursed,
        0::numeric AS current_balance, 0::numeric AS balance_pct_of_fund
   FROM projects p;
GRANT SELECT ON public.v_cashbook_running_balance TO anon;
