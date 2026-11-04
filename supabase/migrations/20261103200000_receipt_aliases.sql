-- Receipt scanning, photo half (#61). The photo is read on the phone and never leaves it; no receipt or receipt line is
-- stored. What's kept is what the family taught: a receipt line's text (as the app normalizes it: printed words without
-- prices, codes and flags, lowercased) is this item. Anyone in the family can teach it, kids too, since a correction
-- helps the whole household and checking off is open to everyone.
-- One alias per text per household. Correcting it again moves it to the new item; it's never deleted, and it goes with its
-- item or household (both only ever deleted with the household).

create table public.receipt_aliases (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  raw_text text not null
    check (char_length(raw_text) between 1 and 80 and raw_text = lower(btrim(raw_text))),
  item_id uuid not null,
  -- Set null, not cascade: what someone taught stays with the household after they're gone.
  created_by uuid references public.members (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (item_id, household_id) references public.items (id, household_id) on delete cascade,
  constraint receipt_aliases_household_text_key unique (household_id, raw_text)
);

create index receipt_aliases_item_idx on public.receipt_aliases (item_id, household_id);
create index receipt_aliases_created_by_idx on public.receipt_aliases (created_by);

create trigger receipt_aliases_set_updated_at before update on public.receipt_aliases
  for each row execute function public.set_updated_at();

revoke all on public.receipt_aliases from anon, authenticated;
grant select on public.receipt_aliases to authenticated;
grant insert (household_id, raw_text, item_id, created_by) on public.receipt_aliases to authenticated;
grant update (item_id) on public.receipt_aliases to authenticated;

alter table public.receipt_aliases enable row level security;

create policy "members read receipt aliases" on public.receipt_aliases
  for select to authenticated using (public.is_household_member(household_id));
create policy "members teach receipt aliases" on public.receipt_aliases
  for insert to authenticated
  with check (public.is_household_member(household_id)
              and (created_by is null or created_by = public.my_member_id(household_id)));
create policy "members correct receipt aliases" on public.receipt_aliases
  for update to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- Teach one line: insert, or move an existing alias to the new item. Runs under the caller's RLS, like ensure_item; the
-- composite foreign key keeps the item in the same household.
create function public.teach_receipt_alias(target_household uuid, alias_text text, target_item uuid)
returns public.receipt_aliases
language sql security invoker set search_path = ''
as $$
  insert into public.receipt_aliases as existing (household_id, raw_text, item_id, created_by)
  values (target_household, lower(btrim(alias_text)), target_item, public.my_member_id(target_household))
  on conflict (household_id, raw_text) do update set item_id = excluded.item_id
  returning *;
$$;

revoke execute on function public.teach_receipt_alias(uuid, text, uuid) from public, anon;
grant execute on function public.teach_receipt_alias(uuid, text, uuid) to authenticated;

-- The export holds what "What Foon keeps" lists, and that now includes the receipt lines someone corrected.
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
    'hidden_comments', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.hidden_at), '[]')
                        from public.hidden_comments c where household_id = target_household),
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
                     from public.plan_changes c where household_id = target_household),
    'notification_log', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                         from public.notification_log l where household_id = target_household),
    'polls', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
              from public.polls p where household_id = target_household),
    'poll_votes', (select coalesce(jsonb_agg(to_jsonb(v) - 'household_id' order by v.voted_at), '[]')
                   from public.poll_votes v where household_id = target_household),
    'receipt_aliases', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.raw_text), '[]')
                        from public.receipt_aliases r where household_id = target_household)
  );
end;
$$;
