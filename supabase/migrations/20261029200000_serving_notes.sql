-- Serving notes (#46, part 2): how someone likes a dish served ("Nora: keep everything separate before mixing").
-- One per person per dish, up to 120 characters, visible to the whole family; shown on day cards when that person is
-- home and in cook mode. The person writes their own; parents (guardians) write anyone's, kids without phones
-- included. Clearing a note deletes it: it's a preference, not history. Whoever last wrote it is kept, for kid retention.

create table public.serving_notes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  meal_id uuid not null,
  member_id uuid not null,
  note text not null check (char_length(btrim(note)) between 1 and 120),
  written_by_member_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint serving_notes_one_per_member unique (meal_id, member_id),
  constraint serving_notes_meal_fkey foreign key (meal_id, household_id) references public.meals (id, household_id),
  constraint serving_notes_member_fkey foreign key (member_id, household_id) references public.members (id, household_id),
  constraint serving_notes_writer_fkey foreign key (written_by_member_id, household_id)
    references public.members (id, household_id)
);

create index serving_notes_household_idx on public.serving_notes (household_id);

create trigger serving_notes_set_updated_at before update on public.serving_notes
  for each row execute function public.set_updated_at();

-- Who may write a member's note: themselves, or a parent.
create function public.may_write_note_for(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members m
    where m.id = target_member and m.status <> 'removed'
      and (m.id = public.my_member_id(m.household_id) or public.is_household_manager(m.household_id))
  );
$$;

revoke execute on function public.may_write_note_for(uuid) from public, anon;
grant execute on function public.may_write_note_for(uuid) to authenticated;

-- The writer is stamped, never claimed.
create function public.serving_notes_stamp_writer()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user = 'authenticated' then
    new.written_by_member_id := public.my_member_id(new.household_id);
    new.note := btrim(new.note);
  end if;
  return new;
end;
$$;

create trigger serving_notes_stamp_writer before insert or update on public.serving_notes
  for each row execute function public.serving_notes_stamp_writer();

revoke all on public.serving_notes from anon, authenticated;
grant select, delete on public.serving_notes to authenticated;
grant insert (household_id, meal_id, member_id, note) on public.serving_notes to authenticated;
grant update (note) on public.serving_notes to authenticated;

alter table public.serving_notes enable row level security;

create policy "members read serving notes" on public.serving_notes
  for select to authenticated using (public.is_household_member(household_id));
create policy "people write their notes, parents anyone's" on public.serving_notes
  for insert to authenticated
  with check (public.is_household_member(household_id) and public.may_write_note_for(member_id));
create policy "people change their notes, parents anyone's" on public.serving_notes
  for update to authenticated
  using (public.may_write_note_for(member_id))
  with check (public.may_write_note_for(member_id));
create policy "people clear their notes, parents anyone's" on public.serving_notes
  for delete to authenticated using (public.may_write_note_for(member_id));

-- Sets, changes, or (with a blank note) clears a member's note on a dish, in one call.
create function public.set_serving_note(target_meal uuid, target_member uuid, note_text text)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
begin
  select household_id into household from public.meals where id = target_meal;
  if household is null then
    raise exception 'no meal %', target_meal using errcode = 'P0002';
  end if;
  if not public.may_write_note_for(target_member) then
    raise exception 'people write their own notes; parents write anyone''s' using errcode = '42501';
  end if;
  if nullif(btrim(note_text), '') is null then
    delete from public.serving_notes where meal_id = target_meal and member_id = target_member;
    return;
  end if;
  insert into public.serving_notes as existing (household_id, meal_id, member_id, note)
  values (household, target_meal, target_member, note_text)
  on conflict (meal_id, member_id) do update set note = excluded.note;
end;
$$;

revoke execute on function public.set_serving_note(uuid, uuid, text) from public, anon;
grant execute on function public.set_serving_note(uuid, uuid, text) to authenticated;

