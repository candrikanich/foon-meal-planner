-- A weekly list line remembers which nights' dishes it's for (#337), so the list can say "Tue · Chili, Fri · Tacos" (#351).
-- Nights, not meal names: the weekday comes from the night's date and the dish from the night's meal when read, so a swap or
-- a rename stays right with nothing to update here. Update the list (approve_plan) rewrites this week's rows.
-- Composite foreign keys keep a row inside one household. Both cascade, so deleting a line or a night (or erasing a
-- household) takes its rows with it.
alter table public.list_items add constraint list_items_id_household_key unique (id, household_id);

create table public.list_item_nights (
  household_id uuid not null references public.households (id),
  list_item_id uuid not null,
  plan_night_id uuid not null,
  primary key (list_item_id, plan_night_id),
  foreign key (list_item_id, household_id) references public.list_items (id, household_id) on delete cascade,
  foreign key (plan_night_id, household_id) references public.plan_nights (id, household_id) on delete cascade
);

create index list_item_nights_night_idx on public.list_item_nights (plan_night_id);
create index list_item_nights_household_idx on public.list_item_nights (household_id);

revoke all on public.list_item_nights from anon, authenticated;
grant select, insert, delete on public.list_item_nights to authenticated;

alter table public.list_item_nights enable row level security;

create policy "members read list nights" on public.list_item_nights
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members add list nights" on public.list_item_nights
  for insert to authenticated
  with check (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members remove list nights" on public.list_item_nights
  for delete to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));

-- Each element of lines may carry night_ids, the nights whose dishes need that item. Missing means none. Ids that aren't
-- nights of this plan are ignored. Only this plan's nights are rewritten: another week's rows on a shared line stay.
create or replace function public.approve_plan(target_plan uuid, lines jsonb)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
begin
  -- Under the caller's row-level security another household's plan is simply not found.
  select household_id into household from public.plans where id = target_plan;
  if household is null then
    raise exception 'no plan %', target_plan using errcode = 'P0002';
  end if;
  if not public.is_household_planner(household) then
    raise exception 'only planners approve the week' using errcode = '42501';
  end if;
  if jsonb_typeof(lines) is distinct from 'array' then
    raise exception 'lines must be a JSON array' using errcode = '22023';
  end if;

  -- This week no longer needs these. One another week also listed goes to that week, keeping the notes from elsewhere until
  -- that week rebuilds it, when only a hand-added note is kept. One with a hand-added note stays as a hand-added line with
  -- that note. The rest go.
  update public.list_items
  set plan_id = also_for_plan,
      also_for_plan = null,
      source = case when also_for_plan is null then 'manual'::public.list_item_source else source end,
      note = case when also_for_plan is null then hand_note else kept_note end,
      kept_note = hand_note,
      quantity = null
  where household_id = household and plan_id = target_plan and list = 'weekly' and checked_at is null
    and (also_for_plan is not null or hand_note is not null)
    and item_id not in (select (line ->> 'item_id')::uuid from jsonb_array_elements(lines) as line);

  -- And a line this week had merged into, that it no longer needs, isn't handed to it later.
  update public.list_items set also_for_plan = null
  where household_id = household and also_for_plan = target_plan and checked_at is null
    and item_id not in (select (line ->> 'item_id')::uuid from jsonb_array_elements(lines) as line);

  delete from public.list_items
  where plan_id = target_plan and list = 'weekly' and checked_at is null
    and item_id not in (select (line ->> 'item_id')::uuid from jsonb_array_elements(lines) as line);

  insert into public.list_items as existing (household_id, item_id, list, source, quantity, note, plan_id)
  select household, (line ->> 'item_id')::uuid, 'weekly',
         case when (line ->> 'staple')::boolean then 'staple' else 'plan' end::public.list_item_source,
         nullif(btrim(line ->> 'quantity'), ''), nullif(btrim(line ->> 'note'), ''), target_plan
  from jsonb_array_elements(lines) as line
  where not exists (
    select 1 from public.list_items bought
    where bought.plan_id = target_plan and bought.item_id = (line ->> 'item_id')::uuid
      and bought.checked_at is not null
      and (nullif(btrim(line ->> 'note'), '') is null
           or position(btrim(line ->> 'note') in coalesce(bought.note, '')) > 0)
      -- A weekly line bought is bought. A pivot line only covered one dish, so more of it may still be needed.
      and (bought.list = 'weekly'
           or (bought.quantity is not distinct from nullif(btrim(line ->> 'quantity'), '')
               and (line ->> 'staple')::boolean is not true))
  )
  on conflict (household_id, list, item_id) where checked_at is null do update
    -- This week's own line: its amount and note are rebuilt, keeping every note that came from elsewhere. A hand-added line,
    -- or another week's, keeps its own and gains any new note, which that week's update will keep.
    set quantity = case when existing.plan_id = target_plan then excluded.quantity else existing.quantity end,
        note = case when existing.plan_id = target_plan then public.merge_line_notes(existing.kept_note, excluded.note)
                    else public.merge_line_notes(existing.note, excluded.note) end,
        kept_note = case when existing.plan_id = target_plan then existing.kept_note
                         else public.merge_line_notes(existing.kept_note, excluded.note) end,
        also_for_plan = case when existing.plan_id is distinct from target_plan and existing.plan_id is not null
                             then target_plan else existing.also_for_plan end;

  -- This week's nights are rewritten from the lines, so a dropped item or a night no longer needing it loses its row.
  delete from public.list_item_nights
  where plan_night_id in (select id from public.plan_nights where plan_id = target_plan);

  insert into public.list_item_nights (household_id, list_item_id, plan_night_id)
  select distinct household, open_line.id, night.id
  from jsonb_array_elements(lines) as line
  cross join lateral jsonb_array_elements_text(
    case when jsonb_typeof(line -> 'night_ids') = 'array' then line -> 'night_ids' else '[]'::jsonb end
  ) as night_id
  join public.plan_nights night on night.id = night_id::uuid and night.plan_id = target_plan
  join public.list_items open_line
    on open_line.household_id = household and open_line.list = 'weekly'
   and open_line.item_id = (line ->> 'item_id')::uuid and open_line.checked_at is null;

  update public.plans set approved_at = now() where id = target_plan;
end;
$$;
