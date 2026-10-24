-- =====================================================================
-- SiteTracker v2 - baseline schema
--
-- Exported 2026-10-24 from the live Supabase project "construction-tracker"
-- (ref jkrufgvevngifqkbrpja). Until now the schema lived only in that
-- project (the original migrations 001-007 were run by hand in the SQL
-- editor and never committed). This file recreates it exactly as it is
-- live: it is a snapshot, not a redesign. Fixes go in later migrations.
--
-- Not included (set by hand per project, see supabase/README.md):
--   * Vault secrets: edge_function_base_url, service_role_key
--   * Edge function env: RESEND_API_KEY, ACCOUNTS_EMAIL_FROM
-- =====================================================================


-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;


-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
CREATE TABLE public.companies (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  name text NOT NULL,
  currency text DEFAULT 'BTN'::text NOT NULL,
  subscription_tier text DEFAULT 'internal'::text NOT NULL,
  project_limit integer,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.profiles (
  id uuid NOT NULL,
  company_id uuid NOT NULL,
  name text NOT NULL,
  email text NOT NULL,
  phone text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.projects (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  company_id uuid NOT NULL,
  name text NOT NULL,
  location text,
  start_date date,
  target_end_date date,
  total_budget numeric(14,2) DEFAULT 0 NOT NULL,
  currency text DEFAULT 'BTN'::text NOT NULL,
  status text DEFAULT 'active'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.project_settings (
  project_id uuid NOT NULL,
  max_upload_size_mb integer DEFAULT 2 NOT NULL,
  settlement_grace_days integer DEFAULT 7 NOT NULL,
  master_roll_reminder_hours integer DEFAULT 6 NOT NULL,
  progress_report_reminder_hours integer DEFAULT 6 NOT NULL,
  cash_replenishment_threshold_pct numeric(5,2) DEFAULT 20.00 NOT NULL,
  accounts_department_email text,
  coordinator_split_mode text DEFAULT 'none'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.project_roles (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  user_id uuid NOT NULL,
  role text NOT NULL,
  status text DEFAULT 'active'::text NOT NULL,
  assigned_by uuid,
  assigned_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.zones (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  name text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.coordinator_assignments (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  coordinator_id uuid NOT NULL,
  scope_type text NOT NULL,
  scope_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.leave_periods (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  coordinator_id uuid NOT NULL,
  start_date date NOT NULL,
  end_date date NOT NULL,
  reason text,
  declared_by uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.boq_sections (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  name text NOT NULL,
  sort_order integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.boq_items (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  section_id uuid NOT NULL,
  zone_id uuid,
  description text NOT NULL,
  unit text NOT NULL,
  quantity numeric(14,3) NOT NULL,
  rate numeric(14,2) NOT NULL,
  budgeted_cost numeric(14,2) GENERATED ALWAYS AS ((quantity * rate)) STORED,
  planned_start date,
  planned_end date,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.boq_variations (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  boq_item_id uuid NOT NULL,
  qty_delta numeric(14,3) DEFAULT 0 NOT NULL,
  rate_delta numeric(14,2) DEFAULT 0 NOT NULL,
  reason text NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.labour_categories (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  name text NOT NULL,
  default_daily_rate numeric(10,2) DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.labourers (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  name text NOT NULL,
  photo_url text NOT NULL,
  id_number text NOT NULL,
  labour_type text NOT NULL,
  labour_category_id uuid,
  contracted_rate numeric(10,2),
  created_by uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.master_roll_entries (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  coordinator_id uuid NOT NULL,
  date date NOT NULL,
  is_no_work_day boolean DEFAULT false NOT NULL,
  no_work_remarks text,
  is_late_entry boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.master_roll_attendance (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  entry_id uuid NOT NULL,
  labourer_id uuid NOT NULL,
  present boolean DEFAULT true NOT NULL
);

CREATE TABLE public.subcontracts (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  boq_item_id uuid NOT NULL,
  team_lead_name text NOT NULL,
  agreed_rate numeric(14,2) NOT NULL,
  status text DEFAULT 'active'::text NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.progress_reports (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  boq_item_id uuid NOT NULL,
  subcontract_id uuid,
  coordinator_id uuid NOT NULL,
  date date NOT NULL,
  measured_quantity numeric(14,3) NOT NULL,
  notes text,
  status text DEFAULT 'reported'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.progress_corrections (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  progress_report_id uuid NOT NULL,
  original_quantity numeric(14,3) NOT NULL,
  corrected_quantity numeric(14,3) NOT NULL,
  reason text NOT NULL,
  corrected_by uuid NOT NULL,
  corrected_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.material_logs (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  boq_item_id uuid,
  coordinator_id uuid NOT NULL,
  material_name text NOT NULL,
  quantity numeric(14,3) NOT NULL,
  unit text NOT NULL,
  log_type text NOT NULL,
  date date NOT NULL,
  notes text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.ledger_heads (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  name text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.advance_requisitions (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  requested_by uuid NOT NULL,
  advance_category text NOT NULL,
  boq_item_id uuid,
  subcontract_id uuid,
  ledger_head_id uuid,
  amount numeric(14,2) NOT NULL,
  justification text NOT NULL,
  status text DEFAULT 'pending_verification'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.advance_requisition_actions (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  requisition_id uuid NOT NULL,
  action_by uuid NOT NULL,
  action_type text NOT NULL,
  remarks text,
  action_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.advance_settlements (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  requisition_id uuid NOT NULL,
  project_id uuid NOT NULL,
  submitted_by uuid NOT NULL,
  settled_amount numeric(14,2) NOT NULL,
  status text DEFAULT 'pending_verification'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  receipt_url text
);

CREATE TABLE public.advance_settlement_actions (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  settlement_id uuid NOT NULL,
  action_by uuid NOT NULL,
  action_type text NOT NULL,
  remarks text,
  action_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.documents (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  file_path text NOT NULL,
  file_size_bytes integer NOT NULL,
  mime_type text NOT NULL,
  uploaded_by uuid NOT NULL,
  uploaded_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.fund_receipts (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL,
  source text DEFAULT 'head_office'::text NOT NULL,
  received_at timestamp with time zone DEFAULT now() NOT NULL,
  recorded_by uuid NOT NULL
);

CREATE TABLE public.fund_requisitions (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  requested_by uuid NOT NULL,
  amount numeric(14,2) NOT NULL,
  reason text NOT NULL,
  status text DEFAULT 'pending_approval'::text NOT NULL,
  fund_receipt_id uuid,
  accounts_email_sent_at timestamp with time zone,
  approved_by uuid,
  approved_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.report_definitions (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  key text NOT NULL,
  name text NOT NULL,
  category text NOT NULL,
  default_visible_to_viewer boolean DEFAULT false NOT NULL
);

CREATE TABLE public.user_report_permissions (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  user_id uuid NOT NULL,
  report_definition_id uuid NOT NULL,
  granted boolean DEFAULT false NOT NULL,
  granted_by uuid,
  granted_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.notification_events (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid NOT NULL,
  event_type text NOT NULL,
  target_user_id uuid,
  payload jsonb DEFAULT '{}'::jsonb NOT NULL,
  status text DEFAULT 'pending'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  sent_at timestamp with time zone
);

CREATE TABLE public.audit_log (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  project_id uuid,
  actor_id uuid,
  action_type text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  before_value jsonb,
  after_value jsonb,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);


-- ---------------------------------------------------------------------
-- Primary keys, unique and check constraints
-- ---------------------------------------------------------------------
ALTER TABLE ONLY public.companies ADD CONSTRAINT companies_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.profiles ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.projects ADD CONSTRAINT projects_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.projects ADD CONSTRAINT projects_status_check CHECK ((status = ANY (ARRAY['active'::text, 'on_hold'::text, 'completed'::text, 'archived'::text])));
ALTER TABLE ONLY public.project_settings ADD CONSTRAINT project_settings_pkey PRIMARY KEY (project_id);
ALTER TABLE ONLY public.project_settings ADD CONSTRAINT project_settings_coordinator_split_mode_check CHECK ((coordinator_split_mode = ANY (ARRAY['none'::text, 'section'::text, 'zone'::text])));
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_project_id_user_id_role_key UNIQUE (project_id, user_id, role);
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_role_check CHECK ((role = ANY (ARRAY['company_owner'::text, 'admin'::text, 'site_coordinator'::text, 'cashier'::text, 'viewer'::text])));
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text])));
ALTER TABLE ONLY public.zones ADD CONSTRAINT zones_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.coordinator_assignments ADD CONSTRAINT coordinator_assignments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.coordinator_assignments ADD CONSTRAINT coordinator_assignments_project_id_coordinator_id_scope_typ_key UNIQUE (project_id, coordinator_id, scope_type, scope_id);
ALTER TABLE ONLY public.coordinator_assignments ADD CONSTRAINT coordinator_assignments_scope_type_check CHECK ((scope_type = ANY (ARRAY['section'::text, 'zone'::text])));
ALTER TABLE ONLY public.leave_periods ADD CONSTRAINT leave_periods_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.leave_periods ADD CONSTRAINT leave_periods_check CHECK ((end_date >= start_date));
ALTER TABLE ONLY public.boq_sections ADD CONSTRAINT boq_sections_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.boq_items ADD CONSTRAINT boq_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.boq_items ADD CONSTRAINT boq_items_quantity_check CHECK ((quantity >= (0)::numeric));
ALTER TABLE ONLY public.boq_items ADD CONSTRAINT boq_items_rate_check CHECK ((rate >= (0)::numeric));
ALTER TABLE ONLY public.boq_variations ADD CONSTRAINT boq_variations_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.labour_categories ADD CONSTRAINT labour_categories_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.labourers ADD CONSTRAINT labourers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.labourers ADD CONSTRAINT labourers_check CHECK ((((labour_type = 'daily_wage'::text) AND (labour_category_id IS NOT NULL)) OR (labour_type = 'contract'::text)));
ALTER TABLE ONLY public.labourers ADD CONSTRAINT labourers_labour_type_check CHECK ((labour_type = ANY (ARRAY['contract'::text, 'daily_wage'::text])));
ALTER TABLE ONLY public.master_roll_entries ADD CONSTRAINT master_roll_entries_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.master_roll_entries ADD CONSTRAINT master_roll_entries_check CHECK ((((is_no_work_day = true) AND (no_work_remarks IS NOT NULL) AND (length(TRIM(BOTH FROM no_work_remarks)) > 0)) OR (is_no_work_day = false)));
ALTER TABLE ONLY public.master_roll_attendance ADD CONSTRAINT master_roll_attendance_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.master_roll_attendance ADD CONSTRAINT master_roll_attendance_entry_id_labourer_id_key UNIQUE (entry_id, labourer_id);
ALTER TABLE ONLY public.subcontracts ADD CONSTRAINT subcontracts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.subcontracts ADD CONSTRAINT subcontracts_agreed_rate_check CHECK ((agreed_rate >= (0)::numeric));
ALTER TABLE ONLY public.subcontracts ADD CONSTRAINT subcontracts_status_check CHECK ((status = ANY (ARRAY['active'::text, 'completed'::text, 'exited'::text])));
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_measured_quantity_check CHECK ((measured_quantity >= (0)::numeric));
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_status_check CHECK ((status = ANY (ARRAY['reported'::text, 'certified'::text])));
ALTER TABLE ONLY public.progress_corrections ADD CONSTRAINT progress_corrections_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.progress_corrections ADD CONSTRAINT progress_corrections_corrected_quantity_check CHECK ((corrected_quantity >= (0)::numeric));
ALTER TABLE ONLY public.material_logs ADD CONSTRAINT material_logs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.material_logs ADD CONSTRAINT material_logs_log_type_check CHECK ((log_type = ANY (ARRAY['received'::text, 'consumed'::text])));
ALTER TABLE ONLY public.ledger_heads ADD CONSTRAINT ledger_heads_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_advance_category_check CHECK ((advance_category = ANY (ARRAY['work_tied'::text, 'subcontract'::text, 'overhead'::text])));
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_check CHECK ((((advance_category = 'work_tied'::text) AND (boq_item_id IS NOT NULL) AND (subcontract_id IS NULL)) OR ((advance_category = 'subcontract'::text) AND (subcontract_id IS NOT NULL) AND (boq_item_id IS NULL)) OR ((advance_category = 'overhead'::text) AND (boq_item_id IS NULL) AND (subcontract_id IS NULL))));
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_status_check CHECK ((status = ANY (ARRAY['pending_verification'::text, 'pending_approval'::text, 'approved'::text, 'disbursed'::text, 'rejected'::text])));
ALTER TABLE ONLY public.advance_requisition_actions ADD CONSTRAINT advance_requisition_actions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.advance_requisition_actions ADD CONSTRAINT advance_requisition_actions_action_type_check CHECK ((action_type = ANY (ARRAY['verified'::text, 'approved'::text, 'rejected'::text, 'disbursed'::text])));
ALTER TABLE ONLY public.advance_requisition_actions ADD CONSTRAINT advance_requisition_actions_check CHECK (((action_type <> 'rejected'::text) OR ((remarks IS NOT NULL) AND (length(TRIM(BOTH FROM remarks)) > 0))));
ALTER TABLE ONLY public.advance_settlements ADD CONSTRAINT advance_settlements_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.advance_settlements ADD CONSTRAINT advance_settlements_settled_amount_check CHECK ((settled_amount > (0)::numeric));
ALTER TABLE ONLY public.advance_settlements ADD CONSTRAINT advance_settlements_status_check CHECK ((status = ANY (ARRAY['pending_verification'::text, 'settled'::text, 'rejected'::text])));
ALTER TABLE ONLY public.advance_settlement_actions ADD CONSTRAINT advance_settlement_actions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.advance_settlement_actions ADD CONSTRAINT advance_settlement_actions_action_type_check CHECK ((action_type = ANY (ARRAY['verified'::text, 'rejected'::text])));
ALTER TABLE ONLY public.advance_settlement_actions ADD CONSTRAINT advance_settlement_actions_check CHECK (((action_type <> 'rejected'::text) OR ((remarks IS NOT NULL) AND (length(TRIM(BOTH FROM remarks)) > 0))));
ALTER TABLE ONLY public.documents ADD CONSTRAINT documents_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.fund_receipts ADD CONSTRAINT fund_receipts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.fund_receipts ADD CONSTRAINT fund_receipts_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_status_check CHECK ((status = ANY (ARRAY['pending_approval'::text, 'approved'::text, 'rejected'::text])));
ALTER TABLE ONLY public.report_definitions ADD CONSTRAINT report_definitions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.report_definitions ADD CONSTRAINT report_definitions_key_key UNIQUE (key);
ALTER TABLE ONLY public.report_definitions ADD CONSTRAINT report_definitions_category_check CHECK ((category = ANY (ARRAY['progress'::text, 'financial'::text, 'labour'::text, 'system'::text])));
ALTER TABLE ONLY public.user_report_permissions ADD CONSTRAINT user_report_permissions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.user_report_permissions ADD CONSTRAINT user_report_permissions_project_id_user_id_report_definitio_key UNIQUE (project_id, user_id, report_definition_id);
ALTER TABLE ONLY public.notification_events ADD CONSTRAINT notification_events_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.notification_events ADD CONSTRAINT notification_events_event_type_check CHECK ((event_type = ANY (ARRAY['master_roll_reminder'::text, 'master_roll_final_reminder'::text, 'master_roll_lock'::text, 'progress_report_reminder'::text, 'progress_report_final_reminder'::text, 'progress_report_lock'::text, 'settlement_reminder'::text, 'settlement_final_reminder'::text, 'settlement_lock'::text, 'cash_replenishment_alert'::text, 'fund_requisition_approved_accounts_email'::text])));
ALTER TABLE ONLY public.notification_events ADD CONSTRAINT notification_events_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'failed'::text])));
ALTER TABLE ONLY public.audit_log ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


-- ---------------------------------------------------------------------
-- Foreign keys
-- ---------------------------------------------------------------------
ALTER TABLE ONLY public.profiles ADD CONSTRAINT profiles_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.profiles ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.projects ADD CONSTRAINT projects_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.project_settings ADD CONSTRAINT project_settings_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.project_roles ADD CONSTRAINT project_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.zones ADD CONSTRAINT zones_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.coordinator_assignments ADD CONSTRAINT coordinator_assignments_coordinator_id_fkey FOREIGN KEY (coordinator_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.coordinator_assignments ADD CONSTRAINT coordinator_assignments_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.leave_periods ADD CONSTRAINT leave_periods_coordinator_id_fkey FOREIGN KEY (coordinator_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.leave_periods ADD CONSTRAINT leave_periods_declared_by_fkey FOREIGN KEY (declared_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.leave_periods ADD CONSTRAINT leave_periods_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.boq_sections ADD CONSTRAINT boq_sections_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.boq_items ADD CONSTRAINT boq_items_section_id_fkey FOREIGN KEY (section_id) REFERENCES boq_sections(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.boq_items ADD CONSTRAINT boq_items_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES zones(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.boq_variations ADD CONSTRAINT boq_variations_boq_item_id_fkey FOREIGN KEY (boq_item_id) REFERENCES boq_items(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.boq_variations ADD CONSTRAINT boq_variations_created_by_fkey FOREIGN KEY (created_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.labour_categories ADD CONSTRAINT labour_categories_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.labourers ADD CONSTRAINT labourers_created_by_fkey FOREIGN KEY (created_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.labourers ADD CONSTRAINT labourers_labour_category_id_fkey FOREIGN KEY (labour_category_id) REFERENCES labour_categories(id);
ALTER TABLE ONLY public.labourers ADD CONSTRAINT labourers_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.master_roll_entries ADD CONSTRAINT master_roll_entries_coordinator_id_fkey FOREIGN KEY (coordinator_id) REFERENCES profiles(id);
ALTER TABLE ONLY public.master_roll_entries ADD CONSTRAINT master_roll_entries_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.master_roll_attendance ADD CONSTRAINT master_roll_attendance_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES master_roll_entries(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.master_roll_attendance ADD CONSTRAINT master_roll_attendance_labourer_id_fkey FOREIGN KEY (labourer_id) REFERENCES labourers(id);
ALTER TABLE ONLY public.subcontracts ADD CONSTRAINT subcontracts_boq_item_id_fkey FOREIGN KEY (boq_item_id) REFERENCES boq_items(id);
ALTER TABLE ONLY public.subcontracts ADD CONSTRAINT subcontracts_created_by_fkey FOREIGN KEY (created_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.subcontracts ADD CONSTRAINT subcontracts_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_boq_item_id_fkey FOREIGN KEY (boq_item_id) REFERENCES boq_items(id);
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_coordinator_id_fkey FOREIGN KEY (coordinator_id) REFERENCES profiles(id);
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.progress_reports ADD CONSTRAINT progress_reports_subcontract_id_fkey FOREIGN KEY (subcontract_id) REFERENCES subcontracts(id);
ALTER TABLE ONLY public.progress_corrections ADD CONSTRAINT progress_corrections_corrected_by_fkey FOREIGN KEY (corrected_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.progress_corrections ADD CONSTRAINT progress_corrections_progress_report_id_fkey FOREIGN KEY (progress_report_id) REFERENCES progress_reports(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.material_logs ADD CONSTRAINT material_logs_boq_item_id_fkey FOREIGN KEY (boq_item_id) REFERENCES boq_items(id);
ALTER TABLE ONLY public.material_logs ADD CONSTRAINT material_logs_coordinator_id_fkey FOREIGN KEY (coordinator_id) REFERENCES profiles(id);
ALTER TABLE ONLY public.material_logs ADD CONSTRAINT material_logs_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.ledger_heads ADD CONSTRAINT ledger_heads_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_boq_item_id_fkey FOREIGN KEY (boq_item_id) REFERENCES boq_items(id);
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_ledger_head_id_fkey FOREIGN KEY (ledger_head_id) REFERENCES ledger_heads(id);
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.advance_requisitions ADD CONSTRAINT advance_requisitions_subcontract_id_fkey FOREIGN KEY (subcontract_id) REFERENCES subcontracts(id);
ALTER TABLE ONLY public.advance_requisition_actions ADD CONSTRAINT advance_requisition_actions_action_by_fkey FOREIGN KEY (action_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.advance_requisition_actions ADD CONSTRAINT advance_requisition_actions_requisition_id_fkey FOREIGN KEY (requisition_id) REFERENCES advance_requisitions(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.advance_settlements ADD CONSTRAINT advance_settlements_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.advance_settlements ADD CONSTRAINT advance_settlements_requisition_id_fkey FOREIGN KEY (requisition_id) REFERENCES advance_requisitions(id);
ALTER TABLE ONLY public.advance_settlements ADD CONSTRAINT advance_settlements_submitted_by_fkey FOREIGN KEY (submitted_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.advance_settlement_actions ADD CONSTRAINT advance_settlement_actions_action_by_fkey FOREIGN KEY (action_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.advance_settlement_actions ADD CONSTRAINT advance_settlement_actions_settlement_id_fkey FOREIGN KEY (settlement_id) REFERENCES advance_settlements(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.documents ADD CONSTRAINT documents_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.documents ADD CONSTRAINT documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.fund_receipts ADD CONSTRAINT fund_receipts_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.fund_receipts ADD CONSTRAINT fund_receipts_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_fund_receipt_id_fkey FOREIGN KEY (fund_receipt_id) REFERENCES fund_receipts(id);
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.fund_requisitions ADD CONSTRAINT fund_requisitions_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.user_report_permissions ADD CONSTRAINT user_report_permissions_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES profiles(id);
ALTER TABLE ONLY public.user_report_permissions ADD CONSTRAINT user_report_permissions_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.user_report_permissions ADD CONSTRAINT user_report_permissions_report_definition_id_fkey FOREIGN KEY (report_definition_id) REFERENCES report_definitions(id);
ALTER TABLE ONLY public.user_report_permissions ADD CONSTRAINT user_report_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.notification_events ADD CONSTRAINT notification_events_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.notification_events ADD CONSTRAINT notification_events_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES profiles(id);
ALTER TABLE ONLY public.audit_log ADD CONSTRAINT audit_log_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES profiles(id);
ALTER TABLE ONLY public.audit_log ADD CONSTRAINT audit_log_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);


-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
CREATE INDEX idx_profiles_company ON public.profiles USING btree (company_id);
CREATE INDEX idx_projects_company ON public.projects USING btree (company_id);
CREATE INDEX idx_project_roles_project ON public.project_roles USING btree (project_id, role);
CREATE INDEX idx_project_roles_user ON public.project_roles USING btree (user_id);
CREATE INDEX idx_zones_project ON public.zones USING btree (project_id);
CREATE INDEX idx_coordinator_assignments_coordinator ON public.coordinator_assignments USING btree (coordinator_id);
CREATE INDEX idx_leave_periods_coordinator ON public.leave_periods USING btree (coordinator_id, start_date, end_date);
CREATE INDEX idx_boq_sections_project ON public.boq_sections USING btree (project_id);
CREATE INDEX idx_boq_items_section ON public.boq_items USING btree (section_id);
CREATE INDEX idx_boq_items_zone ON public.boq_items USING btree (zone_id);
CREATE INDEX idx_boq_variations_item ON public.boq_variations USING btree (boq_item_id);
CREATE INDEX idx_labourers_id_number ON public.labourers USING btree (project_id, id_number);
CREATE INDEX idx_labourers_project ON public.labourers USING btree (project_id);
CREATE INDEX idx_master_roll_date ON public.master_roll_entries USING btree (project_id, date);
CREATE UNIQUE INDEX uq_master_roll_entry ON public.master_roll_entries USING btree (project_id, coordinator_id, date);
CREATE INDEX idx_master_roll_attendance_entry ON public.master_roll_attendance USING btree (entry_id);
CREATE INDEX idx_master_roll_attendance_labourer ON public.master_roll_attendance USING btree (labourer_id);
CREATE INDEX idx_subcontracts_boq_item ON public.subcontracts USING btree (boq_item_id);
CREATE INDEX idx_subcontracts_project ON public.subcontracts USING btree (project_id);
CREATE INDEX idx_progress_reports_boq_item ON public.progress_reports USING btree (boq_item_id, date);
CREATE INDEX idx_progress_reports_project_date ON public.progress_reports USING btree (project_id, date);
CREATE INDEX idx_progress_reports_subcontract ON public.progress_reports USING btree (subcontract_id);
CREATE INDEX idx_progress_corrections_report ON public.progress_corrections USING btree (progress_report_id);
CREATE INDEX idx_material_logs_boq_item ON public.material_logs USING btree (boq_item_id);
CREATE INDEX idx_material_logs_project ON public.material_logs USING btree (project_id, date);
CREATE INDEX idx_ledger_heads_project ON public.ledger_heads USING btree (project_id);
CREATE INDEX idx_advance_req_boq_item ON public.advance_requisitions USING btree (boq_item_id);
CREATE INDEX idx_advance_req_project_status ON public.advance_requisitions USING btree (project_id, status);
CREATE INDEX idx_advance_req_requested_by ON public.advance_requisitions USING btree (requested_by);
CREATE INDEX idx_advance_req_subcontract ON public.advance_requisitions USING btree (subcontract_id);
CREATE INDEX idx_advance_req_actions_req ON public.advance_requisition_actions USING btree (requisition_id);
CREATE INDEX idx_advance_settlements_project_status ON public.advance_settlements USING btree (project_id, status);
CREATE INDEX idx_advance_settlements_requisition ON public.advance_settlements USING btree (requisition_id);
CREATE INDEX idx_settlement_actions_settlement ON public.advance_settlement_actions USING btree (settlement_id);
CREATE INDEX idx_documents_entity ON public.documents USING btree (entity_type, entity_id);
CREATE INDEX idx_documents_project ON public.documents USING btree (project_id);
CREATE INDEX idx_fund_receipts_project ON public.fund_receipts USING btree (project_id);
CREATE INDEX idx_fund_requisitions_project_status ON public.fund_requisitions USING btree (project_id, status);
CREATE INDEX idx_user_report_perms_user ON public.user_report_permissions USING btree (project_id, user_id);
CREATE INDEX idx_notification_events_project ON public.notification_events USING btree (project_id, event_type);
CREATE INDEX idx_notification_events_status ON public.notification_events USING btree (status, created_at);
CREATE INDEX idx_audit_log_entity ON public.audit_log USING btree (entity_type, entity_id);
CREATE INDEX idx_audit_log_project ON public.audit_log USING btree (project_id, created_at);


-- ---------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_create_default_project_settings()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  insert into project_settings (project_id) values (new.id);
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_is_on_leave(p_coordinator_id uuid, p_project_id uuid, p_check_date date DEFAULT CURRENT_DATE)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1 from leave_periods
    where coordinator_id = p_coordinator_id
      and project_id = p_project_id
      and p_check_date between start_date and end_date
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_boq_effective_budget(p_boq_item_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  select
    (bi.quantity + coalesce(sum(bv.qty_delta), 0)) *
    (bi.rate + coalesce(sum(bv.rate_delta), 0))
  from boq_items bi
  left join boq_variations bv on bv.boq_item_id = bi.id
  where bi.id = p_boq_item_id
  group by bi.id, bi.quantity, bi.rate;
$function$;

CREATE OR REPLACE FUNCTION public.fn_validate_coordinator_scope()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.scope_type = 'section' then
    if not exists (
      select 1 from boq_sections
      where id = new.scope_id and project_id = new.project_id
    ) then
      raise exception 'scope_id % is not a valid boq_section for project %', new.scope_id, new.project_id;
    end if;
  elsif new.scope_type = 'zone' then
    if not exists (
      select 1 from zones
      where id = new.scope_id and project_id = new.project_id
    ) then
      raise exception 'scope_id % is not a valid zone for project %', new.scope_id, new.project_id;
    end if;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_flag_late_master_roll()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.date < (current_date - interval '1 day')::date then
    new.is_late_entry := true;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_validate_requisition_action()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  current_status text;
begin
  select status into current_status from advance_requisitions where id = new.requisition_id;

  if new.action_type = 'verified' and current_status != 'pending_verification' then
    raise exception 'Cannot verify a requisition in status %', current_status;
  elsif new.action_type = 'approved' and current_status != 'pending_approval' then
    raise exception 'Cannot approve a requisition in status % (must be verified first)', current_status;
  elsif new.action_type = 'disbursed' and current_status != 'approved' then
    raise exception 'Cannot disburse a requisition in status % (must be approved first)', current_status;
  elsif new.action_type = 'rejected' and current_status not in ('pending_verification','pending_approval') then
    raise exception 'Cannot reject a requisition in status %', current_status;
  end if;

  update advance_requisitions
  set status = case new.action_type
    when 'verified' then 'pending_approval'
    when 'approved' then 'approved'
    when 'disbursed' then 'disbursed'
    when 'rejected' then 'rejected'
  end
  where id = new.requisition_id;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_check_settlement_total()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_advance_amount numeric(14,2);
  v_existing_total numeric(14,2);
begin
  select amount into v_advance_amount
  from advance_requisitions
  where id = new.requisition_id;

  select coalesce(sum(settled_amount), 0) into v_existing_total
  from advance_settlements
  where requisition_id = new.requisition_id
    and status in ('pending_verification', 'settled')
    and id != new.id; -- exclude self, relevant on update

  if v_existing_total + new.settled_amount > v_advance_amount then
    raise exception
      'Settlement of % would bring total settlements to % for an advance of only % (requisition %)',
      new.settled_amount, v_existing_total + new.settled_amount, v_advance_amount, new.requisition_id;
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_validate_settlement_action()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  current_status text;
begin
  select status into current_status from advance_settlements where id = new.settlement_id;

  if new.action_type = 'verified' and current_status != 'pending_verification' then
    raise exception 'Cannot verify a settlement in status %', current_status;
  elsif new.action_type = 'rejected' and current_status != 'pending_verification' then
    raise exception 'Cannot reject a settlement in status %', current_status;
  end if;

  update advance_settlements
  set status = case new.action_type when 'verified' then 'settled' when 'rejected' then 'rejected' end
  where id = new.settlement_id;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_seed_default_report_permissions()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.role = 'viewer' then
    insert into user_report_permissions (project_id, user_id, report_definition_id, granted)
    select new.project_id, new.user_id, id, default_visible_to_viewer
    from report_definitions
    on conflict (project_id, user_id, report_definition_id) do nothing;
  elsif new.role in ('admin','company_owner') then
    insert into user_report_permissions (project_id, user_id, report_definition_id, granted)
    select new.project_id, new.user_id, id, true
    from report_definitions
    on conflict (project_id, user_id, report_definition_id) do nothing;
  elsif new.role = 'cashier' then
    insert into user_report_permissions (project_id, user_id, report_definition_id, granted)
    select new.project_id, new.user_id, id, (category in ('financial','labour'))
    from report_definitions
    on conflict (project_id, user_id, report_definition_id) do nothing;
  elsif new.role = 'site_coordinator' then
    insert into user_report_permissions (project_id, user_id, report_definition_id, granted)
    select new.project_id, new.user_id, id, (category = 'progress')
    from report_definitions
    on conflict (project_id, user_id, report_definition_id) do nothing;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_audit_log_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_actor_id uuid;
  v_project_id uuid;
begin
  v_actor_id := auth.uid();

  -- best-effort: most audited tables carry project_id directly
  begin
    if tg_op = 'DELETE' then
      v_project_id := (to_jsonb(old) ->> 'project_id')::uuid;
    else
      v_project_id := (to_jsonb(new) ->> 'project_id')::uuid;
    end if;
  exception when others then
    v_project_id := null;
  end;

  insert into audit_log (project_id, actor_id, action_type, entity_type, entity_id, before_value, after_value)
  values (
    v_project_id,
    v_actor_id,
    lower(tg_op),
    tg_table_name,
    coalesce((to_jsonb(new) ->> 'id')::uuid, (to_jsonb(old) ->> 'id')::uuid),
    case when tg_op != 'INSERT' then to_jsonb(old) else null end,
    case when tg_op != 'DELETE' then to_jsonb(new) else null end
  );

  return coalesce(new, old);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_has_project_access(p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select exists (
    select 1 from project_roles
    where project_id = p_project_id
      and user_id = auth.uid()
      and status = 'active'
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_has_project_role(p_project_id uuid, p_role text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select exists (
    select 1 from project_roles
    where project_id = p_project_id
      and user_id = auth.uid()
      and role = p_role
      and status = 'active'
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_is_company_owner_of_project(p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select exists (
    select 1
    from projects p
    join profiles me on me.id = auth.uid()
    where p.id = p_project_id
      and p.company_id = me.company_id
      and fn_has_project_role(p_project_id, 'company_owner')
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_coordinator_covers_boq_item(p_boq_item_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select exists (
    select 1
    from boq_items bi
    join coordinator_assignments ca on ca.coordinator_id = auth.uid()
    where bi.id = p_boq_item_id
      and (
        (ca.scope_type = 'section' and ca.scope_id = bi.section_id)
        or (ca.scope_type = 'zone' and ca.scope_id = bi.zone_id)
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_coordinator_has_boq_access(p_boq_item_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select case
    when (select coordinator_split_mode from project_settings ps
          join boq_sections bs on bs.project_id = ps.project_id
          join boq_items bi on bi.section_id = bs.id
          where bi.id = p_boq_item_id) = 'none'
    then true
    else fn_coordinator_covers_boq_item(p_boq_item_id)
  end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_viewer_has_financial_grant(p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select exists (
    select 1 from user_report_permissions urp
    join report_definitions rd on rd.id = urp.report_definition_id
    where urp.project_id = p_project_id
      and urp.user_id = auth.uid()
      and rd.key = 'cashbook_report'
      and urp.granted = true
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_can_view_document(p_entity_type text, p_entity_id uuid, p_project_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
begin
  if fn_is_company_owner_of_project(p_project_id) or fn_has_project_role(p_project_id, 'admin') then
    return true;
  end if;

  if p_entity_type = 'progress_report' then
    return fn_has_project_access(p_project_id);
  elsif p_entity_type = 'advance_settlement' then
    if fn_has_project_role(p_project_id, 'cashier') then
      return true;
    end if;
    if fn_has_project_role(p_project_id, 'viewer') then
      return fn_viewer_has_financial_grant(p_project_id);
    end if;
    return exists (
      select 1 from advance_settlements s
      where s.id = p_entity_id and s.submitted_by = auth.uid()
    );
  end if;

  return false;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_run_escalation_checks()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  coord record;
  proj record;
  settlement_row record;
  hours_since_date numeric;
  hours_since_disbursement numeric;
begin

  -- ============================================================
  -- 1. Missing Master Roll
  -- ============================================================
  for coord in
    select distinct pr.user_id as coordinator_id, pr.project_id, ps.master_roll_reminder_hours
    from project_roles pr
    join project_settings ps on ps.project_id = pr.project_id
    where pr.role = 'site_coordinator' and pr.status = 'active'
  loop
    if fn_is_on_leave(coord.coordinator_id, coord.project_id, current_date) then
      continue;
    end if;

    if exists (
      select 1 from master_roll_entries
      where coordinator_id = coord.coordinator_id
        and project_id = coord.project_id
        and date = current_date
    ) then
      continue;
    end if;

    hours_since_date := extract(epoch from (now() - current_date::timestamptz)) / 3600;

    if hours_since_date >= coord.master_roll_reminder_hours * 2 then
      if not exists (
        select 1 from notification_events
        where project_id = coord.project_id and target_user_id = coord.coordinator_id
          and event_type = 'master_roll_final_reminder' and created_at::date = current_date
      ) then
        insert into notification_events (project_id, event_type, target_user_id, payload)
        values (coord.project_id, 'master_roll_final_reminder', coord.coordinator_id,
                jsonb_build_object('date', current_date));
      end if;
      if not exists (
        select 1 from notification_events
        where project_id = coord.project_id and target_user_id = coord.coordinator_id
          and event_type = 'master_roll_lock' and created_at::date = current_date
      ) then
        insert into notification_events (project_id, event_type, target_user_id, payload)
        values (coord.project_id, 'master_roll_lock', coord.coordinator_id,
                jsonb_build_object('date', current_date));
      end if;
    elsif hours_since_date >= coord.master_roll_reminder_hours then
      if not exists (
        select 1 from notification_events
        where project_id = coord.project_id and target_user_id = coord.coordinator_id
          and event_type = 'master_roll_reminder' and created_at::date = current_date
      ) then
        insert into notification_events (project_id, event_type, target_user_id, payload)
        values (coord.project_id, 'master_roll_reminder', coord.coordinator_id,
                jsonb_build_object('date', current_date));
      end if;
    end if;
  end loop;

  -- ============================================================
  -- 2. Missing Progress Report
  -- ============================================================
  for coord in
    select distinct pr.user_id as coordinator_id, pr.project_id, ps.progress_report_reminder_hours
    from project_roles pr
    join project_settings ps on ps.project_id = pr.project_id
    where pr.role = 'site_coordinator' and pr.status = 'active'
  loop
    if fn_is_on_leave(coord.coordinator_id, coord.project_id, current_date) then
      continue;
    end if;

    if exists (
      select 1 from progress_reports
      where coordinator_id = coord.coordinator_id
        and project_id = coord.project_id
        and date = current_date
    ) then
      continue;
    end if;

    hours_since_date := extract(epoch from (now() - current_date::timestamptz)) / 3600;

    if hours_since_date >= coord.progress_report_reminder_hours * 2 then
      if not exists (
        select 1 from notification_events
        where project_id = coord.project_id and target_user_id = coord.coordinator_id
          and event_type = 'progress_report_final_reminder' and created_at::date = current_date
      ) then
        insert into notification_events (project_id, event_type, target_user_id, payload)
        values (coord.project_id, 'progress_report_final_reminder', coord.coordinator_id,
                jsonb_build_object('date', current_date));
      end if;
      if not exists (
        select 1 from notification_events
        where project_id = coord.project_id and target_user_id = coord.coordinator_id
          and event_type = 'progress_report_lock' and created_at::date = current_date
      ) then
        insert into notification_events (project_id, event_type, target_user_id, payload)
        values (coord.project_id, 'progress_report_lock', coord.coordinator_id,
                jsonb_build_object('date', current_date));
      end if;
    elsif hours_since_date >= coord.progress_report_reminder_hours then
      if not exists (
        select 1 from notification_events
        where project_id = coord.project_id and target_user_id = coord.coordinator_id
          and event_type = 'progress_report_reminder' and created_at::date = current_date
      ) then
        insert into notification_events (project_id, event_type, target_user_id, payload)
        values (coord.project_id, 'progress_report_reminder', coord.coordinator_id,
                jsonb_build_object('date', current_date));
      end if;
    end if;
  end loop;

  -- ============================================================
  -- 3. Advance Settlement overdue
  -- ============================================================
  for settlement_row in
    select
      ar.id as requisition_id, ar.requested_by as coordinator_id, ar.project_id,
      ar.amount, ara.action_at as disbursed_at, ps.settlement_grace_days
    from advance_requisitions ar
    join advance_requisition_actions ara on ara.requisition_id = ar.id and ara.action_type = 'disbursed'
    join project_settings ps on ps.project_id = ar.project_id
    where ar.status = 'disbursed'
      and coalesce((
        select sum(s.settled_amount) from advance_settlements s
        where s.requisition_id = ar.id and s.status in ('pending_verification','settled')
      ), 0) < ar.amount
  loop
    if fn_is_on_leave(settlement_row.coordinator_id, settlement_row.project_id, current_date) then
      continue;
    end if;

    hours_since_disbursement := extract(epoch from (now() - settlement_row.disbursed_at)) / 3600;
    declare
      grace_hours numeric := settlement_row.settlement_grace_days * 24;
    begin
      if hours_since_disbursement >= grace_hours then
        if not exists (
          select 1 from notification_events
          where project_id = settlement_row.project_id and target_user_id = settlement_row.coordinator_id
            and event_type = 'settlement_lock' and payload->>'requisition_id' = settlement_row.requisition_id::text
            and created_at::date = current_date
        ) then
          insert into notification_events (project_id, event_type, target_user_id, payload)
          values (settlement_row.project_id, 'settlement_lock', settlement_row.coordinator_id,
                  jsonb_build_object('requisition_id', settlement_row.requisition_id));
        end if;
      elsif hours_since_disbursement >= grace_hours * 0.75 then
        if not exists (
          select 1 from notification_events
          where project_id = settlement_row.project_id and target_user_id = settlement_row.coordinator_id
            and event_type = 'settlement_final_reminder' and payload->>'requisition_id' = settlement_row.requisition_id::text
            and created_at::date = current_date
        ) then
          insert into notification_events (project_id, event_type, target_user_id, payload)
          values (settlement_row.project_id, 'settlement_final_reminder', settlement_row.coordinator_id,
                  jsonb_build_object('requisition_id', settlement_row.requisition_id));
        end if;
      elsif hours_since_disbursement >= grace_hours * 0.5 then
        if not exists (
          select 1 from notification_events
          where project_id = settlement_row.project_id and target_user_id = settlement_row.coordinator_id
            and event_type = 'settlement_reminder' and payload->>'requisition_id' = settlement_row.requisition_id::text
            and created_at::date = current_date
        ) then
          insert into notification_events (project_id, event_type, target_user_id, payload)
          values (settlement_row.project_id, 'settlement_reminder', settlement_row.coordinator_id,
                  jsonb_build_object('requisition_id', settlement_row.requisition_id));
        end if;
      end if;
    end;
  end loop;

end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_is_master_roll_locked(p_coordinator_id uuid, p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1 from notification_events
    where target_user_id = p_coordinator_id and project_id = p_project_id
      and event_type = 'master_roll_lock' and created_at::date = current_date
  )
  and not exists (
    select 1 from master_roll_entries
    where coordinator_id = p_coordinator_id and project_id = p_project_id and date = current_date
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_is_progress_report_locked(p_coordinator_id uuid, p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1 from notification_events
    where target_user_id = p_coordinator_id and project_id = p_project_id
      and event_type = 'progress_report_lock' and created_at::date = current_date
  )
  and not exists (
    select 1 from progress_reports
    where coordinator_id = p_coordinator_id and project_id = p_project_id and date = current_date
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_is_settlement_locked(p_coordinator_id uuid, p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1 from advance_requisitions ar
    join advance_requisition_actions ara on ara.requisition_id = ar.id and ara.action_type = 'disbursed'
    join project_settings ps on ps.project_id = ar.project_id
    where ar.requested_by = p_coordinator_id and ar.project_id = p_project_id
      and ar.status = 'disbursed'
      and coalesce((
        select sum(s.settled_amount) from advance_settlements s
        where s.requisition_id = ar.id and s.status in ('pending_verification','settled')
      ), 0) < ar.amount
      and extract(epoch from (now() - ara.action_at)) / 3600 >= ps.settlement_grace_days * 24
  );
$function$;

CREATE OR REPLACE FUNCTION public.fn_dispatch_pending_notifications()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  evt record;
  edge_function_url text;
  service_key text;
begin
  select decrypted_secret into edge_function_url from vault.decrypted_secrets where name = 'edge_function_base_url';
  select decrypted_secret into service_key from vault.decrypted_secrets where name = 'service_role_key';

  if edge_function_url is null or service_key is null then
    raise warning 'fn_dispatch_pending_notifications: vault secrets not configured, skipping dispatch this run.';
    return;
  end if;

  for evt in
    select * from notification_events where status = 'pending' order by created_at asc limit 100
  loop
    perform net.http_post(
      url := edge_function_url || '/send-notification',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || service_key,
        'apikey', service_key,
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'notification_event_id', evt.id,
        'event_type', evt.event_type,
        'target_user_id', evt.target_user_id,
        'project_id', evt.project_id,
        'payload', evt.payload
      )
    );
    update notification_events set status = 'sent', sent_at = now() where id = evt.id;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_storage_path_project_id(object_name text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  select (storage.foldername(object_name))[1]::uuid;
$function$;

CREATE OR REPLACE FUNCTION public.fn_my_company_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select company_id from profiles where id = auth.uid();
$function$;


-- ---------------------------------------------------------------------
-- Views
-- NOTE: as live, these views run with the owner's rights (no
-- security_invoker), so RLS on the underlying tables does NOT apply.
-- Kept identical here; see the follow-up security migration.
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
   FROM progress_reports pr;

CREATE OR REPLACE VIEW public.v_actual_cost_by_boq_item AS
 SELECT ar.boq_item_id,
    sum(s.settled_amount) AS actual_cost
   FROM advance_settlements s
     JOIN advance_requisitions ar ON ar.id = s.requisition_id
  WHERE s.status = 'settled'::text AND ar.advance_category = 'work_tied'::text AND ar.boq_item_id IS NOT NULL
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
          GROUP BY pe.subcontract_id, sc2.agreed_rate) earned ON earned.subcontract_id = sc.id;

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
          GROUP BY advance_requisitions.project_id) disb ON disb.project_id = p.id;

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
     JOIN boq_sections bs ON bs.id = bi.section_id;

CREATE OR REPLACE VIEW public.v_evm_by_project AS
 SELECT project_id,
    sum(planned_value) AS total_planned_value,
    sum(earned_value) AS total_earned_value,
    sum(actual_cost) AS total_actual_cost,
    sum(earned_value) - sum(actual_cost) AS cost_variance,
    sum(earned_value) - sum(planned_value) AS schedule_variance,
    sum(original_budgeted_cost) AS total_budgeted_cost,
        CASE
            WHEN sum(original_budgeted_cost) > 0::numeric THEN round(100.0 * sum(earned_value) / sum(original_budgeted_cost), 2)
            ELSE 0::numeric
        END AS physical_progress_pct,
        CASE
            WHEN sum(original_budgeted_cost) > 0::numeric THEN round(100.0 * sum(actual_cost) / sum(original_budgeted_cost), 2)
            ELSE 0::numeric
        END AS financial_progress_pct,
    count(*) FILTER (WHERE cumulative_measured_quantity > budgeted_quantity) AS items_exceeding_boq_estimate
   FROM v_evm_by_boq_item
  GROUP BY project_id;


-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_audit_advance_requisition_actions AFTER INSERT OR DELETE OR UPDATE ON public.advance_requisition_actions FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_validate_requisition_action BEFORE INSERT ON public.advance_requisition_actions FOR EACH ROW EXECUTE FUNCTION fn_validate_requisition_action();
CREATE TRIGGER trg_audit_advance_requisitions AFTER INSERT OR DELETE OR UPDATE ON public.advance_requisitions FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_advance_settlement_actions AFTER INSERT OR DELETE OR UPDATE ON public.advance_settlement_actions FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_validate_settlement_action BEFORE INSERT ON public.advance_settlement_actions FOR EACH ROW EXECUTE FUNCTION fn_validate_settlement_action();
CREATE TRIGGER trg_audit_advance_settlements AFTER INSERT OR DELETE OR UPDATE ON public.advance_settlements FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_check_settlement_total BEFORE INSERT OR UPDATE ON public.advance_settlements FOR EACH ROW EXECUTE FUNCTION fn_check_settlement_total();
CREATE TRIGGER trg_audit_boq_items AFTER INSERT OR DELETE OR UPDATE ON public.boq_items FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_boq_variations AFTER INSERT OR DELETE OR UPDATE ON public.boq_variations FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_validate_coordinator_scope BEFORE INSERT OR UPDATE ON public.coordinator_assignments FOR EACH ROW EXECUTE FUNCTION fn_validate_coordinator_scope();
CREATE TRIGGER trg_audit_fund_receipts AFTER INSERT OR DELETE OR UPDATE ON public.fund_receipts FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_fund_requisitions AFTER INSERT OR DELETE OR UPDATE ON public.fund_requisitions FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_labourers AFTER INSERT OR DELETE OR UPDATE ON public.labourers FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_leave_periods AFTER INSERT OR DELETE OR UPDATE ON public.leave_periods FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_master_roll_attendance AFTER INSERT OR DELETE OR UPDATE ON public.master_roll_attendance FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_master_roll_entries AFTER INSERT OR DELETE OR UPDATE ON public.master_roll_entries FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_flag_late_master_roll BEFORE INSERT ON public.master_roll_entries FOR EACH ROW EXECUTE FUNCTION fn_flag_late_master_roll();
CREATE TRIGGER trg_audit_progress_corrections AFTER INSERT OR DELETE OR UPDATE ON public.progress_corrections FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_progress_reports AFTER INSERT OR DELETE OR UPDATE ON public.progress_reports FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_audit_project_roles AFTER INSERT OR DELETE OR UPDATE ON public.project_roles FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();
CREATE TRIGGER trg_seed_default_report_permissions AFTER INSERT ON public.project_roles FOR EACH ROW EXECUTE FUNCTION fn_seed_default_report_permissions();
CREATE TRIGGER trg_create_default_project_settings AFTER INSERT ON public.projects FOR EACH ROW EXECUTE FUNCTION fn_create_default_project_settings();
CREATE TRIGGER trg_audit_subcontracts AFTER INSERT OR DELETE OR UPDATE ON public.subcontracts FOR EACH ROW EXECUTE FUNCTION fn_audit_log_trigger();


-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coordinator_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.boq_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.boq_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.boq_variations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.labour_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.labourers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_roll_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_roll_attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subcontracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.progress_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.progress_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.material_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_heads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advance_requisitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advance_requisition_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advance_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advance_settlement_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fund_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fund_requisitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_report_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------
-- RLS policies (public schema)
-- ---------------------------------------------------------------------
CREATE POLICY ara_insert_admin ON public.advance_requisition_actions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((action_by = auth.uid()) AND (action_type = 'approved'::text) AND fn_has_project_role(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)), 'admin'::text)));

CREATE POLICY ara_insert_cashier ON public.advance_requisition_actions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((action_by = auth.uid()) AND (action_type = ANY (ARRAY['verified'::text, 'disbursed'::text])) AND fn_has_project_role(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)), 'cashier'::text)));

CREATE POLICY ara_insert_reject_admin ON public.advance_requisition_actions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((action_by = auth.uid()) AND (action_type = 'rejected'::text) AND fn_has_project_role(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)), 'admin'::text)));

CREATE POLICY ara_insert_reject_cashier ON public.advance_requisition_actions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((action_by = auth.uid()) AND (action_type = 'rejected'::text) AND fn_has_project_role(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)), 'cashier'::text)));

CREATE POLICY ara_select_admin ON public.advance_requisition_actions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)), 'admin'::text));

CREATE POLICY ara_select_cashier ON public.advance_requisition_actions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)), 'cashier'::text));

CREATE POLICY ara_select_owner ON public.advance_requisition_actions AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(( SELECT advance_requisitions.project_id
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id))));

CREATE POLICY ara_select_self ON public.advance_requisition_actions AS PERMISSIVE FOR SELECT TO public
  USING ((( SELECT advance_requisitions.requested_by
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_requisition_actions.requisition_id)) = auth.uid()));

CREATE POLICY ar_insert_self ON public.advance_requisitions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((requested_by = auth.uid()) AND fn_has_project_role(project_id, 'site_coordinator'::text) AND (NOT fn_is_master_roll_locked(auth.uid(), project_id)) AND (NOT fn_is_progress_report_locked(auth.uid(), project_id)) AND (NOT fn_is_settlement_locked(auth.uid(), project_id))));

CREATE POLICY ar_select_admin ON public.advance_requisitions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY ar_select_cashier ON public.advance_requisitions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY ar_select_owner ON public.advance_requisitions AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY ar_select_self ON public.advance_requisitions AS PERMISSIVE FOR SELECT TO public
  USING ((requested_by = auth.uid()));

CREATE POLICY ar_select_viewer ON public.advance_requisitions AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(project_id, 'viewer'::text) AND fn_viewer_has_financial_grant(project_id)));

CREATE POLICY asa_insert_cashier ON public.advance_settlement_actions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((action_by = auth.uid()) AND fn_has_project_role(( SELECT advance_settlements.project_id
   FROM advance_settlements
  WHERE (advance_settlements.id = advance_settlement_actions.settlement_id)), 'cashier'::text)));

CREATE POLICY asa_select_admin ON public.advance_settlement_actions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT advance_settlements.project_id
   FROM advance_settlements
  WHERE (advance_settlements.id = advance_settlement_actions.settlement_id)), 'admin'::text));

CREATE POLICY asa_select_cashier ON public.advance_settlement_actions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT advance_settlements.project_id
   FROM advance_settlements
  WHERE (advance_settlements.id = advance_settlement_actions.settlement_id)), 'cashier'::text));

CREATE POLICY asa_select_owner ON public.advance_settlement_actions AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(( SELECT advance_settlements.project_id
   FROM advance_settlements
  WHERE (advance_settlements.id = advance_settlement_actions.settlement_id))));

CREATE POLICY as_insert_self ON public.advance_settlements AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((submitted_by = auth.uid()) AND (( SELECT advance_requisitions.requested_by
   FROM advance_requisitions
  WHERE (advance_requisitions.id = advance_settlements.requisition_id)) = auth.uid())));

CREATE POLICY as_select_admin ON public.advance_settlements AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY as_select_cashier ON public.advance_settlements AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY as_select_owner ON public.advance_settlements AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY as_select_self ON public.advance_settlements AS PERMISSIVE FOR SELECT TO public
  USING ((submitted_by = auth.uid()));

CREATE POLICY as_select_viewer ON public.advance_settlements AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(project_id, 'viewer'::text) AND fn_viewer_has_financial_grant(project_id)));

CREATE POLICY al_select_admin ON public.audit_log AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY al_select_owner ON public.audit_log AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY boq_items_select_admin ON public.boq_items AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id)), 'admin'::text));

CREATE POLICY boq_items_select_cashier ON public.boq_items AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id)), 'cashier'::text));

CREATE POLICY boq_items_select_coordinator ON public.boq_items AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id)), 'site_coordinator'::text) AND fn_coordinator_has_boq_access(id)));

