-- A weekly line is one per item, so when next week lists an item this week's line already has, it merges into this week's
-- line. If this week then drops the item, Update the list deleted the line, and next week's need went with it (#209).
-- also_for_plan remembers the other week that merged in; when the owning week drops the item, the line goes to that week
-- instead, with its notes from elsewhere and no amount, since the amount was this week's. That week's next Update the list
-- rebuilds it. A line with a note added by hand (hand_note, written only by add_to_list) stays as a hand-added line.
-- kept_note can't decide that: it also holds other weeks' notes, and a line kept for one would stay when no week needs it.
-- Only one other week is remembered: two weeks ahead merging into the same line is rare, and the later one wins.
-- Lines open today have no hand_note, so they go as before when their week drops them.
alter table public.list_items
  add column also_for_plan uuid,
  add column hand_note text check (char_length(hand_note) <= 400),
  add constraint list_items_also_for_plan_fkey foreign key (also_for_plan, household_id)
    references public.plans (id, household_id);

create index list_items_also_for_plan_idx on public.list_items (also_for_plan) where also_for_plan is not null;

-- approve_plan and add_to_list run as the caller. Any member could already insert a line with any plan and delete any line.
grant insert (also_for_plan, hand_note), update (also_for_plan, plan_id, hand_note) on public.list_items to authenticated;

create or replace function public.add_to_list(
  target_household uuid,
  target_item uuid,
  target_list public.list_kind,
  item_urgency public.list_urgency default 'whenever',
  item_source public.list_item_source default 'manual',
  item_note text default null,
  line_id uuid default null,
  item_quantity text default null,
  item_plan uuid default null
)
returns public.list_items
language sql security invoker set search_path = ''
as $$
  insert into public.list_items as existing (id, household_id, item_id, list, urgency, source, note, kept_note, hand_note,
                                             quantity, plan_id)
  values (coalesce(line_id, gen_random_uuid()), target_household, target_item, target_list, item_urgency,
          item_source, item_note, nullif(btrim(item_note), ''), nullif(btrim(item_note), ''), item_quantity, item_plan)
  on conflict (household_id, list, item_id) where checked_at is null do update
    set urgency = case when excluded.urgency = 'tonight' then 'tonight'::public.list_urgency else existing.urgency end,
        note = public.merge_line_notes(existing.note, excluded.note),
        kept_note = public.merge_line_notes(existing.kept_note, excluded.note),
        hand_note = public.merge_line_notes(existing.hand_note, excluded.note),
        quantity = coalesce(existing.quantity, excluded.quantity),
        source = case when existing.source = 'staple' then excluded.source else existing.source end
  returning *;
$$;

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

  update public.plans set approved_at = now() where id = target_plan;
end;
$$;
