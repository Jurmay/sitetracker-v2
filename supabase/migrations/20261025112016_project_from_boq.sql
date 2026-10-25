-- =====================================================================
-- Create a project from a won tender's BOQ.
--
-- Until now no user could create a project: projects_insert_owner lets a
-- Company Owner insert the row, but project_roles_insert_owner needs them
-- to already own that project, so nobody could give themselves the first
-- role. fn_create_project_from_boq does the whole thing in one checked,
-- atomic step: project (budget = BOQ total), Company Owner role for the
-- caller, BOQ sections and items. Project settings and report permissions
-- come from the existing triggers.
--
-- Only a Company Owner (active on any project of their own company) may
-- call it, and the project always lands in the caller's own company.
-- companies.project_limit, when set, is respected.
-- =====================================================================

ALTER TABLE public.projects ADD COLUMN tender_ref text;  -- NIT / tender number the project was won under

-- Company Owner on at least one active project of their own company.
CREATE FUNCTION public.fn_can_create_project()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  select exists (
    select 1 from project_roles r join projects p on p.id = r.project_id
    where r.user_id = auth.uid() and r.status = 'active' and r.role = 'company_owner'
      and p.company_id = fn_my_company_id()
  );
$function$;

-- p_sections: [{"name": "...", "items": [{"description", "unit", "quantity", "rate"}, ...]}, ...]
CREATE FUNCTION public.fn_create_project_from_boq(
  p_name text, p_sections jsonb,
  p_location text DEFAULT NULL, p_start_date date DEFAULT NULL, p_target_end_date date DEFAULT NULL,
  p_tender_ref text DEFAULT NULL)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
declare
  v_user uuid := auth.uid();
  v_company uuid := fn_my_company_id();
  v_limit integer;
  v_currency text;
  v_project uuid;
  v_section uuid;
  v_total numeric;
  s record;
  bad text;
begin
  if v_user is null or not fn_can_create_project() then
    raise exception 'Only a Company Owner can create projects' using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'Give the project a name';
  end if;
  if p_start_date is not null and p_target_end_date is not null and p_target_end_date < p_start_date then
    raise exception 'The target end date is before the start date';
  end if;
  if p_sections is null or jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) = 0 then
    raise exception 'The BOQ has no sections';
  end if;

  -- Every item needs a description and unit, and a quantity and rate that aren't negative.
  select coalesce(sec->>'name', '?') || ': ' || coalesce(it->>'description', '(no description)')
    into bad
    from jsonb_array_elements(p_sections) sec, jsonb_array_elements(coalesce(sec->'items', '[]')) it
   where coalesce(btrim(it->>'description'), '') = '' or coalesce(btrim(it->>'unit'), '') = ''
      or (it->>'quantity') is null or (it->>'quantity')::numeric < 0
      or (it->>'rate') is null or (it->>'rate')::numeric < 0
   limit 1;
  if bad is not null then
    raise exception 'BOQ line needs a description, unit, and a quantity and rate of 0 or more: %', bad;
  end if;
  if not exists (select 1 from jsonb_array_elements(p_sections) sec, jsonb_array_elements(coalesce(sec->'items', '[]')) it) then
    raise exception 'The BOQ has no items';
  end if;

  select project_limit, currency into v_limit, v_currency from companies where id = v_company for update;
  if v_limit is not null and (select count(*) from projects where company_id = v_company) >= v_limit then
    raise exception 'Your plan allows % projects; archive one or raise the limit first', v_limit;
  end if;

  select coalesce(sum(round((it->>'quantity')::numeric * (it->>'rate')::numeric, 2)), 0) into v_total
    from jsonb_array_elements(p_sections) sec, jsonb_array_elements(coalesce(sec->'items', '[]')) it;

  insert into projects (company_id, name, location, start_date, target_end_date, total_budget, currency, status, tender_ref)
  values (v_company, btrim(p_name), nullif(btrim(p_location), ''), p_start_date, p_target_end_date, v_total,
          coalesce(v_currency, 'BTN'), 'active', nullif(btrim(p_tender_ref), ''))
  returning id into v_project;

  insert into project_roles (project_id, user_id, role, status, assigned_by)
  values (v_project, v_user, 'company_owner', 'active', v_user);

  for s in select sec, ord from jsonb_array_elements(p_sections) with ordinality as x(sec, ord) loop
    insert into boq_sections (project_id, name, sort_order)
    values (v_project, coalesce(nullif(btrim(s.sec->>'name'), ''), 'General'), s.ord)
    returning id into v_section;

    insert into boq_items (section_id, description, unit, quantity, rate)
    select v_section, btrim(it->>'description'), btrim(it->>'unit'), (it->>'quantity')::numeric, (it->>'rate')::numeric
      from jsonb_array_elements(coalesce(s.sec->'items', '[]')) it;
  end loop;

  return v_project;
end;
$function$;

REVOKE ALL ON FUNCTION public.fn_can_create_project(), public.fn_create_project_from_boq(text, jsonb, text, date, date, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_can_create_project(), public.fn_create_project_from_boq(text, jsonb, text, date, date, text)
  TO authenticated;