CREATE POLICY boq_items_select_owner ON public.boq_items AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id))));

CREATE POLICY boq_items_select_viewer ON public.boq_items AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id)), 'viewer'::text) AND fn_viewer_has_financial_grant(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id)))));

CREATE POLICY boq_items_write_admin ON public.boq_items AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id)), 'admin'::text));

CREATE POLICY boq_items_write_owner ON public.boq_items AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(( SELECT boq_sections.project_id
   FROM boq_sections
  WHERE (boq_sections.id = boq_items.section_id))));

CREATE POLICY boq_sections_select_admin ON public.boq_sections AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY boq_sections_select_cashier ON public.boq_sections AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY boq_sections_select_coordinator ON public.boq_sections AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'site_coordinator'::text));

CREATE POLICY boq_sections_select_owner ON public.boq_sections AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY boq_sections_select_viewer ON public.boq_sections AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(project_id, 'viewer'::text) AND fn_viewer_has_financial_grant(project_id)));

CREATE POLICY boq_sections_write_admin ON public.boq_sections AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY boq_sections_write_owner ON public.boq_sections AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY boq_variations_select ON public.boq_variations AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_access(( SELECT bs.project_id
   FROM (boq_sections bs
     JOIN boq_items bi ON ((bi.section_id = bs.id)))
  WHERE (bi.id = boq_variations.boq_item_id))));

