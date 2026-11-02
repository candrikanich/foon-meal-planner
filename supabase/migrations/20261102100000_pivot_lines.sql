-- What a pivot puts on the quick list (#44).
--
-- 1. Merging into an open line kept the old note and threw away the new one, so an allergy note was lost whenever the line
--    already said something ("Couldn't find it last trip"). Now both stay, newest first and never repeated. The limit rises
--    so two full notes fit (a note can be 140 by itself); past it the oldest text is cut, visibly, rather than failing the add.
-- 2. add_to_list takes an amount, so a pivot line says how much (a line that already has one keeps it), and the plan it was
--    for, since a quick line for this week's dish says nothing about next week's. Only pivot lines carry a plan on the quick
--    list; approve_plan's clear-out now only touches weekly lines.
-- 3. approve_plan's note on a line it doesn't own (hand-added, or another week's) merges too, for the same reason as 1.
-- 4. "Already bought for this week" now sees pivot lines too, when they bought the same amount. Either way, an allergy note
--    the bought line didn't have goes back on: what's in the house isn't what that person can have. A low staple does too.

alter table public.list_items
  drop constraint list_items_note_check,
  add constraint list_items_note_check check (char_length(note) <= 400);

create function public.merge_line_notes(existing text, incoming text)
returns text
language sql immutable set search_path = ''
as $$
  select case
    when nullif(btrim(incoming), '') is null then existing
    when existing is null then incoming
    when position(incoming in existing) > 0 then existing
    when char_length(incoming || '; ' || existing) <= 400 then incoming || '; ' || existing
    else left(incoming || '; ' || existing, 399) || '…'
  end;
$$;

revoke execute on function public.merge_line_notes(text, text) from public, anon;
grant execute on function public.merge_line_notes(text, text) to authenticated;

drop function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text, uuid);

create function public.add_to_list(
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
  insert into public.list_items as existing (id, household_id, item_id, list, urgency, source, note, quantity, plan_id)
  values (coalesce(line_id, gen_random_uuid()), target_household, target_item, target_list, item_urgency,
          item_source, item_note, item_quantity, item_plan)
  on conflict (household_id, list, item_id) where checked_at is null do update
    set urgency = case when excluded.urgency = 'tonight' then 'tonight'::public.list_urgency else existing.urgency end,
        note = public.merge_line_notes(existing.note, excluded.note),
        quantity = coalesce(existing.quantity, excluded.quantity)
  returning *;
$$;

revoke execute on function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text, uuid, text, uuid)
  from public, anon;
grant execute on function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text, uuid, text, uuid)
  to authenticated;

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
    -- Refresh only what this week's plan wrote; a hand-added line, or another week's, keeps its own and gains any new note.
    set quantity = case when existing.plan_id = target_plan then excluded.quantity else existing.quantity end,
        note = case when existing.plan_id = target_plan then excluded.note
                    else public.merge_line_notes(existing.note, excluded.note) end;

  update public.plans set approved_at = now() where id = target_plan;
end;
$$;
