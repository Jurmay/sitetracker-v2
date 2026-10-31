-- Per-project on/off switches for the three "site discipline" locks that
-- block a coordinator from raising a new advance:
--   1. today's master roll not sent by the lock time
--   2. today's progress report not sent by the lock time
--   3. an earlier advance overdue for settling
--
-- All three default to ON, which is exactly the behaviour before this
-- migration, so existing projects are unchanged until an admin or owner
-- turns a switch off on the Settings page. Changes to project settings are
-- now written to audit_log (who changed what, before and after).

ALTER TABLE public.project_settings
  ADD COLUMN IF NOT EXISTS lock_master_roll_enabled boolean DEFAULT true NOT NULL,
  ADD COLUMN IF NOT EXISTS lock_progress_report_enabled boolean DEFAULT true NOT NULL,
  ADD COLUMN IF NOT EXISTS lock_settlement_enabled boolean DEFAULT true NOT NULL;

CREATE OR REPLACE FUNCTION public.fn_is_master_roll_locked(p_coordinator_id uuid, p_project_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET "TimeZone" TO 'Asia/Thimphu'
AS $function$
  select coalesce((select ps.lock_master_roll_enabled from project_settings ps where ps.project_id = p_project_id), true)
  and exists (
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
 SET "TimeZone" TO 'Asia/Thimphu'
AS $function$
  select coalesce((select ps.lock_progress_report_enabled from project_settings ps where ps.project_id = p_project_id), true)
  and exists (
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
  select coalesce((select ps.lock_settlement_enabled from project_settings ps where ps.project_id = p_project_id), true)
  and exists (
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

-- project_settings has no id column (its key is project_id), and
-- audit_log.entity_id is NOT NULL, so the shared fn_audit_log_trigger would
-- fail every settings save. This variant uses project_id as the entity id
-- and only logs updates that actually change something.
CREATE OR REPLACE FUNCTION public.fn_audit_project_settings()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if to_jsonb(new) is distinct from to_jsonb(old) then
    insert into audit_log (project_id, actor_id, action_type, entity_type, entity_id, before_value, after_value)
    values (new.project_id, auth.uid(), 'update', 'project_settings', new.project_id, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$function$;

DROP TRIGGER IF EXISTS trg_audit_project_settings ON public.project_settings;
CREATE TRIGGER trg_audit_project_settings
  AFTER UPDATE ON public.project_settings
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_project_settings();