CREATE POLICY boq_variations_write_admin ON public.boq_variations AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_has_project_role(( SELECT bs.project_id
   FROM (boq_sections bs
     JOIN boq_items bi ON ((bi.section_id = bs.id)))
  WHERE (bi.id = boq_variations.boq_item_id)), 'admin'::text));

CREATE POLICY boq_variations_write_owner ON public.boq_variations AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_is_company_owner_of_project(( SELECT bs.project_id
   FROM (boq_sections bs
     JOIN boq_items bi ON ((bi.section_id = bs.id)))
  WHERE (bi.id = boq_variations.boq_item_id))));

CREATE POLICY companies_select ON public.companies AS PERMISSIVE FOR SELECT TO public
  USING ((id = ( SELECT profiles.company_id
   FROM profiles
  WHERE (profiles.id = auth.uid()))));

CREATE POLICY companies_update_owner ON public.companies AS PERMISSIVE FOR UPDATE TO public
  USING (((id = ( SELECT profiles.company_id
   FROM profiles
  WHERE (profiles.id = auth.uid()))) AND (EXISTS ( SELECT 1
   FROM project_roles
  WHERE ((project_roles.user_id = auth.uid()) AND (project_roles.role = 'company_owner'::text) AND (project_roles.status = 'active'::text))))));

