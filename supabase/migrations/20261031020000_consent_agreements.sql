-- Who agreed to keep allergy data, and to which wording (#47).
-- 1. consents stays the gate: one active row per household, which says whether allergy data may be kept. Calling
--    grant_allergy_consent again while it's active changes nothing there, so a second parent's agreement, a new wording, or a
--    real parent agreeing in a sample family ("sample-family-v1" means nobody read it) were never written down. They go in
--    consent_agreements, one row per person per wording. Nothing that reads consents changes, and older builds keep working:
--    they call the same function with the same arguments.
-- 2. set_member_allergies lets a parent clear someone's list without active consent. The sentence promises parents can
--    delete them anytime, and revoking consent shouldn't stop that. Adding still needs consent.

create table public.consent_agreements (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  -- No foreign key: like consents.granted_by, the record outlives the account that agreed.
  agreed_by uuid not null default auth.uid(),
  agreed_at timestamptz not null default now(),
  -- Which wording the person agreed to.
  text_version text not null check (char_length(btrim(text_version)) between 1 and 40),
  constraint consent_agreements_one_per_wording unique (household_id, agreed_by, text_version)
);

revoke all on public.consent_agreements from anon, authenticated;
grant select on public.consent_agreements to authenticated;
-- agreed_by and agreed_at aren't granted: they're always this person, now.
grant insert (household_id, text_version) on public.consent_agreements to authenticated;

alter table public.consent_agreements enable row level security;

create policy "members read household agreements" on public.consent_agreements
  for select to authenticated
  using (public.is_household_member(household_id));

create policy "guardians record their own agreement" on public.consent_agreements
  for insert to authenticated
  with check (agreed_by = (select auth.uid()) and public.is_household_manager(household_id));

-- What's already known: whoever gave each consent agreed to its wording, then.
insert into public.consent_agreements (household_id, agreed_by, agreed_at, text_version)
select household_id, granted_by, min(granted_at), text_version
from public.consents
where kind = 'allergy_data'
group by household_id, granted_by, text_version;

create or replace function public.grant_allergy_consent(target_household uuid, wording text)
returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  if not public.is_household_manager(target_household) then
    raise exception 'only parents decide about allergy data' using errcode = '42501';
  end if;
  insert into public.consents (household_id, kind, text_version) values (target_household, 'allergy_data', wording)
  on conflict (household_id, kind, member_id) where revoked_at is null do nothing;
  insert into public.consent_agreements (household_id, text_version) values (target_household, wording)
  on conflict (household_id, agreed_by, text_version) do nothing;
end;
$$;

create or replace function public.set_member_allergies(target_member uuid, allergens public.allergen[], custom text[])
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
begin
  select household_id into household from public.members where id = target_member;
  if household is null then
    raise exception 'no member %', target_member using errcode = 'P0002';
  end if;
  if not public.is_household_manager(household) then
    raise exception 'only parents set allergies' using errcode = '42501';
  end if;
  -- Keeping something needs consent. Clearing keeps nothing, so it doesn't.
  if (exists (select 1 from unnest(allergens) as allergen where allergen <> 'custom')
      or exists (select 1 from unnest(custom) as text where btrim(text) <> ''))
     and not public.has_active_consent(household, 'allergy_data') then
    raise exception 'the household has not agreed to keep allergy data' using errcode = '42501';
  end if;

  delete from public.member_allergies where member_id = target_member;

  insert into public.member_allergies (household_id, member_id, category)
  select distinct household, target_member, allergen
  from unnest(allergens) as allergen
  where allergen <> 'custom';

  insert into public.member_allergies (household_id, member_id, category, custom_text)
  select distinct household, target_member, 'custom'::public.allergen, btrim(text)
  from unnest(custom) as text
  where btrim(text) <> '';
end;
$$;

-- Deleting and exporting ------------------------------------------------------------------------------------------------

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Holds the nights first, so a Swap in flight can't log a new entry after the log's been emptied and fail the erase.
  perform 1 from public.plan_nights where household_id = target for update;
  delete from public.plan_changes where household_id = target;
  delete from public.night_claims where household_id = target;
  delete from public.attendance_templates where household_id = target;
  delete from public.request_plus_ones where household_id = target;
  delete from public.requests where household_id = target;
  delete from public.serving_notes where household_id = target;
  delete from public.chef_thanks where household_id = target;
  delete from public.reactions where household_id = target;
  delete from public.meal_logs where household_id = target;
  delete from public.night_attendance where household_id = target;
  delete from public.list_items where household_id = target;
  delete from public.plan_nights where household_id = target;
  delete from public.freezer_stash where household_id = target;
  delete from public.plans where household_id = target;
  delete from public.traditions where household_id = target;
  delete from public.meal_sides where household_id = target;
  delete from public.meal_ingredients where household_id = target;
  delete from public.meals where household_id = target;
  delete from public.items where household_id = target;
  delete from public.member_allergies where household_id = target;
  delete from public.invites where household_id = target;
  delete from public.consent_agreements where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;

create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners export the household' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'household', (select to_jsonb(h) - 'owner' from public.households h where id = target_household),
    'members', (select coalesce(jsonb_agg(to_jsonb(m) - 'user_id' - 'household_id' order by m.created_at), '[]')
                from public.members m where household_id = target_household),
    'allergies', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                  from public.member_allergies a where household_id = target_household),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' - 'granted_by' order by c.granted_at), '[]')
                 from public.consents c where household_id = target_household),
    'consent_agreements', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id' - 'agreed_by' order by a.agreed_at), '[]')
                           from public.consent_agreements a where household_id = target_household),
    'meals', (select coalesce(jsonb_agg(to_jsonb(m) - 'household_id' order by m.name), '[]')
              from public.meals m where household_id = target_household),
    'meal_ingredients', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id'), '[]')
                         from public.meal_ingredients i where household_id = target_household),
    'meal_sides', (select coalesce(jsonb_agg(to_jsonb(s) - 'household_id'), '[]')
                   from public.meal_sides s where household_id = target_household),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id' order by i.canonical_name), '[]')
              from public.items i where household_id = target_household),
    'traditions', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id'), '[]')
                   from public.traditions t where household_id = target_household),
    'plans', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.week_start), '[]')
              from public.plans p where household_id = target_household),
    'nights', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.date), '[]')
               from public.plan_nights n where household_id = target_household),
    'attendance', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                   from public.night_attendance a where household_id = target_household),
    'list_items', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id'), '[]')
                   from public.list_items l where household_id = target_household),
    'meal_logs', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                  from public.meal_logs l where household_id = target_household),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                  from public.reactions r where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household),
    'attendance_templates', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                             from public.attendance_templates t where household_id = target_household),
    'freezer_stash', (select coalesce(jsonb_agg(to_jsonb(f) - 'household_id' order by f.created_at), '[]')
                      from public.freezer_stash f where household_id = target_household),
    'night_claims', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.created_at), '[]')
                     from public.night_claims c where household_id = target_household),
    'plan_changes', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.id), '[]')
                     from public.plan_changes c where household_id = target_household)
  );
end;
$$;
