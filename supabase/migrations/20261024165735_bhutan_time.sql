-- =====================================================================
-- Run the working day on Bhutan time (Asia/Thimphu, UTC+6).
--
-- Until now the database ran on UTC, so "today" rolled over at 06:00
-- Bhutan time: master roll / progress submitted between midnight and
-- 6 am counted for the previous day, and the daily reminders and
-- advance locks were measured from UTC midnight.
--
-- Reminder and lock times stay where coordinators are used to them:
-- reminder at 12:00, final reminder + lock at 18:00 Bhutan time.
-- Previously that came from reminder_hours = 6 counted from UTC midnight
-- with the lock at 2x; now the day starts at Bhutan midnight, so the
-- reminder is 12 hours in and the lock gets its own setting (18 hours).
-- =====================================================================

-- Every new session (API, dashboard, SQL editor) uses Bhutan time.
ALTER DATABASE postgres SET timezone TO 'Asia/Thimphu';

-- Pin it on the functions that decide "today" too, so the pg_cron worker
-- and any session that overrides its timezone get the same answer.
ALTER FUNCTION public.fn_is_master_roll_locked(uuid, uuid) SET timezone TO 'Asia/Thimphu';
ALTER FUNCTION public.fn_is_progress_report_locked(uuid, uuid) SET timezone TO 'Asia/Thimphu';
ALTER FUNCTION public.fn_flag_late_master_roll() SET timezone TO 'Asia/Thimphu';

-- Separate lock hour; reminder moves to 12 hours after Bhutan midnight.
ALTER TABLE public.project_settings
  ADD COLUMN master_roll_lock_hours integer DEFAULT 18 NOT NULL,
  ADD COLUMN progress_report_lock_hours integer DEFAULT 18 NOT NULL;
ALTER TABLE public.project_settings
  ALTER COLUMN master_roll_reminder_hours SET DEFAULT 12,
  ALTER COLUMN progress_report_reminder_hours SET DEFAULT 12;
UPDATE public.project_settings
  SET master_roll_reminder_hours = 12, progress_report_reminder_hours = 12
  WHERE master_roll_reminder_hours = 6 AND progress_report_reminder_hours = 6;

-- Same function as before, except: final reminder + lock fire at the
-- lock hour instead of 2x the reminder hour, and it runs on Bhutan time.
CREATE OR REPLACE FUNCTION public.fn_run_escalation_checks()
 RETURNS void
 LANGUAGE plpgsql
 SET timezone TO 'Asia/Thimphu'
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
    select distinct pr.user_id as coordinator_id, pr.project_id, ps.master_roll_reminder_hours, ps.master_roll_lock_hours
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

    if hours_since_date >= coord.master_roll_lock_hours then
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
    select distinct pr.user_id as coordinator_id, pr.project_id, ps.progress_report_reminder_hours, ps.progress_report_lock_hours
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

    if hours_since_date >= coord.progress_report_lock_hours then
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