CREATE POLICY coord_assign_select_admin ON public.coordinator_assignments AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY coord_assign_select_cashier ON public.coordinator_assignments AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY coord_assign_select_owner ON public.coordinator_assignments AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY coord_assign_select_self ON public.coordinator_assignments AS PERMISSIVE FOR SELECT TO public
  USING ((coordinator_id = auth.uid()));

CREATE POLICY coord_assign_write_admin ON public.coordinator_assignments AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY coord_assign_write_owner ON public.coordinator_assignments AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY documents_insert_self ON public.documents AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((uploaded_by = auth.uid()) AND fn_has_project_access(project_id)));

CREATE POLICY documents_select ON public.documents AS PERMISSIVE FOR SELECT TO public
  USING (fn_can_view_document(entity_type, entity_id, project_id));

CREATE POLICY fr_insert_admin ON public.fund_receipts AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY fr_insert_cashier ON public.fund_receipts AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY fr_select_admin ON public.fund_receipts AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY fr_select_cashier ON public.fund_receipts AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY fr_select_owner ON public.fund_receipts AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY freq_insert_cashier ON public.fund_requisitions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((requested_by = auth.uid()) AND fn_has_project_role(project_id, 'cashier'::text)));

CREATE POLICY freq_select_admin ON public.fund_requisitions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY freq_select_cashier ON public.fund_requisitions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY freq_select_owner ON public.fund_requisitions AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY freq_update_admin ON public.fund_requisitions AS PERMISSIVE FOR UPDATE TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY labour_cat_select ON public.labour_categories AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_access(project_id));