-- Deletion, export, and retention cover notes.
create or replace function public.delete_account_data(target_user uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  owned uuid;
  profile public.members;
begin
  -- Rate-limit bookkeeping keyed by the account; nothing to keep once it's gone.
  delete from public.invite_redeem_attempts where user_id = target_user;

  select id into owned from public.households where owner = target_user;
  if owned is not null then
    delete from public.serving_notes where household_id = owned;
    delete from public.chef_thanks where household_id = owned;
    delete from public.reactions where household_id = owned;
    delete from public.meal_logs where household_id = owned;
    delete from public.night_attendance where household_id = owned;
    delete from public.list_items where household_id = owned;
    delete from public.plan_nights where household_id = owned;
    delete from public.plans where household_id = owned;
    delete from public.traditions where household_id = owned;
    delete from public.meal_sides where household_id = owned;
    delete from public.meal_ingredients where household_id = owned;
    delete from public.meals where household_id = owned;
    delete from public.items where household_id = owned;
    delete from public.member_allergies where household_id = owned;
    delete from public.invites where household_id = owned;
    delete from public.consents where household_id = owned;
    delete from public.members where household_id = owned;
    delete from public.households where id = owned;
    return 'household_deleted';
  end if;

  select * into profile from public.members where user_id = target_user;
  if profile.id is null then
    return 'no_household';
  end if;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    return 'unlinked';
  end if;

  delete from public.member_allergies where member_id = profile.id;
  -- Notes about how someone likes their food are about them; they go with the name.
  delete from public.serving_notes where member_id = profile.id;
  -- Their ratings stay as anonymous history; what they wrote in their own words doesn't.
  update public.reactions set comment = null where member_id = profile.id;
  update public.members
  set status = 'removed', removed_at = now(), first_name = 'Former member', avatar = null,
      attendance_defaults = '{}', notification_prefs = '{}', declared_age_band = null, anonymized_at = now()
  where id = profile.id;
  return 'profile_anonymized';
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
                      from public.serving_notes n where household_id = target_household)
  );
end;
$$;
create or replace function public.anonymize_expired_profiles()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  removed uuid[];
  withdrawn uuid[];
begin
  select coalesce(array_agg(m.id), '{}') into removed
  from public.members m
  where m.age_group = 'kid' and m.anonymized_at is null and m.user_id is null
    and m.status = 'removed' and m.removed_at < now() - interval '12 months';

  select coalesce(array_agg(m.id), '{}') into withdrawn
  from public.members m
  where m.age_group = 'kid' and m.user_id is null and m.status <> 'removed'
    and not public.has_parental_consent(m.id)
    -- Measured from the latest withdrawal, so an older consent cycle can't shorten the 30 days;
    -- erased again only if a newer withdrawal came after the last erase.
    and (select max(c.revoked_at) from public.consents c where c.member_id = m.id and c.kind = 'parental')
        < now() - interval '30 days'
    and (m.own_data_erased_at is null
         or m.own_data_erased_at < (select max(c.revoked_at) from public.consents c
                                    where c.member_id = m.id and c.kind = 'parental'));

  delete from public.member_allergies where member_id = any (removed);
  delete from public.serving_notes where member_id = any (removed);
  -- A removed kid's ratings stay as anonymous history; their own words don't.
  update public.reactions set comment = null where member_id = any (removed);
  -- What a kid rated themselves (not what a parent entered for them by passing the phone) is theirs to lose.
  delete from public.reactions where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.reactions set comment = null where member_id = any (withdrawn);
  -- The thanks a kid sent from their own phone are theirs too.
  delete from public.chef_thanks where from_member_id = any (withdrawn);
  -- Notes a kid wrote themselves are theirs; ones a parent wrote for them stay.
  delete from public.serving_notes where member_id = any (withdrawn) and written_by_member_id = member_id;
  update public.members
  set first_name = 'Former member', avatar = null, attendance_defaults = '{}', notification_prefs = '{}',
      declared_age_band = null, anonymized_at = now()
  where id = any (removed);

  update public.members
  set declared_age_band = null, own_data_erased_at = now()
  where id = any (withdrawn);

  return cardinality(removed) + cardinality(withdrawn);
end;
$$;
