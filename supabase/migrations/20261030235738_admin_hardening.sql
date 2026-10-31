-- =====================================================================
-- Admin hardening (from the admin page review).
--
-- project_roles rules, enforced in the database so they hold for every
-- way in (the app, the API, Supabase's own tools when signed in):
--   * a person can only be given a role on a project of their own company
--   * only a Company Owner can grant, change or remove the Company Owner
--     role (an Admin can no longer make themselves Owner or lock the
--     Owner out); the first owner of a new project is the exception
--   * every project keeps at least one active Company Owner
--   * a role row's project, person and role are fixed; change a role by
--     adding the new one and switching the old one off
--
-- fn_project_members: the People list for Owners and Admins: everyone in
-- the company, their roles on this project, invite status, last sign-in.
-- fn_project_activity: the audit log for Owners and Admins, with names.
--
-- fund_requisitions: can now be rejected, with a reason; a decided
-- requisition can't be decided again.
-- =====================================================================


-- ---------------------------------------------------------------------
-- project_roles rules
-- ---------------------------------------------------------------------
CREATE FUNCTION public.fn_project_roles_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_project uuid := coalesce(new.project_id, old.project_id);
  v_other_owners integer;
begin
  if tg_op = 'UPDATE' and (new.project_id <> old.project_id or new.user_id <> old.user_id or new.role <> old.role) then
    raise exception 'A role cannot be changed in place; add the new role and switch the old one off';
  end if;

  if tg_op <> 'DELETE' and not exists (
    select 1 from profiles u join projects p on p.company_id = u.company_id
    where u.id = new.user_id and p.id = new.project_id
  ) then
    raise exception 'That person is not part of this company, so they cannot be given a role on its projects';
  end if;

  -- Owner role: only an owner may grant, change or remove it. auth.uid()
  -- is null for the backend's own system jobs, which this does not limit.
  -- A project with no active owner yet (just being created) may get its first.
  if auth.uid() is not null
     and ((tg_op <> 'DELETE' and new.role = 'company_owner') or (tg_op <> 'INSERT' and old.role = 'company_owner'))
     and exists (select 1 from project_roles r where r.project_id = v_project and r.role = 'company_owner' and r.status = 'active')
     and not fn_is_company_owner_of_project(v_project) then
    raise exception 'Only a Company Owner can grant, change or remove the Company Owner role' using errcode = '42501';
  end if;

  -- Keep at least one active owner.
  if tg_op <> 'INSERT' and old.role = 'company_owner' and old.status = 'active'
     and (tg_op = 'DELETE' or new.status <> 'active') then
    select count(*) into v_other_owners from project_roles r
     where r.project_id = old.project_id and r.role = 'company_owner' and r.status = 'active' and r.id <> old.id;
    if v_other_owners = 0 then
      raise exception 'A project must keep at least one active Company Owner; make someone else an owner first';
    end if;
  end if;

  return coalesce(new, old);
end;
$function$;

CREATE TRIGGER trg_project_roles_guard BEFORE INSERT OR UPDATE OR DELETE ON public.project_roles
  FOR EACH ROW EXECUTE FUNCTION fn_project_roles_guard();


-- ---------------------------------------------------------------------
-- People list and activity (Owners and Admins of the project only)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.fn_can_manage_people(p_project_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select fn_is_company_owner_of_project(p_project_id) or fn_has_project_role(p_project_id, 'admin');
$function$;

-- Everyone in the project's company, with their roles on this project.
-- invite_pending: invited but has never signed in.
CREATE FUNCTION public.fn_project_members(p_project_id uuid)
 RETURNS TABLE (user_id uuid, name text, email text, phone text, roles jsonb,
                has_active_role boolean, invite_pending boolean, invited_at timestamptz, last_sign_in_at timestamptz)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
begin
  if not fn_can_manage_people(p_project_id) then
    raise exception 'Only an Admin or Company Owner can see the people on this project' using errcode = '42501';
  end if;
  return query
  select u.id, u.name, u.email, u.phone,
         coalesce((select jsonb_agg(jsonb_build_object('role', r.role, 'status', r.status, 'assigned_at', r.assigned_at)
                                    order by r.status, r.role)
                     from project_roles r where r.project_id = p_project_id and r.user_id = u.id), '[]'::jsonb),
         exists (select 1 from project_roles r where r.project_id = p_project_id and r.user_id = u.id and r.status = 'active'),
         (au.last_sign_in_at is null and au.invited_at is not null),
         au.invited_at, au.last_sign_in_at
    from profiles u
    join projects p on p.id = p_project_id and p.company_id = u.company_id
    left join auth.users au on au.id = u.id
   order by 6 desc, u.name;
end;
$function$;

-- Recent changes on the project, newest first, with who made them.
CREATE FUNCTION public.fn_project_activity(p_project_id uuid, p_limit integer DEFAULT 100)
 RETURNS TABLE (id uuid, created_at timestamptz, actor_name text, action_type text, entity_type text,
                entity_id uuid, before_value jsonb, after_value jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
begin
  if not fn_can_manage_people(p_project_id) then
    raise exception 'Only an Admin or Company Owner can see the activity log' using errcode = '42501';
  end if;
  return query
  select a.id, a.created_at, coalesce(pr.name, 'System'), a.action_type, a.entity_type, a.entity_id,
         a.before_value, a.after_value
    from audit_log a
    left join profiles pr on pr.id = a.actor_id
   where a.project_id = p_project_id
   order by a.created_at desc
   limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$function$;


-- ---------------------------------------------------------------------
-- Fund requisitions: reject with a reason; decide once
-- ---------------------------------------------------------------------
ALTER TABLE public.fund_requisitions
  ADD COLUMN rejected_by uuid REFERENCES public.profiles(id),
  ADD COLUMN rejected_at timestamp with time zone,
  ADD COLUMN rejection_reason text;

CREATE FUNCTION public.fn_fund_requisition_before_update()
 RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $function$
begin
  if new.status = old.status then
    return new;
  end if;
  if old.status <> 'pending_approval' then
    raise exception 'This fund requisition was already %', old.status;
  end if;
  if new.status = 'rejected' then
    if coalesce(btrim(new.rejection_reason), '') = '' then
      raise exception 'Give a reason for rejecting the fund requisition';
    end if;
    new.rejected_by := auth.uid();
    new.rejected_at := now();
  end if;
  return new;
end;
$function$;

CREATE TRIGGER trg_fund_requisition_before_update BEFORE UPDATE ON public.fund_requisitions
  FOR EACH ROW EXECUTE FUNCTION fn_fund_requisition_before_update();


-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fn_can_manage_people(uuid), public.fn_project_members(uuid),
  public.fn_project_activity(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_can_manage_people(uuid), public.fn_project_members(uuid),
  public.fn_project_activity(uuid, integer) TO authenticated;
REVOKE ALL ON FUNCTION public.fn_project_roles_guard(), public.fn_fund_requisition_before_update()
  FROM PUBLIC, anon, authenticated;