CREATE POLICY labour_cat_write_admin ON public.labour_categories AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY labour_cat_write_owner ON public.labour_categories AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY labourers_insert_coordinator ON public.labourers AS PERMISSIVE FOR INSERT TO public
  WITH CHECK ((fn_has_project_role(project_id, 'admin'::text) OR fn_has_project_role(project_id, 'site_coordinator'::text)));

CREATE POLICY labourers_select_admin ON public.labourers AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY labourers_select_cashier ON public.labourers AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY labourers_select_coordinator ON public.labourers AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'site_coordinator'::text));

CREATE POLICY labourers_select_owner ON public.labourers AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY leave_select_admin ON public.leave_periods AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY leave_select_owner ON public.leave_periods AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY leave_select_self ON public.leave_periods AS PERMISSIVE FOR SELECT TO public
  USING ((coordinator_id = auth.uid()));

CREATE POLICY leave_write_admin ON public.leave_periods AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY leave_write_owner ON public.leave_periods AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY lh_select ON public.ledger_heads AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_access(project_id));

CREATE POLICY lh_write_admin ON public.ledger_heads AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY lh_write_owner ON public.ledger_heads AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY mra_insert_self ON public.master_roll_attendance AS PERMISSIVE FOR INSERT TO public
  WITH CHECK ((( SELECT master_roll_entries.coordinator_id
   FROM master_roll_entries
  WHERE (master_roll_entries.id = master_roll_attendance.entry_id)) = auth.uid()));

