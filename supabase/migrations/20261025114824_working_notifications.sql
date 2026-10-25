-- =====================================================================
-- Make notification emails real.
--
-- Until now no email was ever delivered: the send-notification function
-- crashed on start (it read its key from SUPABASE_SECRET_KEYS, which this
-- project doesn't set), and fn_dispatch_pending_notifications marked every
-- event "sent" the moment it queued the HTTP call, so 4,600+ reminders
-- show as sent though none arrived. The function is fixed separately
-- (supabase/functions/send-notification). Here:
--
--   * dispatch records the HTTP request id (status 'dispatched'), and the
--     next run marks the event 'sent' or 'failed' from the actual response,
--     keeping the error text in last_error;
--   * events for addresses that can't receive mail (test domains such as
--     seedtest.local, test.com) are 'skipped' instead of sent;
--   * reminders and locks only run for projects whose status is 'active',
--     so putting a project on hold stops its emails;
--   * a daily all-sites summary (19:00 Bhutan time) goes to every Company
--     Owner and Admin of an active project.
-- =====================================================================

ALTER TABLE public.notification_events DROP CONSTRAINT notification_events_status_check;
ALTER TABLE public.notification_events ADD CONSTRAINT notification_events_status_check
  CHECK (status = ANY (ARRAY['pending'::text, 'dispatched'::text, 'sent'::text, 'failed'::text, 'skipped'::text]));
ALTER TABLE public.notification_events DROP CONSTRAINT notification_events_event_type_check;
ALTER TABLE public.notification_events ADD CONSTRAINT notification_events_event_type_check
  CHECK (event_type = ANY (ARRAY['master_roll_reminder'::text, 'master_roll_final_reminder'::text, 'master_roll_lock'::text,
    'progress_report_reminder'::text, 'progress_report_final_reminder'::text, 'progress_report_lock'::text,
    'settlement_reminder'::text, 'settlement_final_reminder'::text, 'settlement_lock'::text,
    'cash_replenishment_alert'::text, 'fund_requisition_approved_accounts_email'::text, 'daily_owner_summary'::text]));
-- The daily summary covers all of a person's sites, so it has no single project.
ALTER TABLE public.notification_events ALTER COLUMN project_id DROP NOT NULL;
ALTER TABLE public.notification_events
  ADD COLUMN net_request_id bigint,
  ADD COLUMN dispatched_at timestamp with time zone,
  ADD COLUMN last_error text;


-- An address that can actually receive mail (not a reserved/test domain).
CREATE FUNCTION public.fn_is_deliverable_email(p_email text)
 RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public
AS $function$
  select coalesce(p_email, '') ~* '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$'
     and lower(split_part(p_email, '@', 2)) !~ '(^|\.)(local|localhost|test|example|invalid)$'
     and lower(split_part(p_email, '@', 2)) not in ('example.com', 'example.org', 'example.net', 'test.com');
$function$;


CREATE OR REPLACE FUNCTION public.fn_dispatch_pending_notifications()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path = public
AS $function$
declare
  evt record;
  edge_function_url text;
  service_key text;
  v_request bigint;
begin
  -- 1. Results of earlier calls (pg_net keeps responses for about 6 hours).
  update notification_events e
     set status = case when r.status_code between 200 and 299 then 'sent' else 'failed' end,
         sent_at = case when r.status_code between 200 and 299 then r.created end,
         last_error = case when r.status_code between 200 and 299 then null
                           else left(coalesce(nullif(r.error_msg, ''), r.content::text, 'HTTP ' || r.status_code::text), 500) end
    from net._http_response r
   where e.status = 'dispatched' and r.id = e.net_request_id;

  update notification_events
     set status = 'failed', last_error = 'No response from the email function'
   where status = 'dispatched' and dispatched_at < now() - interval '3 hours';

  -- 2. Nothing to deliver to.
  update notification_events e
     set status = 'skipped', last_error = 'No deliverable email address'
   where e.status = 'pending'
     and not fn_is_deliverable_email((select p.email from profiles p where p.id = e.target_user_id));

  -- 3. Send what's pending.
  select decrypted_secret into edge_function_url from vault.decrypted_secrets where name = 'edge_function_base_url';
  select decrypted_secret into service_key from vault.decrypted_secrets where name = 'service_role_key';

  if edge_function_url is null or service_key is null then
    raise warning 'fn_dispatch_pending_notifications: vault secrets not configured, skipping dispatch this run.';
    return;
  end if;

  for evt in
    select * from notification_events where status = 'pending' order by created_at asc limit 100
  loop
    v_request := net.http_post(
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
    update notification_events
       set status = 'dispatched', net_request_id = v_request, dispatched_at = now()
     where id = evt.id;
  end loop;
end;
$function$;


-- Daily all-sites summary for each Company Owner / Admin of an active
-- project. Built from v_portfolio_summary as that person, so it holds
-- exactly the sites they see on the dashboard.
CREATE FUNCTION public.fn_queue_daily_owner_summaries()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
 SET timezone TO 'Asia/Thimphu'
AS $function$
declare
  u record;
  v_sites jsonb;
  v_queued integer := 0;
begin
  for u in
    select distinct r.user_id
      from project_roles r join projects p on p.id = r.project_id
     where r.status = 'active' and r.role in ('company_owner', 'admin') and p.status = 'active'
  loop
    if exists (
      select 1 from notification_events
       where target_user_id = u.user_id and event_type = 'daily_owner_summary' and created_at::date = current_date
    ) then
      continue;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', u.user_id, 'role', 'authenticated')::text, true);
    select jsonb_agg(jsonb_build_object(
             'name', s.name,
             'physical_progress_pct', s.physical_progress_pct,
             'financial_progress_pct', s.financial_progress_pct,
             'cost_variance', s.cost_variance,
             'cash_balance', s.cash_balance,
             'cash_low', s.cash_low,
             'coordinators_on_duty', s.coordinators_on_duty,
             'submitted_today', least(s.master_roll_submitted_today, s.progress_submitted_today),
             'coordinators_missing_today', s.coordinators_missing_today,
             'settlements_overdue', s.settlements_overdue,
             'advances_pending_approval', s.advances_pending_approval,
             'fund_requisitions_pending', s.fund_requisitions_pending,
             'schedule_items_late', s.schedule_items_late,
             'po_deliveries_overdue', s.po_deliveries_overdue,
             'po_open_value', s.po_open_value
           ) order by s.name)
      into v_sites
      from v_portfolio_summary s
     where s.status = 'active';

    if v_sites is not null then
      insert into notification_events (project_id, event_type, target_user_id, payload)
      values (null, 'daily_owner_summary', u.user_id, jsonb_build_object('date', current_date, 'sites', v_sites));
      v_queued := v_queued + 1;
    end if;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  return v_queued;
end;
$function$;

REVOKE ALL ON FUNCTION public.fn_queue_daily_owner_summaries(), public.fn_dispatch_pending_notifications()
  FROM PUBLIC, anon, authenticated;


-- Same as before, except reminders and locks only for active projects.
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
    join projects pj on pj.id = pr.project_id and pj.status = 'active'
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
    join projects pj on pj.id = pr.project_id and pj.status = 'active'
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
    join projects pj on pj.id = ar.project_id and pj.status = 'active'
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

-- 19:00 Bhutan time (pg_cron runs on UTC).
SELECT cron.schedule('daily-owner-summary', '0 13 * * *', 'select fn_queue_daily_owner_summaries();');
