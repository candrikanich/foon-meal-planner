-- Update the list replaces the note on a line its own week wrote, so a dish swapped out takes its allergy note with it. But a
-- line is per item, so the same line also gathers notes from elsewhere: another week's Update the list, or a tap that merged
-- into it. Replacing the whole note lost those until their own week was updated again (#197).
-- kept_note holds what came from anywhere but the line's own week. That week's Update the list rebuilds the note from it
-- plus its own; everything else merges into both. The app reads only note.
alter table public.list_items
  add column kept_note text check (char_length(kept_note) <= 400);

-- Lines open today can't tell their own week's text from the rest, so they keep all of it: a stale note over a lost one.
update public.list_items set kept_note = note
where checked_at is null and note is not null and plan_id is not null and list = 'weekly';

-- add_to_list and approve_plan run as the caller. Any member could already write note directly; this is no more than that.
grant insert (kept_note), update (kept_note) on public.list_items to authenticated;

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
  insert into public.list_items as existing (id, household_id, item_id, list, urgency, source, note, kept_note, quantity, plan_id)
  values (coalesce(line_id, gen_random_uuid()), target_household, target_item, target_list, item_urgency,
          item_source, item_note, nullif(btrim(item_note), ''), item_quantity, item_plan)
  on conflict (household_id, list, item_id) where checked_at is null do update
    set urgency = case when excluded.urgency = 'tonight' then 'tonight'::public.list_urgency else existing.urgency end,
        note = public.merge_line_notes(existing.note, excluded.note),
        kept_note = public.merge_line_notes(existing.kept_note, excluded.note),
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
                         else public.merge_line_notes(existing.kept_note, excluded.note) end;

  update public.plans set approved_at = now() where id = target_plan;
end;
$$;