CREATE POLICY mra_select ON public.master_roll_attendance AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_access(( SELECT master_roll_entries.project_id
   FROM master_roll_entries
  WHERE (master_roll_entries.id = master_roll_attendance.entry_id))));

CREATE POLICY mre_insert_self ON public.master_roll_entries AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((coordinator_id = auth.uid()) AND fn_has_project_role(project_id, 'site_coordinator'::text)));

CREATE POLICY mre_select_admin ON public.master_roll_entries AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY mre_select_cashier ON public.master_roll_entries AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY mre_select_owner ON public.master_roll_entries AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY mre_select_self ON public.master_roll_entries AS PERMISSIVE FOR SELECT TO public
  USING ((coordinator_id = auth.uid()));

CREATE POLICY mre_select_viewer ON public.master_roll_entries AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(project_id, 'viewer'::text) AND fn_viewer_has_financial_grant(project_id)));

CREATE POLICY mre_update_self_sameday ON public.master_roll_entries AS PERMISSIVE FOR UPDATE TO public
  USING (((coordinator_id = auth.uid()) AND (date = CURRENT_DATE)));

CREATE POLICY ml_insert_self ON public.material_logs AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((coordinator_id = auth.uid()) AND fn_has_project_role(project_id, 'site_coordinator'::text)));

CREATE POLICY ml_select_admin ON public.material_logs AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY ml_select_owner ON public.material_logs AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY ml_select_self ON public.material_logs AS PERMISSIVE FOR SELECT TO public
  USING ((coordinator_id = auth.uid()));

CREATE POLICY ne_select_admin ON public.notification_events AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY ne_select_self ON public.notification_events AS PERMISSIVE FOR SELECT TO public
  USING ((target_user_id = auth.uid()));

CREATE POLICY profiles_select_same_company ON public.profiles AS PERMISSIVE FOR SELECT TO public
  USING ((company_id = fn_my_company_id()));

CREATE POLICY profiles_select_self ON public.profiles AS PERMISSIVE FOR SELECT TO public
  USING ((id = auth.uid()));

CREATE POLICY profiles_update_self ON public.profiles AS PERMISSIVE FOR UPDATE TO public
  USING ((id = auth.uid()));

CREATE POLICY pc_insert_admin ON public.progress_corrections AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_has_project_role(( SELECT progress_reports.project_id
   FROM progress_reports
  WHERE (progress_reports.id = progress_corrections.progress_report_id)), 'admin'::text));

CREATE POLICY pc_insert_owner ON public.progress_corrections AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_is_company_owner_of_project(( SELECT progress_reports.project_id
   FROM progress_reports
  WHERE (progress_reports.id = progress_corrections.progress_report_id))));

CREATE POLICY pc_select_admin ON public.progress_corrections AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(( SELECT progress_reports.project_id
   FROM progress_reports
  WHERE (progress_reports.id = progress_corrections.progress_report_id)), 'admin'::text));

CREATE POLICY pc_select_owner ON public.progress_corrections AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(( SELECT progress_reports.project_id
   FROM progress_reports
  WHERE (progress_reports.id = progress_corrections.progress_report_id))));

CREATE POLICY pr_insert_self ON public.progress_reports AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((coordinator_id = auth.uid()) AND fn_has_project_role(project_id, 'site_coordinator'::text) AND fn_coordinator_has_boq_access(boq_item_id)));

CREATE POLICY pr_select_admin ON public.progress_reports AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY pr_select_cashier ON public.progress_reports AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY pr_select_owner ON public.progress_reports AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY pr_select_self ON public.progress_reports AS PERMISSIVE FOR SELECT TO public
  USING ((coordinator_id = auth.uid()));

CREATE POLICY pr_select_viewer ON public.progress_reports AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'viewer'::text));

CREATE POLICY project_roles_delete_owner ON public.project_roles AS PERMISSIVE FOR DELETE TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY project_roles_insert_admin ON public.project_roles AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY project_roles_insert_owner ON public.project_roles AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_is_company_owner_of_project(project_id));

CREATE POLICY project_roles_select_admin ON public.project_roles AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY project_roles_select_owner ON public.project_roles AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY project_roles_select_self ON public.project_roles AS PERMISSIVE FOR SELECT TO public
  USING ((user_id = auth.uid()));

CREATE POLICY project_roles_update_admin ON public.project_roles AS PERMISSIVE FOR UPDATE TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY project_roles_update_owner ON public.project_roles AS PERMISSIVE FOR UPDATE TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY project_settings_select ON public.project_settings AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_access(project_id) AND (NOT fn_has_project_role(project_id, 'viewer'::text))));

CREATE POLICY project_settings_update_admin ON public.project_settings AS PERMISSIVE FOR UPDATE TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY project_settings_update_owner ON public.project_settings AS PERMISSIVE FOR UPDATE TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY projects_insert_owner ON public.projects AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((company_id = ( SELECT profiles.company_id
   FROM profiles
  WHERE (profiles.id = auth.uid()))) AND (EXISTS ( SELECT 1
   FROM project_roles
  WHERE ((project_roles.user_id = auth.uid()) AND (project_roles.role = 'company_owner'::text) AND (project_roles.status = 'active'::text))))));

CREATE POLICY projects_select_member ON public.projects AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_access(id));

CREATE POLICY projects_update_admin ON public.projects AS PERMISSIVE FOR UPDATE TO public
  USING (fn_has_project_role(id, 'admin'::text));

CREATE POLICY projects_update_owner ON public.projects AS PERMISSIVE FOR UPDATE TO public
  USING (fn_is_company_owner_of_project(id));

CREATE POLICY rd_select_all ON public.report_definitions AS PERMISSIVE FOR SELECT TO public
  USING (true);

CREATE POLICY subcontracts_select_admin ON public.subcontracts AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY subcontracts_select_cashier ON public.subcontracts AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'cashier'::text));

CREATE POLICY subcontracts_select_coordinator ON public.subcontracts AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'site_coordinator'::text));

CREATE POLICY subcontracts_select_owner ON public.subcontracts AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY subcontracts_select_viewer ON public.subcontracts AS PERMISSIVE FOR SELECT TO public
  USING ((fn_has_project_role(project_id, 'viewer'::text) AND fn_viewer_has_financial_grant(project_id)));

CREATE POLICY subcontracts_write_admin ON public.subcontracts AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY subcontracts_write_owner ON public.subcontracts AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY urp_select_admin ON public.user_report_permissions AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY urp_select_owner ON public.user_report_permissions AS PERMISSIVE FOR SELECT TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY urp_select_self ON public.user_report_permissions AS PERMISSIVE FOR SELECT TO public
  USING ((user_id = auth.uid()));

CREATE POLICY urp_write_admin ON public.user_report_permissions AS PERMISSIVE FOR ALL TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY urp_write_owner ON public.user_report_permissions AS PERMISSIVE FOR ALL TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY zones_delete_admin ON public.zones AS PERMISSIVE FOR DELETE TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY zones_delete_owner ON public.zones AS PERMISSIVE FOR DELETE TO public
  USING (fn_is_company_owner_of_project(project_id));

CREATE POLICY zones_insert_admin ON public.zones AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY zones_insert_owner ON public.zones AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (fn_is_company_owner_of_project(project_id));

CREATE POLICY zones_select ON public.zones AS PERMISSIVE FOR SELECT TO public
  USING (fn_has_project_access(project_id));

CREATE POLICY zones_update_admin ON public.zones AS PERMISSIVE FOR UPDATE TO public
  USING (fn_has_project_role(project_id, 'admin'::text));

CREATE POLICY zones_update_owner ON public.zones AS PERMISSIVE FOR UPDATE TO public
  USING (fn_is_company_owner_of_project(project_id));


-- ---------------------------------------------------------------------
-- Storage buckets and policies
-- ---------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES
  ('labourer-photos', 'labourer-photos', false),
  ('settlement-receipts', 'settlement-receipts', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read receipts" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
  USING ((bucket_id = 'settlement-receipts'::text));

CREATE POLICY "authenticated upload receipts" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK ((bucket_id = 'settlement-receipts'::text));

CREATE POLICY labourer_photos_insert ON storage.objects AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((bucket_id = 'labourer-photos'::text) AND (fn_has_project_role(fn_storage_path_project_id(name), 'admin'::text) OR fn_has_project_role(fn_storage_path_project_id(name), 'site_coordinator'::text))));

CREATE POLICY labourer_photos_select_admin ON storage.objects AS PERMISSIVE FOR SELECT TO public
  USING (((bucket_id = 'labourer-photos'::text) AND fn_has_project_role(fn_storage_path_project_id(name), 'admin'::text)));

CREATE POLICY labourer_photos_select_cashier ON storage.objects AS PERMISSIVE FOR SELECT TO public
  USING (((bucket_id = 'labourer-photos'::text) AND fn_has_project_role(fn_storage_path_project_id(name), 'cashier'::text)));

CREATE POLICY labourer_photos_select_coordinator ON storage.objects AS PERMISSIVE FOR SELECT TO public
  USING (((bucket_id = 'labourer-photos'::text) AND fn_has_project_role(fn_storage_path_project_id(name), 'site_coordinator'::text)));

CREATE POLICY labourer_photos_select_owner ON storage.objects AS PERMISSIVE FOR SELECT TO public
  USING (((bucket_id = 'labourer-photos'::text) AND fn_is_company_owner_of_project(fn_storage_path_project_id(name))));


-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
INSERT INTO public.report_definitions (key, name, category, default_visible_to_viewer) VALUES
('advance_register', 'Advance Register', 'financial', false),
('cashbook_report', 'Cashbook Report', 'financial', false),
('cost_variance_kpi', 'Cost Variance KPI', 'financial', false),
('labour_advance_ledger', 'Labour Advance Ledger (Subcontracts)', 'financial', false),
('ledger_report', 'Ledger Report (combined)', 'financial', false),
('project_financial_report', 'Project Financial Report', 'financial', false),
('schedule_variance_kpi', 'Schedule Variance KPI', 'financial', false),
('settlement_register', 'Settlement Register', 'financial', false),
('labour_productivity_report', 'Labour Productivity Report', 'labour', false),
('master_roll_report', 'Master Roll Report', 'labour', false),
('boq_completion', 'BOQ Completion', 'progress', true),
('daily_progress_report', 'Daily Progress Report', 'progress', true),
('monthly_progress_report', 'Monthly Progress Report', 'progress', true),
('physical_progress_kpi', 'Physical Progress KPI', 'progress', true),
('weekly_progress_report', 'Weekly Progress Report', 'progress', true)
ON CONFLICT (key) DO NOTHING;


-- ---------------------------------------------------------------------
-- Scheduled jobs (pg_cron)
-- ---------------------------------------------------------------------
SELECT cron.schedule('run-escalation-checks', '*/30 * * * *', 'select fn_run_escalation_checks();');
SELECT cron.schedule('dispatch-pending-notifications', '*/5 * * * *', 'select fn_dispatch_pending_notifications();');
